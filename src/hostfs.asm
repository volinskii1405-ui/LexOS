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
; Exports: host_ls, host_get, host_put
;
;   hostput <n> [host] - copies LexOS file n into it (as <host>, an
;                         8.3 name, if given) - see host_put
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
    cmp dword [host_ent_size], BIG_FILE_MAX
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
    mov [fs_stream_size], eax
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
; hostput <n> [host name]: copies LexOS file n (from the current
; directory) into the shared folder's top level - as <host name> if
; given. That has to be a DOS 8.3 name: the entry is an 8.3 one plus a
; single long-name piece spelling the same thing (without it, vvfat
; would name the host file in lowercase). Only NEW files - see
; .overwrite for why an existing one is refused.
;
; The FAT16 write sequence: allocate and fill clusters one at a time
; (each linked from the previous one in the FAT as it's taken), write
; the FAT back to every copy, and only then the directory entry
; pointing at it - so the host never sees an entry for data that isn't
; there yet. vvfat turns that into a real file in the host directory
; as the directory sector is written.
; ============================================================
HOST_PUT_BUF equ BIG_FILE_BUF          ; the file's content, up to 16MB

host_put:
    pushad

    movzx esi, si
    mov edi, fs_tmp_name
    xor ecx, ecx
.src_loop:
    mov al, [esi]
    cmp al, 0
    je .src_done
    cmp al, ' '
    je .src_done
    call to_upper_al
    cmp ecx, FS_NAME_LEN
    jae .src_skip
    mov [edi + ecx], al
    inc ecx
.src_skip:
    inc esi
    jmp .src_loop
.src_done:
    mov byte [edi + ecx], 0
    cmp ecx, 0
    jne .skip_space
    mov si, msg_host_put_usage
    call print_string
    jmp .end

.skip_space:
    cmp byte [esi], ' '
    jne .dst
    inc esi
    jmp .skip_space
.dst:
    cmp byte [esi], 0
    jne .dst_copy
    mov esi, fs_tmp_name                 ; no host name: the same one
.dst_copy:
    xor ecx, ecx
.dst_loop:
    mov al, [esi]
    cmp al, 0
    je .dst_done
    cmp al, ' '
    je .dst_done
    call to_upper_al
    cmp ecx, HOST_NAME_MAX
    jae .bad_name                         ; longer than any 8.3 name
    mov [host_arg_name + ecx], al
    inc ecx
    inc esi
    jmp .dst_loop
.dst_done:
    mov byte [host_arg_name + ecx], 0
    call host_make_83
    jnc .name_ok
.bad_name:
    mov si, msg_host_bad_name
    call print_string
    jmp .end
.name_ok:

    mov esi, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .src_found
    mov si, msg_fs_notfound
    call print_string
    jmp .end
.src_found:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .src_is_file
    mov si, msg_host_put_not_file
    call print_string
    jmp .end
.src_is_file:
    mov ax, [fs_tmp_slot]
    mov edi, HOST_PUT_BUF
    mov ecx, BIG_FILE_MAX
    call fs_load_to
    mov [host_put_size], ecx

    call host_mount
    jc .end

    ; Already there?
    call host_dir_rewind
.find:
    call host_dir_next
    jc .not_there
    mov esi, [host_ent_ptr]
    mov edi, host_put_83
    mov ecx, 11
    repe cmpsb
    jne .find
    test byte [host_ent_attr], 0x10
    jz .overwrite
    mov si, msg_host_is_dir
    call print_string
    jmp .end
.overwrite:
    ; Already there: refuse rather than overwrite. vvfat (QEMU's side of
    ; the shared folder) only reliably turns NEW files into host files -
    ; rewriting one in place either doesn't reach the host (a changed
    ; size is ignored), or trips an assertion that takes all of QEMU
    ; down (a file that shrinks); deleting and recreating it does reach
    ; the host, but leaves vvfat's own view of the directory - what
    ; hostls/hostget read - muddled until the next start.
    mov si, msg_host_exists
    call print_string
    jmp .end

.not_there:
    cmp byte [host_io_error], 0
    jne .io_error
    call host_find_free_entry
    jc .end                               ; (reason printed)

.have_slot:
    mov dword [host_put_first], 0
    mov dword [host_put_prev], 0
    mov dword [host_put_next_free], 2
    mov dword [host_put_src], HOST_PUT_BUF
    mov eax, [host_put_size]
    mov [host_put_left], eax
