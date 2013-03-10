; Inputs:
;   DE: File name
; Outputs:
; (Failure)
;   A: Error code
;   Z: Reset
; (Success)
;   D: File stream ID
;   E: Garbage    
openFileRead:
    push hl
    push de
    push bc
    push af
    ld a, i
    push af
        di
        call findFileEntry
        ex de, hl
        jr nz, .notFound
        ; Create stream based on file entry
        out (6), a
        ld a, (activeFileStreams)
        cp maxFileStreams
        jr nc, .tooManyStreams
        inc a \ ld (activeFileStreams), a
        ld hl, fileHandleTable
        ; Search for open slot
        ld b, 0
_:      ld a, (hl)
        cp 0xFF
        jr z, _
        push bc
            ld bc, 8
            add hl, bc
        pop bc
        inc b
        jr -_
_:      push bc
            ; HL points to next entry in table
            call getCurrentThreadId
            ld (hl), a ; Flags/owner (no need to set readable flag, it should be zero)
            inc hl \ inc hl \ inc hl ; Skip buffer address
            ex de, hl
            ; Seek HL to file size in file entry
            ld bc, 7
            or a \ sbc hl, bc
            ; Do some logic with the file size and save it for later
            ld a, (hl) \ inc hl \ or a \ ld a, (hl)
            push af
                dec hl \ dec hl \ dec hl ; Seek HL to block address
                ; Write block address to table
                ld c, (hl) \ dec hl \ ld b, (hl)
                ex de, hl
                ld (hl), c \ inc hl \ ld (hl), b \ inc hl
                ; Flash address always starts as zero
                ld (hl), 0 \ inc hl
            pop af
            ; Write the size of the final block
            inc hl \ ld (hl), a \ dec hl
            ; Get the size of this block in A
            jr z, _
            ld a, $FF
_:          ; A is block size
            ld (hl), a
        pop bc
        ld d, b
    pop af
    jp po, _
    ei
_:  pop af
    pop bc
    inc sp \ inc sp ; Don't pop de
    pop hl
    cp a
    ret
.tooManyStreams:
    pop af
    jp po, _
    ei
_:  pop af
    pop bc
    pop de
    pop hl
    or 1
    ld a, errTooManyStreams
    ret
.notFound:
    pop af
    jp po, _
    ei
_:  pop af
    pop bc
    pop de
    pop hl
    or 1
    ld a, errFileNotFound
    ret

; Inputs:
;   D: Stream ID
; Outputs:
; (Failure)
;   A: Error code
;   Z: Reset
; (Success)
;   HL: Pointer to entry
getStreamEntry:
    push af
    push hl
    push bc
        ld a, d
        cp maxFileStreams
        jr nc, .notFound
        or a \ rla \ rla \ rla ; A *= 8
        ld hl, fileHandleTable
        add l \ ld l, a
        ld a, (hl)
        cp 0xFF
        jr z, .notFound
    pop bc
    inc sp \ inc sp
    pop af
    cp a
    ret
.notFound:
    pop bc
    pop hl
    pop af
    or 1
    ld a, errStreamNotFound
    ret


; Inputs:
;   D: Stream ID
; Outputs:
; (Failure)
;   A: Error code
;   Z: Reset
; (Success)
;   Z: Set
closeStream:
    push hl
        call getStreamEntry
        jr z, .doClose
    pop hl
    ret
.doClose:
        push af
            ld a, (hl)
            bit 7, a
            jr nz, .closeWritableStream
            ; Close readable stream (just remove the entry)
            ld (hl), 0xFF
        pop af
    pop hl
    cp a
    ret
.closeWritableStream:
    ; TODO

; Inputs:
;   D: Stream ID
; Outputs:
; (Failure)
;   A: Error code
;   Z: Reset
; (Success)
;   A: Byte read
streamReadByte:
    push hl
        call getStreamEntry
        jr z, .doRead
    pop hl
    ret
.doRead:
        push af
        ld a, i
        push af
        push de
        push bc
            di
            ld a, (hl) \ inc hl
            bit 7, a
            jr nz, .readFromWritableStream
            ; Read from read-only stream
            inc hl \ inc hl
            ld e, (hl) \ inc hl \ ld d, (hl)
            ; If DE is 0xFFFF, we've reached the end of this file (and the "next" block is an empty one)
            ld a, 0xFF
            cp e \ jr nz, +_
            cp d \ jr nz, +_
            ; End of stream
            jr .endOfStream_early
_:          ; We'll use DE to indicate the address being used
            ; We need the flash page in A first, though.
            ld a, e \ or a \ rra \ rra \ rra \ rra \ rra \ and 0b111
            sla d \ sla d \ sla d \ or d
            out (6), a
            ; Now get the address of the entry on the page
            ld a, e \ and 0b11111 \ ld d, a
            inc hl \ ld a, (hl) \ ld e, a
            push de
                ld bc, 0x4000 \ ex de, hl \ add hl, bc
                ; Read the byte into A
                ld a, (hl)
                ex de, hl
            pop de
            push af
                xor a
                inc e
                cp e
                jr nz, ++_
                ; Handle block overflow
                dec hl \ dec hl \ ld a, (hl)
                and %11111
                rla \ rla ; A *= 4
                ld d, 0x40 \ ld e, a
                ; DE points to header entry, which tells us where the next block is
                inc de \ inc de
                ex de, hl
                ld c, (hl) \ inc hl \ ld b, (hl)
                ex de, hl
                ; Determine if this is the final block
                push bc
                    ld a, c \ or a \ rra \ rra \ rra \ rra \ rra \ and 0b111
                    sla b \ sla b \ sla b \ or b
                    out (6), a
                    ld a, c \ and %11111 \ rla \ rla \ ld d, 0x40 \ ld e, a
                    ; DE points to header entry of next block
                    inc de \ inc de
                    ex de, hl
                        ld a, 0xFF
                        cp (hl) \ jr nz, _
                        inc hl \ cp (hl) \ jr nz, _
                        ; It is the final block, copy the block size from the final size
                        ex de, hl
                            inc hl \ inc hl \ inc hl \ inc hl \ ld a, (hl) \ dec hl \ ld (hl), a
                            dec hl \ dec hl \ dec hl
                        ex de, hl
_:                  ex de, hl
                pop bc
                ; Update block address in stream entry
                ld (hl), c \ inc hl \ ld (hl), b \ inc hl
                ld e, 0
_:              ; Update flash address
                ld (hl), e
                inc hl
                ld a, (hl) ; Block size
                cp e
                jr c, .endOfStream
            pop af
            ; Return A
.success:
        ld h, a
        pop bc
        pop de
        pop af
        jp po, _
        ei
_:      pop af
        ld a, h
    pop hl
    cp a
    ret
.endOfStream:
            dec hl \ dec hl \ dec (hl)
            pop af
.endOfStream_early:
        pop bc
        pop de
        pop af
        jp po, _
        ei
_:      pop af
    pop hl
    or 1
    ld a, errEndOfStream
    ret
.readFromWritableStream:
    jr .success ; TODO