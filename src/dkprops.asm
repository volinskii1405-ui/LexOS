; dkprops.asm - a file's Properties, in a window of their own
;
; Files' "Properties" and a desktop icon's "Properties..." open it: the
; name (with its icon), what kind of thing it is, the folder it's in,
; its size (a folder: how many things are in it), when it last changed,
; and a Read-only box to tick (as `attrib +r`: rm, ren, mv, writing it -
; all refused). OK keeps the box's change, Cancel or Esc doesn't; space
; ticks it too.
;
; It's the name dialog's (src/dkname.asm) other face: dkn_open with
; dkn_op = DKN_PROPS - the same keys, the same clicks, carried out the
; same way: by the desktop's task, holding the kernel lock. First it
; reads what it shows (dkp_loaded 0), then, on OK, writes the box.
; Exports: dkp_ask (ecx = a slot)

DKN_PROPS      equ 8
DKP_W          equ 480
DKP_H          equ 292
DKP_X          equ (DESK_W - DKP_W) / 2
DKP_Y          equ 170
DKP_BTN_Y      equ DKP_Y + DKP_H - DKN_BTN_H - 12
DKP_OK_X       equ DKP_X + DKP_W - 2 * DKN_BTN_W - 24
DKP_CANCEL_X   equ DKP_X + DKP_W - DKN_BTN_W - 14
DKP_BOX_X      equ DKP_X + 20
DKP_BOX_Y      equ DKP_Y + 214
DKP_VAL_X      equ DKP_X + 136
DKP_VAL_MAX    equ (DKP_X + DKP_W - 16 - DKP_VAL_X) / 8

; ecx = the slot of what it's about
dkp_ask:
    pushad
    cmp byte [dkn_open], 0                ; (one dialog at a time)
    jne .done
    mov byte [dkn_op], DKN_PROPS
    mov [dkn_slot], ecx
    mov dword [dkn_err], 0
    mov byte [dkn_khead], 0
    mov byte [dkn_ktail], 0
    mov byte [dkp_loaded], 0
    mov byte [dkn_open], 1
    mov byte [dkn_req], 1                 ; (what it shows: read first)
    call dkn_mark
.done:
    popad
    ret

dkp_mark:
    pushad
    mov eax, DKP_X
    mov ebx, DKP_Y
    mov ecx, DKP_W + 4
    mov edx, DKP_H + 4
    call dk_mark
    popad
    ret

; al = a key, while it's open: Esc, Enter, space
dkp_key:
    cmp al, 27
    jne .not_esc
    call dkn_close
    ret
.not_esc:
    cmp al, 13
    jne .not_enter
    mov byte [dkn_req], 1
    ret
.not_enter:
    cmp al, ' '
    jne .done
    call dkp_toggle
.done:
    ret

dkp_toggle:
    cmp byte [dkp_loaded], 0
    je .done
    cmp byte [dkp_type], FS_TYPE_DIR      ; (folders: it's files that are
    je .done                              ;  read-only)
    xor byte [dkp_ro], 1
    mov dword [dkn_err], 0
    call dkp_mark
.done:
    ret

; ============================================================
; The kernel lock held (dkn_do): what's shown read, or the box written
; ============================================================
dkp_do:
    pushad
    cmp byte [dkp_loaded], 0
    jne .apply
    call dkp_load
    mov byte [dkp_loaded], 1
    call dkp_mark
    jmp .done
.apply:
    mov al, [dkp_ro]
    cmp al, [dkp_ro_was]
    je .close
    mov eax, [dkn_slot]
    cmp ax, [user_cfg_slot]
    jne .may
    mov dword [dkn_err], dkn_m_protected
    jmp .done
.may:
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_ATTR_OFFSET]
    mov ah, al
    and ah, 0xF0
    cmp ah, FS_ATTR_MAGIC
    je .valid
    xor al, al
.valid:
    or al, FS_ATTR_MAGIC | FS_ATTR_RO
    cmp byte [dkp_ro], 0
    jne .set
    and al, ~FS_ATTR_RO
