const STATE = "/var/lib/nixpit";
const FLAKE_FILE = `${STATE}/hypervisor.flake`;

const logsEl = document.getElementById("logs");
const repoSelectEl = document.getElementById("repo-select");
const fileSelectEl = document.getElementById("file-select");
const rawEditorEl = document.getElementById("raw-editor");

let profiles = [];
let currentGuests = { containers: {}, vms: {} };
let envPairs = [];
let busy = false;

const BUSY_BTN_IDS = [
  "btn-gc", "btn-sync", "btn-diff", "btn-push",
  "btn-validate", "btn-deploy", "btn-rollback"
];

function setBusy(state) {
  busy = state;
  BUSY_BTN_IDS.forEach(id => {
    const el = document.getElementById(id);
    if (el) el.disabled = state;
  });
}

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const log = m => { logsEl.textContent += m; logsEl.scrollTop = logsEl.scrollHeight; };

const run = async (cmd, clear = true) => {
  if (busy) {
    log("\n✖ Another operation is currently running.\n");
    throw new Error("Operation already in progress");
  }
  setBusy(true);
  if (clear) logsEl.textContent = `$ ${cmd.join(" ")}\n`;
  try {
    await cockpit.spawn(cmd, { superuser: "require", err: "out" }).stream(log);
    log("\n✔ Done.\n");
  } catch (e) {
    log(`\n✖ ${e.message}\n`);
    throw e;
  } finally {
    setBusy(false);
  }
};

function switchTab(tabId) {
  document.querySelectorAll(".tab, .panel").forEach(el => el.classList.remove("active"));
  document.querySelector(`.tab[data-tab="${tabId}"]`).classList.add("active");
  document.getElementById(tabId).classList.add("active");
}
document.querySelectorAll(".tab").forEach(btn => { btn.onclick = () => switchTab(btn.dataset.tab); });
document.getElementById("btn-clear-logs").onclick = () => { logsEl.textContent = ""; };

function updateOnboarding() {
  const hasProfiles = profiles.length > 0;
  const hasCloned = profiles.some(p => p.cloned);
  document.getElementById("onboarding").style.display = (hasProfiles && hasCloned) ? "none" : "block";
  document.getElementById("step-profile").style.opacity = hasProfiles ? "0.5" : "1";
  document.getElementById("step-sync").style.opacity = hasCloned ? "0.5" : "1";
}

// --- Host Health Strip ---
async function refreshHealth() {
  try {
    const gen = await cockpit.spawn(["sh", "-c", "readlink /nix/var/nix/profiles/system | grep -oE '[0-9]+' || echo '?'"], { superuser: "require" });
    document.getElementById("stat-gen").textContent = `#${gen.trim()}`;
  } catch { document.getElementById("stat-gen").textContent = "?"; }

  try {
    const df = await cockpit.spawn(["sh", "-c", `df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}'`]);
    document.getElementById("stat-disk").textContent = df.trim();
  } catch { document.getElementById("stat-disk").textContent = "?"; }

  try {
    const store = await cockpit.spawn(["sh", "-c", "du -sh /nix/store 2>/dev/null | awk '{print $1}' || echo '?'"], { superuser: "require" });
    document.getElementById("stat-store").textContent = store.trim();
  } catch { document.getElementById("stat-store").textContent = "?"; }

  refreshGitBadge();
}

function refreshGitBadge() {
  const badge = document.getElementById("stat-git");
  const p = profiles.find(x => x.name === repoSelectEl.value);
  if (!p) {
    badge.textContent = "no profile";
    badge.className = "badge badge-unk";
    return;
  }
  if (!p.cloned) {
    badge.textContent = `${p.branch} • not synced`;
    badge.className = "badge badge-warn";
    return;
  }
  badge.textContent = `${p.branch} • ${p.commit || "HEAD"} • ${p.dirty ? "dirty" : "clean"}`;
  badge.className = `badge ${p.dirty ? "badge-warn" : "badge-ok"}`;
}

document.getElementById("btn-gc").onclick = async () => {
  await run(["nix-collect-garbage"]);
  refreshHealth();
};

async function getFlakeUri() {
  const f = await cockpit.file(FLAKE_FILE, { superuser: "require" }).read();
  return (f && f.trim()) || "path:/etc/nixpit#nixpit";
}

