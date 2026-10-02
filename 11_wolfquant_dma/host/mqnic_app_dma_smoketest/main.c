// SPDX-License-Identifier: BSD-2-Clause
/* Minimal bounded host -> FPGA RAM -> host DMA proof for the MSA-2020.
 * Based on Corundum's mqnic_app_dma_bench register protocol.
 */
#include "mqnic.h"
#include <linux/auxiliary_bus.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/pci.h>

#define WQ_DMA_BUFFER_SIZE (16 * 1024)
#define WQ_DMA_DEST_OFFSET (8 * 1024)
#define WQ_DMA_RAM_OFFSET 0x100

static unsigned int test_len = 256;
module_param(test_len, uint, 0444);
MODULE_PARM_DESC(test_len, "Roundtrip bytes, 1..8192 (default 256)");

struct wq_dma_test {
	struct device *dev;
	struct device *dma_dev;
	struct pci_dev *pdev;
	struct mqnic_reg_block *rb_list;
	struct mqnic_reg_block *dma_rb;
	void *buffer;
	dma_addr_t dma_addr;
	bool stalled;
};

static int wq_wait_status(struct wq_dma_test *test, u32 offset, u16 tag)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(1000);
	u32 status;

	do {
		/* Status is read-to-clear; inspect valid/error/tag together. */
		status = ioread32(test->dma_rb->regs + offset);
		if (status & 0x80000000) {
			if ((status & 0xffff) != tag || (status & 0x0f000000)) {
				dev_err(test->dev, "DMA completion error at 0x%x: 0x%08x\n",
					offset, status);
				return -EIO;
			}
			return 0;
		}
		usleep_range(50, 100);
	} while (time_before(jiffies, deadline));

	dev_err(test->dev, "DMA completion timeout at 0x%x\n", offset);
	/* Preserve the mapped buffer if completion is unknown; stop new bus DMA. */
	test->stalled = true;
	pci_clear_master(test->pdev);
	return -ETIMEDOUT;
}

static int wq_dma_copy(struct wq_dma_test *test, bool to_card,
			dma_addr_t host_addr, u32 ram_addr, u32 len, u16 tag)
{
	void __iomem *regs = test->dma_rb->regs;
	u32 base = to_card ? 0x100 : 0x200;

	/* The DMA address comes only from dma_alloc_coherent on this PCI device. */
	ioread32(regs + base + 0x18); /* Clear any prior completion. */
	iowrite32(lower_32_bits(host_addr), regs + base + 0x00);
	iowrite32(upper_32_bits(host_addr), regs + base + 0x04);
	iowrite32(ram_addr, regs + base + 0x08);
	iowrite32(len, regs + base + 0x10);
	dma_wmb();
	iowrite32(tag, regs + base + 0x14);
	return wq_wait_status(test, base + 0x18, tag);
}

static void wq_dma_test_remove(struct auxiliary_device *adev)
{
	struct wq_dma_test *test = dev_get_drvdata(&adev->dev);

	if (!test)
		return;
	if (test->stalled)
		dev_err(test->dev, "DMA buffer quarantined after timeout; reset FPGA before retry\n");
	if (test->buffer && !test->stalled)
		dma_free_coherent(test->dma_dev, WQ_DMA_BUFFER_SIZE,
				test->buffer, test->dma_addr);
	if (test->rb_list)
		mqnic_free_reg_block_list(test->rb_list);
	test->buffer = NULL;
	test->rb_list = NULL;
}

static int wq_dma_test_probe(struct auxiliary_device *adev,
			const struct auxiliary_device_id *id)
{
	struct mqnic_dev *mdev = container_of(adev, struct mqnic_adev, adev)->mdev;
	struct wq_dma_test *test;
	u8 *bytes;
	unsigned int i;
	int ret;

	if (!test_len || test_len > WQ_DMA_DEST_OFFSET)
		return -EINVAL;
	if (!mdev->app_hw_addr || mdev->app_hw_regs_size < 0x220)
		return -ENODEV;

	test = devm_kzalloc(&adev->dev, sizeof(*test), GFP_KERNEL);
	if (!test)
		return -ENOMEM;
	test->dev = &adev->dev;
	test->dma_dev = mdev->dev;
	test->pdev = to_pci_dev(mdev->dev);
	dev_set_drvdata(&adev->dev, test);

	test->rb_list = mqnic_enumerate_reg_block_list(mdev->app_hw_addr, 0,
			mdev->app_hw_regs_size);
	if (!test->rb_list) {
		ret = -EIO;
		goto fail;
	}
	test->dma_rb = mqnic_find_reg_block(test->rb_list, 0x12348101,
			0x00000100, 0);
	if (!test->dma_rb) {
		ret = -ENODEV;
		goto fail;
	}

	test->buffer = dma_alloc_coherent(test->dma_dev, WQ_DMA_BUFFER_SIZE,
			&test->dma_addr, GFP_KERNEL);
	if (!test->buffer) {
		ret = -ENOMEM;
		goto fail;
	}
	bytes = test->buffer;
	for (i = 0; i < test_len; i++)
		bytes[i] = (i * 131 + 17) & 0xff;
	memset(bytes + WQ_DMA_DEST_OFFSET, 0, test_len);

	ret = wq_dma_copy(test, true, test->dma_addr,
			WQ_DMA_RAM_OFFSET, test_len, 1);
	if (ret)
		goto fail;
	ret = wq_dma_copy(test, false, test->dma_addr + WQ_DMA_DEST_OFFSET,
			WQ_DMA_RAM_OFFSET, test_len, 2);
	if (ret)
		goto fail;
	dma_rmb();
	if (memcmp(bytes, bytes + WQ_DMA_DEST_OFFSET, test_len)) {
		dev_err(test->dev, "DMA roundtrip mismatch (%u bytes)\n", test_len);
		ret = -EIO;
		goto fail;
	}
	dev_info(test->dev, "DMA roundtrip passed: %u bytes host -> FPGA -> host\n",
			test_len);
	return 0;

fail:
	wq_dma_test_remove(adev);
	return ret;
}

static const struct auxiliary_device_id wq_dma_test_ids[] = {
	{ .name = "mqnic.app_12348001" },
	{},
};
MODULE_DEVICE_TABLE(auxiliary, wq_dma_test_ids);

static struct auxiliary_driver wq_dma_test_driver = {
	.name = "mqnic_app_dma_smoketest",
	.probe = wq_dma_test_probe,
	.remove = wq_dma_test_remove,
	.id_table = wq_dma_test_ids,
};

static int __init wq_dma_test_init(void)
{
	return auxiliary_driver_register(&wq_dma_test_driver);
}

static void __exit wq_dma_test_exit(void)
{
	auxiliary_driver_unregister(&wq_dma_test_driver);
}

module_init(wq_dma_test_init);
module_exit(wq_dma_test_exit);

MODULE_DESCRIPTION("MSA-2020 bounded Corundum DMA roundtrip self-test");
MODULE_AUTHOR("WolfQuant hardware prototype");
MODULE_LICENSE("Dual BSD/GPL");
