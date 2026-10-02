// SPDX-License-Identifier: BSD-2-Clause
/* Bounded userspace DMA access to the Corundum dma_bench scratch RAM. */
#include "mqnic.h"

#include <linux/auxiliary_bus.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "tag.h"

/* dma_bench.v instantiates 16 KiB of RAM.  Only its low 8 KiB is exposed
 * until the whole address range is validated on the MSA-2020 board.
 */
#define WQ_CARD_BYTES       8192
#define WQ_STAGE_BYTES      4096
#define WQ_STATUS_VALID     BIT(31)
#define WQ_STATUS_ERROR     GENMASK(27, 24)
#define WQ_STATUS_TAG       GENMASK(15, 0)

struct wqfpga {
	struct kref refs;
	struct mutex lock; /* serializes all DMA and removal */
	struct miscdevice misc;
	struct device *dev;
	struct device *dma_dev;
	struct pci_dev *pdev;
	struct mqnic_reg_block *rb_list;
	struct mqnic_reg_block *dma_rb;
	void *stage;
	dma_addr_t stage_dma;
	char *name;
	u16 next_tag;
	bool online;
	bool quarantined;
};

static void wqfpga_release_ref(struct kref *ref)
{
	struct wqfpga *wq = container_of(ref, struct wqfpga, refs);

	kfree(wq->name);
	/* A timed-out DMA buffer deliberately remains allocated and mapped.
	 * Keep the PCI device object as well until a host restart.  This is a
	 * bounded quarantine, not a normal cleanup path.
	 */
	if (!wq->quarantined)
		put_device(wq->dma_dev);
	kfree(wq);
}

static void wqfpga_quarantine(struct wqfpga *wq, const char *reason)
{
	if (wq->quarantined)
		return;
	wq->quarantined = true;
	/* No cancellation register exists for a dma_bench single descriptor.
	 * Stop further bus mastering and never reuse/free the DMA buffer.
	 */
	pci_clear_master(wq->pdev);
	dev_crit(wq->dev, "%s; bus mastering disabled, DMA buffer quarantined; power-cycle FPGA before rebooting the host\n",
		 reason);
}

static int wqfpga_wait(struct wqfpga *wq, u32 status_offset, u16 tag)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(1000);
	u8 __iomem *regs = wq->dma_rb->regs;
	u32 status;

	for (;;) {
		/* The hardware clears the valid bit on each status read. */
		status = ioread32(regs + status_offset);
		if (status & WQ_STATUS_VALID) {
			if ((status & WQ_STATUS_TAG) != tag ||
			    (status & WQ_STATUS_ERROR)) {
				dev_err(wq->dev, "DMA status 0x%08x at 0x%x, expected tag %u\n",
					status, status_offset, tag);
				wqfpga_quarantine(wq, "unexpected DMA completion");
				return -EIO;
			}
			dma_rmb();
			return 0;
		}
		if (time_after_eq(jiffies, deadline)) {
			wqfpga_quarantine(wq, "DMA completion timed out");
			return -ETIMEDOUT;
		}
		usleep_range(50, 100);
	}
}

/* Caller holds lock and supplies only offsets within the owned buffer and
 * the published low 8 KiB of card RAM.  No userspace DMA address is accepted.
 */
static int wqfpga_xfer(struct wqfpga *wq, bool host_to_card,
			   u32 card_offset, u32 count)
{
	u8 __iomem *regs = wq->dma_rb->regs;
	u32 base = host_to_card ? 0x100 : 0x200;
	u16 tag;

	if (!count || count > WQ_STAGE_BYTES ||
	    card_offset > WQ_CARD_BYTES - count)
		return -EINVAL;
	wq->next_tag = wq_dma_next_tag(wq->next_tag);
	tag = wq->next_tag;

	/* Discard an old read-to-clear completion before posting this request. */
	ioread32(regs + base + 0x18);
	iowrite32(lower_32_bits(wq->stage_dma), regs + base);
	iowrite32(upper_32_bits(wq->stage_dma), regs + base + 0x04);
	iowrite32(card_offset, regs + base + 0x08);
	iowrite32(count, regs + base + 0x10);
	dma_wmb();
	iowrite32(tag, regs + base + 0x14);
	return wqfpga_wait(wq, base + 0x18, tag);
}

