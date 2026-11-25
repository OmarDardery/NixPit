/*
 * nixpit_virtmon.c — NixPit Kernel Virtualization Activity Monitor
 *
 * What: Out-of-tree Linux kernel module (.ko) that detects CPU virtualization
 *       extensions (Intel VT-x / AMD-V) and records virtualization-related OS
 *       events (module loads, virtual NICs, /dev/kvm & /dev/vfio opens, and
 *       hypervisor/container process launches) in a bounded ring buffer.
 * How:  Registers kernel module/netdevice notifiers and two kprobes (vfs_open,
 *       security_bprm_check), storing events under a spinlock and exposing
 *       JSON/NDJSON status, events, and root-only control via /proc/nixpit_virtmon/.
 * Why:  Provides a unified Ring-0 telemetry feed for Cockpit and dmesg without
 *       needing an extra userspace daemon or altering hypervisor binaries.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/spinlock.h>
#include <linux/ktime.h>
#include <linux/timekeeping.h>
#include <linux/netdevice.h>
#include <linux/notifier.h>
#include <linux/kprobes.h>
#include <linux/fs.h>
#include <linux/dcache.h>
#include <linux/path.h>
#include <linux/binfmts.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/stdarg.h>
#ifdef CONFIG_X86
#include <asm/cpufeature.h>
#endif

MODULE_LICENSE("GPL");
MODULE_AUTHOR("NixPit");
MODULE_DESCRIPTION("NixPit kernel virtualization activity monitor");
MODULE_VERSION("1.0.0");

#define VIRTMON_VERSION "1.0.0"
#define VIRTMON_RING_SIZE 512

/* Event category IDs stored compactly as u8 in each ring-buffer slot. */
enum virtmon_cat {
	CAT_SYSTEM = 0,
	CAT_KVM,
	CAT_MODULE,
	CAT_NETWORK,
	CAT_PROCESS,
	CAT_COUNT,
};

static const char *const cat_names[CAT_COUNT] = {
	"system", "kvm", "module", "network", "process",
};

/* Fixed-size event record to avoid kmalloc inside atomic probe contexts. */
struct virtmon_event {
	u64 seq;
	s64 ts_sec;
	u32 ts_nsec;
	u8 cat;
	u8 notice;
	pid_t pid;
	char comm[TASK_COMM_LEN];
	char message[160];
};

/*
 * Bounded 512-entry circular buffer protected by ring_lock.
 * Using spin_lock_irqsave (instead of mutex) is mandatory because kprobes and
 * netdev notifiers can run in atomic/softirq context where sleeping is illegal.
 */
static struct virtmon_event ring_buf[VIRTMON_RING_SIZE];
static DEFINE_SPINLOCK(ring_lock);
static unsigned int ring_head;
static unsigned int ring_count;
static u64 next_seq = 1;
static u64 total_events;
static u64 dropped_events;
static u64 cat_counts[CAT_COUNT];

static bool cpu_vmx, cpu_svm, cpu_hypervisor;
static bool mod_nb_on, net_nb_on, open_kp_on, exec_kp_on;
static struct proc_dir_entry *proc_dir;

/*
 * str_in_list - Check if `s` exactly matches any string in `list`.
 * How: Linear scan over a small compile-time array with strcmp.
 * Why: Shared by module-name and binary-name filters to avoid duplicate loops.
 */
static bool str_in_list(const char *s, const char *const *list, size_t n)
{
	size_t i;

	if (!s)
		return false;
	for (i = 0; i < n; i++) {
		if (strcmp(s, list[i]) == 0)
			return true;
	}
	return false;
}

/*
 * prefix_in_list - Check if `s` starts with any prefix in `list`.
 * How: Linear scan using strncmp against each prefix's length.
 * Why: Virtual NIC names include instance suffixes (e.g. virbr0, vnet1, vethA1).
 */
static bool prefix_in_list(const char *s, const char *const *list, size_t n)
{
	size_t i;

	if (!s)
		return false;
	for (i = 0; i < n; i++) {
		if (strncmp(s, list[i], strlen(list[i])) == 0)
			return true;
	}
	return false;
}

/*
 * virtmon_record - Append a virtualization event to the ring buffer and dmesg.
 * How: Captures wall-clock timestamp and current task PID/comm, formats the
 *      message on the stack, then inserts into ring_buf under spin_lock_irqsave
 *      (overwriting the oldest slot when full). Prints via printk_ratelimited.
 * Why: Keeps critical section tiny, bounded in memory, safe in atomic context,
 *      and immune to dmesg log-flooding.
 */
