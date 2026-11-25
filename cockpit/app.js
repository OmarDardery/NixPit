// Cockpit client logic for NixPit Workloads.
// Manages pure Nix modules (`nix/*.nix`, `workloads.nix`), Compose stacks, Dockerfiles,
// and repo-committed SOPS env vars via `nixpit-repo`, `nixpit-secrets`, `virsh`, and `nixos-rebuild`.

const STATE = "/var/lib/nixpit";
const FLAKE_FILE = `${STATE}/hypervisor.flake`;

const $ = id => document.getElementById(id);
// Escape untrusted strings before rendering into HTML templates to prevent XSS.
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const logsEl = $("logs");
const repoSel = $("repo-select");
const fileSel = $("file-select");
const rawEl = $("raw-editor");

let profiles = [];
let repoData = { nixFiles: [], customNixModules: [], composeFile: "", hasDockerfile: false, hasSopsYaml: false, secrets: [], containers: {}, vms: {} };
let envPairs = [];
let containerEnvPairs = [];
let busy = false;

const BUSY_IDS = ["btn-gc", "btn-sync", "btn-diff", "btn-push", "btn-validate", "btn-deploy", "btn-rollback"];
// Lock/unlock top-level mutating buttons so concurrent Git/NixOS runs cannot collide.
const setBusy = state => {
  busy = state;
  BUSY_IDS.forEach(id => { const el = $(id); if (el) el.disabled = state; });
};

// Display a floating toast notification that auto-dismisses after 2.6 seconds.
function toast(msg, kind = "") {
  const el = document.createElement("div");
  el.className = `toast ${kind ? `toast-${kind}` : ""}`;
  el.textContent = msg;
  $("toasts").appendChild(el);
  setTimeout(() => el.remove(), 2600);
}

// Append streamed command output to the bottom terminal pane and auto-scroll.
const log = m => { logsEl.textContent += m; logsEl.scrollTop = logsEl.scrollHeight; };

// Execute a privileged command via argument vector and return stdout without streaming to UI logs.
async function spawnText(cmd) {
  return cockpit.spawn(cmd, { superuser: "require", err: "out" });
}

// Run a privileged command while holding the global busy lock and streaming output to #logs.
async function run(cmd, clear = true) {
  if (busy) { toast("Another operation is running", "err"); throw new Error("Busy"); }
  setBusy(true);
  if (clear) logsEl.textContent = `$ ${cmd.join(" ")}\n`;
  try {
    await cockpit.spawn(cmd, { superuser: "require", err: "out" }).stream(log);
    log("\n✔ Done.\n");
    toast("Completed", "ok");
  } catch (e) {
    log(`\n✖ ${e.message}\n`);
    toast(e.message || "Command failed", "err");
    throw e;
  } finally {
    setBusy(false);
  }
}

// Activate a navigation tab and its matching panel section.
function switchTab(tabId) {
  document.querySelectorAll(".tab, .panel").forEach(el => el.classList.remove("active"));
  document.querySelector(`.tab[data-tab="${tabId}"]`).classList.add("active");
  $(tabId).classList.add("active");
}
document.querySelectorAll(".tab").forEach(btn => { btn.onclick = () => switchTab(btn.dataset.tab); });
$("btn-clear-logs").onclick = () => { logsEl.textContent = ""; };

// Format a Nix string literal safely, escaping backslashes, quotes, and `${` interpolations.
const nixStr = s => `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$\{/g, "\\${").replace(/\n/g, "\\n")}"`;
const nixAttr = s => (/^[A-Za-z_][A-Za-z0-9_-]*$/.test(s) ? s : nixStr(s));
const nixList = xs => (xs.length ? `[ ${xs.map(nixStr).join(" ")} ]` : "[]");

// Parse KEY=VALUE dotenv lines into an editable array of { k, v } pairs.
function parseDotenv(raw) {
  return String(raw || "").split("\n").filter(l => l.includes("=") && !l.trim().startsWith("#")).map(l => {
    const i = l.indexOf("=");
    return { k: l.slice(0, i).trim(), v: l.slice(i + 1).trim() };
  });
}

// Validate and serialize { k, v } rows into dotenv lines; returns null if empty, throws on bad key.
function serializeDotenv(pairs) {
  const lines = [];
  for (const p of pairs) {
    const k = p.k.trim();
    if (!k) continue;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) throw new Error(`Invalid key: ${k}`);
    if (/[\r\n]/.test(p.v)) throw new Error(`Newlines disallowed in ${k}`);
    lines.push(`${k}=${p.v}`);
  }
  return lines;
}

// Render masked KEY=VALUE editor rows with show/hide toggles and delete buttons into `wrapId`.
function renderEnvPairList(wrapId, pairs) {
  const wrap = $(wrapId);
  wrap.innerHTML = pairs.map((p, i) => `
    <div class="row" style="margin-bottom:0.45rem;">
      <input data-env-k="${i}" value="${esc(p.k)}" placeholder="KEY" class="mono" style="width:220px;" />
      <input data-env-v="${i}" type="password" value="${esc(p.v)}" placeholder="VALUE" class="mono" style="flex:1;" />
      <button type="button" class="sm" data-env-toggle="${i}">Show</button>
      <button type="button" class="sm danger" data-env-del="${i}">×</button>
    </div>
  `).join("");
  wrap.querySelectorAll("[data-env-k]").forEach(el => { el.onchange = () => { pairs[el.dataset.envK].k = el.value; }; });
  wrap.querySelectorAll("[data-env-v]").forEach(el => { el.onchange = () => { pairs[el.dataset.envV].v = el.value; }; });
  wrap.querySelectorAll("[data-env-toggle]").forEach(b => {
    b.onclick = () => {
      const inp = b.previousElementSibling;
      inp.type = inp.type === "password" ? "text" : "password";
      b.textContent = inp.type === "password" ? "Show" : "Hide";
    };
  });
  wrap.querySelectorAll("[data-env-del]").forEach(b => {
    b.onclick = () => { pairs.splice(Number(b.dataset.envDel), 1); renderEnvPairList(wrapId, pairs); };
  });
}