static int wqfpga_open(struct inode *inode, struct file *file)
{
	struct miscdevice *misc = file->private_data;
	struct wqfpga *wq = container_of(misc, struct wqfpga, misc);
	int ret = 0;

	kref_get(&wq->refs);
	mutex_lock(&wq->lock);
	if (!wq->online || wq->quarantined)
		ret = -ENODEV;
	mutex_unlock(&wq->lock);
	if (ret) {
		kref_put(&wq->refs, wqfpga_release_ref);
		return ret;
	}
	file->private_data = wq;
	return 0;
}

static int wqfpga_close(struct inode *inode, struct file *file)
{
	struct wqfpga *wq = file->private_data;

	kref_put(&wq->refs, wqfpga_release_ref);
	return 0;
}

static ssize_t wqfpga_rw(struct file *file, char __user *user,
			 size_t count, loff_t *pos, bool host_to_card)
{
	struct wqfpga *wq = file->private_data;
	size_t done = 0, limit, n;
	int ret = 0;

	if (!count)
		return 0;
	if (*pos < 0)
		return -EINVAL;
	if (*pos >= WQ_CARD_BYTES)
		return host_to_card ? -ENOSPC : 0;
	limit = min_t(size_t, count, WQ_CARD_BYTES - *pos);
	ret = mutex_lock_interruptible(&wq->lock);
	if (ret)
		return ret;
	if (!wq->online) {
		ret = -ENODEV;
		goto out;
	}
	if (wq->quarantined) {
		ret = -EIO;
		goto out;
	}

	while (done < limit) {
		n = min_t(size_t, WQ_STAGE_BYTES, limit - done);
		if (host_to_card) {
			if (copy_from_user(wq->stage, user + done, n)) {
				ret = -EFAULT;
				break;
			}
		} else {
			memset(wq->stage, 0, n);
		}
		ret = wqfpga_xfer(wq, host_to_card, (u32)(*pos + done), n);
		if (ret)
			break;
		if (!host_to_card && copy_to_user(user + done, wq->stage, n)) {
			ret = -EFAULT;
			break;
		}
		done += n;
	}
	*pos += done;
out:
	mutex_unlock(&wq->lock);
	return done ? done : ret;
}

static ssize_t wqfpga_read(struct file *file, char __user *buf,
			   size_t count, loff_t *pos)
{
	return wqfpga_rw(file, buf, count, pos, false);
}

static ssize_t wqfpga_write(struct file *file, const char __user *buf,
			    size_t count, loff_t *pos)
{
	return wqfpga_rw(file, (char __user *)buf, count, pos, true);
}

static loff_t wqfpga_llseek(struct file *file, loff_t offset, int whence)
{
	return fixed_size_llseek(file, offset, whence, WQ_CARD_BYTES);
}

static const struct file_operations wqfpga_fops = {
	.owner = THIS_MODULE,
	.open = wqfpga_open,
	.release = wqfpga_close,
	.read = wqfpga_read,
	.write = wqfpga_write,
	.llseek = wqfpga_llseek,
};