.set:
    mov [SCRATCH_ADDR + FS_ATTR_OFFSET], al
    mov byte [jnl_no_stamp], 1            ; (its content didn't change)
    mov eax, [dkn_slot]
    call fs_write_slot
    mov byte [jnl_no_stamp], 0
    mov byte [dk_fm_refresh], 1
    call snd_click
.close:
    call dkn_close
.done:
    popad
    ret

; dkn_slot -> dkp_name, dkp_type, dkp_icon, dkp_kind, dkp_where,
; dkp_size_text, dkp_time_text, dkp_ro
dkp_load:
    pushad
    mov eax, [dkn_slot]
    call fs_read_slot
    mov esi, SCRATCH_ADDR                 ; the name
    mov edi, dkp_name
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [dkp_name + FS_NAME_LEN], 0
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    mov [dkp_type], al
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    mov [dkp_parent], al
    mov al, [SCRATCH_ADDR + FS_ATTR_OFFSET]   ; read-only?
    mov ah, al
    and ah, 0xF0
    xor ecx, ecx
    cmp ah, FS_ATTR_MAGIC
    jne .ro
    and al, FS_ATTR_RO
    mov cl, al
.ro:
    mov [dkp_ro], cl
    mov [dkp_ro_was], cl
    call dkp_time                         ; (SCRATCH_ADDR's time)
    ; its size: a file's bytes, a program's, or a folder's contents
    mov edi, dkp_size_text
    cmp byte [dkp_type], FS_TYPE_DIR
    je .folder_size
    movzx eax, byte [SCRATCH_ADDR + FS_CONTENT_OFFSET]
    cmp byte [dkp_type], FS_TYPE_PROGRAM
    je .bytes
    call fs_get_size
.bytes:
    push eax
    call wget_append_num
    mov esi, dkp_m_bytes
    call wget_append
    pop eax
    cmp eax, 1024                         ; (and in KB, if it's that big)
    jb .sized
    mov esi, dkp_m_open
    call wget_append
    add eax, 1023
    shr eax, 10
    call wget_append_num
    mov esi, dkp_m_kb
    call wget_append
    jmp .sized
.folder_size:
    xor ebx, ebx                          ; what's in it
    xor edx, edx
    mov ecx, [dkn_slot]
.count:
    cmp ebx, FS_TOTAL_SLOTS
    jae .counted
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .count_next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], cl
    jne .count_next
    inc edx
.count_next:
    inc ebx
    jmp .count
.counted:
    mov eax, edx
    call wget_append_num
    mov esi, dkp_m_items
    call wget_append
.sized:
    mov byte [edi], 0
    ; its kind, and its icon
    mov esi, dkp_name
    call dk_name_kind                     ; -> al (src/dkwins.asm)
    movzx eax, al
    mov [dkp_icon], eax
    mov dword [dkp_kind], dkp_k_folder
    cmp byte [dkp_type], FS_TYPE_DIR
    jne .not_dir
    mov dword [dkp_icon], IC_FOLDER
    jmp .kinded
.not_dir:
    mov dword [dkp_kind], dkp_k_program
    cmp byte [dkp_type], FS_TYPE_PROGRAM
    jne .by_ext
    mov dword [dkp_icon], IC_APP
    jmp .kinded
.by_ext:
    mov dword [dkp_kind], dkp_k_text      ; (no extension: README, LICENSE)
    mov esi, dkp_name
    call dk_ext_dword                     ; -> eax
    or eax, eax
    jz .kinded
    mov dword [dkp_kind], dkp_k_file
    mov esi, dkp_kinds
    call dk_ext_lookup
    jc .kinded
    mov [dkp_kind], eax
.kinded:
    ; the folder it's in
    mov al, [dkp_parent]
    mov edi, dkp_where
    call dkp_path
    popad
    ret

; al = a folder's slot byte, edi = 128 bytes -> "/A/B/C" ("/": the root)
dkp_path:
    pushad
    mov byte [edi], '/'
    mov byte [edi + 1], 0
    xor ecx, ecx                          ; the folders on the way up
.up:
    cmp al, FS_ROOT_BYTE
    je .climbed
    cmp ecx, 7
    jae .climbed
    movzx eax, al
    mov [dkp_up + ecx*4], eax
    inc ecx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .climbed
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    jmp .up
.climbed:
    mov ebx, edi                          ; (where the text is)
.down:
    or ecx, ecx
    jz .done
    dec ecx
    mov eax, [dkp_up + ecx*4]
    call fs_read_slot
    mov edi, ebx
    xor al, al
    push ecx
    mov ecx, 128
    repne scasb
    pop ecx
    dec edi
    cmp byte [edi - 1], '/'
    je .name
    mov byte [edi], '/'
    inc edi
.name:
    mov esi, SCRATCH_ADDR
    push ecx
    mov ecx, FS_NAME_LEN
.char:
    lodsb
    or al, al
    jz .named
    stosb
    loop .char
.named:
    mov byte [edi], 0
    pop ecx
    jmp .down
.done:
    popad
    ret

; SCRATCH_ADDR's time -> dkp_time_text: "DD.MM.20YY HH:MM" (the hour in
; the user's time zone), or "-"
dkp_time:
    pushad
    mov edi, dkp_time_text
    cmp byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 1], 0
    jne .have
    mov word [edi], '-'
    jmp .done
.have:
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 2]
    call dkp_dec2
    mov al, '.'
    stosb
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 1]
    call dkp_dec2
    mov ax, '.2'
    stosw
    mov al, '0'
    stosb
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET]
    call dkp_dec2
    mov al, ' '
    stosb
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
    call dkp_dec2
    mov al, ':'
    stosb
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 4]
    call dkp_dec2
    mov byte [edi], 0