// --- Repo Profiles (nixpit-repo) ---
async function loadProfiles() {
  try {
    const raw = await cockpit.spawn(["nixpit-repo", "list"], { superuser: "require", err: "out" });
    profiles = JSON.parse(raw || "[]");
  } catch (e) {
    log(`✖ Failed to load repo profiles: ${e.message}\n`);
    profiles = [];
  }

  const listEl = document.getElementById("repo-list");
  listEl.innerHTML = profiles.length
    ? profiles.map(p => `
        <div class="item-row">
          <div class="row between">
            <span>
              <strong>${esc(p.name)}</strong>
              <span class="badge ${p.cloned ? "badge-ok" : "badge-warn"}">${esc(p.branch)}${p.commit ? ` @ ${esc(p.commit)}` : " (not synced)"}</span>
              — <code>${esc(p.url)}</code>
            </span>
            <div class="row">
              <button data-sync-profile="${esc(p.name)}">Sync</button>
              <button data-copy-profile-key="${esc(p.name)}">Copy Key</button>
              <button class="warn" data-rotate-key="${esc(p.name)}">Rotate Key</button>
              <button class="danger" data-rm-profile="${esc(p.name)}">Remove</button>
            </div>
          </div>
          <div style="margin-top:0.35rem;font-size:0.78rem;color:#999;">
            SSH Key: <code>${esc(p.pubkey || "Not generated")}</code>
          </div>
        </div>
      `).join("")
    : "<p style='color:#888;'>No repository profiles added yet.</p>";

  listEl.querySelectorAll("[data-sync-profile]").forEach(btn => {
    btn.onclick = async () => {
      await run(["nixpit-repo", "sync", btn.dataset.syncProfile]);
      await loadProfiles();
    };
  });
  listEl.querySelectorAll("[data-copy-profile-key]").forEach(btn => {
    btn.onclick = () => {
      const p = profiles.find(x => x.name === btn.dataset.copyProfileKey);
      if (p && p.pubkey) {
        navigator.clipboard.writeText(p.pubkey);
        log(`✔ Copied SSH public key for profile ${p.name}.\n`);
      }
    };
  });
  listEl.querySelectorAll("[data-rotate-key]").forEach(btn => {
    btn.onclick = async () => {
      const name = btn.dataset.rotateKey;
      if (!confirm(`Rotate SSH deploy key for profile ${name}? Update the deploy key on your Git host afterward.`)) return;
      await run(["nixpit-repo", "keygen", name, "--force"]);
      await loadProfiles();
    };
  });
  listEl.querySelectorAll("[data-rm-profile]").forEach(btn => {
    btn.onclick = async () => {
      const name = btn.dataset.rmProfile;
      if (!confirm(`Remove profile ${name}? Local checkout and key files will be kept unless purged via CLI.`)) return;
      await run(["nixpit-repo", "remove", name]);
      await loadProfiles();
    };
  });

  const prev = repoSelectEl.value;
  repoSelectEl.innerHTML = profiles.map(p => `<option value="${esc(p.name)}">${esc(p.name)} (${esc(p.branch)})</option>`).join("");
  if (prev && profiles.some(p => p.name === prev)) repoSelectEl.value = prev;

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

document.getElementById("btn-add-repo").onclick = async () => {
  const nameInput = document.getElementById("new-repo-name");
  const urlInput = document.getElementById("new-repo-url");
  const branchInput = document.getElementById("new-repo-branch");
  const name = nameInput.value.trim();
  const url = urlInput.value.trim();
  const branch = branchInput.value.trim() || "main";
  if (!name || !url) return log("✖ Profile Name and Git Repository URL are required.\n");
  await run(["nixpit-repo", "add", name, url, branch]);
  nameInput.value = "";
  urlInput.value = "";
  await loadProfiles();
};

// --- Guests JSON & Live Status ---
async function loadGuestsJson() {
  if (!repoSelectEl.value) return;
  const path = `${STATE}/repos/${repoSelectEl.value}/guests.json`;
  const raw = await cockpit.file(path, { superuser: "require" }).read();
  try {
    currentGuests = raw ? JSON.parse(raw) : { containers: {}, vms: {} };
    currentGuests.containers = currentGuests.containers || {};
    currentGuests.vms = currentGuests.vms || {};
  } catch (e) {
    log(`✖ Invalid JSON in ${path}: ${e.message}\n`);
    currentGuests = { containers: {}, vms: {} };
  }
  renderGuestCards();
}

async function getUnitState(unit) {
  try {
    const out = await cockpit.spawn(["systemctl", "is-active", unit], { err: "ignore" });
    return out.trim();
  } catch {
    return "inactive";
  }
}

async function getVmState(name) {
  try {
    const out = await cockpit.spawn(["virsh", "domstate", name], { superuser: "require", err: "ignore" });
    return out.trim() || "unknown";
  } catch {
    return "not defined";
  }
}

function parsePublicHostPort(portSpec) {
  const addrPart = String(portSpec || "").split("/")[0];
  const v6 = addrPart.match(/^\[([^\]]+)\]:(\d+):(\d+)$/);
  if (v6) {
    if (v6[1] === "::1") return null;
    return v6[2];
  }
  const parts = addrPart.split(":");
  if (parts.length === 2) return parts[0];
  if (parts.length === 3 && parts[0] !== "127.0.0.1" && parts[0] !== "::1") return parts[1];
  return null;
}

