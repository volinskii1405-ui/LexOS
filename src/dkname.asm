; dkname.asm - making and changing files with the mouse, no Terminal
;
; A right click - on the desktop, or on Files' empty space - has
; "Create >": hovered (or clicked), a submenu opens beside it: Create a
; folder, Create a TXT, Create a HG (a script), Create a Link (a .LNK
; shortcut). Each asks for a name in a small dialog: a text box, OK and
; Cancel (Enter, Esc). Files' Rename... and Copy to... ask the same way,
; and so do a desktop icon's own menu: Open, Rename..., Delete (into
; TRASH).
;
; The dialog's OK is carried out by the desktop's task between frames,
; holding the kernel lock (as Files' paste does), through the
; filesystem's own functions - whatever they'd print goes nowhere
; (src/pipe.asm), and what went wrong is said in the dialog instead.
; Exports: dkn_ask, dkn_key_in, dkn_work, dkn_draw, dkn_click,
;          dk_sub_hover_work, dk_draw_sub, dk_sub_at

DKN_W          equ 460
DKN_H          equ 136
DKN_X          equ (DESK_W - DKN_W) / 2
DKN_Y          equ 250
DKN_MAX        equ 63                     ; what can be typed
DKN_BTN_W      equ 88
DKN_BTN_H      equ 24
DKN_OK_X       equ DKN_X + DKN_W - 2 * DKN_BTN_W - 24
DKN_CANCEL_X   equ DKN_X + DKN_W - DKN_BTN_W - 14
DKN_BTN_Y      equ DKN_Y + DKN_H - DKN_BTN_H - 12
DK_SUB_W       equ 176
DK_SUB_N       equ 4

DKN_RENAME     equ 1                      ; what the dialog is for
DKN_NEWDIR     equ 2
DKN_NEWTXT     equ 3
DKN_NEWHG      equ 4
DKN_NEWLNK     equ 5
DKN_COPYTO     equ 6
DKN_TRASH      equ 7                      ; (no dialog: done straight away)

; al = DKN_*, bl = the folder (a slot byte), ecx = the slot it's about
; (Rename, Copy to), esi = the text it starts with (0: none)
dkn_ask:
    pushad
    mov [dkn_op], al
    mov [dkn_dir], bl
    mov [dkn_slot], ecx
    mov dword [dkn_err], 0
    mov byte [dkn_khead], 0
    mov byte [dkn_ktail], 0
    xor ecx, ecx
    or esi, esi
    jz .typed
.copy:
    mov al, [esi + ecx]
    or al, al
    jz .typed
    cmp ecx, DKN_MAX
    jae .typed
    mov [dkn_text + ecx], al
    inc ecx
    jmp .copy
.typed:
    mov byte [dkn_text + ecx], 0
    mov [dkn_len], ecx
    mov byte [dkn_fresh], 1               ; (all of it chosen: typing replaces
    cmp byte [dkn_op], DKN_NEWLNK         ;  it - a shortcut's "/APPS/" is
    jne .fresh                            ;  to be added to)
    mov byte [dkn_fresh], 0
.fresh:
    mov byte [dkn_open], 1
    call dkn_mark
.done:
    popad
    ret

; The keyboard's interrupt, while the dialog's open: ax = the key
dkn_key_in:
    push ebx
    movzx ebx, byte [dkn_khead]
    mov [dkn_keys + ebx*2], ax
    inc bl
    and bl, 15
    cmp bl, [dkn_ktail]
    je .full
    mov [dkn_khead], bl
.full:
    pop ebx
    ret

dkn_mark:
    cmp byte [dkn_op], DKN_PROPS          ; (Properties: its own size)
    je dkp_mark
    pushad
    mov eax, DKN_X
    mov ebx, DKN_Y
    mov ecx, DKN_W + 4
    mov edx, DKN_H + 4
    call dk_mark
    popad
    ret

; Each frame: what's typed, and an OK to carry out
dkn_work:
    pushad
    cmp byte [dkn_open], 0
    je .keys_done
.key:
    movzx ebx, byte [dkn_ktail]
    cmp bl, [dkn_khead]
    je .keys_done
    mov ax, [dkn_keys + ebx*2]
    inc bl
    and bl, 15
    mov [dkn_ktail], bl
    cmp byte [dkn_op], DKN_PROPS          ; (Properties: src/dkprops.asm)
    jne .typing
    call dkp_key
    jmp .key
.typing:
    mov ecx, [dkn_len]
    cmp al, 27
    je .cancel
    cmp al, 13
    je .ok
    cmp al, 8
    je .back
    cmp al, ' '
    jb .key
    cmp al, 127
    jae .key
    cmp al, 'a'                           ; (names are capitals)
    jb .char
    cmp al, 'z'
    ja .char
    sub al, 32
.char:
    cmp byte [dkn_fresh], 0               ; (the text it started with: gone)
    je .not_fresh
    mov byte [dkn_fresh], 0
    xor ecx, ecx
    mov [dkn_len], ecx
.not_fresh:
    cmp ecx, DKN_MAX
    jae .key
    mov [dkn_text + ecx], al
    mov byte [dkn_text + ecx + 1], 0
    inc dword [dkn_len]
    mov dword [dkn_err], 0
    call dkn_mark
    jmp .key
.back:
    cmp byte [dkn_fresh], 0               ; (all chosen: all gone)
    je .back_one
    mov byte [dkn_fresh], 0
    mov ecx, 1
.back_one:
    or ecx, ecx
    jz .key
    dec ecx
    cmp byte [dkn_len], 0                 ; (fresh: to nothing)
    je .key
    mov [dkn_len], ecx
    mov byte [dkn_text + ecx], 0
    mov dword [dkn_err], 0
    call dkn_mark
    jmp .key
.ok:
    mov byte [dkn_req], 1
    jmp .key
.cancel:
    call dkn_close
    jmp .done
.keys_done:
    cmp byte [dkn_req], 0
    je .done
    pushfd                                ; OK: with the kernel lock
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    mov byte [dkn_req], 0
    call dkn_do
    call jnl_commit                       ; (written, as one)
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

dkn_close:
    call dkn_mark
    mov byte [dkn_open], 0
    mov byte [dkn_req], 0
    ret

; ============================================================
; Carrying it out (the kernel lock held): done -> the dialog closes; or
; dkn_err says why not
; ============================================================
dkn_do:
    pushad
    push word [fs_current_dir]
    push dword [fs_tmp_slot]
    movzx ebx, byte [console_self]        ; (their messages: nowhere)
    mov al, [pipe_on + ebx]
    push eax
    mov byte [pipe_on + ebx], 2
    movzx eax, byte [dkn_dir]             ; the folder: the current one
    cmp al, FS_ROOT_BYTE
    jne .dir
    mov eax, FS_ROOT
.dir:
    mov [fs_current_dir], ax
    mov dword [dkn_err], 0
    movzx eax, byte [dkn_op]
    cmp eax, DKN_PROPS                    ; (src/dkprops.asm)
    jne .not_props
    call dkp_do
    jmp .out
.not_props:
    cmp eax, DKN_TRASH
    je .trash
    cmp dword [dkn_len], 0
    je .empty
    cmp eax, DKN_NEWLNK
    je .link
    cmp eax, DKN_COPYTO
    je .copy_to
    call dkn_name                         ; the name -> fs_tmp_name
    jc .out
    movzx eax, byte [dkn_op]
    cmp eax, DKN_NEWTXT                   ; (no extension: its own)
    jne .not_txt
    mov esi, dkn_ext_txt
    call dkn_add_ext
.not_txt:
    cmp eax, DKN_NEWHG
    jne .not_hg
    mov esi, dkn_ext_hg
    call dkn_add_ext
.not_hg:
    mov si, fs_tmp_name                   ; taken here?
    call fs_find_by_name
    cmp ax, -1
    je .free
    movzx ecx, ax
    cmp byte [dkn_op], DKN_RENAME         ; (renamed to itself: fine)
    jne .taken
    cmp ecx, [dkn_slot]
    jne .taken
.free:
    movzx eax, byte [dkn_op]
    cmp eax, DKN_RENAME
    je .rename
    cmp eax, DKN_NEWDIR
    je .newdir
    ; a new file: empty (TXT) or a script to start from (HG)
    xor ecx, ecx
    mov esi, dkn_empty
    cmp byte [dkn_op], DKN_NEWHG
    jne .content
    mov esi, dkn_hg_template
    mov ecx, dkn_hg_template_len
.content:
    call dkn_write_file
    jc .full
    jmp .made

.rename:
    mov eax, [dkn_slot]
    cmp ax, [user_cfg_slot]
    je .protected
    call jnl_attr_of
    test al, FS_ATTR_RO
    jnz .read_only
    mov eax, [dkn_slot]
    call fs_read_slot
    mov edi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
    xor eax, eax
    cld
    rep stosb
    mov esi, fs_tmp_name
    mov edi, SCRATCH_ADDR
    call dki_copy
    mov eax, [dkn_slot]
    call fs_write_slot
    jmp .made

.newdir:
    call fs_find_free_dir
    cmp ax, -1
    je .full
    push eax
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    mov esi, fs_tmp_name
    mov edi, SCRATCH_ADDR
    call dki_copy
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    mov al, [dkn_dir]
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], al
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    pop eax
    call fs_write_slot
    jmp .made