static void virtmon_record(enum virtmon_cat cat, bool notice, const char *fmt, ...)
{
	struct virtmon_event ev;
	struct timespec64 ts;
	unsigned long flags;
	unsigned int idx;
	va_list args;

	ktime_get_real_ts64(&ts);
	ev.ts_sec = ts.tv_sec;
	ev.ts_nsec = (u32)ts.tv_nsec;
	ev.cat = (u8)cat;
	ev.notice = notice ? 1 : 0;
	ev.pid = current ? task_pid_nr(current) : 0;
	if (current)
		get_task_comm(ev.comm, current);
	else
		strscpy(ev.comm, "kernel", sizeof(ev.comm));

	va_start(args, fmt);
	vsnprintf(ev.message, sizeof(ev.message), fmt, args);
	va_end(args);

	spin_lock_irqsave(&ring_lock, flags);
	ev.seq = next_seq++;
	total_events++;
	cat_counts[cat]++;
	if (ring_count == VIRTMON_RING_SIZE) {
		idx = ring_head;
		ring_head = (ring_head + 1) % VIRTMON_RING_SIZE;
		dropped_events++;
	} else {
		idx = (ring_head + ring_count) % VIRTMON_RING_SIZE;
		ring_count++;
	}
	ring_buf[idx] = ev;
	spin_unlock_irqrestore(&ring_lock, flags);

	printk_ratelimited(KERN_INFO pr_fmt("[%s] [%s] pid=%d comm=%s %s\n"),
			   cat_names[cat], notice ? "notice" : "info",
			   ev.pid, ev.comm, ev.message);
}

/*
 * virtmon_module_cb - Kernel module lifecycle notifier callback.
 * What: Records load (LIVE) and unload (GOING) events for virtualization modules.
 * How: Registered with register_module_notifier(); ignores unrelated modules.
 * Why: Tracks dynamic loading/unloading of KVM, vhost, VFIO, tun, and virtio.
 */
static int virtmon_module_cb(struct notifier_block *nb, unsigned long val, void *data)
{
	static const char *const mods[] = {
		"kvm", "kvm_intel", "kvm_amd", "vhost", "vhost_net", "vhost_vsock",
		"vhost_scsi", "vfio", "vfio_pci", "vfio_iommu_type1", "tun", "tap",
		"macvtap", "bridge", "br_netfilter", "overlay", "virtio_net",
		"virtio_blk", "virtio_pci", "virtio_balloon", "virtio_console",
		"virtio_gpu", "virtiofs",
	};
	struct module *mod = data;

	if (!mod || !str_in_list(mod->name, mods, ARRAY_SIZE(mods)))
		return NOTIFY_DONE;

	if (val == MODULE_STATE_LIVE)
		virtmon_record(CAT_MODULE, true, "kernel module loaded: %s", mod->name);
	else if (val == MODULE_STATE_GOING)
		virtmon_record(CAT_MODULE, true, "kernel module unloading: %s", mod->name);

	return NOTIFY_DONE;
}

static struct notifier_block virtmon_module_nb = { .notifier_call = virtmon_module_cb };

/*
 * virtmon_netdev_cb - Virtual network interface state notifier callback.
 * What: Logs creation, destruction, link-up, and link-down for virtual NICs.
 * How: Extracts struct net_device via netdev_notifier_info_to_dev() and filters
 *      interface names by virtual bridge/tap/container prefixes.
 * Why: Surfaces VM bridge (virbr/vnet) and container (podman/veth) churn.
 */
static int virtmon_netdev_cb(struct notifier_block *nb, unsigned long event, void *ptr)
{
	static const char *const prefixes[] = {
		"virbr", "vnet", "tap", "macvtap", "podman", "veth", "cni", "br", "vmbr",
	};
	struct net_device *dev = netdev_notifier_info_to_dev(ptr);
	const char *ev_name;

	if (!dev || !prefix_in_list(dev->name, prefixes, ARRAY_SIZE(prefixes)))
		return NOTIFY_DONE;

	switch (event) {
	case NETDEV_REGISTER: ev_name = "registered"; break;
	case NETDEV_UNREGISTER: ev_name = "unregistered"; break;
	case NETDEV_UP: ev_name = "up"; break;
	case NETDEV_DOWN: ev_name = "down"; break;
	default: return NOTIFY_DONE;
	}

	virtmon_record(CAT_NETWORK, false, "virtual interface %s %s (ifindex=%d)",
		       dev->name, ev_name, dev->ifindex);
	return NOTIFY_DONE;
}