// Show the onboarding checklist until at least one repo profile is added and cloned locally.
function updateOnboarding() {
  const hasProfiles = profiles.length > 0;
  const hasCloned = profiles.some(p => p.cloned);
  $("onboarding").style.display = (hasProfiles && hasCloned) ? "none" : "block";
  $("step-profile").style.opacity = hasProfiles ? "0.45" : "1";
  $("step-sync").style.opacity = hasCloned ? "0.45" : "1";
}

// Query host generation number, root filesystem usage, and /nix/store size in parallel.
async function refreshHealth() {
  const queries = [
    ["stat-gen", ["sh", "-c", "readlink /nix/var/nix/profiles/system | grep -oE '[0-9]+' || echo '?'"], s => `#${s}`],
    ["stat-disk", ["sh", "-c", "df -h / | awk 'NR==2 {print $3 \" / \" $2 \" (\" $5 \")\"}'"], s => s],
    ["stat-store", ["sh", "-c", "du -sh /nix/store 2>/dev/null | awk '{print $1}' || echo '?'"], s => s]
  ];
  await Promise.all(queries.map(async ([id, cmd, fmt]) => {
    try { $(id).textContent = fmt((await spawnText(cmd)).trim()); }
    catch { $(id).textContent = "?"; }
  }));
  refreshGitBadge();
}

// Update the topbar Git status pill for the currently selected repo profile.
function refreshGitBadge() {
  const el = $("stat-git");
  const p = profiles.find(x => x.name === repoSel.value);
  if (!p) {
    el.className = "pill";
    el.innerHTML = `<span class="dot"></span><span>No profile</span>`;
    return;
  }
  if (!p.cloned) {
    el.className = "pill pill-warn";
    el.innerHTML = `<span class="dot"></span><span>${esc(p.branch)} · not synced</span>`;
    return;
  }
  el.className = `pill ${p.dirty ? "pill-warn" : "pill-ok"}`;
  el.innerHTML = `<span class="dot"></span><span>${esc(p.branch)} · ${esc(p.commit || "HEAD")}${p.dirty ? " · dirty" : ""}</span>`;
}

$("btn-gc").onclick = async () => { await run(["nix-collect-garbage"]); refreshHealth(); };

// Read the configured host flake URI (defaults to /etc/nixpit#nixpit created by install.sh).
async function getFlakeUri() {
  const f = await cockpit.file(FLAKE_FILE, { superuser: "require" }).read();
  return (f && f.trim()) || "path:/etc/nixpit#nixpit";
}

// Ensure a subdirectory exists inside the active repo checkout before writing a file into it.
async function ensureRepoDir(sub = "") {
  const target = sub ? `${STATE}/repos/${repoSel.value}/${sub}` : `${STATE}/repos/${repoSel.value}`;
  await spawnText(["install", "-d", "-m", "0755", target]);
}

// Write a `.nix` workload file cleanly and verify Nix syntax before marking UI state ready.
async function writeRepoFile(relPath, content) {
  if (!repoSel.value) throw new Error("Select a repository profile first");
  if (relPath.includes("/")) await ensureRepoDir(relPath.split("/").slice(0, -1).join("/"));
  const fullPath = `${STATE}/repos/${repoSel.value}/${relPath}`;
  await cockpit.file(fullPath, { superuser: "require" }).replace(content);
  if (relPath.endsWith(".nix")) {
    await spawnText(["nix-instantiate", "--parse", fullPath]);
  }
}

