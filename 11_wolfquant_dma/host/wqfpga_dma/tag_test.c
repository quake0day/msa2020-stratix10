// SPDX-License-Identifier: BSD-2-Clause
#include "tag.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
	unsigned int tag = 0;
	unsigned int i;

	assert(wq_dma_next_tag(0) == 1);
	assert(wq_dma_next_tag(WQ_DMA_APP_TAG_MAX) == 1);
	assert(wq_dma_next_tag(0xffff) == 1);
	for (i = 0; i < 100000; i++) {
		unsigned int previous = tag;
		tag = wq_dma_next_tag(tag);
		assert(tag > 0 && tag <= WQ_DMA_APP_TAG_MAX);
		assert(tag == (previous == WQ_DMA_APP_TAG_MAX ? 1 : previous + 1));
	}
	printf("PASS: 100000 tags stayed in 1..%u and wrapped correctly\n",
	       WQ_DMA_APP_TAG_MAX);
	return 0;
}
