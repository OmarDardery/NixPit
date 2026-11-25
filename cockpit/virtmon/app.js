const PROC_DIR = "/proc/nixpit_virtmon";
const VIRT_MODS = ["nixpit_virtmon", "kvm", "kvm_intel", "kvm_amd", "vhost_net", "vhost_vsock", "vfio_pci", "tun", "bridge", "overlay"];

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

let logSource = "ring";
let activeCategory = "all";
let currentEvents = [];
let currentRawText = "";
let liveEnabled = true;
let pollTimer = null;
let isRefreshing = false;
let lastRenderKey = "";

function toast(msg, kind = "") {
  const el = document.createElement("div");
  el.className = `toast ${kind ? `toast-${kind}` : ""}`;
  el.textContent = msg;
  $("toasts").appendChild(el);
  setTimeout(() => el.remove(), 2400);
}

function showError(msg) {
  const el = $("error-banner");
  el.style.display = msg ? "block" : "none";
  el.textContent = msg || "";
}

function formatTs(sec, nsec) {
  if (typeof sec !== "number") return "-";
  return new Date(sec * 1000 + Math.floor((nsec || 0) / 1e6)).toISOString().replace("T", " ").replace("Z", "");
}

const catPill = cat => ({ kvm: "pill-ok", module: "pill-info", network: "pill-warn", system: "pill-info" }[cat] || "");

function renderStatus(status) {
  const mod = $("mod-badge");
  const cpu = $("cpu-badge");
  const loadBtn = $("btn-load-mod");

  if (!status) {
    mod.className = "pill pill-err";
    mod.innerHTML = `<span class="dot"></span>Not Loaded`;
    cpu.className = "pill";
    cpu.innerHTML = `<span class="dot"></span>CPU Unknown`;
    loadBtn.style.display = "inline-flex";
    $("probe-strip").innerHTML = `<span class="muted">Module <code>/proc/nixpit_virtmon/status</code> unavailable.</span>`;
    return;
  }

  loadBtn.style.display = "none";
  mod.className = "pill pill-ok";
  mod.innerHTML = `<span class="dot ${liveEnabled ? "dot-live" : ""}"></span>v${esc(status.version || "?")}`;

  const c = status.cpu || {};
  const label = c.vmx ? (c.hypervisor_guest ? "VT-x · Nested" : "Intel VT-x")
    : c.svm ? (c.hypervisor_guest ? "AMD-V · Nested" : "AMD-V")
    : c.hypervisor_guest ? "Hypervisor Guest" : "No HW Virt";
  cpu.className = `pill ${c.hw_virt_available ? "pill-ok" : "pill-warn"}`;
  cpu.innerHTML = `<span class="dot"></span>${label}`;

  $("probe-strip").innerHTML = Object.entries(status.probes || {}).map(([k, v]) =>
    `<span class="pill ${v ? "pill-ok" : ""}"><span class="dot"></span>${esc(k)}</span>`
  ).join("");

  const cnt = status.counters || {};
  $("m-total").textContent = String(cnt.total ?? 0);
  $("m-kvm").textContent = String(cnt.kvm ?? 0);
  $("m-module").textContent = String(cnt.module ?? 0);
  $("m-network").textContent = String(cnt.network ?? 0);
  $("m-process").textContent = String(cnt.process ?? 0);
  $("m-ring").textContent = `${cnt.ring_used ?? 0} / ${cnt.ring_capacity ?? 512}`;
  $("ring-info").textContent = `Ring: ${cnt.ring_used ?? 0}/${cnt.ring_capacity ?? 512} · Dropped: ${cnt.dropped ?? 0}`;
}

async function refreshLoadedModules() {
  try {
    const raw = await cockpit.file("/proc/modules", { superuser: "require" }).read();
    const loaded = new Set((raw || "").split("\n").filter(Boolean).map(l => l.split(/\s+/)[0]));
    $("loaded-mods").innerHTML = VIRT_MODS.map(m =>
      `<span class="pill ${loaded.has(m) ? "pill-ok" : ""}"><span class="dot"></span>${esc(m)}</span>`
    ).join("");
  } catch { $("loaded-mods").innerHTML = ""; }
}

function renderEventsTable() {
  const query = $("search-input").value.trim().toLowerCase();
  const lastSeq = currentEvents.length ? currentEvents[currentEvents.length - 1].seq : 0;
  const key = `ring|${activeCategory}|${query}|${currentEvents.length}|${lastSeq}`;
  if (key === lastRenderKey) return;
  lastRenderKey = key;

  const filtered = currentEvents.filter(ev => {
    if (activeCategory !== "all" && ev.category !== activeCategory) return false;
    if (!query) return true;
    return `${ev.seq} ${ev.category} ${ev.level} ${ev.pid} ${ev.comm} ${ev.message}`.toLowerCase().includes(query);
  });

  $("events-body").innerHTML = filtered.length
    ? [...filtered].reverse().map(ev => `
        <tr>
          <td class="mono muted">${esc(ev.seq)}</td>
          <td class="mono muted">${esc(formatTs(ev.ts_sec, ev.ts_nsec))}</td>
          <td><span class="pill ${catPill(ev.category)}"><span class="dot"></span>${esc(ev.category)}</span></td>
          <td class="muted">${esc(ev.level)}</td>
          <td class="mono">${esc(ev.pid)}</td>
          <td class="mono">${esc(ev.comm)}</td>
          <td class="mono">${esc(ev.message)}</td>
        </tr>
      `).join("")
    : `<tr><td colspan="7" class="muted">No matching virtualization events.</td></tr>`;
}