static struct notifier_block virtmon_netdev_nb = { .notifier_call = virtmon_netdev_cb };

#if defined(CONFIG_KPROBES) && defined(CONFIG_X86_64)
/*
 * vfs_open_pre - Kprobe pre-handler on vfs_open(const struct path *path, ...).
 * What: Detects any process opening /dev/kvm, /dev/vhost-*, /dev/net/tun, or /dev/vfio/*.
 * How: Under x86_64 System V ABI, the 1st argument (path) sits in regs->di.
 *      Verifies S_ISCHR() on the inode, then inspects dentry and parent names.
 * Why: Checking S_ISCHR() avoids false positives on non-device paths like
 *      /sys/module/kvm directories, and catches unprivileged/manual KVM usage.
 */
static int vfs_open_pre(struct kprobe *p, struct pt_regs *regs)
{
	const struct path *path = (const struct path *)regs->di;
	struct dentry *dentry, *parent;
	const char *name, *pname;

	if (!path || !path->dentry || !path->dentry->d_inode || !S_ISCHR(path->dentry->d_inode->i_mode))
		return 0;

	dentry = path->dentry;
	name = (const char *)dentry->d_name.name;
	parent = dentry->d_parent;
	pname = (parent && parent->d_name.name) ? (const char *)parent->d_name.name : "";
	if (!name)
		return 0;

	if (strcmp(name, "kvm") == 0 || strcmp(name, "vhost-net") == 0 || strcmp(name, "vhost-vsock") == 0)
		virtmon_record(CAT_KVM, false, "opened /dev/%s", name);
	else if (strcmp(name, "tun") == 0 && strcmp(pname, "net") == 0)
		virtmon_record(CAT_KVM, false, "opened /dev/net/tun");
	else if (strcmp(pname, "vfio") == 0)
		virtmon_record(CAT_KVM, true, "opened /dev/vfio/%s", name);

	return 0;
}

static struct kprobe vfs_open_kp = { .symbol_name = "vfs_open", .pre_handler = vfs_open_pre };

/*
 * exec_pre - Kprobe pre-handler on security_bprm_check(struct linux_binprm *bprm).
 * What: Logs launches of QEMU, Libvirt, Podman, OCI runtimes, swtpm, and virtiofsd.
 * How: Reads bprm from regs->di, extracts the filename basename, and matches
 *      against qemu-system-* or the known virtualization binary list.
 * Why: Hooks execve() in kernel space without needing auditd or ptrace.
 */
static int exec_pre(struct kprobe *p, struct pt_regs *regs)
{
	static const char *const bins[] = {
		"qemu-kvm", "libvirtd", "virtqemud", "virtlogd", "virsh",
		"podman", "conmon", "crun", "runc", "swtpm", "virtiofsd",
	};
	const struct linux_binprm *bprm = (const struct linux_binprm *)regs->di;
	const char *slash, *base;

	if (!bprm || !bprm->filename)
		return 0;

	slash = strrchr(bprm->filename, '/');
	base = slash ? slash + 1 : bprm->filename;
	if (strncmp(base, "qemu-system-", 12) == 0 || str_in_list(base, bins, ARRAY_SIZE(bins)))
		virtmon_record(CAT_PROCESS, false, "exec %s", bprm->filename);

	return 0;
}

static struct kprobe exec_kp = { .symbol_name = "security_bprm_check", .pre_handler = exec_pre };
#endif

/*
 * seq_json_str - Emit a JSON-escaped string into a procfs seq_file buffer.
 * How: Escapes quotes, backslashes, and ASCII control bytes (< 0x20).
 * Why: Process names and paths can contain arbitrary bytes; escaping guarantees
 *      /proc/nixpit_virtmon/events always outputs valid NDJSON.
 */
static void seq_json_str(struct seq_file *m, const char *s)
{
	const unsigned char *p = (const unsigned char *)(s ? s : "");

	seq_putc(m, '"');
	for (; *p; p++) {
		if (*p == '"' || *p == '\\')
			seq_printf(m, "\\%c", *p);
		else if (*p < 0x20)
			seq_printf(m, "\\u%04x", *p);
		else
			seq_putc(m, *p);
	}
	seq_putc(m, '"');
}