async function hasComposeFile(repoName) {
  for (const f of ["docker-compose.yml", "compose.yaml"]) {
    const content = await cockpit.file(`${STATE}/repos/${repoName}/${f}`, { superuser: "require" }).read();
    if (content !== null) return f;
  }
  return null;
}

async function renderGuestCards() {
  const containerEl = document.getElementById("guest-cards");
  const host = window.location.hostname;
  const cards = [];

  for (const [name, c] of Object.entries(currentGuests.containers)) {
    const unit = `podman-${name}.service`;
    const state = await getUnitState(unit);
    const badge = state === "active" ? "badge-ok" : (state === "failed" ? "badge-err" : "badge-unk");
    const firstPort = (c.ports || []).map(parsePublicHostPort).find(Boolean);
    const isLocalDomain = /\.(local|lan|home\.arpa)$/i.test(c.domain || "");
    const uiUrl = c.domain
      ? `${isLocalDomain ? "http" : "https"}://${c.domain}`
      : (firstPort ? `http://${host}:${firstPort}` : null);
    cards.push(`
      <div class="card" style="margin:0;background:#181818;">
        <div class="row between">
          <strong>${esc(name)}</strong>
          <span class="badge ${badge}">${esc(state)}</span>
        </div>
        <div style="font-size:0.78rem;color:#999;margin:0.35rem 0;word-break:break-all;">
          ${esc(c.image)}${c.network ? ` • net: ${esc(c.network)}` : ""}
        </div>
        <div class="row">
          <button data-edit-c="${esc(name)}">Edit</button>
          <button data-restart="${esc(unit)}">Restart</button>
          <button data-logs="${esc(unit)}">Logs</button>
          ${uiUrl ? `<a href="${esc(uiUrl)}" target="_blank" rel="noopener noreferrer" style="color:#6cb4ee;font-size:0.82rem;">Open ↗</a>` : ""}
          <button class="danger" data-del-type="containers" data-del-name="${esc(name)}">Del</button>
        </div>
      </div>
    `);
  }

  for (const [name, vm] of Object.entries(currentGuests.vms)) {
    const vmState = await getVmState(name);
    const vmBadge = vmState === "running"
      ? "badge-ok"
      : (vmState === "shut off" ? "badge-unk" : "badge-warn");
    cards.push(`
      <div class="card" style="margin:0;background:#181818;">
        <div class="row between">
          <strong>VM: ${esc(name)}</strong>
          <span class="badge ${vmBadge}">${esc(vmState)}</span>
        </div>
        <div style="font-size:0.78rem;color:#999;margin:0.35rem 0;">
          ${esc(vm.vcpus || 2)} vCPU • ${esc(vm.memoryGiB || 2)} GiB • Disk: ${esc(vm.disk)} • Net: ${esc(vm.network || "default")}
          ${(vm.usbPassthrough || []).length ? ` • USB: ${esc(vm.usbPassthrough.join(", "))}` : ""}
        </div>
        <div class="row">
          <button data-edit-vm="${esc(name)}">Edit</button>
          <button class="success" data-vm-action="start" data-vm-name="${esc(name)}">Start</button>
          <button data-vm-action="shutdown" data-vm-name="${esc(name)}">Shutdown</button>
          <button class="warn" data-vm-action="destroy" data-vm-name="${esc(name)}">Force Off</button>
          <button class="danger" data-del-type="vms" data-del-name="${esc(name)}">Del</button>
        </div>
      </div>
    `);
  }

  if (repoSelectEl.value) {
    const composeFile = await hasComposeFile(repoSelectEl.value);
    if (composeFile) {
      const unit = `homelab-compose-${repoSelectEl.value}.service`;
      const state = await getUnitState(unit);
      const badge = state === "active" ? "badge-ok" : (state === "failed" ? "badge-err" : "badge-unk");
      cards.push(`
        <div class="card" style="margin:0;background:#181818;border-color:#2e7d32;">
          <div class="row between">
            <strong>Compose: ${esc(repoSelectEl.value)}</strong>
            <span class="badge ${badge}">${esc(state)}</span>
          </div>
          <div style="font-size:0.78rem;color:#999;margin:0.35rem 0;">File: ${esc(composeFile)} (Podman Compose)</div>
          <div class="row">
            <button class="primary" data-restart="${esc(unit)}">Rebuild / Restart</button>
            <button data-logs="${esc(unit)}">Logs</button>
          </div>
        </div>
      `);
    }
  }

  containerEl.innerHTML = cards.join("") || "<p style='color:#888;'>No guests declared in this profile yet.</p>";

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
      const action = b.dataset.vmAction;
      const vmName = b.dataset.vmName;
      if (action === "destroy" && !confirm(`Force power off VM ${vmName}?`)) return;
      await run(["virsh", action, vmName]);
      renderGuestCards();
    };
  });
  containerEl.querySelectorAll("[data-del-name]").forEach(b => {
    b.onclick = async () => {
      delete currentGuests[b.dataset.delType][b.dataset.delName];
      await persistGuestsJson();
    };
  });
}

