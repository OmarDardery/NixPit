const STATE = "/var/lib/nixpit";
const KEY = `${STATE}/deploy_key`;
const REPOS_FILE = `${STATE}/repos.json`;
const SECRETS_DIR = `${STATE}/secrets`;
const FLAKE_FILE = `${STATE}/hypervisor.flake`;
const SSH_ENV = `GIT_SSH_COMMAND=ssh -i ${KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new`;

const logsEl = document.getElementById("logs");
const repoSelectEl = document.getElementById("repo-select");
const fileSelectEl = document.getElementById("file-select");
const rawEditorEl = document.getElementById("raw-editor");

let repos = [];
let hasKey = false;
let currentGuests = { containers: {}, vms: {} };
let envPairs = [];
let busy = false;

const BUSY_BTN_IDS = [
  "btn-gc", "btn-pull", "btn-diff", "btn-push",
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
    await cockpit.spawn(cmd, { superuser: "require", err: "out", environ: [SSH_ENV] }).stream(log);
    log("\n✔ Done.\n");
  } catch (e) {
    log(`\n✖ ${e.message}\n`);
    throw e;
  } finally {
    setBusy(false);
  }
};

// --- Tabs ---
function switchTab(tabId) {
  document.querySelectorAll(".tab, .panel").forEach(el => el.classList.remove("active"));
  document.querySelector(`.tab[data-tab="${tabId}"]`).classList.add("active");
  document.getElementById(tabId).classList.add("active");
}
document.querySelectorAll(".tab").forEach(btn => { btn.onclick = () => switchTab(btn.dataset.tab); });
document.getElementById("btn-clear-logs").onclick = () => { logsEl.textContent = ""; };