function renderRawLogView() {
  const query = $("search-input").value.trim().toLowerCase();
  const lines = currentRawText.split("\n");
  $("raw-log-view").textContent = (query ? lines.filter(l => l.toLowerCase().includes(query)) : lines).join("\n") || "(no matching log lines)";
}

async function refreshAll() {
  if (isRefreshing) return;
  isRefreshing = true;
  try {
    showError("");
    let statusObj = null;
    try {
      const rawStatus = await cockpit.file(`${PROC_DIR}/status`, { superuser: "require" }).read();
      if (rawStatus) statusObj = JSON.parse(rawStatus);
    } catch { statusObj = null; }
    renderStatus(statusObj);
    await refreshLoadedModules();

    const isRing = logSource === "ring";
    $("ring-view").style.display = isRing ? "block" : "none";
    $("raw-log-view").style.display = isRing ? "none" : "block";
    $("cat-filters").style.display = isRing ? "inline-flex" : "none";

    if (isRing) {
      const rawEvents = await cockpit.file(`${PROC_DIR}/events`, { superuser: "require" }).read();
      if (rawEvents === null) {
        currentEvents = [];
        showError("Kernel module nixpit_virtmon is not loaded (/proc/nixpit_virtmon/events missing). Click Load Module or switch source.");
      } else {
        currentEvents = rawEvents.split("\n").filter(Boolean).map(l => {
          try { return JSON.parse(l); } catch { return null; }
        }).filter(Boolean);
      }
      renderEventsTable();
    } else if (logSource === "dmesg") {
      const out = await cockpit.spawn(["journalctl", "-k", "-n", "300", "--no-pager"], { superuser: "require", err: "out" });
      currentRawText = out.split("\n").filter(l => /nixpit_virtmon|kvm|libvirt|qemu|vfio|vhost|virbr|virtio|podman/i.test(l)).join("\n");
      renderRawLogView();
    } else {
      currentRawText = await cockpit.spawn(["journalctl", "-u", "libvirtd", "-u", "nixvirt", "-u", "nixpit-secrets", "-n", "200", "--no-pager"], { superuser: "require", err: "out" });
      renderRawLogView();
    }
  } catch (e) {
    showError(`Failed to read logs: ${e.message || e}`);
  } finally {
    isRefreshing = false;
  }
}

async function writeControl(cmd) {
  try {
    await cockpit.file(`${PROC_DIR}/control`, { superuser: "require" }).replace(`${cmd}\n`);
    lastRenderKey = "";
    await refreshAll();
    toast(`Executed '${cmd}'`, "ok");
  } catch (e) {
    showError(`Control command '${cmd}' failed: ${e.message || e}`);
  }
}

function updateLiveTimer() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  const btn = $("btn-live");
  if (liveEnabled) {
    btn.textContent = "Live (2s)";
    btn.className = "success";
    pollTimer = setInterval(refreshAll, 2000);
  } else {
    btn.textContent = "Paused";
    btn.className = "";
  }
}

$("btn-load-mod").onclick = async () => {
  try {
    await cockpit.spawn(["modprobe", "nixpit_virtmon"], { superuser: "require", err: "out" });
    lastRenderKey = "";
    await refreshAll();
    toast("Loaded nixpit_virtmon.ko", "ok");
  } catch (e) { showError(`modprobe failed: ${e.message || e}`); }
};

$("btn-probe").onclick = () => writeControl("probe");
$("btn-clear").onclick = () => confirm("Clear the nixpit_virtmon kernel ring buffer?") && writeControl("clear");
$("btn-refresh").onclick = () => { lastRenderKey = ""; refreshAll(); };
$("btn-live").onclick = () => { liveEnabled = !liveEnabled; updateLiveTimer(); refreshAll(); };

$("source-seg").querySelectorAll("button").forEach(btn => {
  btn.onclick = () => {
    $("source-seg").querySelectorAll("button").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    logSource = btn.dataset.src;
    lastRenderKey = "";
    refreshAll();
  };
});

$("cat-filters").querySelectorAll("button").forEach(btn => {
  btn.onclick = () => {
    $("cat-filters").querySelectorAll("button").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    activeCategory = btn.dataset.cat;
    renderEventsTable();
  };
});

$("search-input").oninput = () => {
  if (logSource === "ring") renderEventsTable();
  else renderRawLogView();
};

$("btn-export").onclick = () => {
  const isRing = logSource === "ring";
  const blob = new Blob(
    [isRing ? JSON.stringify(currentEvents, null, 2) : currentRawText],
    { type: isRing ? "application/json" : "text/plain" }
  );
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = isRing ? "nixpit-virtmon-events.json" : `nixpit-virtmon-${logSource}.log`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
  toast("Exported logs", "ok");
};

updateLiveTimer();
refreshAll();