function editContainer(name) {
  const c = currentGuests.containers[name];
  if (!c) return;
  document.getElementById("f-name").value = name;
  document.getElementById("f-image").value = c.image || "";
  document.getElementById("f-ports").value = (c.ports || []).join(", ");
  document.getElementById("f-volumes").value = (c.volumes || []).join(", ");
  document.getElementById("f-network").value = c.network || "";
  document.getElementById("f-domain").value = c.domain || "";
  document.getElementById("f-secret").value = c.secretName || "";
  document.getElementById("f-usb").value = (c.usbPassthrough || []).join(", ");
}

function editVm(name) {
  const vm = currentGuests.vms[name];
  if (!vm) return;
  document.getElementById("vm-name").value = name;
  document.getElementById("vm-uuid").value = vm.uuid || "";
  document.getElementById("vm-vcpus").value = vm.vcpus || 2;
  document.getElementById("vm-mem").value = vm.memoryGiB || 2;
  document.getElementById("vm-disk").value = vm.disk || "";
  document.getElementById("vm-net").value = vm.network || "default";
  document.getElementById("vm-usb").value = (vm.usbPassthrough || []).join(", ");
  switchTab("tab-vms");
}

async function persistGuestsJson() {
  if (!repoSelectEl.value) return;
  const path = `${STATE}/repos/${repoSelectEl.value}/guests.json`;
  const text = JSON.stringify(currentGuests, null, 2) + "\n";
  await cockpit.file(path, { superuser: "require" }).replace(text);
  log(`✔ Saved ${path}\n`);
  await loadGuestsJson();
  if (fileSelectEl.value === "guests.json") rawEditorEl.value = text;
  await loadProfiles();
}

