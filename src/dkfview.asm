; dkfview.asm - Files: the places on the left, the Details view, pictures'
; thumbnails and Recent (the kernel's extension, KEXT)
;
; The places: Desktop, Programs (/APPS), Recent, Trash, This disk (/) -
; a click goes there (Recent: what was opened lately, newest first -
; opened from here, it opens where it is). They show when the window's
; wide enough (DKF_SIDE_MIN).
;
; The view button (the toolbar, left of the pages' arrows) switches
; Icons / Details: a table - the name with a small icon, the size, when
; it last changed, the kind - its headings clicked to sort by them.
;
; In Icons, a .BMP shows a thumbnail of itself instead of the picture
; icon: made a picture a frame by the desktop's task (holding the
; kernel lock), kept in DKF_THUMBS by its slot, size and date.
;
; The grid's geometry (dkf_layout, dkf_cell, dkf_hit) is here for both
; views: src/dkwins.asm's drawing, clicks, dragging and rubber band go
; through it.
; Exports: dkf_layout, dkf_cell, dkf_hit, dkf_draw_frame, dkf_draw_cell,
;          dkf_draw_viewbtn, dkf_click, dkf_refresh, dkf_open,
;          dkf_up, dkf_ctx_items, dkf_rec_add, dkf_thumb_work,
;          dkf_cfg_save, dkf_cfg_load, dkf_entry_extra

DKF_SIDE_W     equ 128                  ; the places' width
DKF_SIDE_MIN   equ 440                  ; (a window narrower: none)
DKF_PLACE_H    equ 24
DKF_ROW_H      equ 22                   ; Details: a row
DKF_HEAD_H     equ 22                   ; ...and the headings
DKF_VIEW_W     equ 30
DKF_THUMB      equ 40                   ; a thumbnail: at most 40x40
DKF_THUMBS     equ 0x7300000            ; (1MB: past the wallpaper)
DKF_TH_N       equ 120
DKF_TH_SIZE    equ 16 + DKF_THUMB * DKF_THUMB * 4
DKF_REC_MAX    equ 10
DKF_REC_SIZE   equ 48                   ; a name (16), its folder (32)
DKF_PLACES     equ 5

; ============================================================
; The geometry
; ============================================================

; Each frame (dk_fm_layout): the grid's cells, as many as the window
; has room for, in the view it's in
dkf_layout:
    pushad
    mov eax, K_FILES
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .done
    mov ebp, eax
    mov ecx, [dkw_w + ebp*4]
    xor eax, eax                          ; the places: room for them?
    cmp ecx, DKF_SIDE_MIN
    jb .side
    mov eax, DKF_SIDE_W
.side:
    mov [dkf_side_w], eax
    add eax, 4
    mov [dkf_gx], eax
    sub ecx, eax
    sub ecx, 4
    cmp byte [dkf_view], 0
    jne .details
    mov dword [dkf_cw], FM_CELL_W
    mov dword [dkf_ch], FM_CELL_H
    mov dword [dkf_gy], FM_TOP
    mov eax, ecx                          ; columns
    xor edx, edx
    mov ecx, FM_CELL_W
    div ecx
    jmp .cols
.details:
    sub ecx, 2
    mov [dkf_cw], ecx
    mov dword [dkf_ch], DKF_ROW_H
    mov dword [dkf_gy], FM_TOP + DKF_HEAD_H
    mov eax, 1
.cols:
    cmp eax, 1
    jae .cols_ok
    mov eax, 1
.cols_ok:
    mov ebx, eax
    mov eax, [dkw_h + ebp*4]              ; rows
    sub eax, [dkf_gy]
    sub eax, 26
    jns .rows_room
    xor eax, eax
.rows_room:
    xor edx, edx
    div dword [dkf_ch]
    cmp eax, 1
    jae .rows
    mov eax, 1
.rows:
    mov ecx, [dkf_side_w]                 ; anything different?
    add ecx, [dkf_cw]
    movzx edx, byte [dkf_view]
    add ecx, edx
    cmp ecx, [dkf_sig]
    jne .changed
    cmp ebx, [dk_fm_cols]
    jne .changed
    cmp eax, [dk_fm_rows]
    je .done
.changed:
    mov [dkf_sig], ecx
    mov [dk_fm_cols], ebx
    mov [dk_fm_rows], eax
    imul eax, ebx
    mov [dk_fm_page_n], eax
    mov dword [dk_fm_page], 0             ; (from the first page again)
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; edi = a cell on the page -> eax, ebx = its corner in the client area,
; ecx, edx = its size
dkf_cell:
    push edi
    mov eax, edi
    xor edx, edx
    div dword [dk_fm_cols]                ; eax = row, edx = column
    imul eax, [dkf_ch]
    add eax, [dkf_gy]
    mov ebx, eax
    mov eax, edx
    imul eax, [dkf_cw]
    add eax, [dkf_gx]
    mov ecx, [dkf_cw]
    mov edx, [dkf_ch]
    pop edi
    ret

; ecx, ebx = a point in the client area -> edx = the cell there, or -1
dkf_hit:
    push eax
    push ebx
    push ecx
    mov edx, -1
    sub ecx, [dkf_gx]
    js .done
    sub ebx, [dkf_gy]
    js .done
    mov eax, ebx
    xor edx, edx
    div dword [dkf_ch]
    cmp eax, [dk_fm_rows]
    jae .none
    mov ebx, eax
    imul ebx, [dk_fm_cols]
    mov eax, ecx
    xor edx, edx
    div dword [dkf_cw]
    cmp eax, [dk_fm_cols]
    jae .none
    lea edx, [ebx + eax]
    jmp .done
.none:
    mov edx, -1
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; Drawing (dk_draw_files, ebp = the window, dk_cx/dk_cy its client)
; ============================================================

; Before the cells: the places, Details' headings
dkf_draw_frame:
    pushad
    cmp dword [dkf_side_w], 0
    je .headings
    mov eax, [dk_cx]                      ; the pane, and its edge
    mov ebx, [dk_cy]
    add ebx, FM_TOP - 4
    mov ecx, DKF_SIDE_W - 2
    mov edx, [dkw_h + ebp*4]
    sub edx, FM_TOP - 4 + 24
    mov esi, COL_PANEL
    call dk_fill
    add eax, ecx
    mov ecx, 1
    mov esi, COL_FRAME
    call dk_fill
    call dkf_place_now                    ; -> ecx = the one we're in
    mov [dkf_here], ecx
    xor edi, edi
.place:
    cmp edi, DKF_PLACES
    jae .headings
    mov eax, [dk_cx]
    add eax, 4
    imul ebx, edi, DKF_PLACE_H
    add ebx, FM_TOP
    add ebx, [dk_cy]
    mov edx, COL_TEXT
    cmp edi, [dkf_here]
    jne .plain
    push ebx
    mov ecx, DKF_SIDE_W - 10
    mov edx, DKF_PLACE_H - 2
    mov esi, COL_TITLE_ON
    call dk_fill
    pop ebx
    mov edx, COL_WHITE
.plain:
    push edx
    add eax, 4                            ; its little icon
    add ebx, 3
    movzx ecx, byte [dkf_place_icons + edi]
    mov dword [dk_icon_fill], dk_fill
    call dka_icon_small
    add eax, 22
    add ebx, 1
    mov esi, [dkf_place_names + edi*4]
    pop edx
    call dk_text
    inc edi
    jmp .place
.headings:
    cmp byte [dkf_view], 0
    je .done
    mov eax, [dk_cx]                      ; the headings' strip
    add eax, [dkf_gx]
    mov ebx, [dk_cy]
    add ebx, FM_TOP
    mov ecx, [dkf_cw]
    mov edx, DKF_HEAD_H - 2
    mov esi, COL_BUTTON
    call dk_fill
    call dkf_columns                      ; -> dkf_c_*
    xor edi, edi
.head:
    cmp edi, 4
    jae .done
    mov eax, [dkf_c_x + edi*4]
    or eax, eax
    jz .head_next
    cmp eax, -1
    je .head_next
    add eax, [dk_cx]
    add eax, 6
    mov ebx, [dk_cy]
    add ebx, FM_TOP + 2
    mov esi, [dkf_head_names + edi*4]
    mov edx, COL_MUTED
    movzx ecx, byte [dkf_head_sort + edi]
    cmp ecx, [dk_fm_sort]
    jne .head_text
    mov edx, COL_TEXT
    push eax                              ; (the order it's in: underlined)
    push ebx
    add ebx, 16
    mov ecx, 40
    mov edx, 2
    mov esi, COL_TITLE_ON
    call dk_fill
    pop ebx
    pop eax
    mov esi, [dkf_head_names + edi*4]
    mov edx, COL_TEXT
.head_text:
    call dk_text
.head_next:
    inc edi
    jmp .head
.done:
    popad
    ret

; Details' columns, from the row's width: dkf_c_x = where each starts in
; the client (name, size, when, kind; -1: no room for it)
dkf_columns:
    push eax
    push ecx
    mov ecx, [dkf_cw]
    mov eax, [dkf_gx]
    mov [dkf_c_x], eax
    mov dword [dkf_c_x + 4], -1
    mov dword [dkf_c_x + 8], -1
    mov dword [dkf_c_x + 12], -1
    add eax, ecx                          ; from the right: the kind...
    cmp ecx, 440
    jb .no_kind
    sub eax, 70
    mov [dkf_c_x + 12], eax
.no_kind:
    cmp ecx, 340                          ; ...when...
    jb .no_date
    sub eax, 140
    mov [dkf_c_x + 8], eax
.no_date:
    cmp ecx, 220                          ; ...the size
    jb .no_size
    sub eax, 84
    mov [dkf_c_x + 4], eax
.no_size:
    pop ecx
    pop eax
    ret

; esi = an entry -> esi = the name to show: its long one, if it has
; one (src/fslong.asm - from the slots' cache: nothing else touched)
dkf_disp:
    cmp byte [esi + 17], IC_UP
    je .as_is
    push eax
    push esi
    movzx eax, word [esi + 20]
    call fsl_peek                         ; -> esi
    jc .none
    add esp, 4
    pop eax
    ret
.none:
    pop esi
    pop eax
.as_is:
    ret

; esi = a name longer than a cell's line: two lines under the icon
; (dk_fm_cell_x/_y), broken at a space if there's one near, ".." at the
; end if it's longer still; dkf_selected: lit
dkf_two_lines:
    pushad
    mov ebx, 11                           ; the first line: to the last
.space:                                   ; space in 6..11 (dropped)...
    cmp byte [esi + ebx], ' '
    je .at_space
    dec ebx
    cmp ebx, 6
    jae .space
    mov ebx, 11                           ; ...or 11 of it
    mov edx, ebx
    jmp .split
.at_space:
    lea edx, [ebx + 1]
.split:
    mov edi, dkf_lines                    ; line 1
    mov ecx, ebx
    push esi
    rep movsb
    mov byte [edi], 0
    pop esi
    add esi, edx                          ; line 2: 11 at most, ".." if
    mov edi, dkf_lines + 12               ; there's more
    mov ecx, 11
.second:
    lodsb
    stosb
    or al, al
    jz .second_done
    loop .second
    mov byte [edi], 0
    cmp byte [esi], 0
    je .second_done
    mov word [edi - 2], '..'
.second_done:
    mov esi, dkf_lines
    mov ebx, [dk_fm_cell_y]
    add ebx, 42
    call dkf_label_line
    mov esi, dkf_lines + 12
    add ebx, 15
    call dkf_label_line
    popad
    ret

; esi = a line, ebx = its y: centered under the cell's icon
dkf_label_line:
    pushad
    call dki_strlen
    mov eax, FM_CELL_W
    mov edi, ecx
    shl edi, 3
    sub eax, edi
    shr eax, 1
    add eax, [dk_fm_cell_x]
    mov edi, ecx
    mov edx, COL_TEXT
    cmp byte [dkf_selected], 0
    je .ink
    push eax
    push ebx
    push ecx
    push esi
    sub eax, 2
    shl ecx, 3
    add ecx, 4
    mov edx, 15
    mov esi, COL_TITLE_ON
    call dk_fill
    pop esi
    pop ecx
    pop ebx
    pop eax
    mov edx, COL_WHITE
.ink:
    call dk_text_raw
    popad
    ret

dkf_lines        times 2 * 11 + 4 db 0

; eax = an entry, edi = its cell on the page: drawn
dkf_draw_cell:
    pushad
    mov edx, eax                          ; edx = the entry's index
    mov esi, eax
    shl esi, 5
    add esi, DESK_FILES
    push edx
    call dkf_cell                         ; -> eax, ebx (client)
    pop edx
    add eax, [dk_cx]
    add ebx, [dk_cy]
    mov [dk_fm_cell_x], eax
    mov [dk_fm_cell_y], ebx
    mov ebx, edx
    call dk_sel_test                      ; carry=0: selected
    setnc [dkf_selected]
    cmp byte [dkf_view], 0
    jne .row
    ; Icons: the icon (or its thumbnail), centered, the name below
    mov eax, [dk_fm_cell_x]
    mov ebx, [dk_fm_cell_y]
    call dkf_thumb_draw                   ; a picture: carry=0 if drawn
    jnc .named
    add eax, (FM_CELL_W - 32) / 2
    add ebx, 6
    call dka_entry_kind                   ; -> ecx (its own, or chosen)
    mov dword [dk_icon_fill], dk_fill
    call dk_icon
    call dka_badge                        ; (a shortcut: its mark)
.named:
    call dkf_disp                         ; (its long name: src/fslong.asm)
    call dki_strlen                       ; the name: 11 at most
    cmp ecx, 11
    jbe .len
    call dkf_two_lines                    ; (longer: two lines)
    jmp .done
.len:
    mov eax, FM_CELL_W
    mov edi, ecx
    shl edi, 3
    sub eax, edi
    shr eax, 1
    add eax, [dk_fm_cell_x]
    mov ebx, [dk_fm_cell_y]
    add ebx, 44
    mov edi, ecx
    mov edx, COL_TEXT
    cmp byte [dkf_selected], 0
    je .icon_name
    push eax
    push ebx
    push ecx
    push esi
    sub eax, 2
    shl ecx, 3
    add ecx, 4
    mov edx, 16
    mov esi, COL_TITLE_ON
    call dk_fill
    pop esi
    pop ecx
    pop ebx
    pop eax
    mov edx, COL_WHITE
.icon_name:
    call dk_text_raw
    jmp .done
.row:
    ; Details: a row - selected, it's lit across
    mov edx, COL_TEXT
    cmp byte [dkf_selected], 0
    je .row_plain
    mov eax, [dk_fm_cell_x]
    mov ebx, [dk_fm_cell_y]
    mov ecx, [dkf_cw]
    mov edx, DKF_ROW_H - 1
    push esi
    mov esi, COL_TITLE_ON
    call dk_fill
    pop esi
    mov edx, COL_WHITE
.row_plain:
    mov [dkf_row_col], edx
    call dkf_columns
    mov eax, [dk_fm_cell_x]               ; the small icon
    add eax, 4
    mov ebx, [dk_fm_cell_y]
    add ebx, 3
    call dka_entry_kind
    mov dword [dk_icon_fill], dk_fill
    call dka_icon_small
    mov eax, [dk_fm_cell_x]               ; the name, to the next column
    add eax, 26
    mov ebx, [dk_fm_cell_y]
    add ebx, 3
    mov edi, [dkf_c_x + 4]
    cmp edi, -1
    jne .name_room
    mov edi, [dkf_gx]
    add edi, [dkf_cw]
.name_room:
    sub edi, [dkf_gx]
    sub edi, 30
    shr edi, 3
    mov edx, [dkf_row_col]
    push esi
    call dkf_disp
    call dk_text_raw
    pop esi
    ; the size (not a folder's)
    mov ecx, [dkf_c_x + 4]
    cmp ecx, -1
    je .date
    movzx eax, byte [esi + 17]
    cmp eax, IC_FOLDER
    je .date
    cmp eax, IC_UP
    je .date
    mov eax, [esi + 24]
    mov edi, dkf_buf
    call dkf_size_text
    mov byte [edi], 0
    push esi
    mov esi, dkf_buf                      ; right-aligned in its column
    call dki_strlen
    mov eax, [dkf_c_x + 4]
    add eax, 76
    shl ecx, 3
    sub eax, ecx
    add eax, [dk_cx]
    mov ebx, [dk_fm_cell_y]
    add ebx, 3
    mov edx, [dkf_row_col]
    mov edi, 12
    call dk_text_raw
    pop esi
.date:
    mov ecx, [dkf_c_x + 8]
    cmp ecx, -1
    je .kind
    cmp byte [esi + 17], IC_UP
    je .kind
    mov eax, [esi + 28]
    or eax, eax
    jz .kind
    mov edi, dkf_buf
    call dkf_date_text
    mov byte [edi], 0
    push esi
    mov esi, dkf_buf
    mov eax, [dkf_c_x + 8]
    add eax, 6
    add eax, [dk_cx]
    mov ebx, [dk_fm_cell_y]
    add ebx, 3
    mov edx, [dkf_row_col]
    mov edi, 16
    call dk_text_raw
    pop esi
.kind:
    mov ecx, [dkf_c_x + 12]
    cmp ecx, -1
    je .done
    cmp byte [esi + 17], IC_UP
    je .done
    push esi
    mov edi, dkf_buf
    cmp byte [esi + 17], IC_FOLDER
    jne .ext
    mov esi, dkf_l_folder
    call tr_lookup
    call wget_append
    jmp .kind_said
.ext:
    call dk_ext_dword                     ; its extension, or "File"
    or eax, eax
    jz .plain_file
    cmp eax, -1
    je .plain_file
    mov [edi], eax
    mov byte [edi + 4], 0
    mov esi, edi
    call dki_strlen
    add edi, ecx
    jmp .kind_said
.plain_file:
    mov esi, dkf_l_file
    call tr_lookup
    call wget_append
.kind_said:
    mov byte [edi], 0
    mov esi, dkf_buf
    mov eax, [dkf_c_x + 12]
    add eax, 6
    add eax, [dk_cx]
    mov ebx, [dk_fm_cell_y]
    add ebx, 3
    mov edx, [dkf_row_col]
    cmp edx, COL_WHITE
    je .kind_col
    mov edx, COL_MUTED
.kind_col:
    mov edi, 8
    call dk_text_raw
    pop esi
.done:
    popad
    ret

; eax = bytes -> at edi: "512 B", "12 KB", "3.4 MB"
dkf_size_text:
    push eax
    push ecx
    push edx
    push esi
    cmp eax, 1024
    jae .kb
    call wget_append_num
    mov esi, dkf_l_b
    jmp .unit
.kb:
    cmp eax, 1024 * 1024
    jae .mb
    add eax, 1023
    shr eax, 10
    call wget_append_num
    mov esi, dkf_l_kb
    jmp .unit
.mb:
    mov ecx, eax                          ; whole MB, a tenth
    shr eax, 20
    call wget_append_num
    mov al, '.'
    stosb
    mov eax, ecx
    and eax, 0xFFFFF
    imul eax, eax, 10
    shr eax, 20
    add al, '0'
    stosb
    mov esi, dkf_l_mb
.unit:
    call wget_append
    pop esi
    pop edx
    pop ecx
    pop eax
    ret

; eax = a date as dkf_entry_extra keeps it -> at edi: "27.09.2026 14:05"
; (the hour in the user's timezone, as Properties shows it)
dkf_date_text:
    push eax
    push ebx
    push edx
    mov ebx, eax
    shr eax, 11                           ; the day
    and eax, 31
    call dkf_two
    mov al, '.'
    stosb
    mov eax, ebx                          ; the month
    shr eax, 16
    and eax, 15
    call dkf_two
    mov eax, '.20'
    stosd
    dec edi
    mov eax, ebx                          ; the year
    shr eax, 20
    and eax, 0xFF
    call dkf_two
    mov al, ' '
    stosb
    mov eax, ebx                          ; the hour
    shr eax, 6
    and eax, 31
    movsx edx, word [user_tz_offset]
    add eax, edx
    add eax, 24
.hour:
    cmp eax, 24
    jl .hour_ok
    sub eax, 24
    jmp .hour
.hour_ok:
    call dkf_two
    mov al, ':'
    stosb
    mov eax, ebx
    and eax, 63
    call dkf_two
    pop edx
    pop ebx
    pop eax
    ret

; eax = 0..99 -> two digits at edi
dkf_two:
    push edx
    push ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    stosb
    mov al, dl
    add al, '0'
    stosb
    pop ecx
    pop edx
    ret

; The toolbar's view button (dk_fm_draw_tools, ebp = the window, edx =
; how far left the tools are): a list (Details next) or a grid (Icons)
dkf_draw_viewbtn:
    pushad
    mov eax, [dk_cx]
    add eax, FM_SORT_X + FM_SORT_W + 4
    sub eax, edx
    mov ebx, [dk_cy]
    add ebx, 4
    mov ecx, DKF_VIEW_W
    mov edx, 22
    mov esi, COL_BUTTON
    call dk_fill
    add eax, 8
    add ebx, 5
    mov esi, COL_TEXT
    cmp byte [dkf_view], 0
    jne .grid
    mov edi, 3                            ; three lines, a dot before each
.line:
    mov ecx, 2
    mov edx, 2
    call dk_fill
    add eax, 4
    mov ecx, 10
    call dk_fill
    sub eax, 4
    add ebx, 4
    dec edi
    jnz .line
    jmp .done
.grid:
    mov ecx, 6                            ; four squares
    mov edx, 5
    call dk_fill
    add eax, 8
    call dk_fill
    add ebx, 7
    call dk_fill
    sub eax, 8
    call dk_fill
.done:
    popad
    ret

; ============================================================
; Clicks (dk_files_click: eax = the window, ecx, ebx = where in its
; client area) - carry=0 if it was one of these
; ============================================================
dkf_click:
    pushad
    mov ebp, eax
    cmp ebx, FM_TOP - 4                   ; the toolbar: the view button?
    jae .below
    push edx
    call dk_fm_shift                      ; -> edx
    mov eax, FM_SORT_X + FM_SORT_W + 4
    sub eax, edx
    pop edx
    cmp ecx, eax
    jb .no
    add eax, DKF_VIEW_W
    cmp ecx, eax
    jae .no
    xor byte [dkf_view], 1
    call snd_click
    mov byte [dk_redraw_all], 1
    jmp .yes
.below:
    cmp ecx, [dkf_side_w]                 ; the places
    jae .heading
    mov eax, ebx
    sub eax, FM_TOP
    js .yes
    xor edx, edx
    mov ecx, DKF_PLACE_H
    div ecx
    cmp eax, DKF_PLACES
    jae .yes
    call dkf_go_place
    call snd_click
    jmp .yes
.heading:
    cmp byte [dkf_view], 0                ; Details' headings: sort by it
    je .no
    cmp ebx, FM_TOP + DKF_HEAD_H
    jae .no
    call dkf_columns
    mov edi, 3
.col:
    mov eax, [dkf_c_x + edi*4]
    cmp eax, -1
    je .col_next
    cmp ecx, eax
    jae .col_hit
.col_next:
    dec edi
    jns .col
    jmp .yes
.col_hit:
    movzx eax, byte [dkf_head_sort + edi]
    mov [dk_fm_sort], eax
    mov byte [dk_fm_refresh], 1
    call snd_click
    mov byte [dk_redraw_all], 1
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; -> ecx = the place Files is showing (-1: none of them)
dkf_place_now:
    push esi
    push edi
    mov ecx, 2
    cmp byte [dkf_recent], 0
    jne .done
    xor ecx, ecx
.each:
    cmp ecx, DKF_PLACES
    jae .none
    mov esi, [dkf_place_paths + ecx*4]
    or esi, esi
    jz .next
    mov edi, dk_fm_path
    call dkx_str_eq
    je .done
.next:
    inc ecx
    jmp .each
.none:
    mov ecx, -1
.done:
    pop edi
    pop esi
    ret

; eax = a place: Files goes there
dkf_go_place:
    pushad
    cmp eax, 2
    je .recent
    mov esi, [dkf_place_paths + eax*4]
    call dkf_go
    jmp .done
.recent:
    mov byte [dkf_recent], 1
    mov esi, dkf_l_recent
    call tr_lookup
    mov edi, dk_fm_path
    call dki_copy
    call dkf_fresh
.done:
    popad
    ret

; esi = a folder's path: Files shows it (carry=1: there's no such folder)
dkf_go:
    pushad
    call dk_shell_idle                    ; (the disk: not while a console's
    jc .busy                              ;  task is in the kernel)
    cmp word [esi], '/'
    je .root
    push esi
    call dki_resolve                      ; -> eax
    pop esi
    cmp eax, -1
    je .none
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .none
    mov [dk_fm_dir], al
    jmp .path
.root:
    mov byte [dk_fm_dir], FS_ROOT_BYTE
.path:
    mov byte [dkf_recent], 0
    mov edi, dk_fm_path
    call dki_copy
    call dkf_fresh
    popad
    clc
    ret
.busy:
    mov dword [dk_fm_msg], dk_fm_busy
    mov byte [dk_redraw_all], 1
    popad
    stc
    ret
.none:
    mov dword [dk_fm_msg], dkf_m_nofolder
    mov byte [dk_redraw_all], 1
    popad
    stc
    ret

; Another folder shown: from its start, nothing selected, no search
dkf_fresh:
    mov dword [dk_fm_page], 0
    mov dword [dk_fm_sel], -1
    mov byte [dk_fm_refresh], 1
    mov dword [dk_fm_find_len], 0
    mov byte [dk_fm_find], 0
    mov byte [dk_redraw_all], 1
    ret

; ============================================================
; Recent: what was opened lately (dk_launch, Pictures), newest first
; ============================================================

; esi = a name, edi = its folder: at the top of the list
dkf_rec_add:
    cmp byte [dkx_st_launching], 0        ; (STARTUP's: not chosen)
    jne .skip
    pushad
    mov [dkf_r_name], esi
    mov [dkf_r_path], edi
    xor ebx, ebx                          ; already there: out of its place
.find:
    cmp ebx, [dkf_rec_n]
    jae .insert
    imul edi, ebx, DKF_REC_SIZE
    add edi, dkf_rec
    mov esi, [dkf_r_name]
    call dkx_str_eq
    jne .next
    add edi, 16
    mov esi, [dkf_r_path]
    call dkx_str_eq
    je .remove
.next:
    inc ebx
    jmp .find
.remove:
    lea ecx, [ebx + 1]                    ; the ones after it, up one
.up:
    cmp ecx, [dkf_rec_n]
    jae .removed
    imul esi, ecx, DKF_REC_SIZE
    add esi, dkf_rec
    lea edi, [esi - DKF_REC_SIZE]
    push ecx
    mov ecx, DKF_REC_SIZE
    cld
    rep movsb
    pop ecx
    inc ecx
    jmp .up
.removed:
    dec dword [dkf_rec_n]
.insert:
    mov ebx, DKF_REC_MAX - 1              ; the others one down
.down:
    or ebx, ebx
    jz .put
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec - DKF_REC_SIZE
    lea edi, [esi + DKF_REC_SIZE]
    mov ecx, DKF_REC_SIZE
    cld
    rep movsb
    dec ebx
    jmp .down
.put:
    mov esi, [dkf_r_name]
    mov edi, dkf_rec
    mov ecx, 15
    call dkx_copy_n
    mov esi, [dkf_r_path]
    mov edi, dkf_rec + 16
    mov ecx, 31
    call dkx_copy_n
    cmp dword [dkf_rec_n], DKF_REC_MAX
    jae .counted
    inc dword [dkf_rec_n]
.counted:
    mov byte [dk_cfg_dirty], 1
    popad
.skip:
    ret

; dk_files_refresh: in Recent, its entries (what's still there) instead
; of a folder's -> edx = how many, carry=0; carry=1: not in Recent
dkf_refresh:
    cmp byte [dkf_recent], 0
    jne .recent
    stc
    ret
.recent:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    xor edx, edx
    xor ebx, ebx
    mov edi, DESK_FILES
.each:
    cmp ebx, [dkf_rec_n]
    jae .listed
    call dkf_rec_path                     ; -> dkf_path
    push edx
    mov esi, dkf_path
    call dki_resolve                      ; -> eax (the slot in scratch)
    pop edx
    cmp eax, -1
    je .next
    push eax
    mov esi, SCRATCH_ADDR                 ; the name
    push edi
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [edi], 0
    pop edi
    pop eax
    mov [edi + 20], ax
    mov [edi + 19], bl                    ; (which recent one)
    mov byte [edi + 17], IC_FOLDER
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .kind_set
    push esi
    mov esi, edi
    call dk_name_kind
    pop esi
    mov [edi + 17], al
.kind_set:
    call fs_get_size
    mov [edi + 24], eax
    movzx eax, word [edi + 20]            ; (its slot again, for the rest)
    call fs_read_slot
    call dka_entry_look
    add edi, FM_ENTRY
    inc edx
.next:
    inc ebx
    jmp .each
.listed:
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    clc
    ret

; ebx = a recent one -> dkf_path = its folder's path, "/", its name
dkf_rec_path:
    push eax
    push esi
    push edi
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec + 16
    mov edi, dkf_path
    call dki_copy
    dec edi                               ; (at its 0)
    cmp byte [edi - 1], '/'               ; (the root: no second "/")
    je .name
    mov byte [edi], '/'
    inc edi
.name:
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec
    call dki_copy
    pop edi
    pop esi
    pop eax
    ret

; dk_files_open (eax = an entry): in Recent, it's opened where it is -
; carry=0 if done here
dkf_open:
    cmp byte [dkf_recent], 0
    jne .recent
    stc
    ret
.recent:
    pushad
    mov esi, eax
    shl esi, 5
    add esi, DESK_FILES
    movzx ebx, byte [esi + 19]            ; which recent one
    cmp ebx, [dkf_rec_n]
    jae .done
    cmp byte [esi + 17], IC_FOLDER        ; a folder: Files goes into it
    jne .file
    call dkf_rec_path
    mov esi, dkf_path
    call dkf_go
    jmp .done
.file:
    ; a file: opened as Files opens it, from its own folder - the path
    ; and the folder swapped in for it, then back
    mov [dkf_open_idx], eax
    mov esi, dk_fm_path
    mov edi, dkf_save_path
    call dki_copy
    mov al, [dk_fm_dir]
    mov [dkf_save_dir], al
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec + 16
    mov edi, dk_fm_path
    call dki_copy
    mov byte [dk_fm_dir], FS_ROOT_BYTE
    cmp word [dk_fm_path], '/'
    je .go
    mov esi, dk_fm_path
    call dki_resolve                      ; -> eax
    cmp eax, -1
    je .back
    mov [dk_fm_dir], al
.go:
    mov byte [dkf_recent], 0
    mov eax, [dkf_open_idx]
    call dk_files_open
    mov byte [dkf_recent], 1
.back:
    mov esi, dkf_save_path
    mov edi, dk_fm_path
    call dki_copy
    mov al, [dkf_save_dir]
    mov [dk_fm_dir], al
    mov byte [dk_fm_refresh], 1
.done:
    popad
    clc
    ret

; dk_files_up: out of Recent - to the root
dkf_up:
    cmp byte [dkf_recent], 0
    jne .recent
    stc
    ret
.recent:
    push esi
    mov esi, dkf_root
    call dkf_go
    pop esi
    clc
    ret

; dk_right_click, over Files (edx: the entry under the pointer, or -1):
; in Recent, only Open and Open its folder - carry=0 if the menu's done
; here (dk_ctx_n: 0 - nothing to show)
dkf_ctx_items:
    cmp byte [dkf_recent], 0
    jne .recent
    stc
    ret
.recent:
    pushad
    cmp edx, -1
    je .done
    mov ebx, edx
    mov [dk_fm_sel], ebx
    call dk_sel_clear
    call dk_sel_set
    mov al, DKC_OPEN
    call dk_ctx_add
    mov al, DKC_LOCATE
    call dk_ctx_add
.done:
    popad
    clc
    ret

; Open its folder (Recent's menu): Files shows where it is
dkf_locate:
    pushad
    mov esi, [dk_fm_sel]
    cmp esi, -1
    je .done
    shl esi, 5
    movzx ebx, byte [DESK_FILES + esi + 19]
    cmp ebx, [dkf_rec_n]
    jae .done
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec + 16
    mov edi, dkf_path
    call dki_copy
    mov esi, dkf_path
    call dkf_go
.done:
    popad
    ret

; ============================================================
; Thumbnails
; ============================================================

; eax, ebx = a cell's corner, esi = its entry: a .BMP's thumbnail drawn
; there (carry=0), or carry=1 (not a picture - or not made yet: then
; it's asked for)
dkf_thumb_draw:
    pushad
    cmp byte [esi + 17], IC_IMAGE
    jne .no
    cmp byte [esi + 18], 0                ; (an icon chosen for it: that)
    jne .no
    push eax
    call dk_ext_dword
    cmp eax, 'BMP'
    je .picture
    cmp eax, 'PNG'
.picture:
    pop eax
    jne .no
    mov [dkf_tx], eax
    mov [dkf_ty], ebx
    call dkf_thumb_find                   ; -> edi, carry=1: none
    jc .want
    cmp byte [edi + 2], 1                 ; (2: it couldn't be read)
    jne .no
    movzx ecx, byte [edi + 3]             ; its size
    movzx edx, byte [edi + 12]
    mov eax, FM_CELL_W                    ; centered over the name
    sub eax, ecx
    shr eax, 1
    add eax, [dkf_tx]
    mov ebx, DKF_THUMB
    sub ebx, edx
    shr ebx, 1
    add ebx, [dkf_ty]
    add ebx, 2
    push eax                              ; a frame round it
    push ebx
    push ecx
    push edx
    dec eax
    dec ebx
    add ecx, 2
    add edx, 2
    mov esi, COL_FRAME
    call dk_fill
    pop edx
    pop ecx
    pop ebx
    pop eax
    lea esi, [edi + 16]
    call dkf_blit
    popad
    clc
    ret
.want:
    cmp dword [dkf_th_want], -1           ; (one at a time)
    jne .no
    movzx eax, word [esi + 20]
    mov [dkf_th_want], eax
    mov eax, [esi + 24]
    mov [dkf_th_want_size], eax
    mov eax, [esi + 28]
    mov [dkf_th_want_date], eax
.no:
    popad
    stc
    ret

; esi = an entry -> edi = its thumbnail (carry=0), carry=1 if none yet
dkf_thumb_find:
    push eax
    push ecx
    push edx
    movzx eax, word [esi + 20]
    mov edi, DKF_THUMBS
    xor ecx, ecx
.each:
    cmp ecx, [dkf_th_used]
    jae .none
    cmp [edi], ax
    jne .next
    mov edx, [esi + 24]
    cmp [edi + 4], edx
    jne .next
    mov edx, [esi + 28]
    cmp [edi + 8], edx
    jne .next
    pop edx
    pop ecx
    pop eax
    clc
    ret
.next:
    add edi, DKF_TH_SIZE
    inc ecx
    jmp .each
.none:
    pop edx
    pop ecx
    pop eax
    stc
    ret

; esi = pixels (DKF_THUMB to a row), eax, ebx = where, ecx, edx = how
; big: into the back buffer, inside the clip rectangle
dkf_blit:
    pushad
    mov [dkf_bw], ecx
    add ecx, eax
    add edx, ebx
    mov [dkf_bx0], eax
    mov [dkf_by0], ebx
    call dk_clip_box                      ; -> eax..edx clipped
    jc .done
    mov ebp, ebx                          ; each row
.row:
    cmp ebp, edx
    jae .done
    push esi
    push ecx
    mov edi, ebp
    sub edi, [dkf_by0]
    imul edi, DKF_THUMB * 4
    add esi, edi
    mov edi, eax
    sub edi, [dkf_bx0]
    lea esi, [esi + edi*4]
    mov edi, ebp
    imul edi, [dk_stride]
    lea edi, [edi + eax*4]
    add edi, [dk_back]
    sub ecx, eax
    cld
    rep movsd
    pop ecx
    pop esi
    inc ebp
    jmp .row
.done:
    popad
    ret

; Each frame (the desktop's task): the thumbnail asked for, made - its
; file read (into DESK_IMG_FILE, when no screenshot's there), shrunk
dkf_thumb_work:
    pushad
    cmp dword [dkf_th_want], -1
    je .done
    cmp byte [dk_shot_ready], 0           ; (a screenshot's in the buffer,
    jne .done                             ;  or the wallpaper's file)
    cmp byte [dkw_busy], 0
    jne .done
    cmp byte [dkw_pending], 0
    jne .done
    cmp byte [dk_pic_state], 1            ; (Pictures about to use it)
    je .done
    pushfd
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    mov edi, [dkf_th_next]                ; the place: the next one round
    imul edi, edi, DKF_TH_SIZE
    add edi, DKF_THUMBS
    mov [dkf_th_at], edi
    inc dword [dkf_th_next]
    cmp dword [dkf_th_next], DKF_TH_N
    jb .placed
    mov dword [dkf_th_next], 0
.placed:
    mov eax, [dkf_th_used]
    cmp eax, DKF_TH_N
    jae .counted
    inc dword [dkf_th_used]
.counted:
    mov eax, [dkf_th_want]
    mov [edi], ax
    mov byte [edi + 2], 2                 ; (couldn't be read - unless...)
    mov ecx, [dkf_th_want_size]
    mov [edi + 4], ecx
    mov ecx, [dkf_th_want_date]
    mov [edi + 8], ecx
    cmp dword [dkf_th_want_size], DESK_IMG_FILE_MAX
    ja .made                              ; (too big to read in)
    mov edi, DESK_IMG_FILE
    mov ecx, DESK_IMG_FILE_MAX
    call fs_load_to                       ; -> ecx bytes
    mov eax, 160                          ; (a PNG: a small BMP - src/dkpng.asm)
    mov ebx, 160
    call dkpng_convert
    jc .made
    mov esi, DESK_IMG_FILE
    call dkb_open                         ; (src/dkwall.asm) -> dkb_*
    jc .made
    mov edi, [dkf_th_at]                  ; fitted into 40x40
    mov eax, [dkb_w]
    mov ebx, [dkb_h]
    mov ecx, DKF_THUMB
    mov edx, DKF_THUMB
    call dkb_fit                          ; -> ecx, edx
    mov [edi + 3], cl
    mov [edi + 12], dl
    lea edi, [edi + 16]
    mov eax, DKF_THUMB * 4
    call dkb_scale                        ; ecx x edx at edi, rows eax apart
    mov edi, [dkf_th_at]
    mov byte [edi + 2], 1
.made:
    mov dword [dkf_th_want], -1
    mov dword [bkl_owner], -1
    mov eax, K_FILES
    call dk_mark_kind
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; dka_entry_look's more (dk_files_refresh, edi = an entry, its slot in
; scratch): when it last changed - yy mm dd hh mi, packed to compare
dkf_entry_extra:
    push eax
    push ebx
    movzx eax, byte [SCRATCH_ADDR + FS_MTIME_OFFSET]
    shl eax, 20
    movzx ebx, byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 1]
    and ebx, 15
    shl ebx, 16
    or eax, ebx
    movzx ebx, byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 2]
    and ebx, 31
    shl ebx, 11
    or eax, ebx
    movzx ebx, byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 3]
    and ebx, 31
    shl ebx, 6
    or eax, ebx
    movzx ebx, byte [SCRATCH_ADDR + FS_MTIME_OFFSET + 4]
    and ebx, 63
    or eax, ebx
    mov [edi + 28], eax
    pop ebx
    pop eax
    ret

; ============================================================
; DESKTOP.CFG: the Recent list ("file=NAME,FOLDER") and the wallpaper
; ============================================================

; dk_settings_work (edi = where the text's got to): our lines
dkf_cfg_save:
    push eax
    push ebx
    push esi
    call dkw_cfg_save                     ; (src/dkwall.asm: "wallpaper=")
    call dkc_cfg_save                     ; (src/dkcpanel.asm: the mouse...)
    mov ebx, [dkf_rec_n]                  ; (oldest first: added back in
.each:                                    ;  order when it's read)
    dec ebx
    js .done
    mov esi, dkf_cfg_file
    call wget_append
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec
    call wget_append
    mov al, ','
    stosb
    imul esi, ebx, DKF_REC_SIZE
    add esi, dkf_rec + 16
    call wget_append
    mov ax, 0x0A0D
    stosw
    jmp .each
.done:
    pop esi
    pop ebx
    pop eax
    ret

; dk_settings_load, dk_cfg_buf read: our lines back
dkf_cfg_load:
    pushad
    mov byte [dkw_on], 0                  ; (another user's: none till read)
    mov byte [dkw_loaded], 0
    call dkw_cfg_load
    call dkc_cfg_load
    mov dword [dkf_rec_n], 0
    mov esi, dk_cfg_buf
.line:
    cmp byte [esi], 0
    je .done
    mov edi, dkf_cfg_file
    xor ecx, ecx
.key:
    mov al, [edi + ecx]
    or al, al
    jz .found
    cmp al, [esi + ecx]
    jne .skip
    inc ecx
    jmp .key
.found:
    add esi, ecx
    mov edi, dkf_r_buf                    ; the name, to the comma
    mov ecx, 15
.name:
    lodsb
    cmp al, ','
    je .named
    cmp al, 13
    jbe .skip_back
    stosb
    loop .name
    jmp .skip
.named:
    mov byte [edi], 0
    mov edi, dkf_r_buf + 16               ; the folder, to the line's end
    mov ecx, 31
.path:
    mov al, [esi]
    cmp al, 13
    jbe .pathed
    stosb
    inc esi
    loop .path
.pathed:
    mov byte [edi], 0
    push esi
    mov esi, dkf_r_buf
    mov edi, dkf_r_buf + 16
    call dkf_rec_add
    pop esi
    jmp .skip
.skip_back:
    dec esi
.skip:
    mov al, [esi]
    or al, al
    jz .done
    inc esi
    cmp al, 10
    jne .skip
    jmp .line
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
dkf_view         db 0                     ; 0 Icons, 1 Details
dkf_recent       db 0                     ; showing Recent
dkf_selected     db 0
dkf_side_w       dd 0
dkf_gx           dd 4
dkf_gy           dd FM_TOP
dkf_cw           dd FM_CELL_W
dkf_ch           dd FM_CELL_H
dkf_sig          dd 0
dkf_here         dd -1
dkf_row_col      dd 0
dkf_c_x          dd 0, 0, 0, 0
dkf_tx           dd 0
dkf_ty           dd 0
dkf_bw           dd 0
dkf_bx0          dd 0
dkf_by0          dd 0
dkf_th_want      dd -1
dkf_th_want_size dd 0
dkf_th_want_date dd 0
dkf_th_used      dd 0
dkf_th_next      dd 0
dkf_th_at        dd 0
dkf_rec_n        dd 0
dkf_open_idx     dd 0
dkf_save_dir     db 0
dkf_save_path    times 128 db 0
dkf_r_name       dd 0
dkf_r_path       dd 0
dkf_rec          times DKF_REC_MAX * DKF_REC_SIZE db 0
dkf_r_buf        times DKF_REC_SIZE db 0
dkf_path         times 64 db 0
dkf_name         times 20 db 0
dkf_buf          times 40 db 0
dkf_root         db "/", 0
dkf_cfg_file     db "file=", 0
dkf_place_names  dd dkf_l_desktop, dkf_l_programs, dkf_l_recent, dkf_l_trash, dkf_l_disk
dkf_place_paths  dd dkf_p_desktop, dkf_p_programs, 0, dkf_p_trash, dkf_root
dkf_place_icons  db IC_DESK, IC_APP, IC_STAR, IC_TRASH, IC_DISK
dkf_p_desktop    db "/DESKTOP", 0
dkf_p_programs   db "/APPS", 0
dkf_p_trash      db "/TRASH", 0
dkf_l_desktop    db "Desktop", 0
dkf_l_programs   db "Programs", 0
dkf_l_recent     db "Recent", 0
dkf_l_trash      db "Trash", 0
dkf_l_disk       db "This disk", 0
dkf_head_names   dd dkf_l_name, dkf_l_size, dkf_l_date, dkf_l_kind
dkf_head_sort    db 0, 1, 3, 2            ; (dk_fm_sort for each)
dkf_l_name       db "Name", 0
dkf_l_size       db "Size", 0
dkf_l_date       db "Modified", 0
dkf_l_kind       db "Type", 0
dkf_l_folder     db "Folder", 0
dkf_l_file       db "File", 0
dkf_l_b          db " B", 0
dkf_l_kb         db " KB", 0
dkf_l_mb         db " MB", 0
dkf_l_locate     db "Open its folder", 0
dkf_m_nofolder   db "That folder isn't there.", 0