/*
 * status_show - Render /proc/nixpit_virtmon/status as a single JSON object.
 * How: Copies counters under ring_lock, drops the lock, then calls seq_printf().
 * Why: seq_printf() may sleep/allocate, so it must run outside the spinlock.
 */
static int status_show(struct seq_file *m, void *v)
{
	unsigned long flags;
	u64 tot, drop, cnt[CAT_COUNT];
	unsigned int used;

	spin_lock_irqsave(&ring_lock, flags);
	tot = total_events;
	drop = dropped_events;
	used = ring_count;
	memcpy(cnt, cat_counts, sizeof(cnt));
	spin_unlock_irqrestore(&ring_lock, flags);

	seq_printf(m,
		   "{\"module\":\"nixpit_virtmon\",\"version\":\"%s\","
		   "\"cpu\":{\"vmx\":%s,\"svm\":%s,\"hypervisor_guest\":%s,\"hw_virt_available\":%s},"
		   "\"probes\":{\"module_notifier\":%s,\"netdev_notifier\":%s,"
		   "\"vfs_open_kprobe\":%s,\"exec_kprobe\":%s},"
		   "\"counters\":{\"total\":%llu,\"dropped\":%llu,"
		   "\"ring_capacity\":%u,\"ring_used\":%u,"
		   "\"kvm\":%llu,\"module\":%llu,\"network\":%llu,"
		   "\"process\":%llu,\"system\":%llu}}\n",
		   VIRTMON_VERSION,
		   cpu_vmx ? "true" : "false", cpu_svm ? "true" : "false",
		   cpu_hypervisor ? "true" : "false", (cpu_vmx || cpu_svm) ? "true" : "false",
		   mod_nb_on ? "true" : "false", net_nb_on ? "true" : "false",
		   open_kp_on ? "true" : "false", exec_kp_on ? "true" : "false",
		   tot, drop, VIRTMON_RING_SIZE, used,
		   cnt[CAT_KVM], cnt[CAT_MODULE], cnt[CAT_NETWORK],
		   cnt[CAT_PROCESS], cnt[CAT_SYSTEM]);
	return 0;
}

/*
 * events_show - Render /proc/nixpit_virtmon/events as NDJSON (oldest to newest).
 * How: Allocates a temporary GFP_KERNEL snapshot buffer, copies ring_buf under
 *      ring_lock, unlocks, formats each event as JSON via seq_file, then frees.
 * Why: Prevents holding the spinlock during slow userspace seq_printf I/O.
 */
static int events_show(struct seq_file *m, void *v)
{
	struct virtmon_event *snap;
	unsigned long flags;
	unsigned int count, i;

	snap = kmalloc_array(VIRTMON_RING_SIZE, sizeof(*snap), GFP_KERNEL);
	if (!snap)
		return -ENOMEM;

	spin_lock_irqsave(&ring_lock, flags);
	count = ring_count;
	for (i = 0; i < count; i++)
		snap[i] = ring_buf[(ring_head + i) % VIRTMON_RING_SIZE];
	spin_unlock_irqrestore(&ring_lock, flags);

	for (i = 0; i < count; i++) {
		const struct virtmon_event *ev = &snap[i];

		seq_printf(m, "{\"seq\":%llu,\"ts_sec\":%lld,\"ts_nsec\":%u,"
			      "\"category\":\"%s\",\"level\":\"%s\",\"pid\":%d,\"comm\":",
			   ev->seq, (long long)ev->ts_sec, ev->ts_nsec,
			   cat_names[ev->cat], ev->notice ? "notice" : "info", ev->pid);
		seq_json_str(m, ev->comm);
		seq_puts(m, ",\"message\":");
		seq_json_str(m, ev->message);
		seq_puts(m, "}\n");
	}

	kfree(snap);
	return 0;
}

/* Open callbacks binding /proc/nixpit_virtmon/{status,events} to seq_file. */
static int status_open(struct inode *inode, struct file *file) { return single_open(file, status_show, NULL); }
static int events_open(struct inode *inode, struct file *file) { return single_open(file, events_show, NULL); }

/*
 * control_write - Handle root writes to /proc/nixpit_virtmon/control.
 * What: Accepts "clear" (resets ring buffer) or "probe" (logs snapshot event).
 * How: Clamps input length, copies safely across user/kernel boundary with
 *      copy_from_user(), trims whitespace, and executes under ring_lock.
 * Why: Direct userspace pointer dereference would fault/violate SMAP; clamping
 *      prevents kernel stack buffer overflow.
 */
