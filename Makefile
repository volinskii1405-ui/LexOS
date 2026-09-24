ASM = nasm
BUILD_DIR = build
SRC_FILES = kernel.asm src/data.asm src/screen.asm src/input.asm src/shell.asm src/interrupts.asm src/devices.asm src/ata.asm src/serial.asm src/mouse.asm src/filesystem.asm src/fs_extra.asm src/programs.asm src/vga.asm src/snake.asm src/paint.asm src/sweeper.asm src/tetris.asm src/game2048.asm src/convert.asm src/assembler.asm src/rtc.asm src/speaker.asm src/sound.asm src/chip8.asm src/turtle.asm src/hostfs.asm src/basic.asm src/net.asm src/inet.asm src/httpd.asm src/chat.asm src/sched.asm src/usermode.asm src/appsys.asm src/console.asm src/grep.asm src/headtail.asm src/uranium.asm src/user.asm src/tabcomplete.asm src/script.asm

.PHONY: all run run-serial lan1 lan2 clean apps

all: $(BUILD_DIR)/os-image.bin

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/boot.bin: boot.asm | $(BUILD_DIR)
	$(ASM) -f bin $< -o $@

$(BUILD_DIR)/kernel.bin: $(SRC_FILES) | $(BUILD_DIR)
	$(ASM) -f bin -i. kernel.asm -o $@

$(BUILD_DIR)/os-image.bin: $(BUILD_DIR)/boot.bin $(BUILD_DIR)/kernel.bin
	cat $(BUILD_DIR)/boot.bin $(BUILD_DIR)/kernel.bin > $@
	@actual=$$(stat -c%s $@); \
	if [ $$actual -gt 229888 ]; then \
		echo "ERROR: boot+kernel already larger than the filesystem area start (229888 bytes = 449 sectors)."; \
		echo "Increase KERNEL_SECTORS_1..4 in boot.asm and FS_START_SECTOR in src/data.asm if needed."; \
		rm -f $@; \
		exit 1; \
	fi
	truncate -s 16M $@

# Audio backend for `beep` (see README > Running the pre-built image).
# Override if the default doesn't work for you, e.g.: make run AUDIODEV=alsa
UNAME_S := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME_S),Darwin)
	AUDIODEV ?= coreaudio
else ifeq ($(OS),Windows_NT)
	AUDIODEV ?= dsound
else
	AUDIODEV ?= pa
endif

# The host folder LexOS's `hostls`/`hostget` see (src/hostfs.asm): QEMU
# presents it to the guest as a whole FAT16 disk - the primary IDE
# channel's slave drive - built from whatever's in it at startup. Files
# added on the host while QEMU is running won't show up until the next
# start. QEMU refuses a read-only IDE hard disk, hence "rw" - LexOS itself
# never writes to it. Override with SHARED=some/other/dir.
SHARED ?= shared
SHARED_DRIVE = -drive file=fat:rw:$(SHARED),format=raw,if=ide,index=1

# The network card `ping`/`ifconfig` drive (src/net.asm): an RTL8139 on
# QEMU's user-mode network - LexOS is 10.0.2.15, the gateway 10.0.2.2.
NIC = -nic user,model=rtl8139,hostfwd=tcp::8080-:80

run: $(BUILD_DIR)/os-image.bin
	mkdir -p $(SHARED)
	qemu-system-i386 -m 128 -drive format=raw,file=$(BUILD_DIR)/os-image.bin,if=ide,index=0 \
		$(SHARED_DRIVE) $(NIC) \
		-audiodev $(AUDIODEV),id=snd0 -machine pcspk-audiodev=snd0 \
		-device adlib,audiodev=snd0,iobase=0x220 -device sb16,audiodev=snd0