.cluster_loop:
    cmp dword [host_put_left], 0
    je .data_done
    call host_alloc_cluster               ; eax = a new cluster, chained
    jc .end
    mov ebx, eax
    sub ebx, 2
    imul ebx, [host_spc]
    add ebx, [host_data_start]            ; ebx = its first sector
    mov ecx, [host_spc]
.sector_loop:
    ; stage the next (up to) 512 bytes, zero-padded, in host_data_buf
    push ecx
    mov edi, host_data_buf
    mov ecx, 512 / 4
    xor eax, eax
    rep stosd
    mov ecx, [host_put_left]
    cmp ecx, 512
    jbe .have_count
    mov ecx, 512
.have_count:
    sub [host_put_left], ecx
    mov esi, [host_put_src]
    add [host_put_src], ecx
    mov edi, host_data_buf
    rep movsb
    pop ecx

    mov eax, ebx
    mov esi, host_data_buf
    call host_write_sector
    jc .io_error
    inc ebx
    cmp dword [host_put_left], 0
    je .cluster_loop                      ; the rest of the cluster is slack
    loop .sector_loop
    jmp .cluster_loop
.data_done:
    call host_fat_flush
    jc .io_error

    ; the directory entry
    mov eax, [host_put_dir_lba]
    mov edi, host_sector_buf
    call host_read_sector
    jc .io_error
    mov edi, [host_put_dir_off]
    add edi, host_sector_buf
    push edi
    mov ecx, 64 / 4                       ; the long-name entry + the 8.3 one
    xor eax, eax
    rep stosd
    pop edi
    call host_write_lfn
    add edi, 32
    mov esi, host_put_83
    mov ecx, 11
    push edi
    rep movsb
    pop edi
    mov byte [edi + 0x0B], 0x20           ; "archive" - an ordinary file
    call host_fat_timestamp
    mov [edi + 0x0E], ax                  ; created
    mov [edi + 0x10], dx
    mov [edi + 0x16], ax                  ; modified
    mov [edi + 0x18], dx
    mov [edi + 0x12], dx                  ; accessed
    mov word [edi + 0x14], 0              ; cluster, high word (FAT32 only)
    mov eax, [host_put_first]
    mov [edi + 0x1A], ax
    mov eax, [host_put_size]
    mov [edi + 0x1C], eax
    mov eax, [host_put_dir_lba]
    mov esi, host_sector_buf
    call host_write_sector
    jc .io_error
    call host_flush_cache

    mov si, msg_host_copied1
    call print_string
    mov eax, [host_put_size]
    call host_print_dec_dword
    mov si, msg_host_put2
    call print_string
    xor ecx, ecx
.print_name:
    mov al, [host_arg_name + ecx]
    cmp al, 0
    je .printed
    call print_char
    inc ecx
    jmp .print_name
.printed:
    mov si, msg_newline
    call print_string
    jmp .end

.io_error:
    mov si, msg_host_io_error
    call print_string
.end:
    popad
    ret

; Fills the 32 bytes at edi (already zeroed) as a single long-name
; entry spelling host_arg_name - so vvfat names the host file exactly
; that, rather than lowercasing a bare 8.3 name the way it otherwise
; does.
host_write_lfn:
    pushad
    mov byte [edi], 0x41                  ; piece 1, and the last one
    mov byte [edi + 0x0B], 0x0F
    ; checksum of the 8.3 name it belongs to
    xor eax, eax
    xor ecx, ecx
.sum:
    ror al, 1
    add al, [host_put_83 + ecx]
    inc ecx
    cmp ecx, 11
    jb .sum
    mov [edi + 0x0D], al
    ; 13 UTF-16 characters: the name, a 0 terminator, then 0xFFFF padding
    xor ecx, ecx                          ; character index
    xor edx, edx                          ; 1 once past the terminator
.char:
    movzx ebx, byte [host_lfn_offsets + ecx]
    cmp edx, 0
    jne .pad
    movzx eax, byte [host_arg_name + ecx]
    mov [edi + ebx], ax
    cmp eax, 0
    jne .next
    inc edx
    jmp .next
.pad:
    mov word [edi + ebx], 0xFFFF
.next:
    inc ecx
    cmp ecx, 13
    jb .char
    popad
    ret

host_lfn_offsets db 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30

; host_arg_name ("NAME.EXT", uppercase) -> host_put_83 ("NAME    EXT"),
; carry=1 if it isn't a valid DOS 8.3 name.
host_make_83:
    pushad
    mov edi, host_put_83
    mov ecx, 11
    mov al, ' '
    rep stosb
    mov esi, host_arg_name
    xor ecx, ecx
