; fsjournal.asm - the filesystem's journal, file times and attributes,
; `ls -l`, `attrib` and `fsck`
;
; The journal: a write that's cut short (the power, QEMU closed, a
; crash) mustn't leave the filesystem half changed - a file's slot
; pointing into sectors the bitmap calls free, a folder gone but not
; its files. So the filesystem's own records - the slots and the
; bitmap (its metadata) - don't go straight to the disk: jnl_write_sector
; keeps them in RAM (each sector once, the newest copy), and
; jnl_commit writes them all out as one:
;   1. every sector into the journal area past the filesystem,
;   2. its header: "LXJN", how many, where each one belongs, a checksum
;      - from here on the change counts as done,
;   3. every sector to its own place,
;   4. the header cleared.
; Cut short before 2: nothing changed. After 2: jnl_replay at the next
; boot does 3 and 4 again. A commit happens whenever the kernel lock is
; let go (src/sched.asm: a console waits for a key, runs a ring-3
; program...) - so a command's changes are written together - when the
; desktop's idle, before switching off, and whenever the RAM copy is
; full. The files' own data goes straight to its sectors, before the
; records that point to it; and a sector a file let go of isn't handed
; to another before the commit (the bitmap says 2: freed, not yet
; free), so a file that's being replaced keeps its old content until
; the new one counts.
;
; A slot also keeps when it last changed (bytes 148..152: year, month,
; day, hour, minute - the RTC's) and its attributes (153: 0xA0 + bits,
; bit 0 read-only). A read-only file can't be written, renamed, moved
; or removed (fs_reject_if_user_cfg asks jnl_ro_check).
; Exports: jnl_write_sector, jnl_commit, jnl_idle, jnl_replay,
;          jnl_start, jnl_stamp, jnl_ro_check, jnl_boot_note,
;          fs_list_long, fs_attrib, fs_fsck

JNL_LBA        equ FS_EXTRA_START_SECTOR + FS_EXTRA_COUNT   ; the header
JNL_MAX        equ 120                    ; sectors in one commit, at most
JNL_BUF        equ 0x3FF0000              ; their RAM copies (60KB)
JNL_SAVE       equ 0x3FFF000              ; SCRATCH_ADDR kept meanwhile
JNL_SAVE2      equ 0x3FFF200              ; (jnl_ro_check's, fsck's)
JNL_SAVE3      equ 0x3FFF400              ; (jnl_put's, when it's full)
JNL_HDR_COUNT  equ 4
JNL_HDR_SUM    equ 8
JNL_HDR_SEQ    equ 12
JNL_HDR_LBAS   equ 16
FS_MTIME_OFFSET equ 148
FS_ATTR_OFFSET  equ 153
FS_ATTR_MAGIC   equ 0xA0
FS_ATTR_RO      equ 1
BMP_FREED       equ 2                     ; a bitmap byte: freed, not yet free

; ============================================================
; The journal
; ============================================================

; ax = a metadata sector's LBA, its content in SCRATCH_ADDR: kept for
; the next commit (as ata_write_sector: carry=1 on a disk error)
jnl_write_sector:
    cmp byte [jnl_on], 0
    jne .keep
    jmp ata_write_sector
.keep:
    pushad
    call jnl_put
    popad
    ret

; ax = LBA, SCRATCH_ADDR: into the RAM copy (a full one written out
; first). carry=1 if that failed.
jnl_put:
    pushad
    xor ecx, ecx
.find:
    cmp ecx, [jnl_count]
    jae .new
    cmp [jnl_lbas + ecx*2], ax
    je .copy
    inc ecx
    jmp .find
.new:
    cmp ecx, JNL_MAX
    jb .add
    mov esi, SCRATCH_ADDR                 ; (full: out with them first)
    mov edi, JNL_SAVE3
    mov ecx, 128
    cld
    rep movsd
    call jnl_flush
    pushfd
    mov esi, JNL_SAVE3
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    rep movsd
    popfd
    jc .fail
    xor ecx, ecx
.add:
    mov [jnl_lbas + ecx*2], ax
    inc dword [jnl_count]
