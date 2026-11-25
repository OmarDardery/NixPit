const PROC_DIR = "/proc/nixpit_virtmon";
const STATUS_PATH = `${PROC_DIR}/status`;
const EVENTS_PATH = `${PROC_DIR}/events`;
const CONTROL_PATH = `${PROC_DIR}/control`;

const VIRT_MODULES = [
  "nixpit_virtmon", "kvm", "kvm_intel", "kvm_amd",
  "vhost_net", "vhost_vsock", "vfio_pci", "tun", "bridge", "overlay"
];

let activeCategory = "all";
let currentEvents = [];
let currentRawText = "";
let liveEnabled = true;
let pollTimer = null;
let isRefreshing = false;

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
}[c]));

function showError(msg) {
  const el = document.getElementById("error-banner");
  if (!msg) {
    el.style.display = "none";
    el.textContent = "";
  } else {
    el.style.display = "block";
    el.textContent = msg;
  }
}

function formatTs(sec, nsec) {
  if (typeof sec !== "number") return "-";
  const ms = Math.floor((nsec || 0) / 1e6);
  const d = new Date(sec * 1000 + ms);
  return d.toISOString().replace("T", " ").replace("Z", "");
}

function categoryBadgeClass(cat) {
  switch (cat) {
    case "kvm": return "badge-ok";
    case "module": return "badge-info";
    case "network": return "badge-warn";
    case "process": return "badge-unk";
    case "system": return "badge-info";
    default: return "badge-unk";
  }
}

function renderStatus(status) {
  const modBadge = document.getElementById("mod-badge");
  const cpuBadge = document.getElementById("cpu-badge");
  const probeStrip = document.getElementById("probe-strip");

  if (!status) {
    modBadge.textContent = "Not Loaded";
    modBadge.className = "badge badge-err";
    cpuBadge.textContent = "CPU: Unknown";
    cpuBadge.className = "badge badge-unk";
    probeStrip.innerHTML = "<span style='color:#999;'>Module /proc/nixpit_virtmon/status unavailable. Click Load Module or check kernel logs.</span>";
    return;
  }

  modBadge.textContent = `Loaded v${status.version || "?"}`;
  modBadge.className = "badge badge-ok";

  const cpu = status.cpu || {};
  let cpuText = "CPU: No VT-x/AMD-V";
  let cpuClass = "badge-warn";
  if (cpu.vmx) {
    cpuText = cpu.hypervisor_guest ? "Intel VT-x (Nested)" : "Intel VT-x";
    cpuClass = "badge-ok";
  } else if (cpu.svm) {
    cpuText = cpu.hypervisor_guest ? "AMD-V (Nested)" : "AMD-V";
    cpuClass = "badge-ok";
  } else if (cpu.hypervisor_guest) {
    cpuText = "Hypervisor Guest";
  }
  cpuBadge.textContent = cpuText;
  cpuBadge.className = `badge ${cpuClass}`;

  const probes = status.probes || {};
  probeStrip.innerHTML = Object.entries(probes).map(([k, v]) =>
    `<span class="badge ${v ? "badge-ok" : "badge-unk"}">${esc(k)}: ${v ? "on" : "off"}</span>`
  ).join("");

  const c = status.counters || {};
  document.getElementById("m-total").textContent = String(c.total ?? 0);
  document.getElementById("m-kvm").textContent = String(c.kvm ?? 0);
  document.getElementById("m-module").textContent = String(c.module ?? 0);
  document.getElementById("m-network").textContent = String(c.network ?? 0);
  document.getElementById("m-process").textContent = String(c.process ?? 0);
  document.getElementById("m-ring").textContent = `${c.ring_used ?? 0} / ${c.ring_capacity ?? 512}`;
  document.getElementById("ring-info").textContent =
    `Ring: ${c.ring_used ?? 0}/${c.ring_capacity ?? 512} • Dropped: ${c.dropped ?? 0} • dmesg: ${status.dmesg_enabled ? "on" : "off"}`;
}

async function refreshLoadedModules() {
  const wrap = document.getElementById("loaded-mods");
  try {
    const raw = await cockpit.file("/proc/modules", { superuser: "require" }).read();
    const loaded = new Set((raw || "").split("\n").filter(Boolean).map(l => l.split(/\s+/)[0]));
    wrap.innerHTML = `<span style="color:var(--muted);">Modules:</span>` + VIRT_MODULES.map(m =>
      `<span class="badge ${loaded.has(m) ? "badge-ok" : "badge-unk"}">${esc(m)}</span>`
    ).join("");
  } catch {
    wrap.innerHTML = "";
  }
}

function renderEventsTable() {
  const tbody = document.getElementById("events-body");
  const query = document.getElementById("search-input").value.trim().toLowerCase();

  const filtered = currentEvents.filter(ev => {
    if (activeCategory !== "all" && ev.category !== activeCategory) return false;
    if (!query) return true;
    const hay = `${ev.seq} ${ev.category} ${ev.level} ${ev.pid} ${ev.comm} ${ev.message}`.toLowerCase();
    return hay.includes(query);
  });

  if (!filtered.length) {
    tbody.innerHTML = `<tr><td colspan="7" style="color:var(--muted);">No matching virtualization events.</td></tr>`;
    return;
  }

  // Show newest events first for operator readability
  const rows = [...filtered].reverse().map(ev => `
    <tr>
      <td class="mono">${esc(ev.seq)}</td>
      <td class="mono">${esc(formatTs(ev.ts_sec, ev.ts_nsec))}</td>
      <td><span class="badge ${categoryBadgeClass(ev.category)}">${esc(ev.category)}</span></td>
      <td>${esc(ev.level)}</td>
      <td class="mono">${esc(ev.pid)}</td>
      <td class="mono">${esc(ev.comm)}</td>
      <td class="mono">${esc(ev.message)}</td>
    </tr>
  `);
  tbody.innerHTML = rows.join("");
}