static int wqfpga_probe(struct auxiliary_device *adev,
			const struct auxiliary_device_id *id)
{
	struct mqnic_dev *mdev = container_of(adev, struct mqnic_adev, adev)->mdev;
	struct wqfpga *wq;
	int ret;

	if (!mdev->pdev || !mdev->app_hw_addr || mdev->app_hw_regs_size < 0x1000)
		return -ENODEV;
	wq = kzalloc(sizeof(*wq), GFP_KERNEL);
	if (!wq)
		return -ENOMEM;
	kref_init(&wq->refs);
	mutex_init(&wq->lock);
	wq->dev = &adev->dev;
	wq->pdev = mdev->pdev;
	wq->dma_dev = get_device(mdev->dev);
	if (!wq->dma_dev) {
		ret = -ENODEV;
		goto fail_free;
	}
	wq->rb_list = mqnic_enumerate_reg_block_list(mdev->app_hw_addr, 0,
					       mdev->app_hw_regs_size);
	if (!wq->rb_list) {
		ret = -EIO;
		goto fail_ref;
	}
	wq->dma_rb = mqnic_find_reg_block(wq->rb_list, 0x12348101,
					  0x00000100, 0);
	if (!wq->dma_rb) {
		ret = -ENODEV;
		goto fail_blocks;
	}
	wq->stage = dma_alloc_coherent(wq->dma_dev, WQ_STAGE_BYTES,
				       &wq->stage_dma, GFP_KERNEL);
	if (!wq->stage) {
		ret = -ENOMEM;
		goto fail_blocks;
	}
	wq->name = kasprintf(GFP_KERNEL, "wqfpga%d", adev->id);
	if (!wq->name) {
		ret = -ENOMEM;
		goto fail_dma;
	}
	wq->misc.minor = MISC_DYNAMIC_MINOR;
	wq->misc.name = wq->name;
	wq->misc.fops = &wqfpga_fops;
	wq->misc.parent = &adev->dev;
	wq->online = true;
	ret = misc_register(&wq->misc);
	if (ret)
		goto fail_dma;
	dev_set_drvdata(&adev->dev, wq);
	dev_info(wq->dev, "/dev/%s: read/write DMA, low %u bytes of card RAM\n",
		 wq->name, WQ_CARD_BYTES);
	return 0;

fail_dma:
	dma_free_coherent(wq->dma_dev, WQ_STAGE_BYTES, wq->stage,
			  wq->stage_dma);
fail_blocks:
	mqnic_free_reg_block_list(wq->rb_list);
fail_ref:
	put_device(wq->dma_dev);
fail_free:
	kfree(wq->name);
	kfree(wq);
	return ret;
}

static void wqfpga_remove(struct auxiliary_device *adev)
{
	struct wqfpga *wq = dev_get_drvdata(&adev->dev);

	if (!wq)
		return;
	misc_deregister(&wq->misc);
	mutex_lock(&wq->lock);
	wq->online = false;
	if (wq->quarantined) {
		dev_crit(wq->dev, "retaining quarantined %u-byte DMA buffer and mapping\n",
			 WQ_STAGE_BYTES);
	} else {
		dma_free_coherent(wq->dma_dev, WQ_STAGE_BYTES, wq->stage,
				  wq->stage_dma);
	}
	mqnic_free_reg_block_list(wq->rb_list);
	wq->rb_list = NULL;
	wq->dma_rb = NULL;
	wq->pdev = NULL;
	mutex_unlock(&wq->lock);
	dev_set_drvdata(&adev->dev, NULL);
	kref_put(&wq->refs, wqfpga_release_ref);
}

static const struct auxiliary_device_id wqfpga_ids[] = {
	{ .name = "mqnic.app_12348001" },
	{},
};
MODULE_DEVICE_TABLE(auxiliary, wqfpga_ids);

static struct auxiliary_driver wqfpga_driver = {
	.name = "wqfpga_dma",
	.probe = wqfpga_probe,
	.remove = wqfpga_remove,
	.id_table = wqfpga_ids,
};

static int __init wqfpga_init(void)
{
	return auxiliary_driver_register(&wqfpga_driver);
}

static void __exit wqfpga_exit(void)
{
	auxiliary_driver_unregister(&wqfpga_driver);
}

module_init(wqfpga_init);
module_exit(wqfpga_exit);

MODULE_DESCRIPTION("Bounded userspace DMA access to Corundum dma_bench RAM");
MODULE_AUTHOR("WolfQuant hardware prototype");
MODULE_LICENSE("Dual BSD/GPL");