document.getElementById("btn-save-guest").onclick = async () => {
  const name = document.getElementById("f-name").value.trim();
  const image = document.getElementById("f-image").value.trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !image) return log("✖ Service Name and OCI Image are required.\n");
  const split = id => document.getElementById(id).value.split(",").map(s => s.trim()).filter(Boolean);
  const net = document.getElementById("f-network").value.trim();
  const domain = document.getElementById("f-domain").value.trim();
  const secret = document.getElementById("f-secret").value.trim();

  const updated = {
    ...(currentGuests.containers[name] || {}),
    image,
    ports: split("f-ports"),
    volumes: split("f-volumes"),
    usbPassthrough: split("f-usb")
  };
  if (net) updated.network = net; else delete updated.network;
  if (domain) updated.domain = domain; else delete updated.domain;
  if (secret) updated.secretName = secret; else delete updated.secretName;

  currentGuests.containers[name] = updated;
  await persistGuestsJson();
};

document.getElementById("btn-gen-uuid").onclick = () => {
  document.getElementById("vm-uuid").value = crypto.randomUUID();
};

document.getElementById("btn-save-vm").onclick = async () => {
  const name = document.getElementById("vm-name").value.trim();
  const disk = document.getElementById("vm-disk").value.trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !disk || disk.includes("..")) {
    return log("✖ Valid VM Name and Disk Volume are required.\n");
  }
  const uuid = document.getElementById("vm-uuid").value.trim() || crypto.randomUUID();
  if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(uuid)) {
    return log("✖ Invalid VM UUID format.\n");
  }
  const vcpus = parseInt(document.getElementById("vm-vcpus").value, 10);
  const memoryGiB = parseInt(document.getElementById("vm-mem").value, 10);
  if (!Number.isInteger(vcpus) || vcpus < 1 || !Number.isInteger(memoryGiB) || memoryGiB < 1) {
    return log("✖ vCPUs and Memory GiB must be positive integers.\n");
  }
  const net = document.getElementById("vm-net").value.trim() || "default";
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(net)) {
    return log("✖ Invalid VM network/bridge name.\n");
  }
  const usb = document.getElementById("vm-usb").value.split(",").map(s => s.trim()).filter(Boolean);
  if (usb.some(vp => !/^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$/.test(vp))) {
    return log("✖ USB passthrough entries must use vendor:product hex format (e.g. 0bda:8812).\n");
  }

  currentGuests.vms[name] = {
    ...(currentGuests.vms[name] || {}),
    uuid,
    vcpus,
    memoryGiB,
    disk,
    network: net,
    usbPassthrough: usb,
    active: currentGuests.vms[name]?.active ?? true
  };
  await persistGuestsJson();
  switchTab("tab-guests");
};

document.getElementById("btn-refresh-status").onclick = renderGuestCards;

// --- USB Scanners ---
async function scanSerialUsb() {
  const picker = document.getElementById("usb-picker");
  try {
    const out = await cockpit.spawn(["sh", "-c", "ls -1 /dev/serial/by-id/* 2>/dev/null || true"], { superuser: "require" });
    const devs = out.trim().split("\n").filter(Boolean);
    picker.innerHTML = devs.length
      ? devs.map(d => `<option value="${esc(d)}">${esc(d.split("/").pop())}</option>`).join("")
      : "<option value=''>No /dev/serial/by-id devices found</option>";
  } catch { picker.innerHTML = "<option value=''>Scan failed</option>"; }
}

async function scanLsusb() {
  const picker = document.getElementById("lsusb-picker");
  try {
    const out = await cockpit.spawn(["lsusb"], { superuser: "require" });
    const lines = out.trim().split("\n").filter(Boolean);
    const opts = lines.map(l => {
      const m = l.match(/ID\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s*(.*)/);
      return m ? `<option value="${esc(m[1])}">${esc(m[1])} — ${esc(m[2])}</option>` : "";
    }).filter(Boolean);
    picker.innerHTML = opts.length ? opts.join("") : "<option value=''>No USB devices found</option>";
  } catch { picker.innerHTML = "<option value=''>lsusb unavailable</option>"; }
}

document.getElementById("btn-scan-usb").onclick = scanSerialUsb;
document.getElementById("btn-add-usb").onclick = () => {
  const dev = document.getElementById("usb-picker").value;
  if (!dev) return;
  const field = document.getElementById("f-usb");
  field.value = field.value ? `${field.value}, ${dev}` : dev;
};

document.getElementById("btn-scan-lsusb").onclick = scanLsusb;
document.getElementById("btn-add-vm-usb").onclick = () => {
  const vp = document.getElementById("lsusb-picker").value;
  if (!vp) return;
  const field = document.getElementById("vm-usb");
  field.value = field.value ? `${field.value}, ${vp}` : vp;
};