.copy:
    shl ecx, 9
    lea edi, [JNL_BUF + ecx]
    mov esi, SCRATCH_ADDR
    mov ecx, 128
    cld
    rep movsd
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; Whatever's waiting, written out as one (see the top). Keeps every
; register and SCRATCH_ADDR.
jnl_commit:
    cmp byte [jnl_on], 0
    je .quick
    cmp dword [jnl_count], 0
    jne .work
    cmp byte [jnl_freed], 0
    je .quick
.work:
    cmp byte [jnl_busy], 0
    jne .quick
    pushad
    pushfd
    mov byte [jnl_busy], 1
    call jnl_save_scratch
    cmp byte [jnl_freed], 0               ; freed sectors: free now
    je .flush
    mov byte [jnl_freed], 0
    xor ebx, ebx                          ; each bitmap sector
.bmp:
    cmp ebx, FS_BITMAP_SECTORS
    jae .flush
    mov edi, ebx
    shl edi, 9
    add edi, FS_BITMAP_CACHE
    xor edx, edx                          ; edx = 1: one changed
    mov ecx, 512
.byte:
    cmp byte [edi], BMP_FREED
    jne .byte_next
    mov byte [edi], 0
    mov edx, 1
.byte_next:
    inc edi
    loop .byte
    or edx, edx
    jz .bmp_next
    lea esi, [edi - 512]                  ; the sector, into the journal
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    cld
    rep movsd
    lea eax, [ebx + FS_BITMAP_SECTOR]
    call jnl_put
.bmp_next:
    inc ebx
    jmp .bmp
.flush:
    call jnl_flush
    call jnl_load_scratch
    mov byte [jnl_busy], 0
    popfd
    popad
.quick:
    ret

