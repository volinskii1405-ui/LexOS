; dkusers.asm - several users, each with a desktop and settings of their
; own (the kernel's extension)
;
; The one logged in keeps theirs where they always were: /USER.CFG,
; /DESKTOP.CFG, /DESKTOP. The others' are in /HOME/<NAME> (the name in
; capitals). Logging in as another swaps them: the one before's three
; go into their /HOME folder, the new one's come out to the root - so
; everything that looks for /DESKTOP or DESKTOP.CFG finds the right
; one, and a new user starts with a desktop of a few shortcuts.
;
; The login screen (src/welcome.asm) goes round the users with Left /
; Right; the Control panel's Users adds one (a name, no password yet)
; and sets the password of the one logged in.
; Exports: dkus_list, dkus_login_start, dkus_login_key, dkus_login_draw,
;          dkus_login_done, dkus_add_do, dkus_pass_do, dkus_masked,
;          dkus_sel_nick, dkus_sel_hash, dkus_n, dkus_nicks

DKUS_MAX       equ 8
DKUS_NICK      equ 16
DKN_ADDUSER    equ 14                   ; (src/dkname.asm's dkn_do)
DKN_PASSWORD   equ 15

; ============================================================
; Folders and files
; ============================================================

; -> al = /HOME's slot byte (made in the root if it isn't there);
; carry=1 if there's no room for it
dkus_home:
    push esi
    mov esi, dkus_p_home
    call dkus_find_dir_root
    jnc .done
    mov esi, dkus_n_home
    mov dl, FS_ROOT_BYTE
    call dkus_mkdir
.done:
    pop esi
    ret

; esi = a folder's name in the root -> al = its slot byte, carry=1: none
dkus_find_dir_root:
    push ebx
    push ecx
    push edx
    mov dl, FS_ROOT_BYTE
    call aext_find_in                     ; (src/appext.asm) -> eax
    cmp eax, -1
    je .none
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .none
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.none:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; esi = a name, dl = the folder to make it in -> al = the new folder's
; slot byte; carry=1: no room
dkus_mkdir:
    push ebx
    push ecx
    push edi
    call fs_find_free_dir
    cmp ax, -1
    je .full
    movzx ebx, ax
    push eax
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    mov edi, SCRATCH_ADDR
    call dki_copy
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    pop eax
    call fs_write_slot
    mov eax, ebx
    pop edi
    pop ecx
    pop ebx
    clc
    ret
.full:
    pop edi
    pop ecx
    pop ebx
    stc
    ret

; esi = a name, dl = its folder, edi = its text, ecx = how long (under
; 127): a small file made there
dkus_mkfile:
    pushad
    call fs_find_free
    cmp ax, -1
    je .done
    movzx ebx, ax
    push esi
    push edi
    push ecx
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    pop ecx
    pop edi
    pop esi
    push edi
    mov edi, SCRATCH_ADDR
    call dki_copy
    pop esi
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    mov edi, SCRATCH_ADDR + FS_CONTENT_OFFSET
    push ecx
    rep movsb
    pop edx
    call fs_scratch_write_size16
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov eax, ebx
    call fs_write_slot
.done:
    popad
    ret

; esi = a name, dl = the folder it's in, dh = the one it goes into: moved
; (if it's there, and the name's free where it goes)
dkus_move:
    pushad
    mov [dkus_to], dh
    call aext_find_in                     ; -> eax
    cmp eax, -1
    je .done
    push eax
    mov dl, [dkus_to]
    call aext_find_in                     ; (taken there?)
    mov ecx, eax
    pop eax
    cmp ecx, -1
    jne .done
    call fs_read_slot
    mov dl, [dkus_to]
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    call fs_write_slot
.done:
    popad
    ret

; esi = a nickname -> dkus_fname: the folder it's kept in - its letters
; and digits in capitals, 12 at most ("USER" if none are left)
dkus_folder_name:
    pushad
    mov edi, dkus_fname
    xor ecx, ecx
.char:
    lodsb
    or al, al
    jz .end
    cmp al, 'a'
    jb .not_lower
    cmp al, 'z'
    ja .not_lower
    sub al, 32
.not_lower:
    cmp al, '0'
    jb .char
    cmp al, '9'
    jbe .keep
    cmp al, 'A'
    jb .char
    cmp al, 'Z'
    ja .char
.keep:
    stosb
    inc ecx
    cmp ecx, 12
    jb .char
.end:
    mov byte [edi], 0
    or ecx, ecx
    jnz .done
    mov dword [dkus_fname], 'USER'
    mov byte [dkus_fname + 4], 0
.done:
    popad
    ret

; ============================================================
; The users there are
; ============================================================