// --- SOPS Secrets (nixpit-secrets + sops-nix) ---
async function loadSecretsOverview() {
  try {
    const raw = await cockpit.spawn(["nixpit-secrets", "list"], { superuser: "require", err: "out" });
    const info = JSON.parse(raw || "{}");
    document.getElementById("age-pubkey").textContent = info.agePublicKey || "Unavailable";
    const rt = (info.runtimeActive || []).join(", ") || "none";
    const sn = (info.sopsNixSecrets || []).join(", ") || "none";
    document.getElementById("sops-summary").textContent =
      `Runtime (/run/nixpit/secrets): ${rt} • sops-nix (/run/secrets/nixpit): ${sn}`;

    const sel = document.getElementById("secret-select");
    const prev = sel.value;
    const names = info.hostSecrets || [];
    sel.innerHTML = names.map(n => `<option value="${esc(n)}">${esc(n)}</option>`).join("");
    if (prev && names.includes(prev)) sel.value = prev;
    if (names.length) await loadSecretFile();
    else { envPairs = []; renderEnvRows(); }
  } catch (e) {
    document.getElementById("age-pubkey").textContent = `Error: ${e.message}`;
  }
}

async function loadSecretFile() {
  const name = document.getElementById("secret-select").value;
  if (!name) return;
  try {
    const raw = await cockpit.spawn(["nixpit-secrets", "get", name], { superuser: "require", err: "out" });
    envPairs = (raw || "").split("\n").filter(l => l.includes("=") && !l.trim().startsWith("#")).map(l => {
      const idx = l.indexOf("=");
      return { k: l.slice(0, idx).trim(), v: l.slice(idx + 1).trim() };
    });
  } catch (e) {
    log(`✖ Failed to decrypt secret ${name}: ${e.message}\n`);
    envPairs = [];
  }
  renderEnvRows();
}

function renderEnvRows() {
  const wrap = document.getElementById("env-rows");
  wrap.innerHTML = envPairs.map((p, i) => `
    <div class="row" style="margin-bottom:0.4rem;">
      <input data-env-k="${i}" value="${esc(p.k)}" placeholder="KEY" style="width:220px;" />
      <input data-env-v="${i}" type="password" value="${esc(p.v)}" placeholder="VALUE" style="flex:1;" />
      <button data-env-toggle="${i}">Show</button>
      <button class="danger" data-env-del="${i}">X</button>
    </div>
  `).join("");

  wrap.querySelectorAll("[data-env-k]").forEach(el => { el.onchange = () => { envPairs[el.dataset.envK].k = el.value; }; });
  wrap.querySelectorAll("[data-env-v]").forEach(el => { el.onchange = () => { envPairs[el.dataset.envV].v = el.value; }; });
  wrap.querySelectorAll("[data-env-toggle]").forEach(btn => {
    btn.onclick = () => {
      const inp = btn.previousElementSibling;
      inp.type = inp.type === "password" ? "text" : "password";
      btn.textContent = inp.type === "password" ? "Show" : "Hide";
    };
  });
  wrap.querySelectorAll("[data-env-del]").forEach(btn => {
    btn.onclick = () => { envPairs.splice(Number(btn.dataset.envDel), 1); renderEnvRows(); };
  });
}

document.getElementById("btn-copy-age").onclick = () => {
  navigator.clipboard.writeText(document.getElementById("age-pubkey").textContent);
  log("✔ Copied host Age public key.\n");
};

document.getElementById("btn-copy-sops-yaml").onclick = async () => {
  const yaml = await cockpit.spawn(["nixpit-secrets", "sops-config"], { superuser: "require", err: "out" });
  navigator.clipboard.writeText(yaml);
  log("✔ Copied .sops.yaml template to clipboard.\n");
};

document.getElementById("btn-sync-secrets").onclick = async () => {
  await run(["systemctl", "restart", "nixpit-secrets.service"]);
  loadSecretsOverview();
};

document.getElementById("secret-select").onchange = loadSecretFile;
document.getElementById("btn-add-env-row").onclick = () => { envPairs.push({ k: "", v: "" }); renderEnvRows(); };