; The desktop's task, now and then: a commit, if nobody's in the kernel
; (for writes whose console hasn't let go of the lock yet - early boot)
jnl_idle:
    pushad
    cmp dword [jnl_count], 0
    jne .try
    cmp byte [jnl_freed], 0
    je .done
.try:
    mov eax, [timer_ms]
    sub eax, [jnl_idle_ms]
    cmp eax, 1000
    jb .done
    mov eax, [timer_ms]
    mov [jnl_idle_ms], eax
    pushfd
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    call jnl_commit
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; The RAM copies to the disk (steps 1-4), SCRATCH_ADDR used (the
; caller keeps it). carry=1 on a disk error (the copies stay).
jnl_flush:
    pushad
    cmp dword [jnl_count], 0
    je .ok
    xor ebx, ebx                          ; 1. into the journal area
    xor ebp, ebp                          ; (the checksum)
.to_journal:
    cmp ebx, [jnl_count]
    jae .header
    call jnl_buf_to_scratch
    call jnl_scratch_sum
    lea eax, [ebx + JNL_LBA + 1]
    call ata_write_sector
    jc .fail
    inc ebx
    jmp .to_journal
.header:                                  ; 2. the header: now it counts
    call jnl_scratch_zero
    mov dword [SCRATCH_ADDR], 'LXJN'
    mov eax, [jnl_count]
    mov [SCRATCH_ADDR + JNL_HDR_COUNT], eax
    mov [SCRATCH_ADDR + JNL_HDR_SUM], ebp
    inc dword [jnl_seq]
    mov eax, [jnl_seq]
    mov [SCRATCH_ADDR + JNL_HDR_SEQ], eax
    mov esi, jnl_lbas
    mov edi, SCRATCH_ADDR + JNL_HDR_LBAS
    mov ecx, [jnl_count]
    cld
    rep movsw
    mov eax, JNL_LBA
    call ata_write_sector
    jc .fail
    xor ebx, ebx                          ; 3. each where it belongs
.home:
    cmp ebx, [jnl_count]
    jae .clear
    call jnl_buf_to_scratch
    movzx eax, word [jnl_lbas + ebx*2]
    call ata_write_sector
    jc .fail
    inc ebx
    jmp .home
.clear:                                   ; 4. done: the header cleared
    call jnl_scratch_zero
    mov eax, JNL_LBA
    call ata_write_sector
    jc .fail
    mov dword [jnl_count], 0
    inc dword [jnl_commits]
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; RAM copy ebx -> SCRATCH_ADDR
jnl_buf_to_scratch:
    push ecx
    push esi
    push edi
    mov esi, ebx
    shl esi, 9
    add esi, JNL_BUF
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    cld
    rep movsd
    pop edi
    pop esi
    pop ecx
    ret

; ebp += SCRATCH_ADDR's dwords
jnl_scratch_sum:
    push ecx
    push esi
    mov esi, SCRATCH_ADDR
    mov ecx, 128
.sum:
    add ebp, [esi]
    add esi, 4
    loop .sum
    pop esi
    pop ecx
    ret

jnl_scratch_zero:
    push eax
    push ecx
    push edi
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    pop edi
    pop ecx
    pop eax
    ret

jnl_save_scratch:
    push ecx
    push esi
    push edi
    mov esi, SCRATCH_ADDR
    mov edi, JNL_SAVE
    jmp jnl_copy_sector
jnl_load_scratch:
    push ecx
    push esi
    push edi
    mov esi, JNL_SAVE
    mov edi, SCRATCH_ADDR
jnl_copy_sector:
    mov ecx, 128
    cld
    rep movsd
    pop edi
    pop esi
    pop ecx
    ret

; At boot, before the filesystem's read (fs_cache_init): a commit that
; was cut short after its header, finished
jnl_replay:
    pushad
    mov byte [jnl_on], 0
    mov eax, JNL_LBA
    call ata_read_sector
    jc .done
    cmp dword [SCRATCH_ADDR], 'LXJN'
    jne .done
    mov ecx, [SCRATCH_ADDR + JNL_HDR_COUNT]
    or ecx, ecx
    jz .done
    cmp ecx, JNL_MAX
    ja .clear
    mov [jnl_count], ecx
    mov eax, [SCRATCH_ADDR + JNL_HDR_SEQ]
    mov [jnl_seq], eax
    mov eax, [SCRATCH_ADDR + JNL_HDR_SUM]
    mov [jnl_sum_want], eax
    mov esi, SCRATCH_ADDR + JNL_HDR_LBAS
    mov edi, jnl_lbas
    cld
    rep movsw
    xor ebx, ebx                          ; the sectors, back into RAM
    xor ebp, ebp
.read:
    cmp ebx, [jnl_count]
    jae .check
    lea eax, [ebx + JNL_LBA + 1]
    call ata_read_sector
    jc .clear
    call jnl_scratch_sum
    mov esi, SCRATCH_ADDR
    mov edi, ebx
    shl edi, 9
    add edi, JNL_BUF
    mov ecx, 128
    rep movsd
    inc ebx
    jmp .read
.check:
    cmp ebp, [jnl_sum_want]               ; (a torn journal: never counted)
    jne .clear
    xor ebx, ebx
.home:
    cmp ebx, [jnl_count]
    jae .replayed
    call jnl_buf_to_scratch
    movzx eax, word [jnl_lbas + ebx*2]
    cmp eax, FS_START_SECTOR              ; (only ever the metadata)
    jb .skip
    cmp eax, FS_EXTRA_START_SECTOR
    jae .skip
    call ata_write_sector
.skip:
    inc ebx
    jmp .home
.replayed:
    mov eax, [jnl_count]
    mov [jnl_replayed], eax
.clear:
    mov dword [jnl_count], 0
    call jnl_scratch_zero
    mov eax, JNL_LBA
    call ata_write_sector
.done:
    popad
    ret

; After fs_cache_init: from now on through the journal. A sector the
; bitmap still calls "freed" (a commit cut short before 2) stays in use
; - fsck can tell whether anything has it.
jnl_start:
    pushad
    mov edi, FS_BITMAP_CACHE
    mov ecx, FS_BITMAP_SECTORS * 512
.each:
    cmp byte [edi], BMP_FREED
    jne .next
    mov byte [edi], 1
.next:
    inc edi
    loop .each
    mov dword [jnl_count], 0
    mov byte [jnl_on], 1
    popad
    ret

; At boot, once the screen's up: had the journal something to finish?
jnl_boot_note:
    cmp dword [jnl_replayed], 0
    je .done
    pushad
    mov esi, jnl_m_rep1
    call jnl_puts
    mov eax, [jnl_replayed]
    xor ecx, ecx
    call jnl_num
    mov esi, jnl_m_rep2
    call jnl_puts
    popad
.done:
    ret

; ============================================================
; Times and attributes
; ============================================================

; fs_write_slot, before it writes SCRATCH_ADDR: the time it changed (a
; slot let go of: its time and attributes cleared)
jnl_stamp:
    cmp byte [jnl_no_stamp], 0
    jne .done
    pushad
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    jne .stamp
    xor eax, eax
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET], eax
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET + 4], ax
    jmp .out