.link:
    ; the text: what it opens ("/APPS/FIRE.APP") - it has to be there
    mov esi, dkn_text
    cmp byte [esi], '/'
    je .absolute
    mov edi, dkn_path                     ; (no "/": from the root)
    mov byte [edi], '/'
    inc edi
    call dki_copy
    mov esi, dkn_path
    mov edi, dkn_text
    call dki_copy
    inc dword [dkn_len]
.absolute:
    mov esi, dkn_text
    call dki_resolve                      ; -> eax
    cmp eax, -1
    je .nothing_there
    mov esi, dkn_text                     ; its name: the last part's, up to
    mov edx, esi                          ; its "." (11 at most) + ".LNK"
.last:
    lodsb
    or al, al
    jz .have_last
    cmp al, '/'
    jne .last
    mov edx, esi
    jmp .last
.have_last:
    mov esi, edx
    mov edi, fs_tmp_name
    mov ecx, 11
.base:
    lodsb
    or al, al
    jz .based
    cmp al, '.'
    je .based
    stosb
    loop .base
.based:
    mov dword [edi], '.LNK'
    mov byte [edi + 4], 0
    cmp edi, fs_tmp_name
    je .empty
    mov esi, fs_tmp_name
    call dkx_fc_free_name                 ; (taken: _2, _3...)
    jc .taken
    mov esi, dkn_text                     ; its text: the path, a line
    mov edi, dkn_path
    call dki_copy
    mov word [edi - 1], 10
    mov esi, dkn_path
    mov ecx, [dkn_len]
    inc ecx
    call dkn_write_file
    jc .full
    jmp .made