document.getElementById("btn-new-secret").onclick = () => {
  const name = document.getElementById("new-secret-name").value.trim().replace(/(\.sops)?\.env$/, "");
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name)) return log("✖ Invalid secret name.\n");
  const sel = document.getElementById("secret-select");
  if (!Array.from(sel.options).some(o => o.value === name)) {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    sel.appendChild(opt);
  }
  sel.value = name;
  document.getElementById("new-secret-name").value = "";
  envPairs = [{ k: "", v: "" }];
  renderEnvRows();
};

document.getElementById("btn-save-secret").onclick = async () => {
  const name = document.getElementById("secret-select").value;
  if (!name) return log("✖ Select or create a secret first.\n");
  const lines = [];
  for (const p of envPairs) {
    const k = p.k.trim();
    if (!k) continue;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) return log(`✖ Invalid environment variable name: ${k}\n`);
    if (/[\r\n]/.test(p.v)) return log(`✖ Value for ${k} cannot contain newlines.\n`);
    lines.push(`${k}=${p.v}`);
  }
  if (!lines.length) return log("✖ Add at least one KEY=VALUE pair before encrypting.\n");
  const proc = cockpit.spawn(["nixpit-secrets", "set", name], { superuser: "require", err: "out" });
  proc.input(lines.join("\n") + "\n");
  await proc;
  log(`✔ Encrypted ${name}.sops.env and updated /run/nixpit/secrets/${name}.env\n`);
  await loadSecretsOverview();
};

document.getElementById("btn-del-secret").onclick = async () => {
  const name = document.getElementById("secret-select").value;
  if (!name || !confirm(`Delete encrypted secret ${name}?`)) return;
  await run(["nixpit-secrets", "delete", name]);
  await loadSecretsOverview();
};

// --- Raw Editor ---
async function loadRawFile() {
  if (!repoSelectEl.value) return;
  const path = `${STATE}/repos/${repoSelectEl.value}/${fileSelectEl.value}`;
  rawEditorEl.value = (await cockpit.file(path, { superuser: "require" }).read()) || "";
}
repoSelectEl.onchange = () => { loadGuestsJson(); loadRawFile(); refreshGitBadge(); };
fileSelectEl.onchange = loadRawFile;
document.getElementById("btn-save-raw").onclick = async () => {
  if (!repoSelectEl.value) return;
  const path = `${STATE}/repos/${repoSelectEl.value}/${fileSelectEl.value}`;
  await cockpit.file(path, { superuser: "require" }).replace(rawEditorEl.value);
  log(`✔ Saved ${path}\n`);
  if (fileSelectEl.value === "guests.json") loadGuestsJson();
  await loadProfiles();
};

// --- Top Toolbar Actions ---
document.getElementById("btn-sync").onclick = async () => {
  if (!repoSelectEl.value) return;
  await run(["nixpit-repo", "sync", repoSelectEl.value]);
  await loadProfiles();
};

document.getElementById("btn-diff").onclick = () =>
  repoSelectEl.value && run(["nixpit-repo", "diff", repoSelectEl.value]);

document.getElementById("btn-push").onclick = async () => {
  if (!repoSelectEl.value) return;
  const msg = document.getElementById("commit-msg").value.trim() || "Update NixPit configs";
  await run(["nixpit-repo", "push", repoSelectEl.value, msg]);
  document.getElementById("commit-msg").value = "";
  await loadProfiles();
};

document.getElementById("btn-validate").onclick = async () => {
  const flake = await getFlakeUri();
  run(["nixos-rebuild", "dry-build", "--impure", "--flake", flake]);
};

document.getElementById("btn-deploy").onclick = async () => {
  const flake = await getFlakeUri();
  await run(["nixos-rebuild", "switch", "--impure", "--flake", flake]);
  renderGuestCards();
  refreshHealth();
  loadSecretsOverview();
};

document.getElementById("btn-rollback").onclick = async () => {
  if (!confirm("Roll back the OS generation only? Git revisions and persistent data will not be restored.")) return;
  await run(["nixos-rebuild", "switch", "--rollback"]);
  renderGuestCards();
  refreshHealth();
};

// Init
loadProfiles();
loadSecretsOverview();
scanSerialUsb();
scanLsusb();
refreshHealth();