.stamp:
    call rtc_read_date                    ; bh day, bl month, cl year
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET], cl
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET + 1], bl
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET + 2], bh
    call rtc_read_time                    ; bh hours, bl minutes
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET + 3], bh
    mov [SCRATCH_ADDR + FS_MTIME_OFFSET + 4], bl
.out:
    popad
.done:
    ret

; ax = a slot -> al = its attribute bits (0: none). SCRATCH_ADDR kept.
jnl_attr_of:
    push ecx
    push esi
    push edi
    push eax
    mov esi, SCRATCH_ADDR
    mov edi, JNL_SAVE2
    mov ecx, 128
    cld
    rep movsd
    pop eax
    push eax
    call fs_read_slot
    pop eax
    mov al, [SCRATCH_ADDR + FS_ATTR_OFFSET]
    mov ah, al
    and ah, 0xF0
    cmp ah, FS_ATTR_MAGIC
    je .valid
    xor al, al
.valid:
    and al, 0x0F
    push eax
    mov esi, JNL_SAVE2
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    rep movsd
    pop eax
    pop edi
    pop esi
    pop ecx
    ret

; ax = a slot about to be changed: carry=1 (and why, printed) if it's
; read-only. Keeps every register.
jnl_ro_check:
    push eax
    call jnl_attr_of
    test al, FS_ATTR_RO
    pop eax
    jz .ok
    push esi
    mov esi, jnl_m_ro
    call jnl_puts
    pop esi
    stc
    ret
.ok:
    clc
    ret

; ============================================================
; ls -l: the current folder, with each one's kind, attributes, time
; and size
; ============================================================
fs_list_long:
    pushad
    mov al, [current_color]
    mov [jnl_color], al
    call fs_get_current_parent_byte
    mov [jnl_parent], al
    mov dword [jnl_found], 0
    xor ebx, ebx
.scan:
    cmp ebx, FS_TOTAL_SLOTS
    jae .scanned
    mov eax, ebx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next
    mov dl, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp dl, [jnl_parent]
    jne .next
    inc dword [jnl_found]
    mov dl, al                            ; dl = the type
    mov al, '-'                           ; its kind: d folder, x program,
    cmp dl, FS_TYPE_DIR                   ; - file
    jne .not_d
    mov al, 'd'
.not_d:
    cmp dl, FS_TYPE_PROGRAM
    jne .kind
    mov al, 'x'
.kind:
    call print_char
    mov al, [SCRATCH_ADDR + FS_ATTR_OFFSET]  ; r: read-only
    mov ah, al
    and ah, 0xF0
    cmp ah, FS_ATTR_MAGIC
    mov al, '-'
    jne .attr
    test byte [SCRATCH_ADDR + FS_ATTR_OFFSET], FS_ATTR_RO
    jz .attr
    mov al, 'r'
.attr:
    call print_char
    mov al, ' '
    call print_char
    call jnl_print_time
    cmp dl, FS_TYPE_DIR                   ; the size
    jne .size
    mov esi, jnl_m_dir
    call print_string32
    jmp .name
.size:
    movzx eax, byte [SCRATCH_ADDR + FS_CONTENT_OFFSET]
    cmp dl, FS_TYPE_PROGRAM
    je .have_size
    call fs_get_size
.have_size:
    mov ecx, 8
    call jnl_num
.name:
    mov al, ' '
    call print_char
    call print_char
    cmp dl, FS_TYPE_DIR
    jne .name_color
    mov byte [current_color], ATTR_LS_DIR
.name_color:
    xor ecx, ecx
.name_char:
    mov al, [SCRATCH_ADDR + ecx]
    or al, al
    jz .named
    call print_char
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .name_char
.named:
    mov al, [jnl_color]
    mov [current_color], al
    mov al, 13
    call print_char
    mov al, 10
    call print_char
.next:
    inc ebx
    jmp .scan
.scanned:
    cmp dword [jnl_found], 0
    jne .done
    mov si, msg_fs_empty
    call print_string
.done:
    popad
    ret

