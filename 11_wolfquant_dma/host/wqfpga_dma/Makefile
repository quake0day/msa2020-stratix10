ifneq ($(KERNELRELEASE),)
KBUILD_EXTRA_SYMBOLS := $(src)/../mqnic/Module.symvers
ccflags-y += -I$(src)/../mqnic/
obj-m += wqfpga_dma.o
wqfpga_dma-y := main.o
else
KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all module tool test clean
all: module tool

module:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

tool:
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -D_FILE_OFFSET_BITS=64 -o wqfpga-loopback loopback.c

test:
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -o wqfpga-tag-test tag_test.c
	./wqfpga-tag-test

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	$(RM) wqfpga-loopback wqfpga-tag-test
endif