.copy_to:
    ; the text: a folder ("/DEMOS", "/" the root) - a copy of the file there
    mov eax, [dkn_slot]
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .files_only
    mov esi, SCRATCH_ADDR                 ; its name, kept
    mov edi, dkn_path
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [dkn_path + FS_NAME_LEN - 1], 0
    mov esi, dkn_text
.slashes:
    cmp byte [esi], '/'
    jne .not_root
    inc esi
    jmp .slashes
.not_root:
    mov eax, FS_ROOT                      ; "/": the root
    cmp byte [esi], 0
    je .dest
    mov esi, dkn_text
    call dki_resolve                      ; -> eax
    cmp eax, -1
    je .nothing_there
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .not_a_folder
.dest:
    push eax
    mov eax, [dkn_slot]                   ; its content (the picture buffer:
    mov edi, DESK_IMG_FILE                ;  free between frames)
    mov ecx, DK_SHOT_SIZE
    call fs_load_to
    mov [dkn_size], ecx
    pop eax
    mov [fs_current_dir], ax
    mov esi, dkn_path
    call dkx_fc_free_name                 ; -> fs_tmp_name
    jc .taken
    mov esi, DESK_IMG_FILE
    mov ecx, [dkn_size]
    call dkn_write_file
    jc .full
    jmp .made