; SCRATCH_ADDR's time: "DD.MM.20YY HH:MM" (the hour in the user's time
; zone, as `time`), or blanks if it has none
jnl_print_time:
    pushad
    cmp byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 1], 0
    jne .have
    mov esi, jnl_m_notime
    call print_string32
    jmp .done
.have:
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 2]
    call print_dec2
    mov al, '.'
    call print_char
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 1]
    call print_dec2
    mov al, '.'
    call print_char
    mov al, '2'
    call print_char
    mov al, '0'
    call print_char
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET]
    call print_dec2
    mov al, ' '
    call print_char
    movzx eax, byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 3]
    movsx edx, word [user_tz_offset]
    add eax, edx
    add eax, 24
.hour:
    cmp eax, 24
    jl .hour_ok
    sub eax, 24
    jmp .hour
.hour_ok:
    call print_dec2
    mov al, ':'
    call print_char
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 4]
    call print_dec2
.done:
    popad
    ret

; eax -> decimal, right-aligned in ecx places (0: as it is)
jnl_num:
    pushad
    mov edi, jnl_numbuf + 11
    mov byte [edi], 0
    mov ebx, 10
.digit:
    xor edx, edx
    div ebx
    add dl, '0'
    dec edi
    mov [edi], dl
    or eax, eax
    jnz .digit
    mov eax, jnl_numbuf + 11
    sub eax, edi                          ; its digits
.pad:
    cmp eax, ecx
    jae .print
    push eax
    mov al, ' '
    call print_char
    pop eax
    inc eax
    jmp .pad
.print:
    mov esi, edi
    call print_string32
    popad
    ret

; esi = English text: printed in the system's language
jnl_puts:
    pushad
    call tr_lookup
    call print_string32
    popad
    ret

; ============================================================
; attrib <name> [+r | -r]
; ============================================================
; esi = what follows "attrib "
fs_attrib:
    pushad
    mov byte [jnl_attr_op], 0             ; 0 show, 1 +r, 2 -r
    mov byte [fs_tmp_name], 0
.word:
    cmp byte [esi], ' '
    jne .word_start
    inc esi
    jmp .word
.word_start:
    mov al, [esi]
    or al, al
    jz .parsed
    cmp al, '+'
    je .flag
    cmp al, '-'
    je .flag
    mov edi, fs_tmp_name                  ; the name
    mov ecx, FS_NAME_LEN
.name:
    mov al, [esi]
    or al, al
    jz .name_end
    cmp al, ' '
    je .name_end
    stosb
    inc esi
    loop .name
.name_skip:
    mov al, [esi]
    or al, al
    jz .name_end
    cmp al, ' '
    je .name_end
    inc esi
    jmp .name_skip
.name_end:
    mov byte [edi], 0
    jmp .word
.flag:
    mov ah, [esi + 1]
    or ah, 0x20
    cmp ah, 'r'
    jne .usage
    mov byte [jnl_attr_op], 1
    cmp al, '+'
    je .flag_done
    mov byte [jnl_attr_op], 2
.flag_done:
    add esi, 2
    jmp .word
.parsed:
    cmp byte [fs_tmp_name], 0
    je .usage
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    mov si, msg_fs_notfound
    call print_string
    jmp .done
.found:
    mov [jnl_attr_slot], ax
    cmp byte [jnl_attr_op], 0
    je .show
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_ATTR_OFFSET]
    mov ah, al
    and ah, 0xF0
    cmp ah, FS_ATTR_MAGIC
    je .valid
    xor al, al
.valid:
    or al, FS_ATTR_MAGIC | FS_ATTR_RO
    cmp byte [jnl_attr_op], 1
    je .set
    and al, ~FS_ATTR_RO
