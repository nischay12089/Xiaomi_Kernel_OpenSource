// SPDX-License-Identifier: GPL-2.0-only
/*
 * Stand-in for the fg_info part of OPLUS sched_info (osi_healthinfo.c), which
 * depends on the OPLUS WALT and can't be loaded on other devices. Provides
 * is_fg() for hybridswap and /proc/fg_info/fg_uids, where the OPLUS framework
 * writes the uid of the foreground app.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>

#define FG_RW		0666
#define MAX_ARRAY_LENGTH	256

static int fg_uids = -555;
static struct proc_dir_entry *fg_dir;

bool is_fg(int uid)
{
	return uid == READ_ONCE(fg_uids);
}
EXPORT_SYMBOL_GPL(is_fg);

static int fg_uids_show(struct seq_file *m, void *v)
{
	seq_printf(m, "fg_uids: %d\n", READ_ONCE(fg_uids));
	return 0;
}

static int fg_uids_open(struct inode *inode, struct file *file)
{
	return single_open(file, fg_uids_show, inode);
}

static ssize_t fg_uids_write(struct file *file, const char __user *buf,
		size_t count, loff_t *ppos)
{
	char buffer[MAX_ARRAY_LENGTH] = { 0 };

	if (count > sizeof(buffer) - 1)
		count = sizeof(buffer) - 1;
	if (copy_from_user(buffer, buf, count))
		return -EFAULT;

	WRITE_ONCE(fg_uids, (int)simple_strtol(buffer, NULL, 0));
	return count;
}

static const struct proc_ops proc_fg_uids_operations = {
	.proc_open	= fg_uids_open,
	.proc_read	= seq_read,
	.proc_write	= fg_uids_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static int __init oplus_fg_info_init(void)
{
	fg_dir = proc_mkdir("fg_info", NULL);
	if (!fg_dir)
		return -ENOMEM;

	if (!proc_create("fg_uids", FG_RW, fg_dir, &proc_fg_uids_operations)) {
		proc_remove(fg_dir);
		return -ENOMEM;
	}

	return 0;
}

static void __exit oplus_fg_info_exit(void)
{
	proc_remove(fg_dir);
}

module_init(oplus_fg_info_init);
module_exit(oplus_fg_info_exit);
MODULE_DESCRIPTION("OPLUS fg_info (is_fg) for non-OPLUS devices");
MODULE_LICENSE("GPL v2");