function updateOnboarding() {
  const done = hasKey && repos.length > 0;
  document.getElementById("onboarding").style.display = done ? "none" : "block";
  document.getElementById("step-key").style.opacity = hasKey ? "0.5" : "1";
  document.getElementById("step-repo").style.opacity = repos.length > 0 ? "0.5" : "1";
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

async function refreshGitBadge() {
  const badge = document.getElementById("stat-git");
  if (!repoSelectEl.value) {
    badge.textContent = "no repo";
    badge.className = "badge badge-unk";
    return;
  }
  const dir = `${STATE}/repos/${repoSelectEl.value}`;
  try {
    const branch = (await cockpit.spawn(["git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], { superuser: "require" })).trim();
    const dirty = (await cockpit.spawn(["git", "-C", dir, "status", "--porcelain"], { superuser: "require" })).trim();
    const count = dirty ? dirty.split("\n").length : 0;
    badge.textContent = count ? `${branch} • ${count} modified` : `${branch} • clean`;
    badge.className = `badge ${count ? "badge-warn" : "badge-ok"}`;
  } catch {
    badge.textContent = "git error";
    badge.className = "badge badge-err";
  }
}

document.getElementById("btn-gc").onclick = async () => {
  await run(["nix-collect-garbage"]);
  refreshHealth();
};

async function getFlakeUri() {
  const f = await cockpit.file(FLAKE_FILE, { superuser: "require" }).read();
  return (f && f.trim()) || "path:/etc/nixpit#nixpit";
}

// --- SSH Key ---
async function loadKey() {
  const pub = await cockpit.file(`${KEY}.pub`, { superuser: "require" }).read();
  hasKey = Boolean(pub && pub.trim());
  document.getElementById("pub-key").textContent = hasKey
    ? pub.trim()
    : 'No key generated yet. Click "Generate Key" to create one.';
  updateOnboarding();
}

document.getElementById("btn-gen-key").onclick = async () => {
  const existing = await cockpit.file(`${KEY}.pub`, { superuser: "require" }).read();
  if (existing && existing.trim()) {
    log("SSH deploy key already exists.\n");
    return loadKey();
  }
  await run(["install", "-d", "-m", "0700", STATE]);
  await run(["ssh-keygen", "-t", "ed25519", "-f", KEY, "-N", "", "-C", "nixpit"], false);
  loadKey();
};
document.getElementById("btn-copy-key").onclick = () => {
  navigator.clipboard.writeText(document.getElementById("pub-key").textContent);
  log("✔ Public key copied to clipboard.\n");
};

// --- Repos ---
async function loadRepos() {
  const raw = await cockpit.file(REPOS_FILE, { superuser: "require" }).read();
  try {
    repos = JSON.parse(raw || "[]");
    if (!Array.isArray(repos)) repos = [];
  } catch (e) {
    log(`✖ Invalid JSON in ${REPOS_FILE}: ${e.message}\n`);
    repos = [];
  }

  const listEl = document.getElementById("repo-list");
  listEl.innerHTML = repos.length
    ? repos.map(r => `
        <div class="item-row">
          <span><strong>${esc(r.name)}</strong> — <code>${esc(r.url)}</code></span>
          <button class="danger" data-rm-repo="${esc(r.name)}">Remove</button>
        </div>
      `).join("")
    : "<p style='color:#888;'>No repositories added yet.</p>";

  listEl.querySelectorAll("[data-rm-repo]").forEach(btn => {
    btn.onclick = () => removeRepo(btn.dataset.rmRepo);
  });

  repoSelectEl.innerHTML = repos.map(r => `<option value="${esc(r.name)}">${esc(r.name)}</option>`).join("");
  updateOnboarding();
  if (repos.length) {
    await loadGuestsJson();
    await loadRawFile();
  }
  refreshGitBadge();
}

async function saveReposList() {
  await cockpit.file(REPOS_FILE, { superuser: "require" }).replace(JSON.stringify(repos, null, 2));
  loadRepos();
}

document.getElementById("btn-add-repo").onclick = async () => {
  const input = document.getElementById("new-repo-url");
  const url = input.value.trim();
  if (!url) return;
  const name = url.split("/").pop().replace(/\.git$/, "");
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !/^(git@github\.com:|ssh:\/\/git@github\.com\/|https:\/\/github\.com\/)/.test(url) || repos.some(r => r.name === name)) return log("Invalid or duplicate GitHub repository.\n");
  await run(["git", "clone", "--", url, `${STATE}/repos/${name}`]);
  repos.push({ name, url });
  input.value = "";
  await saveReposList();
};

async function removeRepo(name) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !confirm(`Remove ${name} from NixPit? Local repository files will be retained.`)) return;
  repos = repos.filter(r => r.name !== name);
  await saveReposList();
}

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

  // 1. Containers
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

  // 2. KVM VMs
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

  // 3. Compose Stack Card (if present in active repo)
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
          <div style="font-size:0.78rem;color:#999;margin:0.35rem 0;">File: ${esc(composeFile)} (Podman Compose + Dockerfile)</div>
          <div class="row">
            <button class="primary" data-restart="${esc(unit)}">Rebuild / Restart</button>
            <button data-logs="${esc(unit)}">Logs</button>
          </div>
        </div>
      `);
    }
  }

  containerEl.innerHTML = cards.join("") || "<p style='color:#888;'>No guests declared in this repo yet. Add one below or pick a template.</p>";

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
  refreshGitBadge();
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

// --- Visual VM Editor ---
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

// --- Templates ---
document.getElementById("template-select").onchange = async e => {
  const tpl = e.target.value;
  e.target.value = "";
  if (tpl === "klipper") {
    Object.assign(currentGuests.containers, {
      klipper: { image: "docker.io/mkuf/klipper:latest", volumes: ["/dev:/dev", "/var/lib/printer_data:/opt/printer_data"], extraOptions: ["--privileged"] },
      moonraker: { image: "docker.io/mkuf/moonraker:latest", ports: ["7125:7125"], network: "printer-net", volumes: ["/var/lib/printer_data:/opt/printer_data"], dependsOn: ["klipper"] },
      mainsail: { image: "ghcr.io/mainsail-crew/mainsail:latest", ports: ["8080:80"], network: "printer-net", domain: "printer.home.arpa", dependsOn: ["moonraker"] }
    });
  } else if (tpl === "aiostreams") {
    Object.assign(currentGuests.containers, {
      aiostreams: { image: "ghcr.io/viren070/aiostreams:latest", ports: ["127.0.0.1:3000:3000"], volumes: ["/var/lib/aiostreams:/app/data"], secretName: "aiostreams" },
      cloudflared: { image: "docker.io/cloudflare/cloudflared:latest", cmd: ["tunnel", "--no-autoupdate", "run"], secretName: "cloudflared", extraOptions: ["--network=host"], dependsOn: ["aiostreams"] }
    });
  } else if (tpl === "vm-debian") {
    currentGuests.vms["debian-vm"] = { uuid: crypto.randomUUID(), vcpus: 2, memoryGiB: 2, disk: "debian-13.qcow2", network: "default", usbPassthrough: [], active: true };
  }
  await persistGuestsJson();
};

// --- Live USB Scanners (/dev/serial/by-id + lsusb) ---
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

// --- Secrets & Env Vars ---
async function writeSecretAtomic(filename, content) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*\.env$/.test(filename)) {
    throw new Error("Invalid secret filename");
  }
  const proc = cockpit.spawn(
    [
      "sh", "-c",
      'set -eu; umask 077; install -d -m 0700 "$1"; tmp=$(mktemp "$1/.tmp.XXXXXX"); cat > "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$1/$2"',
      "--", SECRETS_DIR, filename
    ],
    { superuser: "require", err: "out" }
  );
  proc.input(content);
  await proc;
}

async function loadSecretList() {
  const out = await cockpit.spawn(["sh", "-c", `install -d -m 0700 "${SECRETS_DIR}" && ls -1 "${SECRETS_DIR}"/*.env 2>/dev/null || true`], { superuser: "require" });
  const files = out.trim().split("\n").filter(Boolean).map(p => p.split("/").pop());
  const sel = document.getElementById("secret-select");
  sel.innerHTML = files.map(f => `<option value="${esc(f)}">${esc(f)}</option>`).join("");
  if (files.length) loadSecretFile(); else { envPairs = []; renderEnvRows(); }
}

async function loadSecretFile() {
  const name = document.getElementById("secret-select").value;
  if (!name) return;
  const raw = await cockpit.file(`${SECRETS_DIR}/${name}`, { superuser: "require" }).read();
  envPairs = (raw || "").split("\n").filter(l => l.includes("=")).map(l => {
    const idx = l.indexOf("=");
    return { k: l.slice(0, idx).trim(), v: l.slice(idx + 1).trim() };
  });
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

document.getElementById("secret-select").onchange = loadSecretFile;
document.getElementById("btn-add-env-row").onclick = () => { envPairs.push({ k: "", v: "" }); renderEnvRows(); };
document.getElementById("btn-new-secret").onclick = async () => {
  const name = document.getElementById("new-secret-name").value.trim().replace(/\.env$/, "");
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name)) return log("✖ Invalid secret name.\n");
  await writeSecretAtomic(`${name}.env`, "");
  document.getElementById("new-secret-name").value = "";
  await loadSecretList();
  document.getElementById("secret-select").value = `${name}.env`;
  loadSecretFile();
};
document.getElementById("btn-save-secret").onclick = async () => {
  const name = document.getElementById("secret-select").value;
  if (!name) return;
  const lines = [];
  for (const p of envPairs) {
    const k = p.k.trim();
    if (!k) continue;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) {
      return log(`✖ Invalid environment variable name: ${k}\n`);
    }
    if (/[\r\n]/.test(p.v)) {
      return log(`✖ Value for ${k} cannot contain newlines.\n`);
    }
    lines.push(`${k}=${p.v}`);
  }
  await writeSecretAtomic(name, lines.join("\n") + (lines.length ? "\n" : ""));
  log(`✔ Saved secret ${SECRETS_DIR}/${name} (600)\n`);
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
  refreshGitBadge();
};

// --- Top Toolbar GitOps Actions ---
document.getElementById("btn-pull").onclick = () =>
  repoSelectEl.value && run(["git", "-C", `${STATE}/repos/${repoSelectEl.value}`, "pull", "--ff-only"])
    .then(() => { loadGuestsJson(); loadRawFile(); refreshGitBadge(); });

document.getElementById("btn-diff").onclick = () => {
  if (!repoSelectEl.value) return;
  const dir = `${STATE}/repos/${repoSelectEl.value}`;
  return run([
    "sh", "-c",
    'git -C "$1" status --short && git -C "$1" diff && git -C "$1" diff --cached',
    "--", dir
  ]);
};

document.getElementById("btn-push").onclick = async () => {
  if (!repoSelectEl.value) return;
  const dir = `${STATE}/repos/${repoSelectEl.value}`;
  const msg = document.getElementById("commit-msg").value.trim() || "Update guests via Cockpit";
  await run(["sh", "-c", `
    set -eu
    cd "$1"
    if [ -n "$(git status --porcelain)" ]; then
      if ! git diff --cached --quiet; then
        echo "Refusing to commit a pre-staged index. Review and unstage it first." >&2
        exit 1
      fi
      for file in guests.json compose.yaml docker-compose.yml Dockerfile; do
        if [ -L "$file" ]; then
          echo "Refusing symlink: $file" >&2
          exit 1
        fi
        if [ -f "$file" ] || git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
          git add -- "$file" || exit 1
        fi
      done
      git diff --cached --quiet || git commit -m "$2"
    else
      echo "No local changes to commit; pushing any unpushed commits..."
    fi
    git push
  `, "--", dir, msg]);
  document.getElementById("commit-msg").value = "";
  refreshGitBadge();
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
};

document.getElementById("btn-rollback").onclick = async () => {
  if (!confirm("Roll back the OS generation only? Git revisions and persistent data will not be restored.")) return;
  await run(["nixos-rebuild", "switch", "--rollback"]);
  renderGuestCards();
  refreshHealth();
};

// --- Auto-Sync Timer Toggle ---
async function refreshAutoSync() {
  const btn = document.getElementById("btn-toggle-autosync");
  btn.textContent = "Unavailable — transactional sync required";
  btn.disabled = true;
}

// Init
loadKey();
loadRepos();
loadSecretList();
scanSerialUsb();
scanLsusb();
refreshAutoSync();
refreshHealth();