.set:
    mov [SCRATCH_ADDR + FS_ATTR_OFFSET], al
    mov byte [jnl_no_stamp], 1            ; (its content didn't change)
    mov ax, [jnl_attr_slot]
    call fs_write_slot
    mov byte [jnl_no_stamp], 0
.show:
    mov esi, fs_tmp_name
    call print_string32
    mov ax, [jnl_attr_slot]
    call jnl_attr_of
    mov esi, jnl_m_attr_rw
    test al, FS_ATTR_RO
    jz .say
    mov esi, jnl_m_attr_ro
.say:
    call jnl_puts
    jmp .done
.usage:
    mov esi, jnl_m_attr_use
    call jnl_puts
.done:
    popad
    ret

; ============================================================
; fsck [fix]: the filesystem checked - every slot's type and folder,
; every file's chain of sectors (in range, marked used, nobody else's,
; no loop, as long as its size says) and sectors in use by nothing.
; With "fix" (esi -> "fix"), put right: bad slots freed, lost files
; moved to /, broken or shared chains cut short, sizes set to what the
; chain holds, the bitmap made to match.
; ============================================================
FSCK_SEEN      equ BIG_FILE_BUF           ; a byte per pool sector

fs_fsck:
    pushad
    mov byte [jnl_fix], 0
    or esi, esi
    jz .no_fix
    cmp byte [esi], 'f'
    jne .no_fix
    mov byte [jnl_fix], 1
.no_fix:
    mov esi, jnl_m_fsck_head
    call jnl_puts
    xor eax, eax
    mov [jnl_problems], eax
    mov [jnl_files], eax
    mov [jnl_dirs], eax
    mov [jnl_used], eax
    mov edi, FSCK_SEEN
    mov ecx, FS_EXTRA_COUNT
    cld
    rep stosb
    xor ebx, ebx                          ; each slot on the disk
.slot:
    cmp ebx, FS_FILE_COUNT
    jae .slots_done
    mov [jnl_slot], ebx
    mov eax, ebx
    call fs_read_slot
    mov byte [jnl_dirty], 0
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .slot_next
    cmp al, FS_TYPE_PROGRAM
    jbe .type_ok
    mov esi, jnl_m_badtype                ; unknown: freed
    call fsck_problem
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    mov byte [jnl_dirty], 1
    jmp .slot_write
.type_ok:
    cmp al, FS_TYPE_DIR
    jne .a_file
    inc dword [jnl_dirs]
    jmp .parent
.a_file:
    inc dword [jnl_files]
