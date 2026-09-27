; dkmsel.asm - several desktop icons at once (the kernel's extension)
;
; A rubber band dragged over the desktop picks what it touches; Ctrl+
; click picks one more (or lets it go). Picked, they're carried
; together, dropped together (into a folder, onto Files, onto the
; trash), and Del or the menu's Delete sends them all to the trash.
; dki_sel is still the one clicked last; dkm_sel the others with it.
; Exports: dkm_is, dkm_clear, dkm_press, dkm_band_press, dkm_band_move,
;          dkm_band_draw, dkm_follow, dkm_released, dkm_snap_others,
;          dkm_drop_add, dkm_trash_group, dkm_ctx_items, dkm_delete_group,
;          dkm_trash_do, dkm_pick_one

DKN_TRASHN     equ 13                   ; (src/dkname.asm's dkn_do)

; ebx = an icon -> carry=0 if it's picked
dkm_is:
    cmp ebx, [dki_sel]
    je .yes
    cmp ebx, DKI_MAX
    jae .no
    cmp byte [dkm_sel + ebx], 0
    jne .yes
.no:
    stc
    ret
.yes:
    clc
    ret

; -> ecx = how many are picked
dkm_count:
    push ebx
    xor ecx, ecx
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    call dkm_is
    jc .next
    inc ecx
.next:
    inc ebx
    jmp .each
.done:
    pop ebx
    ret

; None picked (their cells drawn again)
dkm_clear:
    pushad
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    call dkm_is
    jc .next
    call dki_mark
.next:
    mov byte [dkm_sel + ebx], 0
    inc ebx
    cmp ebx, DKI_MAX
    jb .each
.done:
    mov ecx, ebx
.rest:
    cmp ecx, DKI_MAX
    jae .cleared
    mov byte [dkm_sel + ecx], 0
    inc ecx
    jmp .rest
.cleared:
    mov dword [dki_sel], -1
    popad
    ret

; Just ebx picked (a right click, Del on one not picked)
dkm_pick_one:
    call dkm_is
    jnc .done
    call dkm_clear
    mov [dki_sel], ebx
    call dki_mark
.done:
    ret

; dki_press, on icon ecx: carry=0 if that's all (Ctrl: it's picked or
; let go, nothing carried); carry=1 - it's picked (the others kept if
; it was one of them) and may be carried
dkm_press:
    pushad
    mov ebx, ecx
    cmp byte [lang_ctrl_held], 0
    je .plain
    mov eax, [dki_sel]                    ; Ctrl: the one before joins in
    cmp eax, -1
    je .toggle
    mov byte [dkm_sel + eax], 1
.toggle:
    mov dword [dki_sel], -1
    xor byte [dkm_sel + ebx], 1
    call dki_mark
    mov dword [dkm_after], -1
    popad
    clc
    ret
.plain:
    mov dword [dkm_after], -1
    call dkm_is                           ; one of those picked: they stay
    jc .alone                             ; (to be carried together)
    call dkm_count
    cmp ecx, 1
    jbe .alone
    mov eax, [dki_sel]                    ; (the one before: one of them)
    cmp eax, -1
    je .keep
    mov byte [dkm_sel + eax], 1
.keep:
    mov byte [dkm_sel + ebx], 0
    mov [dkm_after], ebx                  ; (not carried: just this one, then)
    jmp .starts
.alone:
    call dkm_clear
.starts:
    xor ecx, ecx                          ; where each is: put back after a
.start:                                   ; drop into a folder
    cmp ecx, [dki_n]
    jae .done
    mov eax, [dki_x + ecx*4]
    mov [dkm_start_x + ecx*4], eax
    mov eax, [dki_y + ecx*4]
    mov [dkm_start_y + ecx*4], eax
    inc ecx
    jmp .start
.done:
    popad
    stc
    ret

; dki_drag_move, let go without moving: a click on one of several
; picked - just it, then
dkm_released:
    pushad
    mov ebx, [dkm_after]
    cmp ebx, -1
    je .done
    mov dword [dkm_after], -1
    call dkm_clear
    mov [dki_sel], ebx
    call dki_mark
.done:
    popad
    ret

; dki_drag_move: the carried one (ebx) going to eax, edx - the others
; picked go the same way
dkm_follow:
    pushad
    mov dword [dkm_after], -1             ; (moved: not a click)
    sub eax, [dki_x + ebx*4]
    sub edx, [dki_y + ebx*4]
    mov [dkm_dx], eax
    mov [dkm_dy], edx
    mov ebp, ebx
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    cmp ebx, ebp
    je .next
    call dkm_is
    jc .next
    call dki_mark
    mov eax, [dki_x + ebx*4]
    add eax, [dkm_dx]
    cmp eax, 0                            ; on the screen, off the taskbar
    jge .x0
    xor eax, eax
