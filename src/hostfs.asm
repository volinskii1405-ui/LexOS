; hostfs.asm — read access to a folder on the HOST machine. QEMU can
; present any host directory to the guest as a whole FAT-formatted disk
; ("vvfat": `-drive file=fat:rw:shared,format=raw,if=ide,index=1`, see
; the Makefile's run targets), which shows up here as the primary IDE
; channel's SLAVE drive. Drop a file into shared/ on the host, and:
;   hostls              - lists what's in the shared folder
;   hostget <n> [new]   - copies file n from it into the current LexOS
;                         directory (as <new>, if given)
; - no more `recv <name> <hex size>` plus a separate `nc` on the host
; just to get a script, ROM or picture onto LexOS's own disk.
;
; Exports: host_ls, host_get
;
; Read-only for now: nothing here ever writes to the host disk. (QEMU
; insists on the drive itself being opened "rw" - an IDE hard disk
; can't be read-only, "Block node is read-only" - but that only matters
; to a guest that writes.)
;
; Only what vvfat actually produces is handled: FAT16 (vvfat's default
; for a hard disk), 512-byte sectors, the volume found either at LBA 0
; or - vvfat's own layout - as partition 1 of an MBR. Only the root
; directory is listed/copied from, and names are the 8.3 short names
; (a host file called "my-long-name.txt" shows up the way DOS would
; see it, "MY-LON~1.TXT"); long-name (LFN) entries are skipped.
;
; The slave drive gets its own small PIO read routine, host_read_sector,
; rather than going through ata_read_sector (src/ata.asm): that one is
; master-only, 16-bit LBA only (vvfat's disk is ~500MB, so its data
; area runs well past LBA 65535), and dispatches to DMA when available.
; Every master-side routine re-selects the master drive itself before
; each command (both PIO and src/atadma.asm's DMA path do), so switching
; to the slave here doesn't disturb them - host_read_sector still
; re-selects the master before returning, to leave the channel exactly
; the way everything else expects to find it. Every wait here is
; bounded (HOST_TIMEOUT), unlike ata_wait_bsy_clear's: the master drive
; is guaranteed to exist (LexOS booted from it), the slave isn't - with
; no shared folder attached, these just time out into an error message
; instead of hanging the whole system.
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exceptions are the
; msg_host_* messages and fs_tmp_name (src/data.asm).
; ============================================================

HOST_ALT_STATUS  equ 0x3F6     ; primary channel's alternate status port
HOST_TIMEOUT     equ 0x200000   ; polling iterations before giving up
HOST_NAME_MAX    equ 12         ; "NAME1234.EXT"

; ============================================================
; hostls: lists the shared folder's root directory - name and size,
; or <DIR> for a subfolder.
; ============================================================
host_ls:
    pushad

    call host_mount
    jc .end

    xor ebx, ebx                        ; entries listed
    call host_dir_rewind
.loop:
    call host_dir_next
    jc .listed
    call host_format_name
    inc ebx

    mov esi, host_fmt_name
    xor ecx, ecx
.print_name:
    mov al, [esi + ecx]
    cmp al, 0
    je .pad
    call print_char
    inc ecx
    jmp .print_name
.pad:
    cmp ecx, HOST_NAME_MAX + 2
    jae .padded
    mov al, ' '
    call print_char
    inc ecx
    jmp .pad
.padded:
    test byte [host_ent_attr], 0x10
    jz .file
    push si
    mov si, msg_host_dir_tag
    call print_string
    pop si
    jmp .line_done
.file:
    mov eax, [host_ent_size]
    call host_print_dec_dword
.line_done:
    push si
    mov si, msg_newline
    call print_string
    pop si
    jmp .loop

.listed:
    cmp byte [host_io_error], 0
    jne .io_error
    cmp ebx, 0
    jne .end
    mov si, msg_fs_empty
    call print_string
    jmp .end
.io_error:
    mov si, msg_host_io_error
    call print_string
.end:
    popad
    ret

; ============================================================
; hostget <n> [new]: copies file n from the shared folder's root into
; the current LexOS directory, named <new> if given, or the same 8.3
; name otherwise. SI points at the arguments (the shell already skipped
; past "hostget "). The actual copying is the same streaming write
; `recv` does (fs_stream_prepare/fs_stream_write, src/fs_extra.asm),
; just fed from host_read_next_byte instead of the serial port.
; ============================================================
host_get:
    pushad

    movzx esi, si
    xor ecx, ecx
.arg_loop:
    mov al, [esi]
    cmp al, 0
    je .arg_done
    cmp al, ' '
    je .arg_done
    call to_upper_al
    cmp ecx, HOST_NAME_MAX
    jae .arg_skip
    mov [host_arg_name + ecx], al
    inc ecx
.arg_skip:
    inc esi
    jmp .arg_loop
.arg_done:
    mov byte [host_arg_name + ecx], 0
    cmp ecx, 0
    jne .have_arg
    mov si, msg_host_get_usage
    call print_string
    jmp .end

.have_arg:
.skip_space:
    cmp byte [esi], ' '
    jne .new_name
    inc esi
    jmp .skip_space
.new_name:
    mov edi, fs_tmp_name
    xor ecx, ecx
.new_loop:
    mov al, [esi]
    cmp al, 0
    je .new_done
    cmp al, ' '
    je .new_done
    call to_upper_al                     ; stored uppercase anyway - this
                                          ; just makes the "Copied" line
                                          ; show it the way `ls` will
    cmp ecx, FS_NAME_LEN
    jae .new_skip
    mov [edi + ecx], al
    inc ecx
.new_skip:
    inc esi
    jmp .new_loop
.new_done:
    mov byte [edi + ecx], 0

    call host_mount
    jc .end

    call host_dir_rewind
.find:
    call host_dir_next
    jc .not_found
    call host_format_name
    call host_name_matches_arg
    jc .find

    test byte [host_ent_attr], 0x10
    jz .is_file
    mov si, msg_host_is_dir
    call print_string
    jmp .end
.is_file:
    cmp dword [host_ent_size], 0xFFFF
    jbe .size_ok
    mov si, msg_host_too_big
    call print_string
    jmp .end
.size_ok:
    cmp byte [fs_tmp_name], 0
    jne .have_target
    xor ecx, ecx
.copy_fmt:
    mov al, [host_fmt_name + ecx]
    mov [fs_tmp_name + ecx], al
    inc ecx
    cmp al, 0
    jne .copy_fmt
.have_target:

    mov eax, [host_ent_size]
    mov [fs_stream_size], ax
    movzx eax, word [host_ent_cluster]
    mov [host_cur_cluster], eax
    mov dword [host_sec_in_cluster], 0
    mov dword [host_byte_idx], 512       ; nothing buffered yet
    mov byte [host_io_error], 0

    call fs_stream_prepare
    jc .end                              ; the reason is already printed

    mov dword [fs_stream_source], host_read_next_byte
    call fs_stream_write
    jnc .written
    mov si, msg_fs_disk_full
    call print_string
    jmp .end
.written:
    cmp byte [host_io_error], 0
    je .report
    mov si, msg_host_io_error
    call print_string
    jmp .end
.report:
    mov si, msg_host_copied1
    call print_string
    mov eax, [host_ent_size]
    call host_print_dec_dword
    mov si, msg_host_copied2
    call print_string
    mov si, fs_tmp_name
    call print_string
    mov si, msg_newline
    call print_string
    jmp .end

.not_found:
    cmp byte [host_io_error], 0
    jne .find_io_error
    mov si, msg_fs_notfound
    call print_string
    jmp .end
.find_io_error:
    mov si, msg_host_io_error
    call print_string
.end:
    popad
    ret

; ============================================================
; fs_stream_source for host_get: returns the file's next byte in al
; (eax), following its cluster chain through the FAT as it goes, and
; preserves every other register. A read error sets host_io_error and
; yields zeros from then on - fs_stream_write has no way to abort
; partway, so host_get checks the flag once it's done instead.
; ============================================================
host_read_next_byte:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp byte [host_io_error], 0
    jne .zero

    cmp dword [host_byte_idx], 512
    jb .have_byte

    mov eax, [host_sec_in_cluster]
    cmp eax, [host_spc]
    jb .same_cluster
    mov eax, [host_cur_cluster]
    call host_fat_next
    jc .io_error
    mov [host_cur_cluster], eax
    mov dword [host_sec_in_cluster], 0
.same_cluster:
    mov eax, [host_cur_cluster]
    cmp eax, 2                           ; 0/1 are reserved, 0xFFF7 bad,
    jb .io_error                         ; 0xFFF8+ end of chain - the
    cmp eax, 0xFFF7                      ; directory entry's size said
    jae .io_error                        ; there was more data than this
    sub eax, 2
    imul eax, [host_spc]
    add eax, [host_data_start]
    add eax, [host_sec_in_cluster]
    mov edi, host_data_buf
    call host_read_sector
    jc .io_error
    inc dword [host_sec_in_cluster]
    mov dword [host_byte_idx], 0

.have_byte:
    mov ebx, [host_byte_idx]
    movzx eax, byte [host_data_buf + ebx]
    inc dword [host_byte_idx]
    jmp .done

.io_error:
    mov byte [host_io_error], 1
.zero:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ============================================================
; eax = cluster -> eax = the next cluster in its chain (its FAT16
; entry). The FAT sector last read is kept in host_fat_buf, so walking
; a chain doesn't re-read the same FAT sector for every single cluster.
; carry=1 on a read error.
; ============================================================
host_fat_next:
    push ebx
    push edx
    push edi

    shl eax, 1                           ; byte offset of the entry
    mov ebx, eax
    shr eax, 9
    add eax, [host_fat_start]            ; eax = the FAT sector holding it
    and ebx, 511                         ; ebx = offset within that sector

    cmp eax, [host_fat_cached_lba]
    je .cached
    mov edi, host_fat_buf
    call host_read_sector
    jc .error
    mov [host_fat_cached_lba], eax
.cached:
    movzx eax, word [host_fat_buf + ebx]
    pop edi
    pop edx
    pop ebx
    clc
    ret
.error:
    mov dword [host_fat_cached_lba], 0xFFFFFFFF
    pop edi
    pop edx
    pop ebx
    stc
    ret

; ============================================================
; Finds the shared folder's FAT16 volume and reads its geometry from
; the boot sector (BPB) into host_spc/host_fat_start/host_root_start/
; host_root_sectors/host_data_start. carry=1 (with the reason already
; printed) if there's no slave drive, it can't be read, or it isn't a
; FAT16 volume. Re-done on every command, not cached: it's only two
; sector reads, and it means attaching or swapping the folder between
; boots can never leave stale geometry behind.
; ============================================================
host_mount:
    pushad
    mov byte [host_io_error], 0
    mov dword [host_fat_cached_lba], 0xFFFFFFFF

    ; No slave drive at all -> its status register reads back as 0
    ; (QEMU) or 0xFF (a floating bus on real hardware).
    mov dx, ATA_DRIVE_HEAD
    mov al, 0xF0
    out dx, al
    call host_400ns
    mov dx, ATA_STATUS
    in al, dx
    mov bl, al
    call host_select_master
    cmp bl, 0
    je .absent
    cmp bl, 0xFF
    je .absent

    xor eax, eax
    mov edi, host_sector_buf
    call host_read_sector
    jc .absent

    cmp word [host_sector_buf + 510], 0xAA55
    jne .not_fat

    ; A volume can start right at LBA 0 (no partition table), or - how
    ; vvfat lays out a hard disk - LBA 0 is an MBR and the volume is its
    ; first partition. A real FAT boot sector starts with a jump
    ; instruction (EB xx / E9 xx xx) and declares 512-byte sectors; an
    ; MBR like vvfat's starts with zeros.
    xor eax, eax
    cmp byte [host_sector_buf], 0xEB
    je .maybe_vbr
    cmp byte [host_sector_buf], 0xE9
    jne .use_partition
.maybe_vbr:
    cmp word [host_sector_buf + 0x0B], 512
    je .have_volume
.use_partition:
    cmp byte [host_sector_buf + 0x1C2], 0     ; partition 1's type byte
    je .not_fat
    mov eax, [host_sector_buf + 0x1C6]        ; partition 1's start LBA
    push eax
    mov edi, host_sector_buf
    call host_read_sector
    pop eax
    jc .io_error
.have_volume:
    mov [host_vol_start], eax

    cmp word [host_sector_buf + 0x0B], 512
    jne .not_fat
    movzx eax, byte [host_sector_buf + 0x0D]   ; sectors per cluster
    cmp eax, 0
    je .not_fat
    mov [host_spc], eax
    movzx eax, word [host_sector_buf + 0x16]   ; sectors per FAT - 0 means
    cmp eax, 0                                  ; FAT32, which keeps it in
    je .not_fat                                 ; a different field
    mov [host_fat_size], eax

    movzx eax, word [host_sector_buf + 0x0E]    ; reserved sectors
    add eax, [host_vol_start]
    mov [host_fat_start], eax

    movzx ecx, byte [host_sector_buf + 0x10]    ; number of FATs
    imul ecx, [host_fat_size]
    add eax, ecx
    mov [host_root_start], eax

    movzx ecx, word [host_sector_buf + 0x11]    ; root directory entries
    shl ecx, 5                                   ; * 32 bytes each
    add ecx, 511
    shr ecx, 9
    mov [host_root_sectors], ecx
    add eax, ecx
    mov [host_data_start], eax

    ; FAT12/16/32 is decided by cluster count alone, never by the
    ; "FAT16   " label string (that's only informational) - only 16 is
    ; handled here.
    movzx eax, word [host_sector_buf + 0x13]    ; total sectors (16-bit)
    cmp eax, 0
    jne .have_total
    mov eax, [host_sector_buf + 0x20]           ; ... or 32-bit if that's 0
.have_total:
    add eax, [host_vol_start]
    sub eax, [host_data_start]
    jbe .not_fat
    xor edx, edx
    div dword [host_spc]
    cmp eax, 4085
    jb .not_fat
    cmp eax, 65525
    jae .not_fat

    popad
    clc
    ret

.absent:
    mov si, msg_host_absent
    call print_string
    jmp .fail
.not_fat:
    mov si, msg_host_not_fat
    call print_string
    jmp .fail
.io_error:
    mov si, msg_host_io_error
    call print_string
.fail:
    popad
    stc
    ret

; ============================================================
; host_dir_rewind / host_dir_next: walk the root directory's entries.
; Each host_dir_next call returns carry=0 with the next real entry's
; fields copied into host_ent_* (the raw 32-byte entry itself is at
; host_ent_ptr) - deleted entries, long-name (LFN) pieces and the
; volume label are skipped - or carry=1 once the directory ends (a
; 0x00 first byte, or the end of the root area). On a read error,
; carry=1 and host_io_error is set.
; ============================================================
host_dir_rewind:
    mov dword [host_dir_sector], 0
    mov dword [host_dir_entry], 16         ; nothing loaded yet
    ret

host_dir_next:
    pushad
.next:
    cmp dword [host_dir_entry], 16
    jb .have_sector
    mov eax, [host_dir_sector]
    cmp eax, [host_root_sectors]
    jae .end_of_dir
    add eax, [host_root_start]
    mov edi, host_sector_buf
    call host_read_sector
    jc .io_error
    inc dword [host_dir_sector]
    mov dword [host_dir_entry], 0
.have_sector:
    mov esi, [host_dir_entry]
    shl esi, 5
    add esi, host_sector_buf
    inc dword [host_dir_entry]

    mov al, [esi]
    cmp al, 0x00
    je .end_of_dir
    cmp al, 0xE5                         ; deleted
    je .next
    mov al, [esi + 0x0B]                 ; attributes
    cmp al, 0x0F                         ; a long-name (LFN) piece
    je .next
    test al, 0x08                        ; the volume label
    jnz .next

    mov [host_ent_ptr], esi
    mov [host_ent_attr], al
    mov ax, [esi + 0x1A]
    mov [host_ent_cluster], ax
    mov eax, [esi + 0x1C]
    mov [host_ent_size], eax
    popad
    clc
    ret

.io_error:
    mov byte [host_io_error], 1
.end_of_dir:
    popad
    stc
    ret

; ============================================================
; Formats the current entry's (host_ent_ptr) space-padded 8.3 name as
; "NAME.EXT" (no dot if there's no extension) into host_fmt_name.
; ============================================================
host_format_name:
    pushad
    mov esi, [host_ent_ptr]
    xor edi, edi

    xor ecx, ecx
.base:
    cmp ecx, 8
    jae .base_done
    mov al, [esi + ecx]
    cmp al, ' '
    je .base_done
    mov [host_fmt_name + edi], al
    inc edi
    inc ecx
    jmp .base
.base_done:

    cmp byte [esi + 8], ' '
    je .terminate
    mov byte [host_fmt_name + edi], '.'
    inc edi
    mov ecx, 8
.ext:
    cmp ecx, 11
    jae .terminate
    mov al, [esi + ecx]
    cmp al, ' '
    je .terminate
    mov [host_fmt_name + edi], al
    inc edi
    inc ecx
    jmp .ext
.terminate:
    mov byte [host_fmt_name + edi], 0
    popad
    ret

; ============================================================
; carry=0 if host_fmt_name equals host_arg_name (already uppercased),
; carry=1 otherwise. 8.3 names are always stored uppercase, so a plain
; byte comparison is already case-insensitive here.
; ============================================================
host_name_matches_arg:
    push eax
    push ecx
    xor ecx, ecx
.loop:
    mov al, [host_fmt_name + ecx]
    cmp al, [host_arg_name + ecx]
    jne .differ
    cmp al, 0
    je .same
    inc ecx
    jmp .loop
.same:
    pop ecx
    pop eax
    clc
    ret
.differ:
    pop ecx
    pop eax
    stc
    ret

; ============================================================
; Reads one 512-byte sector at 28-bit LBA eax from the SLAVE drive into
; [edi], by PIO. carry=1 on error or timeout. Preserves all registers
; and leaves the master drive selected again (see the header note).
; ============================================================
host_read_sector:
    pushad
    mov ebx, eax

    call host_wait_not_busy
    jc .error

    mov dx, ATA_DRIVE_HEAD
    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xF0                          ; slave, LBA mode, LBA bits 24-27
    out dx, al
    call host_400ns
    call host_wait_not_busy              ; now the slave's own status
    jc .error

    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al
    mov dx, ATA_LBA_HI
    mov eax, ebx
    shr eax, 16
    out dx, al
    mov dx, ATA_COMMAND
    mov al, 0x20                          ; READ SECTORS
    out dx, al
    call host_400ns

    call host_wait_drq
    jc .error

    cld
    mov dx, ATA_DATA
    mov ecx, 256
    rep insw

    call host_select_master
    popad
    clc
    ret

.error:
    call host_select_master
    popad
    stc
    ret

; --- Waits (bounded) for the selected drive's BSY to clear. carry=1 on timeout. ---
host_wait_not_busy:
    push eax
    push ecx
    push edx
    mov dx, ATA_STATUS
    mov ecx, HOST_TIMEOUT
.wait:
    in al, dx
    test al, ATA_STATUS_BSY
    jz .ready
    dec ecx
    jnz .wait
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ready:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; --- Waits (bounded) for BSY clear and DRQ set. carry=1 on ERR or timeout. ---
host_wait_drq:
    push eax
    push ecx
    push edx
    mov dx, ATA_STATUS
    mov ecx, HOST_TIMEOUT
.wait:
    in al, dx
    test al, ATA_STATUS_BSY
    jnz .again
    test al, ATA_STATUS_ERR
    jnz .fail
    test al, ATA_STATUS_DRQ
    jnz .ready
.again:
    dec ecx
    jnz .wait
.fail:
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ready:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; --- ~400ns: the settling time the ATA spec asks for after a drive
;     select (four reads of the alternate status port, which - unlike
;     the main status port - doesn't acknowledge anything as a side effect). ---
host_400ns:
    push eax
    push edx
    mov dx, HOST_ALT_STATUS
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    pop edx
    pop eax
    ret

; --- Re-selects the master drive (the boot disk everything else uses). ---
host_select_master:
    push eax
    push edx
    mov dx, ATA_DRIVE_HEAD
    mov al, 0xE0
    out dx, al
    call host_400ns
    pop edx
    pop eax
    ret

; --- Prints eax as an unsigned decimal number (print_dec_word only
;     goes up to 65535; a host file can be far bigger than that). ---
host_print_dec_dword:
    pushad
    mov ebx, 10
    xor ecx, ecx
.divide:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    cmp eax, 0
    jne .divide
.print:
    pop eax
    add al, '0'
    call print_char
    loop .print
    popad
    ret

; ============================================================
; Data
; ============================================================
host_vol_start       dd 0
host_spc             dd 0
host_fat_size        dd 0
host_fat_start       dd 0
host_root_start      dd 0
host_root_sectors    dd 0
host_data_start      dd 0
host_fat_cached_lba  dd 0xFFFFFFFF
host_io_error        db 0

host_dir_sector      dd 0
host_dir_entry       dd 0
host_ent_ptr         dd 0
host_ent_attr        db 0
host_ent_cluster     dw 0
host_ent_size        dd 0

host_cur_cluster     dd 0
host_sec_in_cluster  dd 0
host_byte_idx        dd 512

host_fmt_name        times (HOST_NAME_MAX + 1) db 0
host_arg_name        times (HOST_NAME_MAX + 1) db 0

host_sector_buf      times 512 db 0      ; boot sectors, directory sectors
host_data_buf        times 512 db 0      ; the file being copied
host_fat_buf         times 512 db 0      ; the FAT sector last looked up
