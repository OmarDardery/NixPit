# Out-of-tree Linux kbuild Makefile for nixpit_virtmon.ko.
# Kbuild reads obj-m to compile nixpit_virtmon.c into nixpit_virtmon.ko against KERNELDIR.
obj-m += nixpit_virtmon.o

KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Build nixpit_virtmon.ko using the target kernel's build system.
all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

# Install the compiled .ko under $(INSTALL_MOD_PATH)/lib/modules/<ver>/extra/.
modules_install:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) INSTALL_MOD_DIR=extra modules_install

# Remove kbuild intermediate artifacts.
clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