.base:
    mov al, [esi]
    cmp al, 0
    je .end_base
    cmp al, '.'
    je .end_base
    call host_83_char_ok
    jc .bad
    cmp ecx, 8
    jae .bad
    mov [host_put_83 + ecx], al
    inc ecx
    inc esi
    jmp .base
.end_base:
    cmp ecx, 0
    je .bad                               ; no base name at all
    cmp al, 0
    je .ok
    inc esi                               ; past the '.'
    xor ecx, ecx
.ext:
    mov al, [esi]
    cmp al, 0
    je .ok
    call host_83_char_ok
    jc .bad
    cmp ecx, 3
    jae .bad
    mov [host_put_83 + 8 + ecx], al
    inc ecx
    inc esi
    jmp .ext
.ok:
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; carry=0 if al may appear in an 8.3 name (A-Z 0-9 and DOS's
; punctuation set), carry=1 otherwise.
host_83_char_ok:
    cmp al, 'A'
    jb .not_letter
    cmp al, 'Z'
    jbe .ok
.not_letter:
    cmp al, '0'
    jb .punct
    cmp al, '9'
    jbe .ok
.punct:
    push edi
    push ecx
    mov edi, host_83_punct
    mov ecx, host_83_punct_len
    repne scasb
    pop ecx
    pop edi
    je .ok
    stc
    ret
.ok:
    clc
    ret

host_83_punct     db "!#$%&'()-@^_`{}~"
host_83_punct_len equ $ - host_83_punct

; Two adjacent free root directory slots (never used, or deleted) in
; one sector - a long-name entry plus the 8.3 one - -> host_put_dir_lba
; / host_put_dir_off (the first of the two). carry=1 (message printed) if there's none.
host_find_free_entry:
    pushad
    xor ecx, ecx
.sector:
    cmp ecx, [host_root_sectors]
    jae .full
    mov eax, [host_root_start]
    add eax, ecx
    mov edi, host_sector_buf
    call host_read_sector
    jc .io_error
    xor ebx, ebx
.entry:
    mov al, [host_sector_buf + ebx]
    cmp al, 0x00
    je .first_free
    cmp al, 0xE5
    jne .taken
.first_free:
    mov al, [host_sector_buf + ebx + 32]  ; room for the 8.3 entry right
    cmp al, 0x00                          ; after the long-name one
    je .found
    cmp al, 0xE5
    je .found
.taken:
    add ebx, 32
    cmp ebx, 512 - 32
    jb .entry
    inc ecx
    jmp .sector
.found:
    mov eax, [host_root_start]
    add eax, ecx
    mov [host_put_dir_lba], eax
    mov [host_put_dir_off], ebx
    popad
    clc
    ret
.full:
    mov si, msg_host_dir_full
    call print_string
    popad
    stc
    ret
.io_error:
    mov si, msg_host_io_error
    call print_string
    popad
    stc
    ret

