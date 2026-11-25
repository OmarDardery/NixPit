const STATE = "/var/lib/nixpit";
const FLAKE_FILE = `${STATE}/hypervisor.flake`;

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const logsEl = $("logs");
const repoSel = $("repo-select");
const fileSel = $("file-select");
const rawEl = $("raw-editor");

let profiles = [];
let currentGuests = { containers: {}, vms: {} };
let envPairs = [];
let busy = false;

const BUSY_IDS = ["btn-gc", "btn-sync", "btn-diff", "btn-push", "btn-validate", "btn-deploy", "btn-rollback"];
const setBusy = state => {
  busy = state;
  BUSY_IDS.forEach(id => { const el = $(id); if (el) el.disabled = state; });
};

function toast(msg, kind = "") {
  const el = document.createElement("div");
  el.className = `toast ${kind ? `toast-${kind}` : ""}`;
  el.textContent = msg;
  $("toasts").appendChild(el);
  setTimeout(() => el.remove(), 2600);
}

const log = m => { logsEl.textContent += m; logsEl.scrollTop = logsEl.scrollHeight; };

async function spawnText(cmd) {
  return cockpit.spawn(cmd, { superuser: "require", err: "out" });
}

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

function switchTab(tabId) {
  document.querySelectorAll(".tab, .panel").forEach(el => el.classList.remove("active"));
  document.querySelector(`.tab[data-tab="${tabId}"]`).classList.add("active");
  $(tabId).classList.add("active");
}
document.querySelectorAll(".tab").forEach(btn => { btn.onclick = () => switchTab(btn.dataset.tab); });
$("btn-clear-logs").onclick = () => { logsEl.textContent = ""; };

function updateOnboarding() {
  const hasProfiles = profiles.length > 0;
  const hasCloned = profiles.some(p => p.cloned);
  $("onboarding").style.display = (hasProfiles && hasCloned) ? "none" : "block";
  $("step-profile").style.opacity = hasProfiles ? "0.45" : "1";
  $("step-sync").style.opacity = hasCloned ? "0.45" : "1";
}

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

async function getFlakeUri() {
  const f = await cockpit.file(FLAKE_FILE, { superuser: "require" }).read();
  return (f && f.trim()) || "path:/etc/nixpit#nixpit";
}

// --- Profiles (nixpit-repo) ---
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
  if (profiles.length) {
    await loadGuestsJson();
    await loadRawFile();
  } else {
    currentGuests = { containers: {}, vms: {} };
    renderGuestCards();
  }
  refreshGitBadge();
}

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

// --- Workloads ---
async function loadGuestsJson() {
  if (!repoSel.value) return;
  const path = `${STATE}/repos/${repoSel.value}/guests.json`;
  const raw = await cockpit.file(path, { superuser: "require" }).read();
  try {
    currentGuests = raw ? JSON.parse(raw) : { containers: {}, vms: {} };
    currentGuests.containers ||= {};
    currentGuests.vms ||= {};
  } catch (e) {
    log(`✖ Invalid JSON in ${path}: ${e.message}\n`);
    currentGuests = { containers: {}, vms: {} };
  }
  renderGuestCards();
}

async function getUnitState(unit) {
  try { return (await cockpit.spawn(["systemctl", "is-active", unit], { err: "ignore" })).trim(); }
  catch { return "inactive"; }
}

async function getVmState(name) {
  try { return (await cockpit.spawn(["virsh", "domstate", name], { superuser: "require", err: "ignore" })).trim() || "unknown"; }
  catch { return "not defined"; }
}

function parsePublicHostPort(portSpec) {
  const addrPart = String(portSpec || "").split("/")[0];
  const v6 = addrPart.match(/^\[([^\]]+)\]:(\d+):(\d+)$/);
  if (v6) return v6[1] === "::1" ? null : v6[2];
  const parts = addrPart.split(":");
  if (parts.length === 2) return parts[0];
  if (parts.length === 3 && parts[0] !== "127.0.0.1" && parts[0] !== "::1") return parts[1];
  return null;
}