.done:
    popad
    ret

; al (0..99) -> two digits at edi
dkp_dec2:
    push eax
    push ecx
    movzx eax, al
    mov cl, 10
    div cl
    add ax, '00'
    stosw
    pop ecx
    pop eax
    ret

; ============================================================
; On the screen
; ============================================================
dkp_draw:
    pushad
    mov eax, DKP_X + 4                    ; a shadow, the frame, the face
    mov ebx, DKP_Y + 4
    mov ecx, DKP_W
    mov edx, DKP_H
    mov esi, 0x08101C
    call dk_fill
    mov eax, DKP_X
    mov ebx, DKP_Y
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_MENU
    call dk_fill
    mov edx, 26                           ; its title bar
    mov esi, COL_TITLE_ON
    call dk_fill
    mov esi, dkp_t_title
    mov eax, DKP_X + 10
    mov ebx, DKP_Y + 6
    mov edx, COL_WHITE
    call dk_text
    cmp byte [dkp_loaded], 0
    jne .loaded
    mov esi, dkp_m_reading
    mov eax, DKP_X + 20
    mov ebx, DKP_Y + 50
    mov edx, COL_TEXT
    call dk_text
    jmp .buttons
.loaded:
    mov dword [dk_icon_fill], dk_fill     ; its icon, its name
    mov eax, DKP_X + 20
    mov ebx, DKP_Y + 40
    mov ecx, [dkp_icon]
    call dk_icon
    mov esi, dkp_name
    mov eax, DKP_X + 66
    mov ebx, DKP_Y + 48
    mov edx, COL_TEXT
    call dk_text_raw_all
    mov eax, DKP_X + 16                   ; a line under
    mov ebx, DKP_Y + 84
    mov ecx, DKP_W - 32
    mov edx, 1
    mov esi, COL_FRAME
    call dk_fill
    xor ecx, ecx                          ; the rows: label, value
.row:
    cmp ecx, 4
    jae .rows_done
    imul ebx, ecx, 26
    add ebx, DKP_Y + 98
    mov esi, [dkp_labels + ecx*4]
    mov eax, DKP_X + 20
    mov edx, COL_MUTED
    call dk_text
    mov esi, [dkp_values + ecx*4]
    cmp ecx, 1                            ; (the kind: a word to translate;
    jne .raw                              ;  the rest: as they are)
    mov esi, [dkp_kind]
    mov eax, DKP_VAL_X
    mov edx, COL_TEXT
    call dk_text
    jmp .row_next
.raw:
    mov eax, DKP_VAL_X
    mov edx, COL_TEXT
    push edi
    mov edi, DKP_VAL_MAX
    call dk_text_raw
    pop edi
.row_next:
    inc ecx
    jmp .row
.rows_done:
    mov eax, DKP_X + 16
    mov ebx, DKP_Y + 202
    mov ecx, DKP_W - 32
    mov edx, 1
    mov esi, COL_FRAME
    call dk_fill
    cmp byte [dkp_type], FS_TYPE_DIR      ; the box (not for a folder)
    je .error
    mov eax, DKP_BOX_X
    mov ebx, DKP_BOX_Y
    mov ecx, 16
    mov edx, 16
    mov esi, COL_TITLE_ON
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_WHITE
    call dk_fill
    cmp byte [dkp_ro], 0
    je .unticked
    add eax, 3                            ; ticked: a mark in it
    add ebx, 3
    mov ecx, 8
    mov edx, 8
    mov esi, COL_TITLE_ON
    call dk_fill
.unticked:
    mov esi, dkp_l_ro
    mov eax, DKP_BOX_X + 26
    mov ebx, DKP_BOX_Y
    mov edx, COL_TEXT
    call dk_text
    mov esi, dkp_m_ro_hint
    mov eax, DKP_BOX_X + 26
    mov ebx, DKP_BOX_Y + 20
    mov edx, COL_MUTED
    call dk_text