; dkus_n, dkus_nicks, dkus_hashes, dkus_folders: the others (in /HOME,
; with a USER.CFG), not the one logged in
dkus_list:
    pushad
    push word [fs_current_dir]
    mov dword [dkus_n], 0
    mov esi, dkus_p_home
    call dkus_find_dir_root               ; -> al
    jc .done
    mov [dkus_hb], al
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .done
    cmp dword [dkus_n], DKUS_MAX
    jae .done
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .next
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp al, [dkus_hb]
    jne .next
    mov edi, [dkus_n]                     ; its folder's name
    shl edi, 4
    add edi, dkus_folders
    mov esi, SCRATCH_ADDR
    call dki_copy
    push ebx
    mov dl, bl                            ; its USER.CFG
    mov esi, user_cfg_name
    call aext_find_in                     ; -> eax
    pop ebx
    cmp eax, -1
    je .next
    mov edi, dkus_cfg
    mov ecx, 255
    call fs_load_to                       ; -> ecx
    mov byte [dkus_cfg + ecx], 0
    mov esi, dkus_cfg                     ; the first line: the name
    mov edi, [dkus_n]
    shl edi, 4
    add edi, dkus_nicks
    mov ecx, DKUS_NICK - 1
.nick:
    lodsb
    cmp al, 13
    jbe .nicked
    stosb
    loop .nick
.nicked:
    mov byte [edi], 0
    call dkus_next_line                   ; the second, then the third:
    call dkus_next_line                   ; the password's hash
    call dkus_hex                         ; -> eax
    mov edi, [dkus_n]
    mov [dkus_hashes + edi*4], eax
    inc dword [dkus_n]
.next:
    inc ebx
    jmp .slot
.done:
    pop word [fs_current_dir]
    popad
    ret

; esi in a line -> at the start of the next one
dkus_next_line:
    lodsb
    or al, al
    jz .end
    cmp al, 10
    jne dkus_next_line
    ret
.end:
    dec esi
    ret

; esi = up to 8 hex digits -> eax (0: none)
dkus_hex:
    push ecx
    push edx
    xor eax, eax
    mov ecx, 8
.digit:
    movzx edx, byte [esi]
    sub edx, '0'
    cmp edx, 9
    jbe .add
    sub edx, 'A' - '0' - 10
    cmp edx, 10
    jb .done
    cmp edx, 15
    jbe .add
    sub edx, 'a' - 'A'
    cmp edx, 10
    jb .done
    cmp edx, 15
    ja .done
.add:
    shl eax, 4
    or eax, edx
    inc esi
    loop .digit
.done:
    pop edx
    pop ecx
    ret