.trash:
    mov eax, [dkn_slot]                   ; a desktop icon's file: into TRASH
    cmp ax, [user_cfg_slot]
    je .protected
    call jnl_attr_of
    test al, FS_ATTR_RO
    jnz .read_only
    call dkn_trash_dir                    ; -> al (carry: no room)
    jc .full
    mov dl, al
    mov eax, [dkn_slot]
    call fs_read_slot
    call dkt_note_origin                  ; (src/dktrash.asm: Restore's)
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    call fs_write_slot
    jmp .made

.empty:
    mov dword [dkn_err], dkn_m_empty
    jmp .out
.taken:
    mov dword [dkn_err], dkn_m_taken
    jmp .out
.full:
    mov dword [dkn_err], dkn_m_full
    jmp .out
.protected:
    mov dword [dkn_err], dkn_m_protected
    jmp .out
.read_only:
    mov dword [dkn_err], dkn_m_read_only
    jmp .out
.nothing_there:
    mov dword [dkn_err], dkn_m_nothing
    jmp .out
.not_a_folder:
    mov dword [dkn_err], dkn_m_not_folder
    jmp .out
.files_only:
    mov dword [dkn_err], dkn_m_files_only
    jmp .out
.made:
    mov byte [dk_fm_refresh], 1           ; Files and the icons: again
    mov byte [dki_rescan], 1
    mov byte [dk_redraw_all], 1
    call snd_click
    cmp byte [dkn_op], DKN_TRASH
    je .out
    call dkn_close
.out:
    cmp dword [dkn_err], 0                ; (said in the dialog, or - a
    je .said                              ;  desktop icon's Delete - as a
    cmp byte [dkn_open], 0                ;  toast)
    jne .said_box
    mov esi, [dkn_err]
    call tr_lookup
    mov edi, dk_toast_buf
    call dki_copy
    call dk_toast
    jmp .said
.said_box:
    call dkn_mark
    mov eax, SND_ERROR
    call snd_play
.said:
    pop eax
    movzx ebx, byte [console_self]
    mov [pipe_on + ebx], al
    pop dword [fs_tmp_slot]
    pop word [fs_current_dir]
    popad
    ret

; dkn_text -> fs_tmp_name, if it's a name that can be (15 characters,
; none of / \ | < > * ? " : or a space); carry=1 (dkn_err) if not
dkn_name:
    push eax
    push ecx
    push esi
    mov ecx, [dkn_len]
    cmp ecx, FS_NAME_LEN - 1
    ja .long
    xor ecx, ecx
.char:
    mov al, [dkn_text + ecx]
    or al, al
    jz .good
    mov esi, dkn_bad_chars
.bad:
    cmp byte [esi], 0
    je .ok_char
    cmp al, [esi]
    je .invalid
    inc esi
    jmp .bad
.ok_char:
    mov [fs_tmp_name + ecx], al
    inc ecx
    jmp .char
.good:
    mov byte [fs_tmp_name + ecx], 0
    pop esi
    pop ecx
    pop eax
    clc
    ret
.long:
    mov dword [dkn_err], dkn_m_long
    jmp .fail
.invalid:
    mov dword [dkn_err], dkn_m_invalid
.fail:
    pop esi
    pop ecx
    pop eax
    stc
    ret

; fs_tmp_name without a "." gets esi (".TXT"), if it fits
dkn_add_ext:
    pushad
    mov edi, fs_tmp_name
    xor ecx, ecx
.scan:
    mov al, [edi + ecx]
    or al, al
    jz .none
    cmp al, '.'
    je .done
    inc ecx
    jmp .scan
.none:
    cmp ecx, FS_NAME_LEN - 5
    ja .done
    add edi, ecx
    call dki_copy
.done:
    popad
    ret

; A new file fs_tmp_name in fs_current_dir: esi = its content, ecx long.
; carry=1 if it couldn't be made.
dkn_write_file:
    pushad
    mov [fs_stream_size], ecx
    push esi
    call fs_stream_prepare
    pop esi
    jc .fail
    mov [fh_src_ptr], esi
    mov dword [fs_stream_source], fh_stream_byte
    call fs_stream_write
    jc .fail
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; The root's TRASH folder (made if there's none) -> al; carry=1 no room
dkn_trash_dir:
    push ebx
    push ecx
    push edi
    xor ebx, ebx
.slot:
    cmp ebx, FS_FILE_COUNT
    jae .make
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .next
    cmp byte [SCRATCH_ADDR + FS_PARENT_OFFSET], FS_ROOT_BYTE
    jne .next
    cmp dword [SCRATCH_ADDR], 'TRAS'
    jne .next
    cmp word [SCRATCH_ADDR + 4], 'H'
    jne .next
    mov eax, ebx
    jmp .found
.next:
    inc ebx
    jmp .slot