.parent:
    movzx eax, byte [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp eax, FS_ROOT_BYTE
    je .parent_ok
    call fsck_is_dir                      ; is it a folder?
    jnc .parent_ok
    mov esi, jnl_m_orphan
    call fsck_problem
    mov byte [SCRATCH_ADDR + FS_PARENT_OFFSET], FS_ROOT_BYTE
    mov byte [jnl_dirty], 1
.parent_ok:
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .slot_write
    call fsck_chain
.slot_write:
    cmp byte [jnl_dirty], 0
    je .slot_next
    cmp byte [jnl_fix], 0
    je .slot_next
    mov byte [jnl_no_stamp], 1
    mov eax, [jnl_slot]
    call fs_write_slot
    mov byte [jnl_no_stamp], 0
.slot_next:
    mov ebx, [jnl_slot]
    inc ebx
    jmp .slot
.slots_done:
    ; the RAM slots' (TMP) chains are on the disk too: seen, not checked
    mov ebx, FS_FILE_COUNT
.ram:
    cmp ebx, FS_TOTAL_SLOTS
    jae .lost
    mov [jnl_slot], ebx
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .ram_next
    mov byte [jnl_ram], 1
    call fsck_chain
    mov byte [jnl_ram], 0
.ram_next:
    inc ebx
    jmp .ram
.lost:
    xor ebx, ebx                          ; in use by nothing
    xor edx, edx
.lost_each:
    cmp ebx, FS_EXTRA_COUNT
    jae .lost_done
    cmp byte [FS_BITMAP_CACHE + ebx], 0
    je .lost_next
    cmp byte [FSCK_SEEN + ebx], 0
    jne .lost_next
    inc edx
    cmp byte [jnl_fix], 0
    je .lost_next
    mov eax, ebx
    call fs_extra_free
.lost_next:
    inc ebx
    jmp .lost_each
.lost_done:
    or edx, edx
    jz .summary
    add [jnl_problems], edx
    mov esi, jnl_m_lost
    call jnl_puts
    mov eax, edx
    xor ecx, ecx
    call jnl_num
    mov al, 13
    call print_char
    mov al, 10
    call print_char
.summary:
    mov eax, [jnl_files]
    xor ecx, ecx
    call jnl_num
    mov esi, jnl_m_sum1
    call jnl_puts
    mov eax, [jnl_dirs]
    call jnl_num
    mov esi, jnl_m_sum2
    call jnl_puts
    mov eax, [jnl_used]
    call jnl_num
    mov esi, jnl_m_sum3
    call jnl_puts
    mov esi, jnl_m_ok
    mov eax, [jnl_problems]
    or eax, eax
    jz .said
    call jnl_num
    mov esi, jnl_m_found
    cmp byte [jnl_fix], 0
    je .said
    mov esi, jnl_m_fixed
.said:
    call jnl_puts
    mov esi, jnl_m_journal                ; and the journal
    call jnl_puts
    mov eax, [jnl_commits]
    call jnl_num
    mov esi, jnl_m_journal2
    call jnl_puts
    popad
    ret

; eax = a slot index: carry=0 if it's a folder. SCRATCH_ADDR kept.
fsck_is_dir:
    push eax
    cmp eax, FS_FILE_COUNT
    jae .no
    call jnl_type_of
    cmp al, FS_TYPE_DIR
    jne .no
    pop eax
    clc
    ret
.no:
    pop eax
    stc
    ret

; eax = a slot -> al = its type (read if not cached). SCRATCH_ADDR kept.
jnl_type_of:
    push ecx
    push esi
    push edi
    push eax
    mov esi, SCRATCH_ADDR
    mov edi, JNL_SAVE2
    mov ecx, 128
    cld
    rep movsd
    pop eax
    push eax
    call fs_read_slot
    pop eax
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    push eax
    mov esi, JNL_SAVE2
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    rep movsd
    pop eax
    pop edi
    pop esi
    pop ecx
    ret

; The file in SCRATCH_ADDR (slot jnl_slot): its chain walked (each
; sector read into JNL_SAVE2's place... through SCRATCH_ADDR, so the
; slot's kept at JNL_SAVE2 meanwhile)
fsck_chain:
    pushad
    mov esi, SCRATCH_ADDR                 ; the slot, aside
    mov edi, JNL_SAVE2
    mov ecx, 128
    cld
    rep movsd
    call fs_get_size
    mov [jnl_size], eax
    xor ebp, ebp                          ; bytes it holds
    mov ecx, eax
    cmp ecx, FS_CONTENT_LEN - 1
    jbe .inline
    mov ecx, FS_CONTENT_LEN - 1
.inline:
    add ebp, ecx
    movzx eax, word [SCRATCH_ADDR + FS_CHAIN_OFFSET]
    mov dword [jnl_prev], -1              ; (the sector before: -1 the slot)
.link:
    cmp eax, FS_NO_CHAIN
    je .walked
    mov edx, jnl_m_badlink
    cmp eax, FS_EXTRA_COUNT
    jae .cut
    mov edx, jnl_m_crossed
    cmp byte [FSCK_SEEN + eax], 0
    jne .cut
    mov byte [FSCK_SEEN + eax], 1
    inc dword [jnl_used]
    cmp byte [FS_BITMAP_CACHE + eax], 0
    jne .marked
    cmp byte [jnl_ram], 0
    jne .marked
    push eax
    mov esi, jnl_m_freeused
    call fsck_problem_saved
    pop eax
    cmp byte [jnl_fix], 0
    je .marked
    mov byte [FS_BITMAP_CACHE + eax], 1
    call fs_bitmap_writeback
.marked:
    mov [jnl_prev], eax
    push eax
    call fs_extra_read
    pop eax
    jc .walked
    movzx ecx, word [SCRATCH_ADDR + FS_EXTRA_USED_OFFSET]
    cmp ecx, FS_EXTRA_CONTENT_LEN
    jbe .used_ok
    mov ecx, FS_EXTRA_CONTENT_LEN
.used_ok:
    add ebp, ecx
    movzx eax, word [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET]
    jmp .link
.cut:                                     ; broken here: the chain ends
    cmp byte [jnl_ram], 0                 ; before it
    jne .walked
    mov esi, edx
    call fsck_problem_saved
    cmp byte [jnl_fix], 0
    je .walked
    mov eax, [jnl_prev]
    cmp eax, -1
    jne .cut_sector
    mov word [JNL_SAVE2 + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov byte [jnl_dirty], 1
    jmp .walked
.cut_sector:
    push eax
    call fs_extra_read
    pop eax
    mov word [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET], FS_NO_CHAIN
    push eax
    call fs_extra_write
    pop eax
.walked:
    cmp byte [jnl_ram], 0
    jne .back
    cmp ebp, [jnl_size]                   ; its size: what it holds?
    je .back
    mov esi, jnl_m_size
    call fsck_problem_saved
    mov eax, ebp
    mov [JNL_SAVE2 + FS_TOTAL_LEN_OFFSET], ax
    shr eax, 16
    mov [JNL_SAVE2 + FS_TOTAL_LEN_HI_OFFSET], ax
    mov byte [jnl_dirty], 1
.back:
    mov esi, JNL_SAVE2                    ; the slot back
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    cld
    rep movsd
    popad
    ret

; esi = what's wrong with the slot in SCRATCH_ADDR: said, counted
fsck_problem:
    pushad
    inc dword [jnl_problems]
    call jnl_puts
    xor ecx, ecx
.name:
    mov al, [SCRATCH_ADDR + ecx]
    or al, al
    jz .named
    call print_char
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .name
.named:
    mov al, 13
    call print_char
    mov al, 10
    call print_char
    popad
    ret

; The same, the slot being at JNL_SAVE2
fsck_problem_saved:
    pushad
    inc dword [jnl_problems]
    call jnl_puts
    xor ecx, ecx
.name:
    mov al, [JNL_SAVE2 + ecx]
    or al, al
    jz .named
    call print_char
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .name
.named:
    mov al, 13
    call print_char
    mov al, 10
    call print_char
    popad
    ret

; ============================================================
; Data (shared: the filesystem is one, whichever console uses it)
; ============================================================
jnl_on           db 0
jnl_busy         db 0
jnl_freed        db 0                     ; the bitmap has BMP_FREED bytes
jnl_no_stamp     db 0
jnl_count        dd 0
jnl_seq          dd 0
jnl_sum_want     dd 0
jnl_replayed     dd 0
jnl_commits      dd 0
jnl_idle_ms      dd 0
jnl_lbas         times JNL_MAX dw 0
jnl_color        db 0
jnl_parent       db 0
jnl_found        dd 0
jnl_numbuf       times 12 db 0
jnl_attr_op      db 0
jnl_attr_slot    dw 0
jnl_fix          db 0
jnl_dirty        db 0
jnl_ram          db 0
jnl_problems     dd 0
jnl_files        dd 0
jnl_dirs         dd 0
jnl_used         dd 0
jnl_slot         dd 0
jnl_size         dd 0
jnl_prev         dd 0
jnl_m_dir        db "   <DIR>", 0
jnl_m_notime     db "                ", 0
jnl_m_ro         db "It's read-only (attrib -r <name> allows changes).", 13, 10, 0
jnl_m_attr_ro    db ": read-only", 13, 10, 0
jnl_m_attr_rw    db ": can be changed", 13, 10, 0
jnl_m_attr_use   db "Usage: attrib <name> [+r | -r]", 13, 10, 0
jnl_m_fsck_head  db "Checking the filesystem...", 13, 10, 0
jnl_m_badtype    db "  a slot of no known kind (freed): ", 0
jnl_m_orphan     db "  its folder isn't there (moved to /): ", 0
jnl_m_badlink    db "  its chain breaks off (cut short): ", 0
jnl_m_crossed    db "  shares sectors with another file (cut short): ", 0
jnl_m_freeused   db "  uses sectors marked free (marked used): ", 0
jnl_m_size       db "  its size is wrong (set to what it holds): ", 0
jnl_m_lost       db "  sectors in use by nothing (freed): ", 0
jnl_m_sum1       db " files, ", 0
jnl_m_sum2       db " folders, ", 0
jnl_m_sum3       db " sectors of data.", 13, 10, 0
jnl_m_ok         db "No problems found.", 13, 10, 0
jnl_m_found      db " problem(s) - fsck fix puts them right.", 13, 10, 0
jnl_m_fixed      db " problem(s) put right.", 13, 10, 0
jnl_m_journal    db "Journal: on, ", 0
jnl_m_journal2   db " commits since boot.", 13, 10, 0
jnl_m_rep1       db "Journal: a write cut short was finished (", 0
jnl_m_rep2       db " sectors).", 13, 10, 0