; ============================================================
; The login screen (src/welcome.asm's wl_login)
; ============================================================

; Before it's drawn: the users read, the one logged in chosen
dkus_login_start:
    pushad
    call dkus_list
    mov dword [dkus_sel], 0
    call dkus_sel_set
    popad
    ret

; dkus_sel -> dkus_sel_nick, dkus_sel_hash (0: the one logged in)
dkus_sel_set:
    pushad
    mov esi, user_nickname
    mov eax, [user_pass_hash]
    mov ebx, [dkus_sel]
    or ebx, ebx
    jz .copy
    dec ebx
    mov esi, ebx
    shl esi, 4
    add esi, dkus_nicks
    mov eax, [dkus_hashes + ebx*4]
.copy:
    mov [dkus_sel_hash], eax
    mov edi, dkus_sel_nick
    call dki_copy
    popad
    ret

; ax = a key (ASCII, scan code): Left / Right another user - carry=0
; if it was one of those (the typed password forgotten, then)
dkus_login_key:
    cmp dword [dkus_n], 0
    je .no
    or al, al
    jnz .no
    cmp ah, 0x4B
    je .left
    cmp ah, 0x4D
    je .right
.no:
    stc
    ret
.left:
    dec dword [dkus_sel]
    jns .set
    mov eax, [dkus_n]
    mov [dkus_sel], eax
    jmp .set
.right:
    inc dword [dkus_sel]
    mov eax, [dkus_n]
    cmp [dkus_sel], eax
    jbe .set
    mov dword [dkus_sel], 0
.set:
    call dkus_sel_set
    clc
    ret

; wl_draw_login: arrows either side of the name, and how to use them
dkus_login_draw:
    cmp dword [dkus_n], 0
    je .done
    pushad
    mov esi, dkus_l_left
    mov eax, 40
    mov ebx, 128
    mov edx, WL_MUTED
    mov ecx, 2
    call wl_card_text
    mov esi, dkus_l_right
    mov eax, WL_CARD_W - 56
    call wl_card_text
    mov esi, dkus_m_others
    call tr_lookup
    call wl_strlen
    mov eax, ecx
    shl eax, 2
    neg eax
    add eax, WL_CARD_W / 2
    mov ebx, 300
    mov edx, WL_MUTED
    mov ecx, 1
    call wl_card_text
    popad
.done:
    ret

; The password right: another user chosen - theirs swapped in
dkus_login_done:
    cmp dword [dkus_sel], 0
    je .done
    pushad
    mov ebx, [dkus_sel]
    dec ebx
    call dkus_switch
    popad
.done:
    ret

; ebx = one of dkus_list's: logged in instead of the one who was
dkus_switch:
    pushad
    mov [dkus_idx], ebx
    push word [fs_current_dir]
    mov word [fs_current_dir], FS_ROOT
    call dkus_home                        ; -> al
    jc .done
    mov [dkus_hb], al
    mov esi, user_nickname                ; the one before: their folder
    call dkus_folder_name
    mov esi, dkus_fname
    mov dl, [dkus_hb]
    call aext_find_in                     ; -> eax
    cmp eax, -1
    jne .have_old
    mov esi, dkus_fname
    mov dl, [dkus_hb]
    call dkus_mkdir
    jc .done
.have_old:
    mov [dkus_old], al
    mov esi, [dkus_idx]                   ; the new one's folder
    shl esi, 4
    add esi, dkus_folders
    mov dl, [dkus_hb]
    call aext_find_in
    cmp eax, -1
    je .done
    mov [dkus_new], al
    xor ebp, ebp                          ; the three, each way
.item:
    mov esi, [dkus_items + ebp*4]
    mov dl, FS_ROOT_BYTE
    mov dh, [dkus_old]
    call dkus_move
    inc ebp
    cmp ebp, 3
    jb .item
    xor ebp, ebp
.item_in:
    mov esi, [dkus_items + ebp*4]
    mov dl, [dkus_new]
    mov dh, FS_ROOT_BYTE
    call dkus_move
    inc ebp
    cmp ebp, 3
    jb .item_in
    mov esi, dkus_n_desktop               ; no desktop yet: a new one, with
    call dkus_find_dir_root               ; a few shortcuts on it
    jnc .desk_there
    mov esi, dkus_n_desktop
    mov dl, FS_ROOT_BYTE
    call dkus_mkdir
    jc .reload
    mov dl, al
    xor ebp, ebp
.link:
    mov esi, [dkus_links + ebp*8]
    mov edi, [dkus_links + ebp*8 + 4]
    push esi
    mov esi, edi
    call dki_strlen
    pop esi
    call dkus_mkfile
    inc ebp
    cmp ebp, DKUS_LINKS
    jb .link
.desk_there:
.reload:
    mov si, user_cfg_name                 ; theirs, read in
    call fs_find_by_name
    cmp ax, -1
    je .done
    mov [user_cfg_slot], ax
    mov [fs_tmp_slot], ax
    call fs_load_content
    call user_parse_cfg_content
    call welcome_parse_extra
    call jnl_commit
.done:
    pop word [fs_current_dir]
    popad
    ret

; wl_boot: the login screen wanted? (a password - or others to choose
; from) carry=0 if so
dkus_want_login:
    pushad
    call dkus_list
    cmp dword [user_pass_hash], 0
    jne .yes
    cmp dword [dkus_n], 0
    jne .yes
    popad
    stc
    ret
.yes:
    popad
    clc
    ret

; ============================================================
; The Control panel's Users (dkn_do: the kernel lock held)
; ============================================================

; Add a user: dkn_text, their name - /HOME/<NAME>/USER.CFG, no password,
; the time zone, layouts and language as the one logged in has
dkus_add_do:
    pushad
    cmp dword [dkn_len], 0
    je .empty
    mov esi, dkn_text
    call dkus_folder_name
    mov esi, dkus_fname                   ; taken - by the one logged in,
    mov edi, dkus_mine                    ; or by one of the others?
    push esi
    mov esi, user_nickname
    call dkus_folder_name_to_mine
    pop esi
    call dkx_str_eq
    je .taken
    call dkus_home                        ; -> al
    jc .full
    mov dl, al
    mov esi, dkus_fname
    call aext_find_in
    cmp eax, -1
    jne .taken
    mov esi, dkus_fname
    call dkus_mkdir                       ; -> al
    jc .full
    mov dl, al
    push edx
    mov edi, dkus_cfg                     ; USER.CFG: the name, the time zone,
    mov esi, dkn_text                     ; no password, the layouts, the
    mov ecx, USER_NICKNAME_LEN            ; language - as ours
.nick:
    lodsb
    or al, al
    jz .nicked
    stosb
    loop .nick
.nicked:
    mov ax, 0x0A0D
    stosw
    movsx eax, word [user_tz_offset]
    or eax, eax
    jns .tz
    mov byte [edi], '-'
    inc edi
    neg eax
.tz:
    call wget_append_num
    mov ax, 0x0A0D
    stosw
    stosw
    mov ax, 'en'
    stosw
    mov ax, 0x0A0D
    stosw
    movzx eax, byte [sys_lang]
    mov ax, [wl_ui_codes + eax*2]
    stosw
    mov ax, 0x0A0D
    stosw
    mov ecx, edi
    sub ecx, dkus_cfg
    pop edx
    mov esi, user_cfg_name
    mov edi, dkus_cfg
    call dkus_mkfile
    call dkn_close
    mov edi, dk_toast_buf                 ; "Added: ANNA - log out to switch"
    mov esi, dkus_m_added
    call tr_lookup
    call wget_append
    mov esi, dkn_text
    call wget_append
    mov byte [edi], 0
    call dk_toast
    call dkus_list
    mov eax, K_SYSTEM
    call dk_mark_kind
    jmp .done
.empty:
    mov dword [dkn_err], dkn_m_empty
    jmp .done
.taken:
    mov dword [dkn_err], dkus_m_taken
    jmp .done
.full:
    mov dword [dkn_err], dkn_m_full
.done:
    popad
    ret

; esi = a nickname -> dkus_mine (its folder name, as dkus_folder_name)
dkus_folder_name_to_mine:
    pushad
    push dword [dkus_fname]
    push dword [dkus_fname + 4]
    push dword [dkus_fname + 8]
    push dword [dkus_fname + 12]
    call dkus_folder_name
    mov esi, dkus_fname
    mov edi, dkus_mine
    call dki_copy
    pop dword [dkus_fname + 12]
    pop dword [dkus_fname + 8]
    pop dword [dkus_fname + 4]
    pop dword [dkus_fname]
    popad
    ret

; Password: dkn_text the new one (nothing: none) - USER.CFG written again
dkus_pass_do:
    pushad
    mov esi, dkn_text
    mov ecx, [dkn_len]
    call wl_hash                          ; -> eax (0: no password)
    mov [user_pass_hash], eax
    call user_save_cfg
    mov esi, dkus_m_pass
    cmp dword [user_pass_hash], 0
    jne .said
    mov esi, dkus_m_nopass
.said:
    call tr_lookup
    mov edi, dk_toast_buf
    call dki_copy
    call dk_toast
    mov dword [dkn_text], 0
    call dkn_close
    popad
    ret

; dkn_draw, the text typed: esi = dkn_text - or, typing a password, as
; many dots
dkus_masked:
    cmp byte [dkn_op], DKN_PASSWORD
    jne .done
    push ecx
    push edi
    mov edi, dkus_dots
    mov ecx, [dkn_len]
    cmp ecx, 40
    jbe .n
    mov ecx, 40
.n:
    mov al, '*'
    rep stosb
    mov byte [edi], 0
    pop edi
    pop ecx
    mov esi, dkus_dots
.done:
    ret

; ============================================================
; Data
; ============================================================
DKUS_LINKS     equ 5
dkus_n         dd 0
dkus_sel       dd 0
dkus_sel_hash  dd 0
dkus_hb        db 0
dkus_old       db 0
dkus_to        db 0
dkus_idx       dd 0
dkus_new       db 0
dkus_sel_nick  times DKUS_NICK + 4 db 0
dkus_nicks     times DKUS_MAX * DKUS_NICK db 0
dkus_folders   times DKUS_MAX * 16 db 0
dkus_hashes    times DKUS_MAX dd 0
dkus_fname     times 16 db 0
dkus_mine      times 16 db 0
dkus_cfg       times 260 db 0
dkus_dots      times 44 db 0
dkus_items     dd user_cfg_name, dk_cfg_name, dkus_n_desktop
dkus_links     dd dkus_k1, dkus_t1, dkus_k2, dkus_t2, dkus_k3, dkus_t3
               dd dkus_k4, dkus_t4, dkus_k5, dkus_t5
dkus_k1        db "README.LNK", 0
dkus_t1        db "/README", 13, 10, 0
dkus_k2        db "NOTEPAD.LNK", 0
dkus_t2        db "/APPS/NOTEPAD.APP", 13, 10, 0
dkus_k3        db "PAINT.LNK", 0
dkus_t3        db "/APPS/PAINT.APP", 13, 10, 0
dkus_k4        db "CALC.LNK", 0
dkus_t4        db "/APPS/CALC.APP", 13, 10, 0
dkus_k5        db "WEB.LNK", 0
dkus_t5        db "/APPS/BROWSER.APP", 13, 10, 0
dkus_p_home    db "HOME", 0
dkus_n_home    db "HOME", 0
dkus_n_desktop db "DESKTOP", 0
dkus_l_left    db "<", 0
dkus_l_right   db ">", 0
dkus_m_others  db "Left / Right: another user", 0
dkus_m_added   db "A new user, log out to switch to them: ", 0
dkus_m_taken   db "There's a user by that name already.", 0
dkus_m_pass    db "The password's changed.", 0
dkus_m_nopass  db "No password now.", 0