.error:
    mov esi, [dkn_err]
    or esi, esi
    jz .buttons
    mov eax, DKP_X + 20
    mov ebx, DKP_BTN_Y + 4
    mov edx, 0xE04848
    call dk_text
.buttons:
    mov eax, DKP_OK_X
    mov ebx, DKP_BTN_Y
    mov esi, dkn_l_ok
    call dkn_button_at
    mov eax, DKP_CANCEL_X
    mov esi, dkn_l_cancel
    call dkn_button_at
    popad
    ret

; A left press at eax, ebx while it's open (every click is its)
dkp_click:
    pushad
    cmp ebx, DKP_BTN_Y
    jl .not_buttons
    cmp ebx, DKP_BTN_Y + DKN_BTN_H
    jge .done
    cmp eax, DKP_OK_X
    jl .done
    cmp eax, DKP_OK_X + DKN_BTN_W
    jge .not_ok
    mov byte [dkn_req], 1
    jmp .done
.not_ok:
    cmp eax, DKP_CANCEL_X
    jl .done
    cmp eax, DKP_CANCEL_X + DKN_BTN_W
    jge .done
    call dkn_close
    jmp .done
.not_buttons:
    cmp ebx, DKP_BOX_Y - 2                ; the box, or its words
    jl .done
    cmp ebx, DKP_BOX_Y + 18
    jge .done
    cmp eax, DKP_BOX_X - 2
    jl .done
    cmp eax, DKP_BOX_X + 26 + 12 * 8
    jge .done
    call dkp_toggle
.done:
    popad
    ret

; ============================================================
; Data (shared)
; ============================================================
dkp_loaded       db 0
dkp_type         db 0
dkp_parent       db 0
dkp_ro           db 0
dkp_ro_was       db 0
dkp_icon         dd 0
dkp_kind         dd 0
dkp_up           times 8 dd 0
dkp_name         times FS_NAME_LEN + 1 db 0
dkp_where        times 128 db 0
dkp_size_text    times 64 db 0
dkp_time_text    times 24 db 0
dkp_labels       dd dkp_l_where, dkp_l_kind, dkp_l_size, dkp_l_time
dkp_values       dd dkp_where, 0, dkp_size_text, dkp_time_text
; extensions -> what they are
dkp_kinds        dd 'TXT', dkp_k_text, 'CFG', dkp_k_text, 'HG', dkp_k_script
                 dd 'BAS', dkp_k_basic, 'TRG', dkp_k_script, 'C', dkp_k_c
                 dd 'H', dkp_k_c, 'ASM', dkp_k_asm, 'APP', dkp_k_app
                 dd 'COM', dkp_k_program, 'BIN', dkp_k_program, 'CH8', dkp_k_chip8
                 dd 'BMP', dkp_k_bmp, 'WAV', dkp_k_sound, 'IMF', dkp_k_sound
                 dd 'MOD', dkp_k_music, 'LNK', dkp_k_link, 'HTM', dkp_k_html
                 dd 'MD', dkp_k_md, 'ZIP', dkp_k_zip, 'DAT', dkp_k_data, 0, 0
dkp_t_title      db "Properties", 0
dkp_l_where      db "Location:", 0
dkp_l_kind       db "Kind:", 0
dkp_l_size       db "Size:", 0
dkp_l_time       db "Modified:", 0
dkp_l_ro         db "Read-only", 0
dkp_m_ro_hint    db "(can't be changed, renamed or deleted)", 0
dkp_m_reading    db "Reading...", 0
dkp_m_bytes      db " bytes", 0
dkp_m_open       db " (", 0
dkp_m_kb         db " KB)", 0
dkp_m_items      db " items", 0
dkp_k_folder     db "Folder", 0
dkp_k_program    db "Program", 0
dkp_k_text       db "Text file", 0
dkp_k_file       db "File", 0
dkp_k_script     db "Script (HG)", 0
dkp_k_basic      db "BASIC program", 0
dkp_k_c          db "C source", 0
dkp_k_asm        db "Assembly source", 0
dkp_k_app        db "Application (.APP)", 0
dkp_k_chip8      db "CHIP-8 game", 0
dkp_k_bmp        db "Picture (BMP)", 0
dkp_k_sound      db "Sound", 0
dkp_k_music      db "Music (MOD)", 0
dkp_k_link       db "Shortcut", 0
dkp_k_html       db "Web page", 0
dkp_k_md         db "Markdown text", 0
dkp_k_zip        db "ZIP archive", 0
dkp_k_data       db "Data", 0
