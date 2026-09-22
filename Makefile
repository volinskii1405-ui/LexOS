ASM = nasm
BUILD_DIR = build
SRC_FILES = kernel.asm src/data.asm src/screen.asm src/input.asm src/shell.asm src/interrupts.asm src/devices.asm src/ata.asm src/serial.asm src/mouse.asm src/filesystem.asm src/fs_extra.asm src/programs.asm src/vga.asm src/snake.asm src/paint.asm src/sweeper.asm src/assembler.asm src/rtc.asm src/speaker.asm src/grep.asm src/headtail.asm src/uranium.asm src/user.asm src/tabcomplete.asm

.PHONY: all run run-serial clean

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
	if [ $$actual -gt 136192 ]; then \
		echo "ERROR: boot+kernel already larger than the filesystem area start (136192 bytes = 266 sectors)."; \
		echo "Increase KERNEL_SECTORS_1/2 in boot.asm and FS_START_SECTOR in src/data.asm if needed."; \
		rm -f $@; \
		exit 1; \
	fi
	truncate -s 716800 $@

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

run: $(BUILD_DIR)/os-image.bin
	qemu-system-i386 -drive format=raw,file=$(BUILD_DIR)/os-image.bin \
		-audiodev $(AUDIODEV),id=snd0 -machine pcspk-audiodev=snd0

# Same as `run`, but also exposes COM1 as a TCP socket on localhost, so
# `recv <name> <hex size>` (see README) has something to actually receive
# from - e.g. `nc 127.0.0.1 4444 < myfile.com` in another terminal, after
# typing `recv` in LexOS. Override the port with SERIALPORT=xxxx.
SERIALPORT ?= 4444
run-serial: $(BUILD_DIR)/os-image.bin
	qemu-system-i386 -drive format=raw,file=$(BUILD_DIR)/os-image.bin \
		-audiodev $(AUDIODEV),id=snd0 -machine pcspk-audiodev=snd0 \
		-serial tcp::$(SERIALPORT),server,nowait

clean:
	rm -rf $(BUILD_DIR)
