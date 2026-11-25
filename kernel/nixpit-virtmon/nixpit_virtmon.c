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
#include <linux/cred.h>
#include <linux/user_namespace.h>
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

struct virtmon_event {
	u64 seq;
	s64 ts_sec;
	u32 ts_nsec;
	char category[16];
	char level[8];
	pid_t pid;
	u32 uid;
	char comm[TASK_COMM_LEN];
	char message[192];
};

static struct virtmon_event ring_buf[VIRTMON_RING_SIZE];
static DEFINE_SPINLOCK(ring_lock);
static unsigned int ring_head;
static unsigned int ring_count;
static u64 next_seq = 1;
static u64 total_events;
static u64 dropped_events;
static u64 cnt_kvm;
static u64 cnt_module;
static u64 cnt_network;
static u64 cnt_process;
static u64 cnt_system;

static bool cpu_vmx;
static bool cpu_svm;
static bool cpu_hypervisor;

static bool module_notifier_active;
static bool netdev_notifier_active;
static bool vfs_open_kprobe_active;
static bool exec_kprobe_active;

static struct proc_dir_entry *proc_dir;
static struct proc_dir_entry *proc_status;
static struct proc_dir_entry *proc_events;
static struct proc_dir_entry *proc_control;

static void detect_cpu_virt(void)
{
#ifdef CONFIG_X86
	cpu_vmx = boot_cpu_has(X86_FEATURE_VMX);
	cpu_svm = boot_cpu_has(X86_FEATURE_SVM);
	cpu_hypervisor = boot_cpu_has(X86_FEATURE_HYPERVISOR);
#else
	cpu_vmx = false;
	cpu_svm = false;
	cpu_hypervisor = false;
#endif
}

static void virtmon_record(const char *category, const char *level, const char *fmt, ...)
{
	struct virtmon_event ev;
	struct timespec64 ts;
	unsigned long flags;
	unsigned int idx;
	va_list args;

	ktime_get_real_ts64(&ts);
	ev.ts_sec = ts.tv_sec;
	ev.ts_nsec = (u32)ts.tv_nsec;

	strscpy(ev.category, category ? category : "system", sizeof(ev.category));
	strscpy(ev.level, level ? level : "info", sizeof(ev.level));
	ev.pid = current ? task_pid_nr(current) : 0;
	ev.uid = current ? from_kuid_munged(&init_user_ns, current_uid()) : 0;
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

	if (strcmp(ev.category, "kvm") == 0)
		cnt_kvm++;
	else if (strcmp(ev.category, "module") == 0)
		cnt_module++;
	else if (strcmp(ev.category, "network") == 0)
		cnt_network++;
	else if (strcmp(ev.category, "process") == 0)
		cnt_process++;
	else
		cnt_system++;

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
			   ev.category, ev.level, ev.pid, ev.comm, ev.message);
}

static bool is_virt_module(const char *name)
{
	static const char *const virt_mods[] = {
		"kvm", "kvm_intel", "kvm_amd",
		"vhost", "vhost_net", "vhost_vsock", "vhost_scsi",
		"vfio", "vfio_pci", "vfio_iommu_type1",
		"tun", "tap", "macvtap", "bridge", "br_netfilter", "overlay",
		"virtio_net", "virtio_blk", "virtio_pci", "virtio_balloon",
		"virtio_console", "virtio_gpu", "virtiofs",
	};
	size_t i;

	if (!name)
		return false;

	for (i = 0; i < ARRAY_SIZE(virt_mods); i++) {
		if (strcmp(name, virt_mods[i]) == 0)
			return true;
	}
	return false;
}

static int virtmon_module_cb(struct notifier_block *nb, unsigned long val, void *data)
{
	struct module *mod = data;

	if (!mod || !is_virt_module(mod->name))
		return NOTIFY_DONE;

	if (val == MODULE_STATE_LIVE)
		virtmon_record("module", "notice", "kernel module loaded: %s", mod->name);
	else if (val == MODULE_STATE_GOING)
		virtmon_record("module", "notice", "kernel module unloading: %s", mod->name);

	return NOTIFY_DONE;
}

static struct notifier_block virtmon_module_nb = {
	.notifier_call = virtmon_module_cb,
};

static bool is_virt_netdev(const char *ifname)
{
	static const char *const prefixes[] = {
		"virbr", "vnet", "tap", "macvtap", "podman", "veth", "cni", "br", "vmbr",
	};
	size_t i;

	if (!ifname)
		return false;

	for (i = 0; i < ARRAY_SIZE(prefixes); i++) {
		if (strncmp(ifname, prefixes[i], strlen(prefixes[i])) == 0)
			return true;
	}
	return false;
}