async function renderGuestCards() {
  const containerEl = $("guest-cards");
  const host = window.location.hostname;
  const cards = [];

  for (const [name, c] of Object.entries(currentGuests.containers)) {
    const unit = `podman-${name}.service`;
    const state = await getUnitState(unit);
    const pill = state === "active" ? "pill-ok" : (state === "failed" ? "pill-err" : "");
    const firstPort = (c.ports || []).map(parsePublicHostPort).find(Boolean);
    const isLocal = /\.(local|lan|home\.arpa)$/i.test(c.domain || "");
    const uiUrl = c.domain ? `${isLocal ? "http" : "https"}://${c.domain}` : (firstPort ? `http://${host}:${firstPort}` : null);
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>${esc(name)}</strong>
          <span class="pill ${pill}"><span class="dot ${state === "active" ? "dot-live" : ""}"></span>${esc(state)}</span>
        </div>
        <div class="muted mono" style="margin:0.45rem 0 0.7rem;word-break:break-all;">
          ${esc(c.image)}${c.network ? ` · ${esc(c.network)}` : ""}
        </div>
        <div class="row">
          <button class="sm" data-edit-c="${esc(name)}">Edit</button>
          <button class="sm" data-restart="${esc(unit)}">Restart</button>
          <button class="sm" data-logs="${esc(unit)}">Logs</button>
          ${uiUrl ? `<a href="${esc(uiUrl)}" target="_blank" rel="noopener noreferrer" style="color:var(--blue);font-size:0.78rem;text-decoration:none;margin-left:auto;">Open ↗</a>` : ""}
          <button class="sm danger" data-del-type="containers" data-del-name="${esc(name)}">Del</button>
        </div>
      </div>
    `);
  }

  for (const [name, vm] of Object.entries(currentGuests.vms)) {
    const state = await getVmState(name);
    const pill = state === "running" ? "pill-ok" : (state === "shut off" ? "" : "pill-warn");
    cards.push(`
      <div class="card-subtle">
        <div class="row between">
          <strong>VM · ${esc(name)}</strong>
          <span class="pill ${pill}"><span class="dot ${state === "running" ? "dot-live" : ""}"></span>${esc(state)}</span>
        </div>
        <div class="muted" style="margin:0.45rem 0 0.7rem;">
          ${esc(vm.vcpus || 2)} vCPU · ${esc(vm.memoryGiB || 2)} GiB · ${esc(vm.disk)} · ${esc(vm.network || "default")}
        </div>
        <div class="row">
          <button class="sm" data-edit-vm="${esc(name)}">Edit</button>
          <button class="sm success" data-vm-action="start" data-vm-name="${esc(name)}">Start</button>
          <button class="sm" data-vm-action="shutdown" data-vm-name="${esc(name)}">Shutdown</button>
          <button class="sm warn" data-vm-action="destroy" data-vm-name="${esc(name)}">Force Off</button>
          <button class="sm danger" data-del-type="vms" data-del-name="${esc(name)}">Del</button>
        </div>
      </div>
    `);
  }

  if (repoSel.value) {
    for (const f of ["docker-compose.yml", "compose.yaml"]) {
      if ((await cockpit.file(`${STATE}/repos/${repoSel.value}/${f}`, { superuser: "require" }).read()) !== null) {
        const unit = `homelab-compose-${repoSel.value}.service`;
        const state = await getUnitState(unit);
        const pill = state === "active" ? "pill-ok" : (state === "failed" ? "pill-err" : "");
        cards.push(`
          <div class="card-subtle">
            <div class="row between">
              <strong>Compose · ${esc(repoSel.value)}</strong>
              <span class="pill ${pill}"><span class="dot ${state === "active" ? "dot-live" : ""}"></span>${esc(state)}</span>
            </div>
            <div class="muted mono" style="margin:0.45rem 0 0.7rem;">${esc(f)}</div>
            <div class="row">
              <button class="sm primary" data-restart="${esc(unit)}">Rebuild / Restart</button>
              <button class="sm" data-logs="${esc(unit)}">Logs</button>
            </div>
          </div>
        `);
        break;
      }
    }
  }

  containerEl.innerHTML = cards.join("") || `<p class="muted">No workloads declared in this profile.</p>`;
  containerEl.querySelectorAll("[data-edit-c]").forEach(b => { b.onclick = () => editContainer(b.dataset.editC); });
  containerEl.querySelectorAll("[data-edit-vm]").forEach(b => { b.onclick = () => editVm(b.dataset.editVm); });
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
    b.onclick = async () => { delete currentGuests[b.dataset.delType][b.dataset.delName]; await persistGuestsJson(); };
  });
}

function editContainer(name) {
  const c = currentGuests.containers[name];
  if (!c) return;
  $("f-name").value = name;
  $("f-image").value = c.image || "";
  $("f-ports").value = (c.ports || []).join(", ");
  $("f-volumes").value = (c.volumes || []).join(", ");
  $("f-network").value = c.network || "";
  $("f-domain").value = c.domain || "";
  $("f-secret").value = c.secretName || "";
  $("f-usb").value = (c.usbPassthrough || []).join(", ");
}

function editVm(name) {
  const vm = currentGuests.vms[name];
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

async function persistGuestsJson() {
  if (!repoSel.value) return;
  const path = `${STATE}/repos/${repoSel.value}/guests.json`;
  const text = JSON.stringify(currentGuests, null, 2) + "\n";
  await cockpit.file(path, { superuser: "require" }).replace(text);
  toast("Saved guests.json", "ok");
  await loadGuestsJson();
  if (fileSel.value === "guests.json") rawEl.value = text;
  await loadProfiles();
}

$("btn-save-guest").onclick = async () => {
  const name = $("f-name").value.trim();
  const image = $("f-image").value.trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !image) return toast("Service Name and OCI Image required", "err");
  const split = id => $(id).value.split(",").map(s => s.trim()).filter(Boolean);
  const updated = {
    ...(currentGuests.containers[name] || {}),
    image,
    ports: split("f-ports"),
    volumes: split("f-volumes"),
    usbPassthrough: split("f-usb")
  };
  for (const [k, id] of [["network", "f-network"], ["domain", "f-domain"], ["secretName", "f-secret"]]) {
    const v = $(id).value.trim();
    if (v) updated[k] = v; else delete updated[k];
  }
  currentGuests.containers[name] = updated;
  await persistGuestsJson();
};

$("btn-gen-uuid").onclick = () => { $("vm-uuid").value = crypto.randomUUID(); };

$("btn-save-vm").onclick = async () => {
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

  currentGuests.vms[name] = {
    ...(currentGuests.vms[name] || {}),
    uuid, vcpus, memoryGiB, disk, network: net, usbPassthrough: usb,
    active: currentGuests.vms[name]?.active ?? true
  };
  await persistGuestsJson();
  switchTab("tab-guests");
};

$("btn-refresh-status").onclick = renderGuestCards;

// --- USB Scanners ---
async function scanSerialUsb() {
  const picker = $("usb-picker");
  try {
    const devs = (await spawnText(["sh", "-c", "ls -1 /dev/serial/by-id/* 2>/dev/null || true"])).trim().split("\n").filter(Boolean);
    picker.innerHTML = devs.length ? devs.map(d => `<option value="${esc(d)}">${esc(d.split("/").pop())}</option>`).join("") : "<option value=''>None found</option>";
  } catch { picker.innerHTML = "<option value=''>Scan failed</option>"; }
}

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

// --- Secrets (nixpit-secrets + sops-nix) ---
async function loadSecretsOverview() {
  try {
    const info = JSON.parse((await spawnText(["nixpit-secrets", "list"])) || "{}");
    $("age-pubkey").textContent = info.agePublicKey || "Unavailable";
    $("sops-summary").textContent =
      `Runtime (/run/nixpit/secrets): ${(info.runtimeActive || []).join(", ") || "none"} · sops-nix (/run/secrets/nixpit): ${(info.sopsNixSecrets || []).join(", ") || "none"}`;
    const sel = $("secret-select");
    const prev = sel.value;
    const names = info.hostSecrets || [];
    sel.innerHTML = names.map(n => `<option value="${esc(n)}">${esc(n)}</option>`).join("");
    if (prev && names.includes(prev)) sel.value = prev;
    if (names.length) await loadSecretFile();
    else { envPairs = []; renderEnvRows(); }
  } catch (e) {
    $("age-pubkey").textContent = `Error: ${e.message}`;
  }
}

async function loadSecretFile() {
  const name = $("secret-select").value;
  if (!name) return;
  try {
    const raw = await spawnText(["nixpit-secrets", "get", name]);
    envPairs = raw.split("\n").filter(l => l.includes("=") && !l.trim().startsWith("#")).map(l => {
      const i = l.indexOf("=");
      return { k: l.slice(0, i).trim(), v: l.slice(i + 1).trim() };
    });
  } catch { envPairs = []; }
  renderEnvRows();
}

function renderEnvRows() {
  const wrap = $("env-rows");
  wrap.innerHTML = envPairs.map((p, i) => `
    <div class="row" style="margin-bottom:0.45rem;">
      <input data-env-k="${i}" value="${esc(p.k)}" placeholder="KEY" class="mono" style="width:220px;" />
      <input data-env-v="${i}" type="password" value="${esc(p.v)}" placeholder="VALUE" class="mono" style="flex:1;" />
      <button class="sm" data-env-toggle="${i}">Show</button>
      <button class="sm danger" data-env-del="${i}">×</button>
    </div>
  `).join("");
  wrap.querySelectorAll("[data-env-k]").forEach(el => { el.onchange = () => { envPairs[el.dataset.envK].k = el.value; }; });
  wrap.querySelectorAll("[data-env-v]").forEach(el => { el.onchange = () => { envPairs[el.dataset.envV].v = el.value; }; });
  wrap.querySelectorAll("[data-env-toggle]").forEach(b => {
    b.onclick = () => {
      const inp = b.previousElementSibling;
      inp.type = inp.type === "password" ? "text" : "password";
      b.textContent = inp.type === "password" ? "Show" : "Hide";
    };
  });
  wrap.querySelectorAll("[data-env-del]").forEach(b => {
    b.onclick = () => { envPairs.splice(Number(b.dataset.envDel), 1); renderEnvRows(); };
  });
}

$("btn-copy-age").onclick = () => { navigator.clipboard.writeText($("age-pubkey").textContent); toast("Copied Age public key", "ok"); };
$("btn-copy-sops-yaml").onclick = async () => { navigator.clipboard.writeText(await spawnText(["nixpit-secrets", "sops-config"])); toast("Copied .sops.yaml", "ok"); };
$("btn-sync-secrets").onclick = async () => { await run(["systemctl", "restart", "nixpit-secrets.service"]); loadSecretsOverview(); };
$("secret-select").onchange = loadSecretFile;
$("btn-add-env-row").onclick = () => { envPairs.push({ k: "", v: "" }); renderEnvRows(); };

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
  renderEnvRows();
};

$("btn-save-secret").onclick = async () => {
  const name = $("secret-select").value;
  if (!name) return toast("Select or create a secret first", "err");
  const lines = [];
  for (const p of envPairs) {
    const k = p.k.trim();
    if (!k) continue;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) return toast(`Invalid key: ${k}`, "err");
    if (/[\r\n]/.test(p.v)) return toast(`Newlines disallowed in ${k}`, "err");
    lines.push(`${k}=${p.v}`);
  }
  if (!lines.length) return toast("Add at least one KEY=VALUE entry", "err");
  const proc = cockpit.spawn(["nixpit-secrets", "set", name], { superuser: "require", err: "out" });
  proc.input(lines.join("\n") + "\n");
  await proc;
  toast(`Encrypted ${name}.sops.env`, "ok");
  await loadSecretsOverview();
};

$("btn-del-secret").onclick = async () => {
  const name = $("secret-select").value;
  if (!name || !confirm(`Delete encrypted secret ${name}?`)) return;
  await run(["nixpit-secrets", "delete", name]);
  await loadSecretsOverview();
};

// --- Raw Editor ---
async function loadRawFile() {
  if (!repoSel.value) return;
  rawEl.value = (await cockpit.file(`${STATE}/repos/${repoSel.value}/${fileSel.value}`, { superuser: "require" }).read()) || "";
}
repoSel.onchange = () => { loadGuestsJson(); loadRawFile(); refreshGitBadge(); };
fileSel.onchange = loadRawFile;
$("btn-save-raw").onclick = async () => {
  if (!repoSel.value) return;
  const path = `${STATE}/repos/${repoSel.value}/${fileSel.value}`;
  await cockpit.file(path, { superuser: "require" }).replace(rawEl.value);
  toast(`Saved ${fileSel.value}`, "ok");
  if (fileSel.value === "guests.json") loadGuestsJson();
  await loadProfiles();
};

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
  renderGuestCards();
  refreshHealth();
  loadSecretsOverview();
};
$("btn-rollback").onclick = async () => {
  if (!confirm("Roll back OS generation only?")) return;
  await run(["nixos-rebuild", "switch", "--rollback"]);
  renderGuestCards();
  refreshHealth();
};

loadProfiles();
loadSecretsOverview();
scanSerialUsb();
scanLsusb();
refreshHealth();
