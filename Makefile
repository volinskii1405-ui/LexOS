ASM = nasm
BUILD_DIR = build
SRC_FILES = kernel.asm src/data.asm src/screen.asm src/input.asm src/shell.asm src/interrupts.asm src/devices.asm src/ata.asm src/filesystem.asm src/fs_extra.asm src/programs.asm src/assembler.asm src/rtc.asm src/speaker.asm src/serial.asm src/grep.asm src/headtail.asm src/uranium.asm

.PHONY: all run clean

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
	if [ $$actual -gt 50176 ]; then \
		echo "ERROR: boot+kernel already larger than the filesystem area start (50176 bytes = 98 sectors)."; \
		echo "Increase KERNEL_SECTORS_1/2 in boot.asm and FS_START_SECTOR in src/data.asm if needed."; \
		rm -f $@; \
		exit 1; \
	fi
	truncate -s 112640 $@

run: $(BUILD_DIR)/os-image.bin
	qemu-system-i386 -drive format=raw,file=$(BUILD_DIR)/os-image.bin

clean:
	rm -rf $(BUILD_DIR)
