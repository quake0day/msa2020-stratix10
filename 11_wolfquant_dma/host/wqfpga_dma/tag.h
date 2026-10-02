// SPDX-License-Identifier: BSD-2-Clause
#ifndef WQFPGA_DMA_TAG_H
#define WQFPGA_DMA_TAG_H

/* mqnic_core: DMA_TAG_WIDTH (16) - ceil(log2(IF_COUNT + APP)) (2) - 1
 * for the control/data mux = 13 usable application tag bits.
 */
#define WQ_DMA_APP_TAG_BITS 13U
#define WQ_DMA_APP_TAG_MAX ((1U << WQ_DMA_APP_TAG_BITS) - 1U)

static inline unsigned int wq_dma_next_tag(unsigned int previous)
{
	return previous >= WQ_DMA_APP_TAG_MAX ? 1U : previous + 1U;
}

#endif
