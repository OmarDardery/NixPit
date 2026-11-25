obj-m += nixpit_virtmon.o

KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

modules_install:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) INSTALL_MOD_DIR=extra modules_install

clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