; Takes the next free cluster, marks it end-of-chain and links it from
; the previous one (or records it as the file's first). eax = the
; cluster. carry=1 (message printed) if the disk is full or unreadable.
host_alloc_cluster:
    push ebx
    push edx
    mov ebx, [host_put_next_free]
.scan:
    mov edx, [host_clusters]
    add edx, 2
    cmp ebx, edx
    jae .full
    mov eax, ebx
    call host_fat_next
    jc .io_error
    cmp ax, 0
    je .free
    inc ebx
    jmp .scan
.free:
    lea eax, [ebx + 1]
    mov [host_put_next_free], eax
    mov eax, ebx
    mov dx, 0xFFFF
    call host_fat_set
    jc .io_error
    mov eax, [host_put_prev]
    cmp eax, 0
    jne .link
    mov [host_put_first], ebx
    jmp .linked
.link:
    mov edx, ebx
    call host_fat_set                     ; prev -> this one
    jc .io_error
.linked:
    mov [host_put_prev], ebx
    mov eax, ebx
    pop edx
    pop ebx
    clc
    ret
.full:
    push esi
    mov si, msg_host_disk_full
    call print_string
    pop esi
    pop edx
    pop ebx
    stc
    ret
.io_error:
    push esi
    mov si, msg_host_io_error
    call print_string
    pop esi
    pop edx
    pop ebx
    stc
    ret

; The RTC's current time/date in FAT's packed form: ax = time
; (hours<<11 | minutes<<5 | seconds/2), dx = date ((year-1980)<<9 |
; month<<5 | day).
host_fat_timestamp:
    push ebx
    push ecx
    call rtc_read_date                    ; bh = day, bl = month, cl = yy
    movzx edx, cl
    add edx, 20                           ; 20yy - 1980
    shl edx, 9
    movzx eax, bl
    shl eax, 5
    or edx, eax
    movzx eax, bh
    or edx, eax
    push edx
    call rtc_read_time                    ; bh = h, bl = m, cl = s
    movzx eax, bh
    shl eax, 11
    movzx edx, bl
    shl edx, 5
    or eax, edx
    movzx edx, cl
    shr edx, 1
    or eax, edx
    pop edx
    pop ecx
    pop ebx
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

    call host_fat_load                   ; eax = that sector's LBA
    jc .error
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

; Makes FAT sector eax the one in host_fat_buf (writing back the one
; there first, if hostput changed it). carry=1 on a disk error.
host_fat_load:
    cmp eax, [host_fat_cached_lba]
    je .done
    call host_fat_flush
    jc .fail
    push edi
    mov edi, host_fat_buf
    call host_read_sector
    pop edi
    jc .fail
    mov [host_fat_cached_lba], eax
.done:
    clc
    ret
.fail:
    mov dword [host_fat_cached_lba], 0xFFFFFFFF
    stc
    ret

; Writes host_fat_buf back - to every copy of the FAT - if it was
; changed. carry=1 on a disk error.
host_fat_flush:
    cmp byte [host_fat_dirty], 0
    je .clean
    pushad
    mov eax, [host_fat_cached_lba]
    mov esi, host_fat_buf
    mov ecx, [host_nfats]
.copy:
    call host_write_sector
    jc .fail
    add eax, [host_fat_size]
    loop .copy
    mov byte [host_fat_dirty], 0
    popad
.clean:
    clc
    ret
.fail:
    popad
    stc
    ret

; Sets FAT entry eax (a cluster number) to dx. carry=1 on a disk error.
host_fat_set:
    pushad
    shl eax, 1
    mov ebx, eax
    shr eax, 9
    add eax, [host_fat_start]
    and ebx, 511
    call host_fat_load
    jc .fail
    mov [host_fat_buf + ebx], dx
    mov byte [host_fat_dirty], 1
    popad
    clc
    ret
.fail:
    popad
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
    mov byte [host_fat_dirty], 0

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
    mov [host_nfats], ecx
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
    mov [host_clusters], eax

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
; volume label are skipped - or carry=1 at the end of the root area.
; On a read error, carry=1 and host_io_error is set.
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
    ; 0x00 (never used) normally means "the end of the directory", but
    ; vvfat leaves such holes mid-directory once a hostput has made it
    ; regenerate its view, so the whole root area is always scanned.
    cmp al, 0x00
    je .next
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

; ============================================================
; Writes one 512-byte sector from esi to LBA eax on the slave drive -
; host_read_sector's mirror image (WRITE SECTORS, 0x30).
; carry=1 on error or timeout.
; ============================================================
host_write_sector:
    pushad
    mov ebx, eax

    call host_wait_not_busy
    jc .error

    mov dx, ATA_DRIVE_HEAD
    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xF0
    out dx, al
    call host_400ns
    call host_wait_not_busy
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
    mov al, 0x30                          ; WRITE SECTORS
    out dx, al
    call host_400ns

    call host_wait_drq
    jc .error

    cld
    mov dx, ATA_DATA
    mov ecx, 256
    rep outsw
    call host_400ns
    call host_wait_not_busy
    jc .error
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    call host_select_master
    popad
    clc
    ret

.error:
    call host_select_master
    popad
    stc
    ret

; FLUSH CACHE (0xE7) on the slave - so a hostput is on the host's disk
; before its "Copied" line appears. Failure is ignored: not every
; drive implements it, and the data was already accepted.
host_flush_cache:
    pushad
    mov dx, ATA_DRIVE_HEAD
    mov al, 0xF0
    out dx, al
    call host_400ns
    call host_wait_not_busy
    jc .done
    mov dx, ATA_COMMAND
    mov al, 0xE7
    out dx, al
    call host_400ns
    call host_wait_not_busy
.done:
    call host_select_master
    popad
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
host_fat_dirty       db 0
host_nfats           dd 2
host_clusters        dd 0
host_put_size        dd 0
host_put_first       dd 0
host_put_prev        dd 0
host_put_next_free   dd 2
host_put_src         dd 0
host_put_left        dd 0
host_put_dir_lba     dd 0
host_put_dir_off     dd 0
host_put_83          times 11 db ' '
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