// Load repository profiles via `nixpit-repo list`, render profile cards with per-repo SSH keys,
// populate the active profile dropdown, and refresh workload/secrets/editor views.
async function loadProfiles() {
  try {
    profiles = JSON.parse((await spawnText(["nixpit-repo", "list"])) || "[]");
  } catch (e) {
    log(`✖ Failed to load profiles: ${e.message}\n`);
    profiles = [];
  }

  const listEl = $("repo-list");
  listEl.innerHTML = profiles.length
    ? profiles.map(p => `
        <div class="item-row">
          <div class="row between">
            <div class="row">
              <strong>${esc(p.name)}</strong>
              <span class="pill ${p.cloned ? "pill-ok" : "pill-warn"}"><span class="dot"></span>${esc(p.branch)}${p.commit ? ` @ ${esc(p.commit)}` : " · pending"}</span>
              <code>${esc(p.url)}</code>
            </div>
            <div class="row">
              <button class="sm" data-sync-profile="${esc(p.name)}">Sync</button>
              <button class="sm" data-copy-profile-key="${esc(p.name)}">Copy Key</button>
              <button class="sm warn" data-rotate-key="${esc(p.name)}">Rotate Key</button>
              <button class="sm danger" data-rm-profile="${esc(p.name)}">Remove</button>
            </div>
          </div>
          <div class="muted" style="margin-top:0.45rem;">SSH Key: <code>${esc(p.pubkey || "Not generated")}</code></div>
        </div>
      `).join("")
    : `<p class="muted">No repository profiles configured yet.</p>`;

  listEl.querySelectorAll("[data-sync-profile]").forEach(b => {
    b.onclick = async () => { await run(["nixpit-repo", "sync", b.dataset.syncProfile]); await loadProfiles(); };
  });
  listEl.querySelectorAll("[data-copy-profile-key]").forEach(b => {
    b.onclick = () => {
      const p = profiles.find(x => x.name === b.dataset.copyProfileKey);
      if (p?.pubkey) { navigator.clipboard.writeText(p.pubkey); toast(`Copied SSH key for ${p.name}`, "ok"); }
    };
  });
  listEl.querySelectorAll("[data-rotate-key]").forEach(b => {
    b.onclick = async () => {
      const n = b.dataset.rotateKey;
      if (!confirm(`Rotate SSH deploy key for ${n}?`)) return;
      await run(["nixpit-repo", "keygen", n, "--force"]);
      await loadProfiles();
    };
  });
  listEl.querySelectorAll("[data-rm-profile]").forEach(b => {
    b.onclick = async () => {
      const n = b.dataset.rmProfile;
      if (!confirm(`Remove profile ${n}?`)) return;
      await run(["nixpit-repo", "remove", n]);
      await loadProfiles();
    };
  });

  const prev = repoSel.value;
  repoSel.innerHTML = profiles.map(p => `<option value="${esc(p.name)}">${esc(p.name)} (${esc(p.branch)})</option>`).join("");
  if (prev && profiles.some(p => p.name === prev)) repoSel.value = prev;

  updateOnboarding();
  await refreshActiveRepo();
  refreshGitBadge();
}

// Refresh inspected workloads, editor file list, and repo-scoped SOPS secrets for the active profile.
async function refreshActiveRepo() {
  const p = profiles.find(x => x.name === repoSel.value);
  if (!p || !p.cloned) {
    repoData = { nixFiles: [], customNixModules: [], composeFile: "", hasDockerfile: false, hasSopsYaml: false, secrets: [], containers: {}, vms: {} };
    populateFileSelect();
    await renderGuestCards();
    await loadSecretsOverview();
    return;
  }
  await loadRepoInspect();
  await loadSecretsOverview();
  await loadRawFile();
}

// Create a new repo profile and auto-generate its dedicated ed25519 SSH key.
$("btn-add-repo").onclick = async () => {
  const name = $("new-repo-name").value.trim();
  const url = $("new-repo-url").value.trim();
  const branch = $("new-repo-branch").value.trim() || "main";
  if (!name || !url) return toast("Profile name and URL required", "err");
  await run(["nixpit-repo", "add", name, url, branch]);
  $("new-repo-name").value = "";
  $("new-repo-url").value = "";
  await loadProfiles();
};

// Inspect `.nix` workload files, Compose/Dockerfiles, and `secrets/*.sops.env` via `nixpit-repo inspect`.
async function loadRepoInspect() {
  if (!repoSel.value) return;
  try {
    repoData = JSON.parse((await spawnText(["nixpit-repo", "inspect", repoSel.value])) || "{}");
    repoData.nixFiles ||= [];
    repoData.customNixModules ||= [];
    repoData.secrets ||= [];
    repoData.containers ||= {};
    repoData.vms ||= {};
  } catch (e) {
    log(`✖ Failed to inspect ${repoSel.value}: ${e.message}\n`);
    repoData = { nixFiles: [], customNixModules: [], composeFile: "", hasDockerfile: false, hasSopsYaml: false, secrets: [], containers: {}, vms: {} };
  }
  populateFileSelect();
  await renderGuestCards();
}

// Populate the Editor tab dropdown with standard files plus every `.nix` file in the active repo.
function populateFileSelect(preferred = "") {
  const prev = preferred || fileSel.value;
  const base = ["workloads.nix", "compose.yaml", "docker-compose.yml", "Dockerfile", ".sops.yaml"];
  const all = [...new Set([...(repoData.nixFiles || []), ...base])];
  fileSel.innerHTML = all.map(f => `<option value="${esc(f)}">${esc(f)}</option>`).join("");
  if (prev && all.includes(prev)) fileSel.value = prev;
  else if (repoData.nixFiles?.length) fileSel.value = repoData.nixFiles[0];
}

// Query systemd service state ("active", "failed", or "inactive") for a Podman/Compose/Dockerfile unit.
async function getUnitState(unit) {
  try { return (await cockpit.spawn(["systemctl", "is-active", unit], { err: "ignore" })).trim(); }
  catch { return "inactive"; }
}

// Query Libvirt domain state ("running", "shut off", or "not defined") via virsh.
async function getVmState(name) {
  try { return (await cockpit.spawn(["virsh", "domstate", name], { superuser: "require", err: "ignore" })).trim() || "unknown"; }
  catch { return "not defined"; }
}

// Extract the public host port from a Docker/Podman port spec, skipping loopback-only bindings.
function parsePublicHostPort(portSpec) {
  const addrPart = String(portSpec || "").split("/")[0];
  const v6 = addrPart.match(/^\[([^\]]+)\]:(\d+):(\d+)$/);
  if (v6) return v6[1] === "::1" ? null : v6[2];
  const parts = addrPart.split(":");
  if (parts.length === 2) return parts[0];
  if (parts.length === 3 && parts[0] !== "127.0.0.1" && parts[0] !== "::1") return parts[1];
  return null;
}