# Same as `run`, but also exposes COM1 as a TCP socket on localhost, so
# `recv <name> <hex size>` (see README) has something to actually receive
# from - e.g. `nc 127.0.0.1 4444 < myfile.com` in another terminal, after
# typing `recv` in LexOS. Override the port with SERIALPORT=xxxx.
SERIALPORT ?= 4444
run-serial: $(BUILD_DIR)/os-image.bin
	mkdir -p $(SHARED)
	qemu-system-i386 -m 128 -drive format=raw,file=$(BUILD_DIR)/os-image.bin,if=ide,index=0 \
		$(SHARED_DRIVE) $(NIC) \
		-audiodev $(AUDIODEV),id=snd0 -machine pcspk-audiodev=snd0 \
		-device adlib,audiodev=snd0,iobase=0x220 -device sb16,audiodev=snd0 \
		-serial tcp::$(SERIALPORT),server,nowait

# Two LexOS machines on one network, for `chat` (src/chat.asm): run
# `make lan1` in one terminal and `make lan2` in another. They're joined
# by a virtual Ethernet cable - QEMU's socket network, lan1 listening
# on localhost:$(LAN_PORT), lan2 connecting to it - with no DHCP server
# on it, so each takes an address from its own MAC. lan2 boots its own
# copy of the disk (made on first use), and neither mounts shared/.
LAN_PORT ?= 5560
LAN_QEMU = qemu-system-i386 -m 128 \
	-audiodev $(AUDIODEV),id=snd0 -machine pcspk-audiodev=snd0 \
	-device sb16,audiodev=snd0
lan1: $(BUILD_DIR)/os-image.bin
	$(LAN_QEMU) -drive format=raw,file=$(BUILD_DIR)/os-image.bin,if=ide,index=0 \
		-nic socket,model=rtl8139,listen=:$(LAN_PORT),mac=52:54:00:4c:58:15
lan2: $(BUILD_DIR)/os-image.bin
	test -f $(BUILD_DIR)/os-image-2.bin || cp $(BUILD_DIR)/os-image.bin $(BUILD_DIR)/os-image-2.bin
	$(LAN_QEMU) -drive format=raw,file=$(BUILD_DIR)/os-image-2.bin,if=ide,index=0 \
		-nic socket,model=rtl8139,connect=127.0.0.1:$(LAN_PORT),mac=52:54:00:4c:58:16

# Example ring-3 programs (src/usermode.asm), built into shared/ so
# LexOS can fetch them: hostget hello.app, then run hello.app. The
# assembly ones need only nasm; the C one also a 32-bit-capable gcc
# and ld (on Debian/Ubuntu: gcc-multilib). The built .APP files are
# committed, so plain `make` / `make run` never needs any of this.
APP_CFLAGS = -m32 -ffreestanding -fno-pic -fno-pie -fno-stack-protector \
	-fno-asynchronous-unwind-tables -nostdlib -O2 -Wall
C_APPS = guess wc note fire pong mandel modplay ftest cube
upper = $(shell echo $(1) | tr a-z A-Z)
apps: shared/HELLO.APP shared/CRASH.APP $(foreach a,$(C_APPS),shared/$(call upper,$(a)).APP)

shared/HELLO.APP: apps/hello.asm apps/lexos.inc
	$(ASM) -f bin -i apps/ $< -o $@

shared/CRASH.APP: apps/crash.asm apps/lexos.inc
	$(ASM) -f bin -i apps/ $< -o $@

$(BUILD_DIR)/crt0.o: apps/crt0.asm | $(BUILD_DIR)
	$(ASM) -f elf32 $< -o $@

# one C program per file: apps/guess.c -> shared/GUESS.APP, and so on
define C_APP_RULE
shared/$(call upper,$(1)).APP: apps/$(1).c apps/lexos.h apps/app.ld $(BUILD_DIR)/crt0.o
	gcc $$(APP_CFLAGS) -c apps/$(1).c -o $(BUILD_DIR)/$(1).o
	ld -m elf_i386 -T apps/app.ld --oformat binary -o $$@ $(BUILD_DIR)/crt0.o $(BUILD_DIR)/$(1).o
endef
$(foreach a,$(C_APPS),$(eval $(call C_APP_RULE,$(a))))

clean:
	rm -rf $(BUILD_DIR)