.make:
    call fs_find_free_dir
    cmp ax, -1
    je .none
    movzx ebx, ax
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    mov dword [SCRATCH_ADDR], 'TRAS'
    mov byte [SCRATCH_ADDR + 4], 'H'
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    mov byte [SCRATCH_ADDR + FS_PARENT_OFFSET], FS_ROOT_BYTE
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov eax, ebx
    call fs_write_slot
    mov eax, ebx
.found:
    pop edi
    pop ecx
    pop ebx
    clc
    ret
.none:
    pop edi
    pop ecx
    pop ebx
    stc
    ret

; ============================================================
; The dialog on the screen
; ============================================================
dkn_draw:
    pushad
    cmp byte [dkn_open], 0
    je .done
    cmp byte [dkn_op], DKN_PROPS
    jne .name_box
    call dkp_draw
    jmp .done
.name_box:
    mov eax, DKN_X + 4                    ; a shadow, the frame, the face
    mov ebx, DKN_Y + 4
    mov ecx, DKN_W
    mov edx, DKN_H
    mov esi, 0x08101C
    call dk_fill
    mov eax, DKN_X
    mov ebx, DKN_Y
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
    movzx ecx, byte [dkn_op]
    mov esi, [dkn_titles + ecx*4 - 4]
    mov eax, DKN_X + 10
    mov ebx, DKN_Y + 6
    mov edx, COL_WHITE
    call dk_text
    movzx ecx, byte [dkn_op]              ; what to type
    mov esi, [dkn_prompts + ecx*4 - 4]
    mov eax, DKN_X + 14
    mov ebx, DKN_Y + 36
    mov edx, COL_TEXT
    call dk_text
    mov eax, DKN_X + 14                   ; the box
    mov ebx, DKN_Y + 58
    mov ecx, DKN_W - 28
    mov edx, 24
    mov esi, COL_TITLE_ON
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_WHITE
    call dk_fill
    mov esi, dkn_text                     ; the text (its end, if long)
    mov ecx, [dkn_len]
    sub ecx, (DKN_W - 50) / 8
    jle .whole
    add esi, ecx
.whole:
    mov eax, DKN_X + 22
    mov ebx, DKN_Y + 62
    mov edx, COL_BLACK
    cmp byte [dkn_fresh], 0               ; chosen: white on the title's color
    je .unchosen
    push esi
    call dki_strlen
    shl ecx, 3
    mov edx, 16
    mov esi, COL_TITLE_ON
    call dk_fill
    pop esi
    mov edx, COL_WHITE