.x0:
    push edx
    mov edx, [dk_w]
    add edx, 0 - DKI_W
    mov [dk_ctmp], edx
    pop edx
    cmp eax, [dk_ctmp]
    jle .x1
    mov eax, [dk_w]
    add eax, 0 - DKI_W
.x1:
    mov [dki_x + ebx*4], eax
    mov eax, [dki_y + ebx*4]
    add eax, [dkm_dy]
    cmp eax, 0
    jge .y0
    xor eax, eax
.y0:
    push edx
    mov edx, [dk_h]
    add edx, 0 - DK_TASKBAR_H - DKI_H
    mov [dk_ctmp], edx
    pop edx
    cmp eax, [dk_ctmp]
    jle .y1
    mov eax, [dk_h]
    add eax, 0 - DK_TASKBAR_H - DKI_H
.y1:
    mov [dki_y + ebx*4], eax
    call dki_mark
.next:
    inc ebx
    jmp .each
.done:
    popad
    ret

; Dropped on the desktop (ebx: the carried one, snapped): the others
; each into their nearest free cell
dkm_snap_others:
    pushad
    mov ebp, ebx
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    cmp ebx, ebp
    je .next
    call dkm_is
    jc .next
    call dkg_snap
.next:
    inc ebx
    jmp .each
.done:
    popad
    ret

; The others, back where they were picked up
dkm_put_back:
    pushad
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    call dkm_is
    jc .next
    call dki_mark
    mov eax, [dkm_start_x + ebx*4]
    mov [dki_x + ebx*4], eax
    mov eax, [dkm_start_y + ebx*4]
    mov [dki_y + ebx*4], eax
    call dki_mark
.next:
    inc ebx
    jmp .each
.done:
    popad
    ret

; dkd_icon_drop, the carried one (ebx) added to what's moved or copied:
; the others picked too
dkm_drop_add:
    pushad
    mov ebp, ebx
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    cmp ebx, ebp
    je .next
    call dkm_is
    jc .next
    call dkt_is_icon                      ; (not the trash itself)
    jnc .next
    call dkm_icon_slot                    ; -> eax
    cmp eax, -1
    je .next
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    call dkd_add
.next:
    inc ebx
    jmp .each
.done:
    call dkm_put_back
    popad
    ret

; ebx = an icon -> eax = its file's slot (-1: gone)
dkm_icon_slot:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov esi, dki_folder_path
    mov edi, dkm_path
    call dki_copy
    mov byte [edi - 1], '/'
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    call dki_copy
    mov esi, dkm_path
    call dki_resolve                      ; -> eax
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; Onto the trash (dkd_icon_drop), or Delete / Del with several picked:
; carry=0 if they all go (a request - dkn_do), carry=1: just the one
dkm_trash_group:
    push ecx
    call dkm_count
    cmp ecx, 1
    pop ecx
    jbe .one
    cmp byte [dkn_req], 0
    jne .one
    cmp byte [dkn_open], 0
    jne .one
    call dkm_put_back
    mov byte [dkn_op], DKN_TRASHN
    mov dword [dkn_len], 0
    mov byte [dkn_req], 1
    clc
    ret
.one:
    stc
    ret

; dkx_ctx_items, on icon ecx: several picked, it among them - Open,
; Delete (them all), Properties; carry=0 if so. Not picked: just it.
dkm_ctx_items:
    push ebx
    push ecx
    mov ebx, ecx
    call dkm_is
    jnc .picked
    call dkm_pick_one
    jmp .one
.picked:
    call dkm_count
    cmp ecx, 1
    jbe .one
    mov al, DKC_IOPEN
    call dk_ctx_add
    mov al, DKC_IDELETE
    call dk_ctx_add
    mov al, DKC_IPROPS
    call dk_ctx_add
    pop ecx
    pop ebx
    clc
    ret
.one:
    pop ecx
    pop ebx
    stc
    ret

; dkx_ctx_do's Delete (icon ebx): several picked, it among them - all
; of them; carry=0 if so
dkm_delete_group:
    call dkm_is
    jc .no
    jmp dkm_trash_group
.no:
    stc
    ret

; ============================================================
; The rubber band
; ============================================================

