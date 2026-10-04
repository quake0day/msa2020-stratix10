ifneq ($(KERNELRELEASE),)
KBUILD_EXTRA_SYMBOLS=$(src)/../mqnic/Module.symvers
ccflags-y += -I$(src)/../mqnic/
obj-m += mqnic_app_dma_smoketest.o
mqnic_app_dma_smoketest-y += main.o
else
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(shell pwd) modules
clean:
	$(MAKE) -C $(KDIR) M=$(shell pwd) clean
endif