// Open a specific repo file inside the Editor tab.
function openInEditor(relPath) {
  populateFileSelect(relPath);
  loadRawFile();
  switchTab("tab-code");
}

// Open a specific repo SOPS secret inside the Secrets tab.
async function openSecretEditor(secretName) {
  switchTab("tab-secrets");
  const sel = $("secret-select");
  if (!Array.from(sel.options).some(o => o.value === secretName)) {
    const opt = document.createElement("option");
    opt.value = secretName;
    opt.textContent = secretName;
    sel.appendChild(opt);
    sel.value = secretName;
    envPairs = [{ k: "", v: "" }];
    updateSecretPathNote(secretName);
    renderEnvPairList("env-rows", envPairs);
  } else {
    sel.value = secretName;
    await loadSecretFile();
  }
}

// Build and render cards for Nix containers, KVM VMs, Compose stacks, Dockerfiles, and custom `.nix`.
async function renderGuestCards() {
  const containerEl = $("guest-cards");
  const host = window.location.hostname;
  const cards = [];
  const hasSecret = name => (repoData.secrets || []).includes(name);

  for (const [name, c] of Object.entries(repoData.containers || {})) {
    const unit = `podman-${name}.service`;
    const state = await getUnitState(unit);
    const pill = state === "active" ? "pill-ok" : (state === "failed" ? "pill-err" : "");
    const firstPort = (c.ports || []).map(parsePublicHostPort).find(Boolean);
    const isLocal = /\.(local|lan|home\.arpa)$/i.test(c.domain || "");
    const uiUrl = c.domain ? `${isLocal ? "http" : "https"}://${c.domain}` : (firstPort ? `http://${host}:${firstPort}` : null);
    const secName = c.secretName || name;
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>${esc(name)}</strong>
          <span class="pill ${pill}"><span class="dot ${state === "active" ? "dot-live" : ""}"></span>${esc(state)}</span>
        </div>
        <div class="muted mono" style="margin:0.45rem 0 0.7rem;word-break:break-all;">
          ${esc(c.image)}${c.network ? ` · ${esc(c.network)}` : ""} · ${esc(c._file || `nix/${name}.nix`)}${hasSecret(secName) ? ` · sops:${esc(secName)}` : ""}
        </div>
        <div class="row">
          <button class="sm" data-edit-c="${esc(name)}">Edit</button>
          <button class="sm" data-sec-open="${esc(secName)}">Secrets</button>
          <button class="sm" data-restart="${esc(unit)}">Restart</button>
          <button class="sm" data-logs="${esc(unit)}">Logs</button>
          ${uiUrl ? `<a href="${esc(uiUrl)}" target="_blank" rel="noopener noreferrer" style="color:var(--blue);font-size:0.78rem;text-decoration:none;margin-left:auto;">Open ↗</a>` : ""}
          <button class="sm danger" data-del-nix="${esc(c._file || "")}" data-del-kind="container" data-del-name="${esc(name)}">Del</button>
        </div>
      </div>
    `);
  }

  for (const [name, vm] of Object.entries(repoData.vms || {})) {
    const state = await getVmState(name);
    const pill = state === "running" ? "pill-ok" : (state === "shut off" ? "" : "pill-warn");
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>VM · ${esc(name)}</strong>
          <span class="pill ${pill}"><span class="dot ${state === "running" ? "dot-live" : ""}"></span>${esc(state)}</span>
        </div>
        <div class="muted" style="margin:0.45rem 0 0.7rem;">
          ${esc(vm.vcpus || 2)} vCPU · ${esc(vm.memoryGiB || 2)} GiB · ${esc(vm.disk)} · ${esc(vm.network || "default")} · ${esc(vm._file || `nix/${name}.nix`)}
        </div>
        <div class="row">
          <button class="sm" data-edit-vm="${esc(name)}">Edit</button>
          <button class="sm success" data-vm-action="start" data-vm-name="${esc(name)}">Start</button>
          <button class="sm" data-vm-action="shutdown" data-vm-name="${esc(name)}">Shutdown</button>
          <button class="sm warn" data-vm-action="destroy" data-vm-name="${esc(name)}">Force Off</button>
          <button class="sm danger" data-del-nix="${esc(vm._file || "")}" data-del-kind="vm" data-del-name="${esc(name)}">Del</button>
        </div>
      </div>
    `);
  }

  if (repoSel.value && repoData.composeFile) {
    const unit = `homelab-compose-${repoSel.value}.service`;
    const state = await getUnitState(unit);
    const pill = state === "active" ? "pill-ok" : (state === "failed" ? "pill-err" : "");
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>Compose · ${esc(repoSel.value)}</strong>
          <span class="pill ${pill}"><span class="dot ${state === "active" ? "dot-live" : ""}"></span>${esc(state)}</span>
        </div>
        <div class="muted mono" style="margin:0.45rem 0 0.7rem;">
          ${esc(repoData.composeFile)}${hasSecret("compose") ? " · sops:compose" : ""}
        </div>
        <div class="row">
          <button class="sm" data-edit-file="${esc(repoData.composeFile)}">Edit Compose</button>
          <button class="sm" data-sec-open="compose">Edit Env Vars</button>
          <button class="sm primary" data-restart="${esc(unit)}">Rebuild / Restart</button>
          <button class="sm" data-logs="${esc(unit)}">Logs</button>
        </div>
      </div>
    `);
  } else if (repoSel.value && repoData.hasDockerfile) {
    const unit = `homelab-dockerfile-${repoSel.value}.service`;
    const state = await getUnitState(unit);
    const pill = state === "active" ? "pill-ok" : (state === "failed" ? "pill-err" : "");
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>Dockerfile · ${esc(repoSel.value)}</strong>
          <span class="pill ${pill}"><span class="dot ${state === "active" ? "dot-live" : ""}"></span>${esc(state)}</span>
        </div>
        <div class="muted mono" style="margin:0.45rem 0 0.7rem;">
          Dockerfile${hasSecret("dockerfile") ? " · sops:dockerfile" : ""}
        </div>
        <div class="row">
          <button class="sm" data-edit-file="Dockerfile">Edit Dockerfile</button>
          <button class="sm" data-sec-open="dockerfile">Edit Env Vars</button>
          <button class="sm primary" data-restart="${esc(unit)}">Rebuild / Restart</button>
          <button class="sm" data-logs="${esc(unit)}">Logs</button>
        </div>
      </div>
    `);
  }

  for (const mod of repoData.customNixModules || []) {
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>Nix Module</strong>
          <span class="pill"><span class="dot"></span>${esc(mod)}</span>
        </div>
        <div class="muted" style="margin:0.45rem 0 0.7rem;">Raw NixOS module imported at evaluation.</div>
        <div class="row">
          <button class="sm" data-edit-file="${esc(mod)}">Open in Editor</button>
        </div>
      </div>
    `);
  }

  containerEl.innerHTML = cards.join("") || `<p class="muted">No workloads declared in this profile yet. Add a Nix container, VM, Compose file, or Dockerfile.</p>`;
  containerEl.querySelectorAll("[data-edit-c]").forEach(b => { b.onclick = () => editContainer(b.dataset.editC); });
  containerEl.querySelectorAll("[data-edit-vm]").forEach(b => { b.onclick = () => editVm(b.dataset.editVm); });
  containerEl.querySelectorAll("[data-edit-file]").forEach(b => { b.onclick = () => openInEditor(b.dataset.editFile); });
  containerEl.querySelectorAll("[data-sec-open]").forEach(b => { b.onclick = () => openSecretEditor(b.dataset.secOpen); });
  containerEl.querySelectorAll("[data-restart]").forEach(b => {
    b.onclick = async () => { await run(["systemctl", "restart", b.dataset.restart]); renderGuestCards(); };
  });
  containerEl.querySelectorAll("[data-logs]").forEach(b => {
    b.onclick = () => run(["journalctl", "-u", b.dataset.logs, "-n", "60", "--no-pager"]);
  });
  containerEl.querySelectorAll("[data-vm-action]").forEach(b => {
    b.onclick = async () => {
      if (b.dataset.vmAction === "destroy" && !confirm(`Force power off VM ${b.dataset.vmName}?`)) return;
      await run(["virsh", b.dataset.vmAction, b.dataset.vmName]);
      renderGuestCards();
    };
  });
  containerEl.querySelectorAll("[data-del-name]").forEach(b => {
    b.onclick = async () => {
      const name = b.dataset.delName;
      const rel = b.dataset.delNix;
      const expected = `nix/${name}.nix`;
      if (rel && rel !== expected) {
        toast(`Edit ${rel} directly to remove ${name}`, "err");
        return openInEditor(rel);
      }
      if (!confirm(`Delete ${expected} from ${repoSel.value}?`)) return;
      await spawnText(["rm", "-f", `${STATE}/repos/${repoSel.value}/${expected}`]);
      toast(`Removed ${expected}`, "ok");
      await loadProfiles();
    };
  });
}

// Populate container form fields AND decrypt any existing repo SOPS env vars into the inline editor.
async function editContainer(name) {
  const c = (repoData.containers || {})[name];
  if (!c) return;
  $("f-name").value = name;
  $("f-image").value = c.image || "";
  $("f-ports").value = (c.ports || []).join(", ");
  $("f-volumes").value = (c.volumes || []).join(", ");
  $("f-network").value = c.network || "";
  $("f-domain").value = c.domain || "";
  $("f-secret").value = c.secretName || "";
  $("f-usb").value = (c.usbPassthrough || []).join(", ");

  const secName = c.secretName || name;
  if ((repoData.secrets || []).includes(secName)) {
    try {
      containerEnvPairs = parseDotenv(await spawnText(["nixpit-secrets", "repo-get", repoSel.value, secName]));
    } catch { containerEnvPairs = []; }
  } else {
    containerEnvPairs = [];
  }
  renderEnvPairList("container-env-rows", containerEnvPairs);
}

// Populate VM editor fields from an inspected VM declaration and switch to the VMs tab.
function editVm(name) {
  const vm = (repoData.vms || {})[name];
  if (!vm) return;
  $("vm-name").value = name;
  $("vm-uuid").value = vm.uuid || "";
  $("vm-vcpus").value = vm.vcpus || 2;
  $("vm-mem").value = vm.memoryGiB || 2;
  $("vm-disk").value = vm.disk || "";
  $("vm-net").value = vm.network || "default";
  $("vm-usb").value = (vm.usbPassthrough || []).join(", ");
  switchTab("tab-vms");
}

// Generate clean NixOS module source for a single container in `nix/<name>.nix`.
function renderContainerNix(name, cfg) {
  const lines = [
    "# Generated by NixPit Cockpit UI",
    "{ ... }:",
    "{",
    `  services.nixpit.workloads.containers.${nixAttr(name)} = {`,
    `    image = ${nixStr(cfg.image)};`,
    `    repo = ${nixStr(repoSel.value)};`
  ];
  if (cfg.secretName) lines.push(`    secretName = ${nixStr(cfg.secretName)};`);
  if (cfg.ports.length) lines.push(`    ports = ${nixList(cfg.ports)};`);
  if (cfg.volumes.length) lines.push(`    volumes = ${nixList(cfg.volumes)};`);
  if (cfg.network) lines.push(`    network = ${nixStr(cfg.network)};`);
  if (cfg.domain) lines.push(`    domain = ${nixStr(cfg.domain)};`);
  if (cfg.usbPassthrough.length) lines.push(`    usbPassthrough = ${nixList(cfg.usbPassthrough)};`);
  lines.push("  };", "}", "");
  return lines.join("\n");
}

// Generate clean NixOS module source for a single KVM VM in `nix/<name>.nix`.
function renderVmNix(name, vm) {
  const lines = [
    "# Generated by NixPit Cockpit UI",
    "{ ... }:",
    "{",
    `  services.nixpit.workloads.vms.${nixAttr(name)} = {`,
    `    uuid = ${nixStr(vm.uuid)};`,
    `    vcpus = ${vm.vcpus};`,
    `    memoryGiB = ${vm.memoryGiB};`,
    `    disk = ${nixStr(vm.disk)};`,
    `    network = ${nixStr(vm.network)};`
  ];
  if (vm.usbPassthrough.length) lines.push(`    usbPassthrough = ${nixList(vm.usbPassthrough)};`);
  lines.push(`    active = ${vm.active ? "true" : "false"};`, "  };", "}", "");
  return lines.join("\n");
}

// Save container form into `nix/<name>.nix` + encrypt inline env vars into `secrets/<secret>.sops.env`.
async function saveContainer(pushAfter = false) {
  if (!repoSel.value) return toast("Select a repository profile first", "err");
  const name = $("f-name").value.trim();
  const image = $("f-image").value.trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !image) return toast("Service Name and OCI Image required", "err");
  const split = id => $(id).value.split(",").map(s => s.trim()).filter(Boolean);
  const secretName = $("f-secret").value.trim();
  if (secretName && !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(secretName)) return toast("Invalid Secret Name", "err");

  let envLines;
  try { envLines = serializeDotenv(containerEnvPairs); }
  catch (e) { return toast(e.message, "err"); }

  const nixCode = renderContainerNix(name, {
    image,
    secretName,
    ports: split("f-ports"),
    volumes: split("f-volumes"),
    network: $("f-network").value.trim(),
    domain: $("f-domain").value.trim(),
    usbPassthrough: split("f-usb")
  });
  await writeRepoFile(`nix/${name}.nix`, nixCode);

  const targetSecret = secretName || name;
  if (envLines.length) {
    const proc = cockpit.spawn(["nixpit-secrets", "repo-set", repoSel.value, targetSecret], { superuser: "require", err: "out" });
    proc.input(envLines.join("\n") + "\n");
    await proc;
  }

  toast(`Saved nix/${name}.nix${envLines.length ? ` + secrets/${targetSecret}.sops.env` : ""}`, "ok");
  if (pushAfter) {
    await run(["nixpit-repo", "push", repoSel.value, `Update container ${name}`]);
  }
  await loadProfiles();
}

$("btn-add-container-env").onclick = () => { containerEnvPairs.push({ k: "", v: "" }); renderEnvPairList("container-env-rows", containerEnvPairs); };
$("btn-save-guest").onclick = () => saveContainer(false);
$("btn-save-push-guest").onclick = () => saveContainer(true);
$("btn-gen-uuid").onclick = () => { $("vm-uuid").value = crypto.randomUUID(); };

// Validate VM inputs (name, disk, UUID, vCPUs, RAM, network, USB IDs) and write `nix/<name>.nix`.
async function saveVm(pushAfter = false) {
  if (!repoSel.value) return toast("Select a repository profile first", "err");
  const name = $("vm-name").value.trim();
  const disk = $("vm-disk").value.trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !disk || disk.includes("..")) return toast("Valid VM Name and Disk required", "err");
  const uuid = $("vm-uuid").value.trim() || crypto.randomUUID();
  if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(uuid)) return toast("Invalid UUID", "err");
  const vcpus = parseInt($("vm-vcpus").value, 10);
  const memoryGiB = parseInt($("vm-mem").value, 10);
  if (!Number.isInteger(vcpus) || vcpus < 1 || !Number.isInteger(memoryGiB) || memoryGiB < 1) return toast("vCPUs and Memory must be >= 1", "err");
  const net = $("vm-net").value.trim() || "default";
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(net)) return toast("Invalid network name", "err");
  const usb = $("vm-usb").value.split(",").map(s => s.trim()).filter(Boolean);
  if (usb.some(vp => !/^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$/.test(vp))) return toast("USB format must be xxxx:xxxx", "err");

  const existing = (repoData.vms || {})[name];
  await writeRepoFile(`nix/${name}.nix`, renderVmNix(name, {
    uuid, vcpus, memoryGiB, disk, network: net, usbPassthrough: usb,
    active: existing?.active ?? true
  }));
  toast(`Saved nix/${name}.nix`, "ok");
  if (pushAfter) {
    await run(["nixpit-repo", "push", repoSel.value, `Update VM ${name}`]);
  }
  await loadProfiles();
  switchTab("tab-guests");
}

$("btn-save-vm").onclick = () => saveVm(false);
$("btn-save-push-vm").onclick = () => saveVm(true);
$("btn-refresh-status").onclick = loadRepoInspect;

// Scan /dev/serial/by-id/* for stable USB serial device paths used by container passthrough.
async function scanSerialUsb() {
  const picker = $("usb-picker");
  try {
    const devs = (await spawnText(["sh", "-c", "ls -1 /dev/serial/by-id/* 2>/dev/null || true"])).trim().split("\n").filter(Boolean);
    picker.innerHTML = devs.length ? devs.map(d => `<option value="${esc(d)}">${esc(d.split("/").pop())}</option>`).join("") : "<option value=''>None found</option>";
  } catch { picker.innerHTML = "<option value=''>Scan failed</option>"; }
}

// Parse `lsusb` output into vendor:product pairs for Libvirt VM hostdev USB passthrough.
async function scanLsusb() {
  const picker = $("lsusb-picker");
  try {
    const opts = (await spawnText(["lsusb"])).trim().split("\n").map(l => {
      const m = l.match(/ID\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s*(.*)/);
      return m ? `<option value="${esc(m[1])}">${esc(m[1])} — ${esc(m[2])}</option>` : "";
    }).filter(Boolean);
    picker.innerHTML = opts.length ? opts.join("") : "<option value=''>None found</option>";
  } catch { picker.innerHTML = "<option value=''>Unavailable</option>"; }
}

const appendField = (pickerId, fieldId) => {
  const v = $(pickerId).value;
  if (!v) return;
  $(fieldId).value = $(fieldId).value ? `${$(fieldId).value}, ${v}` : v;
};
$("btn-scan-usb").onclick = scanSerialUsb;
$("btn-add-usb").onclick = () => appendField("usb-picker", "f-usb");
$("btn-scan-lsusb").onclick = scanLsusb;
$("btn-add-vm-usb").onclick = () => appendField("lsusb-picker", "vm-usb");

function updateSecretPathNote(name) {
  const repo = repoSel.value || "<repo>";
  const s = name || "<name>";
  $("secret-path-note").innerHTML = `Encrypted in Git at <code>${esc(repo)}/secrets/${esc(s)}.sops.env</code> · decrypted on deploy by <code>sops-nix</code> into RAM at <code>/run/secrets/nixpit/${esc(repo)}/${esc(s)}</code> (0400).`;
}

// Query host Age pubkey + repo-scoped `secrets/*.sops.env` files and load the selected secret.
async function loadSecretsOverview() {
  try {
    const pub = (await spawnText(["nixpit-secrets", "pubkey"])).trim();
    $("age-pubkey").textContent = pub || "Unavailable";
    const p = profiles.find(x => x.name === repoSel.value);
    const sel = $("secret-select");
    if (!p || !p.cloned) {
      $("sops-summary").textContent = "Sync a repository profile first to edit repo-committed SOPS secrets.";
      sel.innerHTML = "";
      envPairs = [];
      renderEnvPairList("env-rows", envPairs);
      updateSecretPathNote("");
      return;
    }
    const info = JSON.parse((await spawnText(["nixpit-secrets", "repo-list", p.name])) || "{}");
    $("sops-summary").textContent =
      `Repo .sops.yaml: ${info.hasSopsYaml ? "present" : "auto-created on save"} · Repo secrets: ${(info.secrets || []).join(", ") || "none"} · Active sops-nix (/run/secrets/nixpit/${p.name}): ${(info.activeSopsNix || []).join(", ") || "none"}`;
    const prev = sel.value;
    const names = info.secrets || [];
    sel.innerHTML = names.map(n => `<option value="${esc(n)}">${esc(n)}</option>`).join("");
    if (prev && names.includes(prev)) sel.value = prev;
    if (names.length) await loadSecretFile();
    else { envPairs = []; renderEnvPairList("env-rows", envPairs); updateSecretPathNote(""); }
  } catch (e) {
    $("age-pubkey").textContent = `Error: ${e.message}`;
  }
}

// Decrypt `<repo>/secrets/<name>.sops.env` to memory via `nixpit-secrets repo-get`.
async function loadSecretFile() {
  const name = $("secret-select").value;
  updateSecretPathNote(name);
  if (!name || !repoSel.value) return;
  try {
    envPairs = parseDotenv(await spawnText(["nixpit-secrets", "repo-get", repoSel.value, name]));
  } catch { envPairs = []; }
  renderEnvPairList("env-rows", envPairs);
}

$("btn-copy-age").onclick = () => { navigator.clipboard.writeText($("age-pubkey").textContent); toast("Copied Age public key", "ok"); };
$("btn-copy-sops-yaml").onclick = async () => { navigator.clipboard.writeText(await spawnText(["nixpit-secrets", "sops-config"])); toast("Copied .sops.yaml", "ok"); };
$("btn-init-sops-yaml").onclick = async () => {
  if (!repoSel.value) return toast("Select a synced repo profile first", "err");
  await run(["nixpit-secrets", "ensure-sops-yaml", repoSel.value]);
  await loadSecretsOverview();
  await loadProfiles();
};
$("secret-select").onchange = loadSecretFile;
$("btn-add-env-row").onclick = () => { envPairs.push({ k: "", v: "" }); renderEnvPairList("env-rows", envPairs); };

$("btn-new-secret").onclick = () => {
  const name = $("new-secret-name").value.trim().replace(/(\.sops)?\.env$/, "");
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name)) return toast("Invalid secret name", "err");
  const sel = $("secret-select");
  if (!Array.from(sel.options).some(o => o.value === name)) {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    sel.appendChild(opt);
  }
  sel.value = name;
  $("new-secret-name").value = "";
  envPairs = [{ k: "", v: "" }];
  updateSecretPathNote(name);
  renderEnvPairList("env-rows", envPairs);
};

// Encrypt KEY=VALUE pairs directly into `<repo>/secrets/<name>.sops.env` (+ `.sops.yaml`), optionally push.
async function saveRepoSecret(pushAfter = false) {
  if (!repoSel.value) return toast("Select a repository profile first", "err");
  const name = $("secret-select").value;
  if (!name) return toast("Select or create a secret first", "err");
  let lines;
  try { lines = serializeDotenv(envPairs); }
  catch (e) { return toast(e.message, "err"); }
  if (!lines.length) return toast("Add at least one KEY=VALUE entry", "err");

  const proc = cockpit.spawn(["nixpit-secrets", "repo-set", repoSel.value, name], { superuser: "require", err: "out" });
  proc.input(lines.join("\n") + "\n");
  await proc;
  toast(`Encrypted ${repoSel.value}/secrets/${name}.sops.env`, "ok");

  if (pushAfter) {
    await run(["nixpit-repo", "push", repoSel.value, `Update SOPS secret ${name}`]);
  }
  await loadProfiles();
}

$("btn-save-secret").onclick = () => saveRepoSecret(false);
$("btn-save-push-secret").onclick = () => saveRepoSecret(true);
$("btn-del-secret").onclick = async () => {
  const name = $("secret-select").value;
  if (!repoSel.value || !name || !confirm(`Delete ${repoSel.value}/secrets/${name}.sops.env?`)) return;
  await run(["nixpit-secrets", "repo-delete", repoSel.value, name]);
  await loadProfiles();
};

// Load the chosen workload file from the active repo profile into the raw editor.
async function loadRawFile() {
  if (!repoSel.value || !fileSel.value) { rawEl.value = ""; return; }
  rawEl.value = (await cockpit.file(`${STATE}/repos/${repoSel.value}/${fileSel.value}`, { superuser: "require" }).read()) || "";
}
repoSel.onchange = async () => { await refreshActiveRepo(); refreshGitBadge(); };
fileSel.onchange = loadRawFile;

$("btn-new-nix-file").onclick = () => {
  let rel = $("new-nix-file").value.trim().replace(/^\/+/, "");
  if (!rel) return toast("Enter filename like nix/app.nix", "err");
  if (!rel.endsWith(".nix")) rel += ".nix";
  if (!rel.startsWith("nix/") && rel !== "workloads.nix" && rel !== "default.nix") rel = `nix/${rel}`;
  if (!/^(workloads\.nix|default\.nix|nix\/[a-zA-Z0-9][a-zA-Z0-9._-]*\.nix)$/.test(rel)) return toast("Invalid .nix path", "err");
  populateFileSelect(rel);
  if (!Array.from(fileSel.options).some(o => o.value === rel)) {
    const opt = document.createElement("option");
    opt.value = rel;
    opt.textContent = rel;
    fileSel.appendChild(opt);
    fileSel.value = rel;
  }
  $("new-nix-file").value = "";
  rawEl.value = "{ pkgs, lib, ... }:\n{\n  # services.nixpit.workloads.containers.myapp = { image = \"...\"; };\n}\n";
};

async function saveRawEditor(pushAfter = false) {
  if (!repoSel.value || !fileSel.value) return toast("Select a profile and file", "err");
  await writeRepoFile(fileSel.value, rawEl.value);
  toast(`Saved ${fileSel.value}`, "ok");
  if (pushAfter) {
    await run(["nixpit-repo", "push", repoSel.value, `Update ${fileSel.value}`]);
  }
  await loadProfiles();
}

$("btn-save-raw").onclick = () => saveRawEditor(false);
$("btn-save-push-raw").onclick = () => saveRawEditor(true);

// --- Topbar Actions ---
$("btn-sync").onclick = async () => { if (repoSel.value) { await run(["nixpit-repo", "sync", repoSel.value]); await loadProfiles(); } };
$("btn-diff").onclick = () => repoSel.value && run(["nixpit-repo", "diff", repoSel.value]);
$("btn-push").onclick = async () => {
  if (!repoSel.value) return;
  const msg = $("commit-msg").value.trim() || "Update NixPit configs";
  await run(["nixpit-repo", "push", repoSel.value, msg]);
  $("commit-msg").value = "";
  await loadProfiles();
};
$("btn-validate").onclick = async () => run(["nixos-rebuild", "dry-build", "--impure", "--flake", await getFlakeUri()]);
$("btn-deploy").onclick = async () => {
  await run(["nixos-rebuild", "switch", "--impure", "--flake", await getFlakeUri()]);
  await loadProfiles();
  refreshHealth();
};
$("btn-rollback").onclick = async () => {
  if (!confirm("Roll back OS generation only?")) return;
  await run(["nixos-rebuild", "switch", "--rollback"]);
  await loadProfiles();
  refreshHealth();
};

loadProfiles();
scanSerialUsb();
scanLsusb();
refreshHealth();