.unchosen:
    push esi
    mov edi, 1000
    call dk_text_raw
    pop esi
    call dki_strlen                       ; -> ecx (esi's length)
    shl ecx, 3
    lea eax, [DKN_X + 22 + ecx]
    mov ebx, DKN_Y + 61
    mov ecx, 2
    mov edx, 18
    mov esi, COL_TITLE_ON
    call dk_fill
    mov esi, [dkn_err]                    ; what went wrong
    or esi, esi
    jz .buttons
    mov eax, DKN_X + 14
    mov ebx, DKN_Y + DKN_H - 32
    mov edx, 0xE04848
    call dk_text
.buttons:
    mov eax, DKN_OK_X
    mov esi, dkn_l_ok
    call dkn_button
    mov eax, DKN_CANCEL_X
    mov esi, dkn_l_cancel
    call dkn_button
.done:
    popad
    ret

; eax = its x, esi = its words
dkn_button:
    mov ebx, DKN_BTN_Y
; the same at ebx
dkn_button_at:
    pushad
    mov ecx, DKN_BTN_W
    mov edx, DKN_BTN_H
    push esi
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_BUTTON
    call dk_fill
    pop esi
    call tr_lookup
    push eax
    call dki_strlen                       ; centered
    shl ecx, 3
    pop eax
    add eax, (DKN_BTN_W - 2) / 2
    shr ecx, 1
    sub eax, ecx
    add ebx, 3
    mov edx, COL_TEXT
    mov edi, 1000
    call dk_text_raw
    popad
    ret

; A left press at eax, ebx while it's open: carry=0 (it's the dialog's -
; every click is, while it's there)
dkn_click:
    cmp byte [dkn_open], 0
    jne .open
    stc
    ret
.open:
    pushad
    cmp byte [dkn_op], DKN_PROPS
    jne .name_box
    call dkp_click
    jmp .done
.name_box:
    cmp ebx, DKN_BTN_Y
    jl .done
    cmp ebx, DKN_BTN_Y + DKN_BTN_H
    jge .done
    cmp eax, DKN_OK_X
    jl .done
    cmp eax, DKN_OK_X + DKN_BTN_W
    jge .not_ok
    mov byte [dkn_req], 1
    jmp .done
.not_ok:
    cmp eax, DKN_CANCEL_X
    jl .done
    cmp eax, DKN_CANCEL_X + DKN_BTN_W
    jge .done
    call dkn_close
.done:
    popad
    clc
    ret

; ============================================================
; The "Create >" submenu, beside the context menu (src/dkwins.asm)
; ============================================================

; Each frame: the pointer over the context menu - its item lit, and
; Create's submenu opened or closed
dk_sub_hover_work:
    pushad
    cmp byte [dk_ctx_open], 0
    je .done
    mov eax, [dk_mx]
    mov ebx, [dk_my]
    call dk_sub_at                        ; over the submenu?
    cmp ecx, -1
    je .not_sub
    cmp ecx, [dk_sub_hover]
    je .done
    mov [dk_sub_hover], ecx
    call dk_mark_ctx
    jmp .done
.not_sub:
    mov ecx, -1                           ; over the menu: which item
    sub eax, [dk_ctx_x]
    js .have
    cmp eax, DK_CTX_W
    jae .have
    mov eax, ebx
    sub eax, [dk_ctx_y]
    js .have
    xor edx, edx
    mov esi, DK_CTX_ITEM
    div esi
    cmp eax, [dk_ctx_n]
    jae .have
    mov ecx, eax
.have:
    cmp ecx, -1                           ; (off both: as it was)
    je .done
    cmp ecx, [dk_ctx_hover]
    je .done
    call dk_mark_ctx
    mov [dk_ctx_hover], ecx
    mov dword [dk_sub_hover], -1
    mov byte [dk_sub_open], 0
    movzx eax, byte [dk_ctx_ids + ecx]
    cmp eax, DKC_CREATE
    jne .marked
    call dk_sub_place
.marked:
    call dk_mark_ctx
.done:
    popad
    ret

; The submenu opened beside item dk_ctx_hover
dk_sub_place:
    pushad
    mov eax, [dk_ctx_x]
    add eax, DK_CTX_W - 2
    cmp eax, DESK_W - DK_SUB_W
    jle .x_ok
    mov eax, [dk_ctx_x]
    sub eax, DK_SUB_W - 2
.x_ok:
    mov [dk_sub_x], eax
    mov eax, [dk_ctx_hover]
    imul eax, DK_CTX_ITEM
    add eax, [dk_ctx_y]
    mov ecx, DESK_H - DK_TASKBAR_H - DK_SUB_N * DK_CTX_ITEM
    cmp eax, ecx
    jle .y_ok
    mov eax, ecx
.y_ok:
    mov [dk_sub_y], eax
    mov byte [dk_sub_open], 1
    mov dword [dk_sub_hover], -1
    popad
    ret

; eax, ebx -> ecx = the submenu's item there, or -1
dk_sub_at:
    mov ecx, -1
    cmp byte [dk_sub_open], 0
    je .done
    cmp byte [dk_ctx_open], 0
    je .done
    push eax
    push edx
    sub eax, [dk_sub_x]
    js .out
    cmp eax, DK_SUB_W
    jae .out
    mov eax, ebx
    sub eax, [dk_sub_y]
    js .out
    xor edx, edx
    push ecx
    mov ecx, DK_CTX_ITEM
    div ecx
    pop ecx
    cmp eax, DK_SUB_N
    jae .out
    mov ecx, eax
.out:
    pop edx
    pop eax
.done:
    ret

dk_draw_sub:
    pushad
    cmp byte [dk_ctx_open], 0
    je .done
    cmp byte [dk_sub_open], 0
    je .done
    mov eax, [dk_sub_x]
    mov ebx, [dk_sub_y]
    mov ecx, DK_SUB_W
    mov edx, DK_SUB_N * DK_CTX_ITEM
    push eax
    push ebx
    add eax, 3
    add ebx, 3
    mov esi, 0x08101C
    call dk_fill
    pop ebx
    pop eax
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_MENU
    call dk_fill
    xor ecx, ecx
.item:
    cmp ecx, DK_SUB_N
    jae .done
    imul ebx, ecx, DK_CTX_ITEM
    add ebx, [dk_sub_y]
    cmp ecx, [dk_sub_hover]
    jne .plain
    push ecx
    mov eax, [dk_sub_x]
    add eax, 2
    add ebx, 1
    mov ecx, DK_SUB_W - 4
    mov edx, DK_CTX_ITEM - 2
    mov esi, COL_SUBMENU
    call dk_fill
    sub ebx, 1
    pop ecx
.plain:
    mov esi, [dkn_sub_labels + ecx*4]
    mov eax, [dk_sub_x]
    add eax, 12
    add ebx, 3
    mov edx, COL_TEXT
    call dk_text
    inc ecx
    jmp .item
.done:
    popad
    ret

; ============================================================
; Data (shared)
; ============================================================
dkn_open         db 0
dkn_fresh        db 0
dkn_op           db 0
dkn_dir          db 0
dkn_req          db 0
dkn_slot         dd 0
dkn_len          dd 0
dkn_err          dd 0
dkn_size         dd 0
dkn_text         times DKN_MAX + 2 db 0
dkn_path         times DKN_MAX + 8 db 0
dkn_keys         times 16 dw 0
dkn_khead        db 0
dkn_ktail        db 0
dk_ctx_hover     dd -1
dk_sub_open      db 0
dk_sub_hover     dd -1
dk_sub_x         dd 0
dk_sub_y         dd 0
dkn_empty        db 0
dkn_ext_txt      db ".TXT", 0
dkn_ext_hg       db ".HG", 0
dkn_bad_chars    db "/\|<>*?", 34, ": ", 0
dkn_hg_template  db "@echo off", 13, 10
                 db "# a LexOS script: help lists the commands, README says more", 13, 10
                 db "echo Hello from a script!", 13, 10
dkn_hg_template_len equ $ - dkn_hg_template
dkn_titles       dd dkn_t_rename, dkn_t_newdir, dkn_t_newtxt, dkn_t_newhg
                 dd dkn_t_newlnk, dkn_t_copyto
dkn_prompts      dd dkn_p_name, dkn_p_name, dkn_p_name, dkn_p_name
                 dd dkn_p_target, dkn_p_folder
dkn_sub_labels   dd dkx_l_newdir, dkx_l_newtxt, dkx_l_newhg, dkx_l_newlnk
dkn_t_rename     db "Rename", 0
dkn_t_newdir     db "New folder", 0
dkn_t_newtxt     db "New text file", 0
dkn_t_newhg      db "New script", 0
dkn_t_newlnk     db "New shortcut", 0
dkn_t_copyto     db "Copy to", 0
dkn_p_name       db "Name (up to 15 characters):", 0
dkn_p_target     db "What it opens (a path, like /APPS/FIRE.APP):", 0
dkn_p_folder     db "The folder to copy it into (like /DEMOS, or /):", 0
dkn_l_ok         db "OK", 0
dkn_l_cancel     db "Cancel", 0
dkx_l_create     db "Create", 0
dkx_l_newdir     db "Create a folder", 0
dkx_l_newtxt     db "Create a TXT", 0
dkx_l_newhg      db "Create a HG", 0
dkx_l_newlnk     db "Create a Link", 0
dkx_l_iopen      db "Open", 0
dkx_l_irename    db "Rename...", 0
dkx_l_idelete    db "Delete", 0
dkx_l_iprops     db "Properties...", 0
dkt_l_restore    db "Restore", 0
dkn_m_empty      db "Type a name first.", 0
dkn_m_taken      db "That name is taken here.", 0
dkn_m_full       db "No room for it on the disk.", 0
dkn_m_protected  db "USER.CFG stays as it is.", 0
dkn_m_read_only  db "It's read-only (attrib -r).", 0
dkn_m_nothing    db "There's nothing at that path.", 0
dkn_m_not_folder db "That isn't a folder.", 0
dkn_m_files_only db "Only files can be copied.", 0
dkn_m_long       db "At most 15 characters.", 0
dkn_m_invalid    db "Not in a name: / \ | < > * ? : or a space.", 0