function renderRawLogView() {
  const pre = document.getElementById("raw-log-view");
  const query = document.getElementById("search-input").value.trim().toLowerCase();
  const lines = currentRawText.split("\n");
  const filtered = query ? lines.filter(l => l.toLowerCase().includes(query)) : lines;
  pre.textContent = filtered.join("\n") || "(no matching log lines)";
}

async function refreshAll() {
  if (isRefreshing) return;
  isRefreshing = true;
  try {
    showError("");
    let statusObj = null;
    try {
      const rawStatus = await cockpit.file(STATUS_PATH, { superuser: "require" }).read();
      if (rawStatus) statusObj = JSON.parse(rawStatus);
    } catch (e) {
      statusObj = null;
    }
    renderStatus(statusObj);
    await refreshLoadedModules();

    const source = document.getElementById("log-source").value;
    const ringView = document.getElementById("ring-view");
    const rawView = document.getElementById("raw-log-view");
    const catFilters = document.getElementById("cat-filters");

    if (source === "ring") {
      ringView.style.display = "block";
      rawView.style.display = "none";
      catFilters.style.display = "flex";
      const rawEvents = await cockpit.file(EVENTS_PATH, { superuser: "require" }).read();
      if (rawEvents === null) {
        currentEvents = [];
        showError("Kernel module nixpit_virtmon is not loaded (/proc/nixpit_virtmon/events not found). Click 'Load Module' or switch Log Source to Kernel Journal.");
      } else {
        currentEvents = rawEvents.split("\n").filter(Boolean).map(line => {
          try { return JSON.parse(line); } catch { return null; }
        }).filter(Boolean);
      }
      renderEventsTable();
    } else if (source === "dmesg") {
      ringView.style.display = "none";
      rawView.style.display = "block";
      catFilters.style.display = "none";
      const out = await cockpit.spawn(["journalctl", "-k", "-n", "300", "--no-pager"], { superuser: "require", err: "out" });
      const re = /nixpit_virtmon|kvm|libvirt|qemu|vfio|vhost|virbr|virtio|podman/i;
      currentRawText = out.split("\n").filter(l => re.test(l)).join("\n");
      renderRawLogView();
    } else {
      ringView.style.display = "none";
      rawView.style.display = "block";
      catFilters.style.display = "none";
      currentRawText = await cockpit.spawn(
        ["journalctl", "-u", "libvirtd", "-u", "nixvirt", "-n", "200", "--no-pager"],
        { superuser: "require", err: "out" }
      );
      renderRawLogView();
    }
  } catch (e) {
    showError(`Failed to read virtualization logs: ${e.message || e}`);
  } finally {
    isRefreshing = false;
  }
}

async function writeControl(cmd) {
  try {
    showError("");
    await cockpit.file(CONTROL_PATH, { superuser: "require" }).replace(`${cmd}\n`);
    await refreshAll();
  } catch (e) {
    showError(`Control command '${cmd}' failed: ${e.message || e}`);
  }
}

function downloadBlob(filename, mime, content) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function updateLiveTimer() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  const btn = document.getElementById("btn-live");
  if (liveEnabled) {
    btn.textContent = "Live (2s)";
    btn.className = "warn";
    pollTimer = setInterval(refreshAll, 2000);
  } else {
    btn.textContent = "Paused";
    btn.className = "";
  }
}

document.getElementById("btn-load-mod").onclick = async () => {
  try {
    showError("");
    await cockpit.spawn(["modprobe", "nixpit_virtmon"], { superuser: "require", err: "out" });
    await refreshAll();
  } catch (e) {
    showError(`modprobe nixpit_virtmon failed: ${e.message || e}`);
  }
};

document.getElementById("btn-probe").onclick = () => writeControl("probe");
document.getElementById("btn-clear").onclick = () => {
  if (confirm("Clear the nixpit_virtmon kernel ring buffer?")) writeControl("clear");
};
document.getElementById("btn-refresh").onclick = refreshAll;
document.getElementById("btn-live").onclick = () => {
  liveEnabled = !liveEnabled;
  updateLiveTimer();
};

document.getElementById("log-source").onchange = refreshAll;
document.getElementById("search-input").oninput = () => {
  if (document.getElementById("log-source").value === "ring") renderEventsTable();
  else renderRawLogView();
};

document.querySelectorAll(".filter-btn").forEach(btn => {
  btn.onclick = () => {
    document.querySelectorAll(".filter-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    activeCategory = btn.dataset.cat;
    renderEventsTable();
  };
});

document.getElementById("btn-export-json").onclick = () => {
  downloadBlob("nixpit-virtmon-events.json", "application/json", JSON.stringify(currentEvents, null, 2));
};

document.getElementById("btn-export-log").onclick = () => {
  const source = document.getElementById("log-source").value;
  const text = source === "ring"
    ? currentEvents.map(ev => `[${formatTs(ev.ts_sec, ev.ts_nsec)}] [${ev.category}] [${ev.level}] pid=${ev.pid} comm=${ev.comm} ${ev.message}`).join("\n")
    : currentRawText;
  downloadBlob(`nixpit-virtmon-${source}.log`, "text/plain", text);
};

updateLiveTimer();
refreshAll();
