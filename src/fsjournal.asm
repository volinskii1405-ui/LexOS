; fsjournal.asm - the filesystem's journal, file times and attributes,
; `ls -l`, `attrib` and `fsck`
;
; The journal: a write that's cut short (the power, QEMU closed, a
; crash) mustn't leave the filesystem half changed - a file's entry
; pointing into clusters the FAT calls free, a folder gone but not its
; files. So the FAT32 filesystem's own records (src/fat32.asm) - the
; FAT's sectors and the folders' (its metadata) - don't go straight to
; the disk: jnl_put_buf keeps them in RAM (each sector once, the newest
; copy), and jnl_commit writes them all out as one:
;   1. every sector into the journal area past the filesystem,
;   2. its header: "LXJN", how many, where each one belongs, a checksum
;      - from here on the change counts as done,
;   3. every sector to its own place,
;   4. the header cleared.
; Cut short before 2: nothing changed. After 2: jnl_replay at the next
; boot does 3 and 4 again. A commit happens whenever the kernel lock is
; let go (src/sched.asm: a console waits for a key, runs a ring-3
; program... - at most twice a second then: a program writing a big
; file doesn't wait for a commit per piece), when the desktop's idle,
; before switching off, and whenever the RAM copy is full. The files'
; own data goes straight to its clusters, before the records that point
; to it; and a cluster a file let go of isn't handed to another before
; the commit (src/fat32.asm's FAT_PENDING), so a file that's being
; replaced keeps its old content until the new one counts. The journal
; lives before the partition (sectors 1024-1144), where nothing else
; looks.
;
; A slot also keeps when it last changed (bytes 148..152: year, month,
; day, hour, minute - the RTC's) and its attributes (153: 0xA0 + bits,
; bit 0 read-only). A read-only file can't be written, renamed, moved
; or removed (fs_reject_if_user_cfg asks jnl_ro_check).
; Exports: jnl_write_sector, jnl_commit, jnl_idle, jnl_replay,
;          jnl_start, jnl_stamp, jnl_ro_check, jnl_boot_note,
;          fs_list_long, fs_attrib, fs_fsck

JNL_LBA        equ 1024                   ; the header (before the partition)
JNL_MAX        equ 120                    ; sectors in one commit, at most
JNL_BUF        equ 0x3FF0000              ; their RAM copies (60KB)
JNL_SAVE       equ 0x3FFF000              ; SCRATCH_ADDR kept meanwhile
JNL_SAVE2      equ 0x3FFF200              ; (jnl_ro_check's, fsck's)
JNL_SAVE3      equ 0x3FFF400              ; (spare)
JNL_HDR        equ 0x3FFF600              ; the header, as it's written / read
JNL_HDR_COUNT  equ 4
JNL_HDR_SUM    equ 8
JNL_HDR_SEQ    equ 12
JNL_HDR_LBAS   equ 16
FS_MTIME_OFFSET equ 148
FS_ATTR_OFFSET  equ 153
FS_ATTR_MAGIC   equ 0xA0
FS_ATTR_RO      equ 1

; ============================================================
; The journal
; ============================================================

; ax = a sector's LBA, its content in SCRATCH_ADDR: kept for the next
; commit (as ata_write_sector: carry=1 on a disk error)
jnl_write_sector:
    push eax
    push esi
    movzx eax, ax
    mov esi, SCRATCH_ADDR
    call jnl_put_buf
    pop esi
    pop eax
    ret

; eax = a metadata sector's LBA, esi = its 512 bytes: kept for the next
; commit (the journal off: written now). carry=1 on a disk error.
; Keeps every register.
jnl_put_buf:
    cmp byte [jnl_on], 0
    jne .keep
    push ecx
    mov ecx, 1
    call ata_write_lba
    pop ecx
    ret
.keep:
    pushad
    xor ecx, ecx
.find:
    cmp ecx, [jnl_count]
    jae .new
    cmp [jnl_lbas + ecx*4], eax
    je .copy
    inc ecx
    jmp .find
.new:
    cmp ecx, JNL_MAX
    jb .add
    call jnl_flush                        ; (full: out with them first)
    jc .fail
    xor ecx, ecx
.add:
    mov [jnl_lbas + ecx*4], eax
    inc dword [jnl_count]
.copy:
    shl ecx, 9
    lea edi, [JNL_BUF + ecx]
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

; eax = an LBA -> esi = its copy waiting in the journal, carry=0;
; carry=1: none (the disk's is the newest)
jnl_find:
    push ecx
    xor ecx, ecx
.each:
    cmp ecx, [jnl_count]
    jae .none
    cmp [jnl_lbas + ecx*4], eax
    je .found
    inc ecx
    jmp .each
.found:
    mov esi, ecx
    shl esi, 9
    add esi, JNL_BUF
    pop ecx
    clc
    ret
.none:
    pop ecx
    stc
    ret

; eax = the first LBA, ecx = how many, edi = where to: read, with what
; the journal has for any of them over it. carry=1 on a disk error.
jnl_read_lbas:
    call ata_read_lba
    jc .done
    pushad
    xor ebx, ebx
.each:
    cmp ebx, [jnl_count]
    jae .over
    mov edx, [jnl_lbas + ebx*4]
    sub edx, eax
    cmp edx, ecx
    jae .next
    push ecx
    push edi
    mov esi, ebx
    shl esi, 9
    add esi, JNL_BUF
    shl edx, 9
    add edi, edx
    mov ecx, 128
    cld
    rep movsd
    pop edi
    pop ecx
.next:
    inc ebx
    jmp .each
.over:
    popad
    clc
.done:
    ret

; Whatever's waiting, written out as one (see the top) - the FAT's
; changed sectors with it. Keeps every register and SCRATCH_ADDR.
jnl_commit:
    cmp byte [jnl_on], 0
    je .quick
    cmp byte [jnl_busy], 0
    jne .quick
    cmp dword [jnl_count], 0
    jne .work
    cmp byte [fat_dirty_any], 0
    jne .work
    cmp byte [fat_pending_any], 0
    je .quick
.work:
    pushad
    pushfd
    mov byte [jnl_busy], 1
    call fat_journal_fat                  ; (src/fat32.asm)
    call jnl_flush
    jc .kept
    call fat_commit_done                  ; freed clusters: free now
.kept:
    mov eax, [timer_ms]
    mov [jnl_last_ms], eax
    mov byte [jnl_busy], 0
    popfd
    popad
.quick:
    ret

; The same, but not more than twice a second (the kernel lock let go:
; a program writing a big file a piece at a time) - the desktop's idle
; commit (jnl_idle) and the next one catch up
jnl_commit_lazy:
    push eax
    mov eax, [timer_ms]
    sub eax, [jnl_last_ms]
    cmp eax, 500
    pop eax
    jb .later
    jmp jnl_commit
.later:
    ret

; The desktop's task, now and then: a commit, if nobody's in the kernel
; (for writes whose console hasn't let go of the lock yet - early boot)
jnl_idle:
    pushad
    cmp dword [jnl_count], 0
    jne .try
    cmp byte [fat_dirty_any], 0
    jne .try
    cmp byte [fat_pending_any], 0
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

; The RAM copies to the disk (steps 1-4). carry=1 on a disk error (the
; copies stay).
jnl_flush:
    pushad
    cmp dword [jnl_count], 0
    je .ok
    mov eax, JNL_LBA + 1                  ; 1. into the journal area, all at once
    mov ecx, [jnl_count]
    mov esi, JNL_BUF
    call ata_write_lba
    jc .fail
    xor ebp, ebp                          ; (their checksum)
    mov esi, JNL_BUF
    mov ecx, [jnl_count]
    shl ecx, 7
.sum:
    add ebp, [esi]
    add esi, 4
    loop .sum
    call ata_flush                        ; 2. the header: now it counts
    mov edi, JNL_HDR                      ; (what's before it: on the disk -
    mov ecx, 128                          ;  the files' own clusters too)
    xor eax, eax
    cld
    rep stosd
    mov dword [JNL_HDR], 'LXJN'
    mov eax, [jnl_count]
    mov [JNL_HDR + JNL_HDR_COUNT], eax
    mov [JNL_HDR + JNL_HDR_SUM], ebp
    inc dword [jnl_seq]
    mov eax, [jnl_seq]
    mov [JNL_HDR + JNL_HDR_SEQ], eax
    mov esi, jnl_lbas
    mov edi, JNL_HDR + JNL_HDR_LBAS
    mov ecx, [jnl_count]
    rep movsd
    mov eax, JNL_LBA
    mov esi, JNL_HDR
    mov ecx, 1
    call ata_write_lba
    jc .fail
    call ata_flush
    xor ebx, ebx                          ; 3. each where it belongs
.home:
    cmp ebx, [jnl_count]
    jae .clear
    mov eax, [jnl_lbas + ebx*4]
    mov esi, ebx
    shl esi, 9
    add esi, JNL_BUF
    mov ecx, 1
    call ata_write_lba
    jc .fail
    inc ebx
    jmp .home
.clear:                                   ; 4. done: the header cleared
    call ata_flush                        ; (a replay of it now: harmless)
    mov edi, JNL_HDR
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov eax, JNL_LBA
    mov esi, JNL_HDR
    mov ecx, 1
    call ata_write_lba
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

; At boot, before the filesystem's read (fs_cache_init): a commit that
; was cut short after its header, finished
jnl_replay:
    pushad
    mov byte [jnl_on], 0
    mov eax, JNL_LBA
    mov edi, JNL_HDR
    mov ecx, 1
    call ata_read_lba
    jc .done
    cmp dword [JNL_HDR], 'LXJN'
    jne .done
    mov ecx, [JNL_HDR + JNL_HDR_COUNT]
    or ecx, ecx
    jz .done
    cmp ecx, JNL_MAX
    ja .clear
    mov [jnl_count], ecx
    mov eax, [JNL_HDR + JNL_HDR_SEQ]
    mov [jnl_seq], eax
    mov eax, JNL_LBA + 1                  ; the sectors, back into RAM
    mov edi, JNL_BUF
    call ata_read_lba
    jc .clear
    xor ebp, ebp
    mov esi, JNL_BUF
    shl ecx, 7
.sum:
    add ebp, [esi]
    add esi, 4
    loop .sum
    cmp ebp, [JNL_HDR + JNL_HDR_SUM]      ; (a torn journal: never counted)
    jne .clear
    xor ebx, ebx
.home:
    cmp ebx, [jnl_count]
    jae .replayed
    mov eax, [JNL_HDR + JNL_HDR_LBAS + ebx*4]
    cmp eax, FAT_PART_LBA                 ; (only ever the partition's)
    jb .skip
    mov esi, ebx
    shl esi, 9
    add esi, JNL_BUF
    mov ecx, 1
    call ata_write_lba
.skip:
    inc ebx
    jmp .home
.replayed:
    mov eax, [jnl_count]
    mov [jnl_replayed], eax
.clear:
    mov dword [jnl_count], 0
    mov edi, JNL_HDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    mov eax, JNL_LBA
    mov esi, JNL_HDR
    mov ecx, 1
    call ata_write_lba
.done:
    popad
    ret

; After fs_cache_init: from now on through the journal
jnl_start:
    mov dword [jnl_count], 0
    mov byte [jnl_on], 1
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
    push esi
    mov esi, SCRATCH_ADDR
    call jnl_stamp_at
    pop esi
.done:
    ret

; esi = a record: the same, to it
jnl_stamp_at:
    pushad
    cmp byte [esi + FS_TYPE_OFFSET], FS_TYPE_FREE
    jne .stamp
    xor eax, eax
    mov [esi + FS_MTIME_OFFSET], eax
    mov [esi + FS_MTIME_OFFSET + 4], ax
    jmp .out
.stamp:
    call rtc_read_date                    ; bh day, bl month, cl year
    mov [esi + FS_MTIME_OFFSET], cl
    mov [esi + FS_MTIME_OFFSET + 1], bl
    mov [esi + FS_MTIME_OFFSET + 2], bh
    call rtc_read_time                    ; bh hours, bl minutes
    mov [esi + FS_MTIME_OFFSET + 3], bh
    mov [esi + FS_MTIME_OFFSET + 4], bl
.out:
    popad
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
    push eax
    mov al, ' '
    call print_char
    pop eax
    mov ecx, 10                           ; (up to FAT32's 4GB)
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
    call fsl_print_long                   ; (src/fslong.asm)
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
; fsck [fix]: the filesystem checked - every file's and folder's chain
; of clusters (in range, nobody else's, no loop, as long as its size
; says: src/fat32.asm's fat_fsck) and clusters in use by nothing. With
; "fix" (esi -> "fix"), put right: broken or shared chains cut short,
; sizes set to what the chain holds, what's too long or lost freed.
; ============================================================
fs_fsck:
    pushad
    mov byte [jnl_fix], 0
    or esi, esi
    jz .no_fix
    cmp byte [esi], 'f'
    jne .no_fix
    mov byte [jnl_fix], 1
.no_fix:
    mov al, [jnl_fix]
    mov [fat_fsck_fix], al
    mov esi, jnl_m_fsck_head
    call jnl_puts
    xor eax, eax
    mov [jnl_problems], eax
    mov [jnl_files], eax
    mov [jnl_dirs], eax
    cmp byte [fat_ok], 0
    jne .mounted
    mov esi, jnl_m_nofat
    call jnl_puts
    popad
    ret
.mounted:
    call fat_fsck_start
    xor ebx, ebx                          ; each slot on the disk
.slot:
    cmp ebx, FS_FILE_COUNT
    jae .slots_done
    mov [jnl_slot], ebx
    mov eax, ebx
    shl eax, 9
    mov al, [FS_SLOT_CACHE + eax + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .slot_next
    cmp al, FS_TYPE_DIR
    jne .a_file
    inc dword [jnl_dirs]
    jmp .chain
.a_file:
    inc dword [jnl_files]
.chain:
    call fat_fsck                         ; -> eax problems
    or eax, eax
    jz .slot_next
    mov eax, ebx
    call fs_read_slot
    mov esi, jnl_m_chain
    call fsck_problem
.slot_next:
    mov ebx, [jnl_slot]
    inc ebx
    call dkfs_progress                    ; (at boot: its bar, src/dkfscheck.asm)
    jmp .slot
.slots_done:
    call fat_fsck_lost                    ; in use by nothing
    or eax, eax
    jz .summary
    add [jnl_problems], eax
    mov esi, jnl_m_lost
    call jnl_puts
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
    call fat_total_kb
    push eax
    call fat_free_kb
    pop edx
    sub edx, eax
    mov eax, edx
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
jnl_no_stamp     db 0
jnl_count        dd 0
jnl_seq          dd 0
jnl_sum_want     dd 0
jnl_replayed     dd 0
jnl_commits      dd 0
jnl_idle_ms      dd 0
jnl_last_ms      dd 0
jnl_lbas         times JNL_MAX dd 0
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
jnl_m_dir        db "      <DIR>", 0
jnl_m_notime     db "                ", 0
jnl_m_ro         db "It's read-only (attrib -r <name> allows changes).", 13, 10, 0
jnl_m_attr_ro    db ": read-only", 13, 10, 0
jnl_m_attr_rw    db ": can be changed", 13, 10, 0
jnl_m_attr_use   db "Usage: attrib <name> [+r | -r]", 13, 10, 0
jnl_m_fsck_head  db "Checking the filesystem...", 13, 10, 0
jnl_m_chain      db "  its clusters don't add up (cut to what's there): ", 0
jnl_m_lost       db "  clusters in use by nothing (freed): ", 0
jnl_m_nofat      db "There's no FAT32 filesystem on this disk.", 13, 10, 0
jnl_m_sum1       db " files, ", 0
jnl_m_sum2       db " folders, ", 0
jnl_m_sum3       db " KB of data (FAT32).", 13, 10, 0
jnl_m_ok         db "No problems found.", 13, 10, 0
jnl_m_found      db " problem(s) - fsck fix puts them right.", 13, 10, 0
jnl_m_fixed      db " problem(s) put right.", 13, 10, 0
jnl_m_journal    db "Journal: on, ", 0
jnl_m_journal2   db " commits since boot.", 13, 10, 0
jnl_m_rep1       db "Journal: a write cut short was finished (", 0
jnl_m_rep2       db " sectors).", 13, 10, 0