; dki_press on the background (eax, ebx): a band starts there
dkm_band_press:
    mov [dkm_bx0], eax
    mov [dkm_by0], ebx
    mov [dkm_bx1], eax
    mov [dkm_by1], ebx
    mov byte [dkm_band], 1
    cmp byte [lang_ctrl_held], 0          ; (Ctrl: added to what's picked)
    jne .keep
    call dkm_clear
.keep:
    ret

; dk_mouse_events, the pointer at eax, ebx (button cl): carry=0 if a
; band's being dragged (then it follows; let go, it picks)
dkm_band_move:
    cmp byte [dkm_band], 0
    jne .band
    stc
    ret
.band:
    pushad
    call dkm_band_mark                    ; where it was...
    mov [dkm_bx1], eax
    mov [dkm_by1], ebx
    call dkm_band_mark                    ; ...and is
    or cl, cl
    jnz .done
    mov byte [dkm_band], 0                ; let go: what it touches, picked
    call dkm_band_rect                    ; -> eax, ebx, ecx, edx
    mov [dkm_l], eax
    mov [dkm_t], ebx
    mov [dkm_r], ecx
    mov [dkm_b], edx
    sub ecx, eax                          ; (a click, not a band: nothing)
    sub edx, ebx
    add ecx, edx
    cmp ecx, 4
    jb .done
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .picked
    mov eax, [dki_x + ebx*4]
    cmp eax, [dkm_r]
    jge .next
    add eax, DKI_W
    cmp eax, [dkm_l]
    jle .next
    mov eax, [dki_y + ebx*4]
    cmp eax, [dkm_b]
    jge .next
    add eax, DKI_H
    cmp eax, [dkm_t]
    jle .next
    call dkt_is_icon                      ; (not the trash)
    jnc .next
    mov byte [dkm_sel + ebx], 1
    call dki_mark
.next:
    inc ebx
    jmp .each
.picked:
    mov dword [dki_sel], -1
.done:
    popad
    clc
    ret

; -> eax, ebx, ecx, edx = the band's left, top, right, bottom
dkm_band_rect:
    mov eax, [dkm_bx0]
    mov ecx, [dkm_bx1]
    cmp eax, ecx
    jle .x
    xchg eax, ecx
.x:
    mov ebx, [dkm_by0]
    mov edx, [dkm_by1]
    cmp ebx, edx
    jle .y
    xchg ebx, edx
.y:
    ret

; Its rectangle, to be drawn again
dkm_band_mark:
    pushad
    call dkm_band_rect
    sub ecx, eax
    sub edx, ebx
    inc ecx
    inc edx
    call dk_mark
    popad
    ret

; dki_draw's end: the band, over the icons
dkm_band_draw:
    cmp byte [dkm_band], 0
    je .done
    pushad
    call dkm_band_rect
    mov [dkm_l], eax
    mov [dkm_t], ebx
    mov [dkm_r], ecx
    mov [dkm_b], edx
    mov ecx, [dkm_r]                      ; the top and bottom edges
    sub ecx, eax
    inc ecx
    mov edx, 1
    mov esi, COL_WHITE
    call dk_fill
    mov ebx, [dkm_b]
    call dk_fill
    mov ebx, [dkm_t]                      ; the sides
    mov ecx, 1
    mov edx, [dkm_b]
    sub edx, ebx
    inc edx
    call dk_fill
    mov eax, [dkm_r]
    call dk_fill
    popad
.done:
    ret

; ============================================================
; Into the trash, all of them (dkn_do: the kernel lock held)
; ============================================================
dkm_trash_do:
    pushad
    mov dword [dkm_gone], 0
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .said
    call dkm_is
    jc .next
    call dkt_is_icon
    jnc .next
    call dkm_icon_slot                    ; -> eax
    cmp eax, -1
    je .next
    cmp ax, [user_cfg_slot]
    je .next
    mov [dkm_slot], eax
    call jnl_attr_of
    test al, FS_ATTR_RO
    jnz .next
    call dkn_trash_dir                    ; -> al (carry: no room)
    jc .said
    mov dl, al
    mov eax, [dkm_slot]
    call fs_read_slot
    call dkt_note_origin                  ; (Restore's, Undo's)
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    call fs_write_slot
    inc dword [dkm_gone]
.next:
    inc ebx
    jmp .each
.said:
    mov edi, dk_toast_buf                 ; "Moved to the trash: 3"
    mov esi, dkm_m_trashed
    call tr_lookup
    call wget_append
    mov eax, [dkm_gone]
    call wget_append_num
    mov byte [edi], 0
    call dk_toast
    call dkm_clear
    mov byte [dki_rescan], 1
    mov byte [dk_fm_refresh], 1
    mov byte [dk_redraw_all], 1
    mov eax, SND_TRASH                    ; (a whoosh)
    call snd_play
    popad
    ret

; ============================================================
; Data
; ============================================================
dkm_band       db 0
dkm_bx0        dd 0
dkm_by0        dd 0
dkm_bx1        dd 0
dkm_by1        dd 0
dkm_l          dd 0
dkm_t          dd 0
dkm_r          dd 0
dkm_b          dd 0
dkm_dx         dd 0
dkm_dy         dd 0
dkm_after      dd -1
dkm_slot       dd 0
dkm_gone       dd 0
dkm_sel        times DKI_MAX db 0
dkm_start_x    times DKI_MAX dd 0
dkm_start_y    times DKI_MAX dd 0
dkm_path       times DKI_PATH + FS_NAME_LEN + 4 db 0
dkm_m_trashed  db "Moved to the trash: ", 0