static int virtmon_netdev_cb(struct notifier_block *nb, unsigned long event, void *ptr)
{
	struct net_device *dev = netdev_notifier_info_to_dev(ptr);
	const char *ev_name = NULL;

	if (!dev || !is_virt_netdev(dev->name))
		return NOTIFY_DONE;

	switch (event) {
	case NETDEV_REGISTER:
		ev_name = "registered";
		break;
	case NETDEV_UNREGISTER:
		ev_name = "unregistered";
		break;
	case NETDEV_UP:
		ev_name = "up";
		break;
	case NETDEV_DOWN:
		ev_name = "down";
		break;
	default:
		return NOTIFY_DONE;
	}

	virtmon_record("network", "info", "virtual interface %s %s (ifindex=%d)",
		       dev->name, ev_name, dev->ifindex);
	return NOTIFY_DONE;
}

static struct notifier_block virtmon_netdev_nb = {
	.notifier_call = virtmon_netdev_cb,
};

#if defined(CONFIG_KPROBES) && defined(CONFIG_X86_64)
static int vfs_open_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	const struct path *path = (const struct path *)regs->di;
	struct dentry *dentry;
	struct dentry *parent;
	const char *name;
	const char *pname;

	if (!path || !path->dentry)
		return 0;

	dentry = path->dentry;
	if (!dentry->d_inode || !S_ISCHR(dentry->d_inode->i_mode))
		return 0;

	name = (const char *)dentry->d_name.name;
	if (!name)
		return 0;

	parent = dentry->d_parent;
	pname = (parent && parent->d_name.name) ? (const char *)parent->d_name.name : "";

	if (strcmp(name, "kvm") == 0 ||
	    strcmp(name, "vhost-net") == 0 ||
	    strcmp(name, "vhost-vsock") == 0) {
		virtmon_record("kvm", "info", "opened /dev/%s", name);
	} else if (strcmp(name, "tun") == 0 && strcmp(pname, "net") == 0) {
		virtmon_record("kvm", "info", "opened /dev/net/tun");
	} else if (strcmp(pname, "vfio") == 0) {
		virtmon_record("kvm", "notice", "opened /dev/vfio/%s", name);
	}

	return 0;
}

static struct kprobe vfs_open_kp = {
	.symbol_name = "vfs_open",
	.pre_handler = vfs_open_pre_handler,
};

static const char *virtmon_basename(const char *path)
{
	const char *slash;

	if (!path)
		return NULL;
	slash = strrchr(path, '/');
	return slash ? slash + 1 : path;
}

static bool is_virt_binary(const char *base)
{
	static const char *const exact[] = {
		"qemu-kvm", "libvirtd", "virtqemud", "virtlogd", "virsh",
		"podman", "conmon", "crun", "runc", "swtpm", "virtiofsd",
	};
	size_t i;

	if (!base)
		return false;

	if (strncmp(base, "qemu-system-", strlen("qemu-system-")) == 0)
		return true;

	for (i = 0; i < ARRAY_SIZE(exact); i++) {
		if (strcmp(base, exact[i]) == 0)
			return true;
	}
	return false;
}

static int exec_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	const struct linux_binprm *bprm = (const struct linux_binprm *)regs->di;
	const char *base;

	if (!bprm || !bprm->filename)
		return 0;

	base = virtmon_basename(bprm->filename);
	if (is_virt_binary(base))
		virtmon_record("process", "info", "exec %s", bprm->filename);

	return 0;
}

static struct kprobe exec_kp = {
	.symbol_name = "security_bprm_check",
	.pre_handler = exec_pre_handler,
};
#endif

static void virtmon_seq_json_str(struct seq_file *m, const char *s)
{
	const unsigned char *p = (const unsigned char *)(s ? s : "");

	seq_putc(m, '"');
	while (*p) {
		unsigned char c = *p++;

		if (c == '"')
			seq_puts(m, "\\\"");
		else if (c == '\\')
			seq_puts(m, "\\\\");
		else if (c == '\b')
			seq_puts(m, "\\b");
		else if (c == '\f')
			seq_puts(m, "\\f");
		else if (c == '\n')
			seq_puts(m, "\\n");
		else if (c == '\r')
			seq_puts(m, "\\r");
		else if (c == '\t')
			seq_puts(m, "\\t");
		else if (c < 0x20)
			seq_printf(m, "\\u%04x", c);
		else
			seq_putc(m, c);
	}
	seq_putc(m, '"');
}

static int status_show(struct seq_file *m, void *v)
{
	unsigned long flags;
	u64 tot, drop, k, mod, net, proc, sys;
	unsigned int used;

	spin_lock_irqsave(&ring_lock, flags);
	tot = total_events;
	drop = dropped_events;
	used = ring_count;
	k = cnt_kvm;
	mod = cnt_module;
	net = cnt_network;
	proc = cnt_process;
	sys = cnt_system;
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
		   cpu_vmx ? "true" : "false",
		   cpu_svm ? "true" : "false",
		   cpu_hypervisor ? "true" : "false",
		   (cpu_vmx || cpu_svm) ? "true" : "false",
		   module_notifier_active ? "true" : "false",
		   netdev_notifier_active ? "true" : "false",
		   vfs_open_kprobe_active ? "true" : "false",
		   exec_kprobe_active ? "true" : "false",
		   tot, drop, VIRTMON_RING_SIZE, used,
		   k, mod, net, proc, sys);
	return 0;
}