static ssize_t control_write(struct file *file, const char __user *ubuf, size_t count, loff_t *ppos)
{
	char buf[16];
	size_t len = min(count, sizeof(buf) - 1);
	unsigned long flags;

	if (!len)
		return 0;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = '\0';
	strim(buf);

	if (strcmp(buf, "clear") == 0) {
		spin_lock_irqsave(&ring_lock, flags);
		ring_head = 0;
		ring_count = 0;
		spin_unlock_irqrestore(&ring_lock, flags);
		virtmon_record(CAT_SYSTEM, true, "ring buffer cleared via /proc control");
	} else if (strcmp(buf, "probe") == 0) {
		unsigned int used;
		u64 tot;

		spin_lock_irqsave(&ring_lock, flags);
		used = ring_count;
		tot = total_events;
		spin_unlock_irqrestore(&ring_lock, flags);
		virtmon_record(CAT_SYSTEM, true,
			       "probe snapshot: vmx=%d svm=%d hv=%d total=%llu ring=%u/%u",
			       cpu_vmx, cpu_svm, cpu_hypervisor, tot, used, VIRTMON_RING_SIZE);
	} else {
		return -EINVAL;
	}
	return count;
}

static const struct proc_ops status_ops = {
	.proc_open = status_open, .proc_read = seq_read, .proc_lseek = seq_lseek, .proc_release = single_release,
};
static const struct proc_ops events_ops = {
	.proc_open = events_open, .proc_read = seq_read, .proc_lseek = seq_lseek, .proc_release = single_release,
};
static const struct proc_ops control_ops = { .proc_write = control_write };

/*
 * nixpit_virtmon_init - Module entry point called on insmod/modprobe.
 * How: Reads CPUID virt flags, creates /proc/nixpit_virtmon/{status,events,control},
 *      registers notifiers and kprobes, and records the initial startup event.
 * Why: Cleanly rolls back /proc entries if creation fails, and keeps kprobe
 *      failures non-fatal so status reporting still works on non-x86/restricted kernels.
 */
static int __init nixpit_virtmon_init(void)
{
#ifdef CONFIG_X86
	cpu_vmx = boot_cpu_has(X86_FEATURE_VMX);
	cpu_svm = boot_cpu_has(X86_FEATURE_SVM);
	cpu_hypervisor = boot_cpu_has(X86_FEATURE_HYPERVISOR);
#endif
	proc_dir = proc_mkdir("nixpit_virtmon", NULL);
	if (!proc_dir)
		return -ENOMEM;

	if (!proc_create("status", 0444, proc_dir, &status_ops) ||
	    !proc_create("events", 0444, proc_dir, &events_ops) ||
	    !proc_create("control", 0200, proc_dir, &control_ops)) {
		proc_remove(proc_dir);
		return -ENOMEM;
	}

	mod_nb_on = register_module_notifier(&virtmon_module_nb) == 0;
	net_nb_on = register_netdevice_notifier(&virtmon_netdev_nb) == 0;
#if defined(CONFIG_KPROBES) && defined(CONFIG_X86_64)
	open_kp_on = register_kprobe(&vfs_open_kp) == 0;
	exec_kp_on = register_kprobe(&exec_kp) == 0;
#endif
	virtmon_record(CAT_SYSTEM, true, "nixpit_virtmon %s loaded (vmx=%d svm=%d hv=%d)",
		       VIRTMON_VERSION, cpu_vmx, cpu_svm, cpu_hypervisor);
	return 0;
}

/*
 * nixpit_virtmon_exit - Module exit point called on rmmod.
 * How: Unregisters kprobes, netdev notifier, and module notifier in reverse order
 *      before recursively removing /proc/nixpit_virtmon.
 * Why: Reverse teardown guarantees no callback fires into freed module memory.
 */
static void __exit nixpit_virtmon_exit(void)
{
#if defined(CONFIG_KPROBES) && defined(CONFIG_X86_64)
	if (exec_kp_on)
		unregister_kprobe(&exec_kp);
	if (open_kp_on)
		unregister_kprobe(&vfs_open_kp);
#endif
	if (net_nb_on)
		unregister_netdevice_notifier(&virtmon_netdev_nb);
	if (mod_nb_on)
		unregister_module_notifier(&virtmon_module_nb);
	proc_remove(proc_dir);
	pr_info("unloaded\n");
}

module_init(nixpit_virtmon_init);
module_exit(nixpit_virtmon_exit);