static int status_open(struct inode *inode, struct file *file)
{
	return single_open(file, status_show, NULL);
}

static const struct proc_ops status_proc_ops = {
	.proc_open = status_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int events_show(struct seq_file *m, void *v)
{
	struct virtmon_event *snapshot;
	unsigned long flags;
	unsigned int count = 0;
	unsigned int i;

	snapshot = kmalloc_array(VIRTMON_RING_SIZE, sizeof(*snapshot), GFP_KERNEL);
	if (!snapshot)
		return -ENOMEM;

	spin_lock_irqsave(&ring_lock, flags);
	count = ring_count;
	for (i = 0; i < count; i++) {
		unsigned int idx = (ring_head + i) % VIRTMON_RING_SIZE;

		snapshot[i] = ring_buf[idx];
	}
	spin_unlock_irqrestore(&ring_lock, flags);

	for (i = 0; i < count; i++) {
		const struct virtmon_event *ev = &snapshot[i];

		seq_printf(m, "{\"seq\":%llu,\"ts_sec\":%lld,\"ts_nsec\":%u,",
			   ev->seq, (long long)ev->ts_sec, ev->ts_nsec);
		seq_puts(m, "\"category\":");
		virtmon_seq_json_str(m, ev->category);
		seq_puts(m, ",\"level\":");
		virtmon_seq_json_str(m, ev->level);
		seq_printf(m, ",\"pid\":%d,\"uid\":%u,\"comm\":", ev->pid, ev->uid);
		virtmon_seq_json_str(m, ev->comm);
		seq_puts(m, ",\"message\":");
		virtmon_seq_json_str(m, ev->message);
		seq_puts(m, "}\n");
	}

	kfree(snapshot);
	return 0;
}

static int events_open(struct inode *inode, struct file *file)
{
	return single_open(file, events_show, NULL);
}

static const struct proc_ops events_proc_ops = {
	.proc_open = events_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static ssize_t control_write(struct file *file, const char __user *ubuf,
			     size_t count, loff_t *ppos)
{
	char buf[32];
	size_t len = min(count, sizeof(buf) - 1);
	unsigned long flags;

	if (len == 0)
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
		virtmon_record("system", "notice", "ring buffer cleared via /proc control");
	} else if (strcmp(buf, "probe") == 0) {
		unsigned int used;
		u64 tot;

		spin_lock_irqsave(&ring_lock, flags);
		used = ring_count;
		tot = total_events;
		spin_unlock_irqrestore(&ring_lock, flags);

		virtmon_record("system", "notice",
			       "probe snapshot: vmx=%d svm=%d hv=%d total=%llu ring=%u/%u",
			       cpu_vmx ? 1 : 0, cpu_svm ? 1 : 0, cpu_hypervisor ? 1 : 0,
			       tot, used, VIRTMON_RING_SIZE);
	} else {
		return -EINVAL;
	}

	return count;
}

static const struct proc_ops control_proc_ops = {
	.proc_write = control_write,
};

static int __init nixpit_virtmon_init(void)
{
	detect_cpu_virt();

	proc_dir = proc_mkdir("nixpit_virtmon", NULL);
	if (!proc_dir)
		return -ENOMEM;

	proc_status = proc_create("status", 0444, proc_dir, &status_proc_ops);
	proc_events = proc_create("events", 0444, proc_dir, &events_proc_ops);
	proc_control = proc_create("control", 0200, proc_dir, &control_proc_ops);
	if (!proc_status || !proc_events || !proc_control) {
		proc_remove(proc_dir);
		return -ENOMEM;
	}

	if (register_module_notifier(&virtmon_module_nb) == 0)
		module_notifier_active = true;

	if (register_netdevice_notifier(&virtmon_netdev_nb) == 0)
		netdev_notifier_active = true;

#if defined(CONFIG_KPROBES) && defined(CONFIG_X86_64)
	if (register_kprobe(&vfs_open_kp) == 0)
		vfs_open_kprobe_active = true;

	if (register_kprobe(&exec_kp) == 0)
		exec_kprobe_active = true;
#endif

	virtmon_record("system", "notice",
		       "nixpit_virtmon %s loaded (vmx=%d svm=%d hv=%d)",
		       VIRTMON_VERSION,
		       cpu_vmx ? 1 : 0, cpu_svm ? 1 : 0, cpu_hypervisor ? 1 : 0);
	return 0;
}

static void __exit nixpit_virtmon_exit(void)
{
#if defined(CONFIG_KPROBES) && defined(CONFIG_X86_64)
	if (exec_kprobe_active)
		unregister_kprobe(&exec_kp);
	if (vfs_open_kprobe_active)
		unregister_kprobe(&vfs_open_kp);
#endif
	if (netdev_notifier_active)
		unregister_netdevice_notifier(&virtmon_netdev_nb);
	if (module_notifier_active)
		unregister_module_notifier(&virtmon_module_nb);

	proc_remove(proc_dir);
	pr_info("unloaded\n");
}

module_init(nixpit_virtmon_init);
module_exit(nixpit_virtmon_exit);
