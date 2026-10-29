	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 15, 0	sdk_version 15, 2
	.globl	_main                           ; -- Begin function main
	.p2align	2
_main:                                  ; @main
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #352
	stp	x28, x27, [sp, #256]            ; 16-byte Folded Spill
	stp	x26, x25, [sp, #272]            ; 16-byte Folded Spill
	stp	x24, x23, [sp, #288]            ; 16-byte Folded Spill
	stp	x22, x21, [sp, #304]            ; 16-byte Folded Spill
	stp	x20, x19, [sp, #320]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #336]            ; 16-byte Folded Spill
	add	x29, sp, #336
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	cmp	w0, #2
	b.gt	LBB0_2
; %bb.1:
Lloh0:
	adrp	x8, ___stderrp@GOTPAGE
Lloh1:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh2:
	ldr	x3, [x8]
Lloh3:
	adrp	x0, l_.str@PAGE
Lloh4:
	add	x0, x0, l_.str@PAGEOFF
	mov	w1, #44                         ; =0x2c
	mov	w2, #1                          ; =0x1
	bl	_fwrite
	mov	w0, #2                          ; =0x2
	b	LBB0_327
LBB0_2:
	ldp	x21, x20, [x1, #8]
Lloh5:
	adrp	x1, l_.str.1@PAGE
Lloh6:
	add	x1, x1, l_.str.1@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_40
; %bb.3:
Lloh7:
	adrp	x1, l_.str.2@PAGE
Lloh8:
	add	x1, x1, l_.str.2@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_82
; %bb.4:
Lloh9:
	adrp	x1, l_.str.3@PAGE
Lloh10:
	add	x1, x1, l_.str.3@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_121
; %bb.5:
Lloh11:
	adrp	x1, l_.str.4@PAGE
Lloh12:
	add	x1, x1, l_.str.4@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_182
; %bb.6:
Lloh13:
	adrp	x1, l_.str.5@PAGE
Lloh14:
	add	x1, x1, l_.str.5@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbnz	w0, LBB0_326
; %bb.7:
Lloh15:
	adrp	x1, l_.str.26@PAGE
Lloh16:
	add	x1, x1, l_.str.26@PAGEOFF
	sub	x8, x29, #160
	mov	x0, x20
	bl	_load
	adrp	x8, _heap@PAGE+24
	ldr	x0, [x8, _heap@PAGEOFF+24]
	cbz	x0, LBB0_329
; %bb.8:
	ldr	x9, [x0]
	str	x9, [x8, _heap@PAGEOFF+24]
LBB0_9:
	mov	w8, #2                          ; =0x2
	strh	w8, [x0, #4]
	mov	w8, #5                          ; =0x5
	mov	w9, #21061                      ; =0x5245
	movk	w9, #20306, lsl #16
	mov	x10, x0
	str	w9, [x10, #16]!
	str	x10, [sp, #72]                  ; 8-byte Folded Spill
	str	x8, [x0, #8]
	mov	w8, #82                         ; =0x52
	strb	w8, [x0, #20]
	str	wzr, [x0]
	ldp	x19, x28, [x29, #-160]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	str	x0, [sp, #80]                   ; 8-byte Folded Spill
	cmp	x28, #1
	b.lt	LBB0_261
; %bb.10:
	mov	x9, #0                          ; =0x0
	stp	xzr, xzr, [sp, #144]            ; 16-byte Folded Spill
	mov	x20, #0                         ; =0x0
	add	x10, x19, #2
	add	x8, x19, #3
	stp	x8, x10, [sp, #112]             ; 16-byte Folded Spill
	add	x10, x19, #4
	add	x8, x19, #5
	stp	x8, x10, [sp, #96]              ; 16-byte Folded Spill
	add	x8, x19, #6
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	stp	x28, x19, [sp, #128]            ; 16-byte Folded Spill
LBB0_11:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_12 Depth 2
                                        ;     Child Loop BB0_14 Depth 2
                                        ;     Child Loop BB0_16 Depth 2
                                        ;     Child Loop BB0_18 Depth 2
                                        ;     Child Loop BB0_20 Depth 2
                                        ;     Child Loop BB0_22 Depth 2
                                        ;     Child Loop BB0_24 Depth 2
                                        ;     Child Loop BB0_29 Depth 2
                                        ;     Child Loop BB0_33 Depth 2
	str	x9, [sp, #168]                  ; 8-byte Folded Spill
	add	x21, x19, x20
	sub	x2, x28, x20
	mov	x0, x21
	mov	w1, #10                         ; =0xa
	bl	_memchr
	mov	x6, #0                          ; =0x0
	sub	x8, x0, x19
	ldp	x10, x9, [sp, #112]             ; 16-byte Folded Reload
	add	x9, x9, x20
	add	x11, x10, x20
	ldr	x10, [sp, #104]                 ; 8-byte Folded Reload
	add	x12, x10, x20
	ldr	x10, [sp, #96]                  ; 8-byte Folded Reload
	add	x14, x10, x20
	add	x16, x20, #13
	ldr	x10, [sp, #88]                  ; 8-byte Folded Reload
	add	x1, x10, x20
LBB0_12:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x27, x6
	mov	x10, x9
	mov	x13, x11
	mov	x15, x12
	mov	x17, x14
	mov	x2, x16
	mov	x3, x1
	ldrb	w4, [x21, x6]
	add	x6, x6, #1
	add	x9, x9, #1
	add	x11, x11, #1
	add	x12, x12, #1
	add	x14, x14, #1
	add	x16, x16, #1
	add	x1, x1, #1
	cmp	w4, #32
	b.ne	LBB0_12
; %bb.13:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x7, #0                          ; =0x0
	add	x9, x19, x20
	add	x4, x9, x6
LBB0_14:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x21, x7
	mov	x9, x10
	mov	x11, x13
	mov	x12, x15
	mov	x14, x17
	mov	x16, x2
	mov	x1, x3
	ldrb	w5, [x4, x7]
	add	x7, x7, #1
	add	x10, x10, #1
	add	x13, x13, #1
	add	x15, x15, #1
	add	x17, x17, #1
	add	x2, x2, #1
	add	x3, x3, #1
	cmp	w5, #32
	b.ne	LBB0_14
; %bb.15:                               ;   in Loop: Header=BB0_11 Depth=1
	str	x20, [sp, #160]                 ; 8-byte Folded Spill
	add	x10, x20, x6
	add	x25, x10, x7
	mov	x20, #-1                        ; =0xffffffffffffffff
LBB0_16:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x10, x11
	mov	x13, x12
	mov	x15, x14
	mov	x17, x16
	mov	x2, x1
	ldrb	w3, [x9], #1
	add	x25, x25, #1
	add	x20, x20, #1
	add	x11, x11, #1
	add	x12, x12, #1
	add	x14, x14, #1
	add	x16, x16, #1
	add	x1, x1, #1
	cmp	w3, #32
	b.ne	LBB0_16
; %bb.17:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x23, #-1                        ; =0xffffffffffffffff
	mov	x24, x25
LBB0_18:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x12, x13
	mov	x14, x15
	mov	x16, x17
	mov	x1, x2
	ldrb	w9, [x10], #1
	add	x24, x24, #1
	add	x23, x23, #1
	add	x13, x13, #1
	add	x15, x15, #1
	add	x17, x17, #1
	add	x2, x2, #1
	cmp	w9, #32
	b.ne	LBB0_18
; %bb.19:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x26, #-1                        ; =0xffffffffffffffff
	mov	x11, x24
LBB0_20:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x9, x14
	mov	x13, x16
	mov	x17, x1
	ldrb	w10, [x12], #1
	add	x11, x11, #1
	add	x26, x26, #1
	add	x14, x14, #1
	add	x16, x16, #1
	add	x1, x1, #1
	cmp	w10, #32
	b.ne	LBB0_20
; %bb.21:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x1, #0                          ; =0x0
	mov	x16, x9
	mov	x12, x11
LBB0_22:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x15, x12
	mov	x22, x13
	mov	x10, x17
	ldrb	w2, [x16], #1
	mov	x14, x1
	add	x12, x12, #1
	add	x13, x13, #1
	add	x17, x17, #1
	add	x1, x1, #1
	cmp	w2, #32
	b.ne	LBB0_22
; %bb.23:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x17, #-2                        ; =0xfffffffffffffffe
	mov	x16, x10
LBB0_24:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x13, x17
	ldrb	w1, [x16], #1
	add	x22, x22, #1
	add	x17, x17, #1
	cmp	w1, #32
	b.ne	LBB0_24
; %bb.25:                               ;   in Loop: Header=BB0_11 Depth=1
	cmp	x0, #0
	csel	x17, x28, x8, eq
	ldur	x0, [x29, #-160]
	ldur	x16, [x29, #-144]
	ldr	w8, [x16]
	cmp	w8, #1
	b.lt	LBB0_27
; %bb.26:                               ;   in Loop: Header=BB0_11 Depth=1
	add	w8, w8, #5
	str	w8, [x16]
LBB0_27:                                ;   in Loop: Header=BB0_11 Depth=1
	cmp	x11, x15
	b.ge	LBB0_30
; %bb.28:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x19, #0                         ; =0x0
	mov	w15, #10                        ; =0xa
LBB0_29:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrsb	x11, [x9], #1
	madd	x11, x19, x15, x11
	sub	x19, x11, #48
	subs	x14, x14, #1
	b.ne	LBB0_29
	b	LBB0_31
LBB0_30:                                ;   in Loop: Header=BB0_11 Depth=1
	mov	x19, #0                         ; =0x0
	mov	w15, #10                        ; =0xa
LBB0_31:                                ;   in Loop: Header=BB0_11 Depth=1
	sub	x9, x22, #10
	cmp	x12, x9
	b.ge	LBB0_38
; %bb.32:                               ;   in Loop: Header=BB0_11 Depth=1
	mov	x28, #0                         ; =0x0
LBB0_33:                                ;   Parent Loop BB0_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrsb	x9, [x10], #1
	madd	x9, x28, x15, x9
	sub	x28, x9, #48
	subs	x13, x13, #1
	b.ne	LBB0_33
; %bb.34:                               ;   in Loop: Header=BB0_11 Depth=1
	cmp	w8, #1
	b.lt	LBB0_36
LBB0_35:                                ;   in Loop: Header=BB0_11 Depth=1
	add	w8, w8, #1
	str	w8, [x16]
LBB0_36:                                ;   in Loop: Header=BB0_11 Depth=1
	ldr	x8, [sp, #144]                  ; 8-byte Folded Reload
	ldr	x15, [sp, #168]                 ; 8-byte Folded Reload
	cmp	x15, x8
	b.eq	LBB0_39
LBB0_37:                                ;   in Loop: Header=BB0_11 Depth=1
	ldp	x10, x8, [sp, #152]             ; 16-byte Folded Reload
	add	x8, x0, x8
	add	x9, x8, x6
	mov	w11, #160                       ; =0xa0
	madd	x10, x15, x11, x10
	stp	x8, x27, [x10]
	add	x8, x17, #1
	add	x11, x0, x25
	add	x12, x9, x7
	add	x13, x0, x24
	stp	x16, x9, [x10, #16]
	add	x9, x0, x22
	sub	x14, x17, x22
	add	x27, x15, #1
	stp	x21, x16, [x10, #32]
	stp	x12, x20, [x10, #48]
	stp	x16, x11, [x10, #64]
	stp	x23, x16, [x10, #80]
	stp	x13, x26, [x10, #96]
	stp	x16, x9, [x10, #112]
	stp	x14, x16, [x10, #128]
	mov	x9, x27
	mov	x20, x8
	stp	x19, x28, [x10, #144]
	ldp	x28, x19, [sp, #128]            ; 16-byte Folded Reload
	cmp	x8, x28
	b.lt	LBB0_11
	b	LBB0_262
LBB0_38:                                ;   in Loop: Header=BB0_11 Depth=1
	mov	x28, #0                         ; =0x0
	cmp	w8, #1
	b.ge	LBB0_35
	b	LBB0_36
LBB0_39:                                ;   in Loop: Header=BB0_11 Depth=1
	lsl	x8, x15, #1
	cmp	x15, #0
	csinc	x8, x8, xzr, ne
	str	x8, [sp, #144]                  ; 8-byte Folded Spill
	add	x8, x8, x8, lsl #2
	lsl	x1, x8, #5
	stp	x0, x17, [sp, #32]              ; 16-byte Folded Spill
	ldr	x0, [sp, #152]                  ; 8-byte Folded Reload
	stp	x7, x6, [sp, #56]               ; 16-byte Folded Spill
	str	x16, [sp, #48]                  ; 8-byte Folded Spill
	bl	_realloc
	ldp	x17, x16, [sp, #40]             ; 16-byte Folded Reload
	ldp	x7, x6, [sp, #56]               ; 16-byte Folded Reload
	ldr	x15, [sp, #168]                 ; 8-byte Folded Reload
	str	x0, [sp, #152]                  ; 8-byte Folded Spill
	ldr	x0, [sp, #32]                   ; 8-byte Folded Reload
	b	LBB0_37
LBB0_40:
Lloh17:
	adrp	x1, l_.str.8@PAGE
Lloh18:
	add	x1, x1, l_.str.8@PAGEOFF
	sub	x8, x29, #160
	mov	x0, x20
	bl	_load
	adrp	x8, _heap@PAGE+24
	ldr	x0, [x8, _heap@PAGEOFF+24]
	cbz	x0, LBB0_328
; %bb.41:
	ldr	x9, [x0]
	str	x9, [x8, _heap@PAGEOFF+24]
LBB0_42:
	mov	w8, #2                          ; =0x2
	strh	w8, [x0, #4]
	mov	w8, #6                          ; =0x6
	str	x8, [x0, #8]
	mov	w8, #25970                      ; =0x6572
	movk	w8, #30068, lsl #16
	mov	x22, x0
	str	w8, [x22, #16]!
	mov	w8, #28274                      ; =0x6e72
	strh	w8, [x0, #20]
	str	wzr, [x0]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	ldur	x21, [x29, #-152]
	cmp	x21, #1
	str	x0, [sp, #168]                  ; 8-byte Folded Spill
	b.lt	LBB0_160
; %bb.43:
	mov	x23, #0                         ; =0x0
	mov	x11, #0                         ; =0x0
	mov	x0, #0                          ; =0x0
	mov	x19, #0                         ; =0x0
	ldur	x24, [x29, #-160]
	mov	w26, #1                         ; =0x1
	mov	x12, #1536                      ; =0x600
	movk	x12, #1, lsl #32
	mov	x13, #8804682956800             ; =0x80200000000
	movk	x13, #28672, lsl #48
	b	LBB0_46
LBB0_44:                                ;   in Loop: Header=BB0_46 Depth=1
	add	x28, x19, #1
LBB0_45:                                ;   in Loop: Header=BB0_46 Depth=1
	mov	x19, x28
	cmp	x28, x21
	b.ge	LBB0_161
LBB0_46:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_62 Depth 2
                                        ;     Child Loop BB0_56 Depth 2
                                        ;     Child Loop BB0_51 Depth 2
	ldrb	w8, [x24, x19]
	cmp	w8, #32
	lsl	x9, x26, x8
	and	x9, x9, x12
	ccmp	x9, #0, #4, ls
	b.ne	LBB0_44
; %bb.47:                               ;   in Loop: Header=BB0_46 Depth=1
	add	x28, x19, #1
	cmp	w8, #95
	b.eq	LBB0_49
; %bb.48:                               ;   in Loop: Header=BB0_46 Depth=1
	orr	w9, w8, #0x20
	sub	w9, w9, #97
	cmp	w9, #25
	b.hi	LBB0_54
LBB0_49:                                ;   in Loop: Header=BB0_46 Depth=1
	cmp	x28, x21
	b.lt	LBB0_51
	b	LBB0_53
LBB0_50:                                ;   in Loop: Header=BB0_51 Depth=2
	add	x28, x28, #1
	cmp	x21, x28
	b.eq	LBB0_59
LBB0_51:                                ;   Parent Loop BB0_46 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w8, [x24, x28]
	cmp	w8, #95
	b.eq	LBB0_50
; %bb.52:                               ;   in Loop: Header=BB0_51 Depth=2
	orr	w9, w8, #0x20
	sub	w9, w9, #97
	sub	w8, w8, #48
	cmp	w9, #26
	ccmp	w8, #9, #0, hs
	b.ls	LBB0_50
LBB0_53:                                ;   in Loop: Header=BB0_46 Depth=1
	mov	x20, #0                         ; =0x0
	b	LBB0_77
LBB0_54:                                ;   in Loop: Header=BB0_46 Depth=1
	sub	w9, w8, #48
	cmp	w9, #9
	b.hi	LBB0_60
; %bb.55:                               ;   in Loop: Header=BB0_46 Depth=1
	cmp	x28, x21
	b.ge	LBB0_66
LBB0_56:                                ;   Parent Loop BB0_46 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w8, [x24, x28]
	sub	w8, w8, #48
	cmp	w8, #9
	b.hi	LBB0_66
; %bb.57:                               ;   in Loop: Header=BB0_56 Depth=2
	add	x28, x28, #1
	cmp	x21, x28
	b.ne	LBB0_56
; %bb.58:                               ;   in Loop: Header=BB0_46 Depth=1
	mov	x28, x21
	mov	w20, #1                         ; =0x1
	b	LBB0_77
LBB0_59:                                ;   in Loop: Header=BB0_46 Depth=1
	mov	x20, #0                         ; =0x0
	mov	x28, x21
	b	LBB0_77
LBB0_60:                                ;   in Loop: Header=BB0_46 Depth=1
	cmp	w8, #34
	b.ne	LBB0_67
; %bb.61:                               ;   in Loop: Header=BB0_46 Depth=1
	cmp	x28, x21
	b.ge	LBB0_65
LBB0_62:                                ;   Parent Loop BB0_46 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w8, [x24, x28]
	cmp	w8, #34
	b.eq	LBB0_65
; %bb.63:                               ;   in Loop: Header=BB0_62 Depth=2
	add	x28, x28, #1
	cmp	x21, x28
	b.ne	LBB0_62
; %bb.64:                               ;   in Loop: Header=BB0_46 Depth=1
	mov	x28, x21
LBB0_65:                                ;   in Loop: Header=BB0_46 Depth=1
	add	x28, x28, #1
	mov	w20, #2                         ; =0x2
	b	LBB0_77
LBB0_66:                                ;   in Loop: Header=BB0_46 Depth=1
	mov	w20, #1                         ; =0x1
	b	LBB0_77
LBB0_67:                                ;   in Loop: Header=BB0_46 Depth=1
	cmp	x28, x21
	b.ge	LBB0_76
; %bb.68:                               ;   in Loop: Header=BB0_46 Depth=1
	cmp	w8, #62
	b.hi	LBB0_76
; %bb.69:                               ;   in Loop: Header=BB0_46 Depth=1
	mov	w9, w8
	lsl	x10, x26, x9
	tst	x10, x13
	b.eq	LBB0_72
; %bb.70:                               ;   in Loop: Header=BB0_46 Depth=1
	ldrb	w9, [x24, x28]
	cmp	w9, #61
	b.eq	LBB0_75
; %bb.71:                               ;   in Loop: Header=BB0_46 Depth=1
	cmp	w8, #45
	b.eq	LBB0_74
	b	LBB0_76
LBB0_72:                                ;   in Loop: Header=BB0_46 Depth=1
	cmp	x9, #45
	b.ne	LBB0_76
; %bb.73:                               ;   in Loop: Header=BB0_46 Depth=1
	ldrb	w9, [x24, x28]
LBB0_74:                                ;   in Loop: Header=BB0_46 Depth=1
	cmp	w9, #62
	b.ne	LBB0_76
LBB0_75:                                ;   in Loop: Header=BB0_46 Depth=1
	add	x28, x19, #2
LBB0_76:                                ;   in Loop: Header=BB0_46 Depth=1
	mov	w20, #3                         ; =0x3
LBB0_77:                                ;   in Loop: Header=BB0_46 Depth=1
	ldur	x27, [x29, #-160]
	ldur	x25, [x29, #-144]
	ldr	w8, [x25]
	cmp	w8, #1
	b.lt	LBB0_79
; %bb.78:                               ;   in Loop: Header=BB0_46 Depth=1
	add	w8, w8, #1
	str	w8, [x25]
LBB0_79:                                ;   in Loop: Header=BB0_46 Depth=1
	cmp	x23, x11
	b.eq	LBB0_81
LBB0_80:                                ;   in Loop: Header=BB0_46 Depth=1
	add	x8, x27, x19
	sub	x9, x28, x19
	add	x10, x0, x23, lsl #5
	stp	x20, x8, [x10]
	add	x23, x23, #1
	stp	x9, x25, [x10, #16]
	b	LBB0_45
LBB0_81:                                ;   in Loop: Header=BB0_46 Depth=1
	lsl	x8, x23, #1
	cmp	x23, #0
	csinc	x8, x8, xzr, ne
	str	x8, [sp, #160]                  ; 8-byte Folded Spill
	lsl	x1, x8, #5
	bl	_realloc
	mov	x13, #8804682956800             ; =0x80200000000
	movk	x13, #28672, lsl #48
	mov	x12, #1536                      ; =0x600
	movk	x12, #1, lsl #32
	ldr	x11, [sp, #160]                 ; 8-byte Folded Reload
	b	LBB0_80
LBB0_82:
Lloh19:
	adrp	x1, l_.str.18@PAGE
Lloh20:
	add	x1, x1, l_.str.18@PAGEOFF
	sub	x8, x29, #112
	mov	x0, x20
	bl	_load
	ldp	x19, x28, [x29, #-112]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stur	xzr, [x29, #-128]
	movi.2d	v0, #0000000000000000
	stp	q0, q0, [x29, #-160]
	cmp	x28, #0
	b.le	LBB0_229
; %bb.83:
	str	x20, [sp, #96]                  ; 8-byte Folded Spill
	stp	xzr, xzr, [sp, #128]            ; 16-byte Folded Spill
	mov	x25, #0                         ; =0x0
	mov	x23, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
	mov	x27, #0                         ; =0x0
	sub	x8, x19, #4
	stp	x8, xzr, [sp, #112]             ; 16-byte Folded Spill
	mov	x20, #44233                     ; =0xacc9
	movk	x20, #38446, lsl #16
	movk	x20, #19347, lsl #32
	movk	x20, #35768, lsl #48
	ldur	x8, [x29, #-96]
	str	x8, [sp, #104]                  ; 8-byte Folded Spill
	sub	x8, x19, #16
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	mov	w24, #40                        ; =0x28
                                        ; implicit-def: $x26
	stp	x28, x19, [sp, #152]            ; 16-byte Folded Spill
LBB0_84:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_119 Depth 2
                                        ;     Child Loop BB0_95 Depth 2
                                        ;     Child Loop BB0_106 Depth 2
	add	x0, x19, x27
	sub	x2, x28, x27
	str	x0, [sp, #168]                  ; 8-byte Folded Spill
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x19
	cmp	x0, #0
	csel	x13, x28, x8, eq
	sub	x21, x13, x27
	cmp	x21, #17
	b.hs	LBB0_118
; %bb.85:                               ;   in Loop: Header=BB0_84 Depth=1
	cmp	x21, #4
	ldr	x14, [sp, #120]                 ; 8-byte Folded Reload
	b.lo	LBB0_87
; %bb.86:                               ;   in Loop: Header=BB0_84 Depth=1
	lsr	x8, x21, #1
	and	x8, x8, #0x7ffffffffffffffc
	ldr	x10, [sp, #168]                 ; 8-byte Folded Reload
	ldr	w9, [x10]
	ldr	w10, [x10, x8]
	orr	x10, x10, x9, lsl #32
	ldr	x9, [sp, #112]                  ; 8-byte Folded Reload
	add	x9, x9, x13
	sub	x8, x9, x8
	ldr	w9, [x9]
	ldr	w8, [x8]
	orr	x9, x8, x9, lsl #32
	b	LBB0_90
LBB0_87:                                ;   in Loop: Header=BB0_84 Depth=1
	cbz	x21, LBB0_89
; %bb.88:                               ;   in Loop: Header=BB0_84 Depth=1
	mov	x9, #0                          ; =0x0
	ldr	x11, [sp, #168]                 ; 8-byte Folded Reload
	ldrb	w8, [x11]
	lsr	x10, x21, #1
	ldrb	w10, [x11, x10]
	lsl	x8, x8, #16
	orr	x8, x8, x10, lsl #8
	add	x10, x21, x11
	ldurb	w10, [x10, #-1]
	orr	x10, x8, x10
	b	LBB0_90
LBB0_89:                                ;   in Loop: Header=BB0_84 Depth=1
	mov	x10, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
LBB0_90:                                ;   in Loop: Header=BB0_84 Depth=1
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_91:                                ;   in Loop: Header=BB0_84 Depth=1
	eor	x11, x21, x20
	eor	x10, x10, x20
	eor	x8, x9, x8
	mul	x9, x8, x10
	umulh	x8, x8, x10
	eor	x8, x9, x8
	mul	x9, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x9
	mov	x9, #30886                      ; =0x78a6
	movk	x9, #43628, lsl #16
	movk	x9, #36300, lsl #32
	movk	x9, #11573, lsl #48
	eor	x8, x8, x9
	mov	x10, #53468                     ; =0xd0dc
	movk	x10, #59748, lsl #16
	movk	x10, #12842, lsl #32
	movk	x10, #5519, lsl #48
	mul	x9, x8, x10
	umulh	x8, x8, x10
	eor	x8, x8, x9
	cmp	x8, #1
	csinc	x28, x8, xzr, hi
	str	x13, [sp, #144]                 ; 8-byte Folded Spill
	cbz	w14, LBB0_100
; %bb.92:                               ;   in Loop: Header=BB0_84 Depth=1
	neg	w8, w14
	lsr	x27, x28, x8
	ldr	w8, [x22, x27, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_101
; %bb.93:                               ;   in Loop: Header=BB0_84 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	lsl	x9, x9, x14
	mvn	x19, x9
	b	LBB0_95
LBB0_94:                                ;   in Loop: Header=BB0_95 Depth=2
	add	x8, x27, #1
	and	x27, x8, x19
	ldr	w8, [x22, x27, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_101
LBB0_95:                                ;   Parent Loop BB0_84 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	smull	x9, w8, w24
	ldr	x9, [x23, x9]
	cmp	x9, x28
	b.ne	LBB0_94
; %bb.96:                               ;   in Loop: Header=BB0_95 Depth=2
	sxtw	x20, w8
	smaddl	x8, w20, w24, x23
	ldr	x8, [x8, #16]
	cmp	x8, x21
	b.ne	LBB0_94
; %bb.97:                               ;   in Loop: Header=BB0_95 Depth=2
	smaddl	x8, w20, w24, x23
	ldr	x0, [x8, #8]
	ldr	x1, [sp, #168]                  ; 8-byte Folded Reload
	mov	x2, x21
	bl	_memcmp
	cbnz	w0, LBB0_94
; %bb.98:                               ;   in Loop: Header=BB0_84 Depth=1
	tbnz	w20, #31, LBB0_117
; %bb.99:                               ;   in Loop: Header=BB0_84 Depth=1
	smaddl	x8, w20, w24, x23
	ldr	x9, [x8, #32]
	add	x9, x9, #1
	str	x9, [x8, #32]
	ldp	x28, x19, [sp, #152]            ; 16-byte Folded Reload
	mov	x20, #44233                     ; =0xacc9
	movk	x20, #38446, lsl #16
	movk	x20, #19347, lsl #32
	movk	x20, #35768, lsl #48
	ldr	x12, [sp, #144]                 ; 8-byte Folded Reload
	b	LBB0_116
LBB0_100:                               ;   in Loop: Header=BB0_84 Depth=1
	mov	x27, #0                         ; =0x0
LBB0_101:                               ;   in Loop: Header=BB0_84 Depth=1
	ldur	x8, [x29, #-152]
	ldr	x9, [sp, #136]                  ; 8-byte Folded Reload
	cmp	x9, x8
	b.ne	LBB0_110
; %bb.102:                              ;   in Loop: Header=BB0_84 Depth=1
	sub	x0, x29, #160
	bl	_smap_room
	ldur	w23, [x29, #-144]
	mov	x20, #44233                     ; =0xacc9
	movk	x20, #38446, lsl #16
	movk	x20, #19347, lsl #32
	movk	x20, #35768, lsl #48
	cbz	w23, LBB0_112
; %bb.103:                              ;   in Loop: Header=BB0_84 Depth=1
	neg	w8, w23
	lsr	x26, x28, x8
	ldp	x25, x22, [x29, #-136]
	ldr	w8, [x22, x26, lsl #2]
	cmn	w8, #1
	str	x23, [sp, #128]                 ; 8-byte Folded Spill
	b.eq	LBB0_111
; %bb.104:                              ;   in Loop: Header=BB0_84 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	lsl	x9, x9, x23
	mvn	x19, x9
	b	LBB0_106
LBB0_105:                               ;   in Loop: Header=BB0_106 Depth=2
	add	x8, x26, #1
	and	x26, x8, x19
	ldr	w8, [x22, x26, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_111
LBB0_106:                               ;   Parent Loop BB0_84 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	smull	x9, w8, w24
	ldr	x9, [x25, x9]
	cmp	x9, x28
	b.ne	LBB0_105
; %bb.107:                              ;   in Loop: Header=BB0_106 Depth=2
	sxtw	x8, w8
	smaddl	x9, w8, w24, x25
	ldr	x9, [x9, #16]
	cmp	x9, x21
	b.ne	LBB0_105
; %bb.108:                              ;   in Loop: Header=BB0_106 Depth=2
	smaddl	x8, w8, w24, x25
	ldr	x0, [x8, #8]
	ldr	x1, [sp, #168]                  ; 8-byte Folded Reload
	mov	x2, x21
	bl	_memcmp
	cbnz	w0, LBB0_105
; %bb.109:                              ;   in Loop: Header=BB0_84 Depth=1
                                        ; kill: def $w23 killed $w23 killed $x23 def $x23
	str	x23, [sp, #120]                 ; 8-byte Folded Spill
	mov	x26, x27
	b	LBB0_113
LBB0_110:                               ;   in Loop: Header=BB0_84 Depth=1
	mov	x26, x27
	mov	x20, #44233                     ; =0xacc9
	movk	x20, #38446, lsl #16
	movk	x20, #19347, lsl #32
	movk	x20, #35768, lsl #48
	b	LBB0_113
LBB0_111:                               ;   in Loop: Header=BB0_84 Depth=1
                                        ; kill: def $w23 killed $w23 killed $x23 def $x23
	str	x23, [sp, #120]                 ; 8-byte Folded Spill
	b	LBB0_113
LBB0_112:                               ;   in Loop: Header=BB0_84 Depth=1
	stp	xzr, xzr, [sp, #120]            ; 16-byte Folded Spill
	mov	x26, #0                         ; =0x0
	ldur	x25, [x29, #-136]
LBB0_113:                               ;   in Loop: Header=BB0_84 Depth=1
	ldur	x8, [x29, #-160]
	madd	x9, x8, x24, x25
	str	x28, [x9], #8
	ldr	x11, [sp, #104]                 ; 8-byte Folded Reload
	ldr	w10, [x11]
	cmp	w10, #1
	ldr	x12, [sp, #144]                 ; 8-byte Folded Reload
	b.lt	LBB0_115
; %bb.114:                              ;   in Loop: Header=BB0_84 Depth=1
	add	w10, w10, #1
	str	w10, [x11]
LBB0_115:                               ;   in Loop: Header=BB0_84 Depth=1
	ldp	x19, x10, [sp, #160]            ; 16-byte Folded Reload
	stp	x10, x21, [x9]
	str	x11, [x9, #16]
	madd	x9, x8, x24, x25
	mov	w10, #1                         ; =0x1
	str	x10, [x9, #32]
	ldur	x22, [x29, #-128]
	str	w8, [x22, x26, lsl #2]
	add	x8, x8, #1
	str	x8, [sp, #136]                  ; 8-byte Folded Spill
	stur	x8, [x29, #-160]
	mov	x23, x25
	ldr	x28, [sp, #152]                 ; 8-byte Folded Reload
LBB0_116:                               ;   in Loop: Header=BB0_84 Depth=1
	add	x27, x12, #1
	cmp	x27, x28
	b.lt	LBB0_84
	b	LBB0_131
LBB0_117:                               ;   in Loop: Header=BB0_84 Depth=1
	mov	x27, x26
	b	LBB0_101
LBB0_118:                               ;   in Loop: Header=BB0_84 Depth=1
	ldr	x8, [sp, #88]                   ; 8-byte Folded Reload
	add	x9, x8, x27
	mov	x11, x21
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
	ldr	x14, [sp, #120]                 ; 8-byte Folded Reload
LBB0_119:                               ;   Parent Loop BB0_84 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x10, x11
	ldp	x11, x12, [x9, #16]!
	eor	x11, x11, x20
	eor	x8, x12, x8
	mul	x12, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x12
	sub	x11, x10, #16
	cmp	x11, #16
	b.hi	LBB0_119
; %bb.120:                              ;   in Loop: Header=BB0_84 Depth=1
	add	x9, x9, x10
	ldp	x10, x9, [x9, #-16]
	b	LBB0_91
LBB0_121:
Lloh21:
	adrp	x1, l_.str.22@PAGE
Lloh22:
	add	x1, x1, l_.str.22@PAGEOFF
	sub	x8, x29, #160
	mov	x0, x20
	bl	_load
	ldp	x23, x24, [x29, #-160]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	cmp	x24, #1
	str	x0, [sp, #152]                  ; 8-byte Folded Spill
	b.lt	LBB0_238
; %bb.122:
	mov	x0, x23
	mov	w1, #10                         ; =0xa
	mov	x2, x24
	bl	_memchr
	sub	x8, x0, x23
	cmp	x0, #0
	csel	x19, x24, x8, eq
	add	x26, x19, #1
	ldur	x20, [x29, #-144]
	ldr	w8, [x20]
	cmp	w8, #1
	b.lt	LBB0_124
; %bb.123:
	add	w8, w8, #1
	str	w8, [x20]
LBB0_124:
	mov	w0, #24                         ; =0x18
	bl	_malloc
	stp	x23, x19, [x0]
	str	x0, [sp, #168]                  ; 8-byte Folded Spill
	str	x20, [x0, #16]
	cmp	x26, x24
	b.ge	LBB0_239
; %bb.125:
	mov	x27, #0                         ; =0x0
	mov	w21, #1                         ; =0x1
	mov	w25, #48                        ; =0x30
	mov	w28, #2                         ; =0x2
	mov	w8, #1                          ; =0x1
	str	x8, [sp, #160]                  ; 8-byte Folded Spill
LBB0_126:                               ; =>This Inner Loop Header: Depth=1
	add	x0, x23, x26
	sub	x2, x24, x26
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x23
	cmp	x0, #0
	csel	x22, x24, x8, eq
	ldur	x19, [x29, #-144]
	ldr	w8, [x19]
	cmp	w8, #1
	b.lt	LBB0_128
; %bb.127:                              ;   in Loop: Header=BB0_126 Depth=1
	add	w8, w8, #1
	str	w8, [x19]
LBB0_128:                               ;   in Loop: Header=BB0_126 Depth=1
	ldur	x20, [x29, #-160]
	ldr	x8, [sp, #160]                  ; 8-byte Folded Reload
	cmp	x21, x8
	b.eq	LBB0_130
LBB0_129:                               ;   in Loop: Header=BB0_126 Depth=1
	add	x8, x20, x26
	sub	x9, x22, x26
	add	x10, x22, #1
	add	x21, x21, #1
	ldr	x11, [sp, #168]                 ; 8-byte Folded Reload
	add	x11, x11, x27
	stp	x8, x9, [x11, #24]
	add	x25, x25, #48
	str	x19, [x11, #40]
	add	x28, x28, #2
	add	x27, x27, #24
	mov	x26, x10
	cmp	x10, x24
	b.lt	LBB0_126
	b	LBB0_240
LBB0_130:                               ;   in Loop: Header=BB0_126 Depth=1
	ldr	x0, [sp, #168]                  ; 8-byte Folded Reload
	mov	x1, x25
	bl	_realloc
	stp	x28, x0, [sp, #160]             ; 16-byte Folded Spill
	b	LBB0_129
LBB0_131:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	str	x0, [sp, #120]                  ; 8-byte Folded Spill
	mov	x19, #0                         ; =0x0
	mov	x26, #0                         ; =0x0
	mov	x8, #-1                         ; =0xffffffffffffffff
	ldr	x9, [sp, #128]                  ; 8-byte Folded Reload
	lsl	x8, x8, x9
	mvn	x25, x8
	mov	w8, #64                         ; =0x40
	sub	w8, w8, w9
	str	x8, [sp, #144]                  ; 8-byte Folded Spill
	ldp	x22, x21, [x29, #-136]
	mov	x24, x28
	mov	w28, #40                        ; =0x28
LBB0_132:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_150 Depth 2
                                        ;     Child Loop BB0_142 Depth 2
	ldr	x20, [sp, #160]                 ; 8-byte Folded Reload
	add	x23, x20, x26
	sub	x2, x24, x26
	mov	x0, x23
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x20
	cmp	x0, #0
	csel	x14, x24, x8, eq
	sub	x24, x14, x26
	cmp	x24, #17
	b.hs	LBB0_149
; %bb.133:                              ;   in Loop: Header=BB0_132 Depth=1
	cmp	x24, #4
	mov	x13, #44233                     ; =0xacc9
	movk	x13, #38446, lsl #16
	movk	x13, #19347, lsl #32
	movk	x13, #35768, lsl #48
	b.lo	LBB0_135
; %bb.134:                              ;   in Loop: Header=BB0_132 Depth=1
	lsr	x8, x24, #1
	and	x8, x8, #0x7ffffffffffffffc
	ldr	w9, [x23]
	ldr	w10, [x23, x8]
	orr	x10, x10, x9, lsl #32
	ldr	x9, [sp, #112]                  ; 8-byte Folded Reload
	add	x9, x9, x14
	sub	x8, x9, x8
	ldr	w9, [x9]
	ldr	w8, [x8]
	orr	x9, x8, x9, lsl #32
	b	LBB0_138
LBB0_135:                               ;   in Loop: Header=BB0_132 Depth=1
	cbz	x24, LBB0_137
; %bb.136:                              ;   in Loop: Header=BB0_132 Depth=1
	mov	x9, #0                          ; =0x0
	ldrb	w8, [x23]
	lsr	x10, x24, #1
	ldrb	w10, [x23, x10]
	lsl	x8, x8, #16
	orr	x8, x8, x10, lsl #8
	add	x10, x24, x23
	ldurb	w10, [x10, #-1]
	orr	x10, x8, x10
	b	LBB0_138
LBB0_137:                               ;   in Loop: Header=BB0_132 Depth=1
	mov	x10, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
LBB0_138:                               ;   in Loop: Header=BB0_132 Depth=1
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_139:                               ;   in Loop: Header=BB0_132 Depth=1
	str	x19, [sp, #168]                 ; 8-byte Folded Spill
	eor	x11, x24, x13
	eor	x10, x10, x13
	eor	x8, x9, x8
	mul	x9, x8, x10
	umulh	x8, x8, x10
	eor	x8, x9, x8
	mul	x9, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x9
	mov	x9, #30886                      ; =0x78a6
	movk	x9, #43628, lsl #16
	movk	x9, #36300, lsl #32
	movk	x9, #11573, lsl #48
	eor	x8, x8, x9
	mov	x10, #53468                     ; =0xd0dc
	movk	x10, #59748, lsl #16
	movk	x10, #12842, lsl #32
	movk	x10, #5519, lsl #48
	mul	x9, x8, x10
	umulh	x8, x8, x10
	eor	x8, x8, x9
	cmp	x8, #1
	csinc	x26, x8, xzr, hi
	ldr	x8, [sp, #128]                  ; 8-byte Folded Reload
	cbz	w8, LBB0_146
; %bb.140:                              ;   in Loop: Header=BB0_132 Depth=1
	mov	x19, x14
	ldr	x8, [sp, #144]                  ; 8-byte Folded Reload
	lsr	x27, x26, x8
	b	LBB0_142
LBB0_141:                               ;   in Loop: Header=BB0_142 Depth=2
	add	x8, x27, #1
	and	x27, x8, x25
LBB0_142:                               ;   Parent Loop BB0_132 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w8, [x21, x27, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_147
; %bb.143:                              ;   in Loop: Header=BB0_142 Depth=2
	smull	x9, w8, w28
	ldr	x9, [x22, x9]
	cmp	x9, x26
	b.ne	LBB0_141
; %bb.144:                              ;   in Loop: Header=BB0_142 Depth=2
	sxtw	x20, w8
	smaddl	x8, w20, w28, x22
	ldr	x8, [x8, #16]
	cmp	x8, x24
	b.ne	LBB0_141
; %bb.145:                              ;   in Loop: Header=BB0_142 Depth=2
	smaddl	x8, w20, w28, x22
	ldr	x0, [x8, #8]
	mov	x1, x23
	mov	x2, x24
	bl	_memcmp
	cbnz	w0, LBB0_141
	b	LBB0_148
LBB0_146:                               ;   in Loop: Header=BB0_132 Depth=1
	mov	x19, x14
LBB0_147:                               ;   in Loop: Header=BB0_132 Depth=1
	mov	x20, #-1                        ; =0xffffffffffffffff
LBB0_148:                               ;   in Loop: Header=BB0_132 Depth=1
	add	x26, x19, #1
	smaddl	x8, w20, w28, x22
	ldr	x8, [x8, #32]
	ldr	x19, [sp, #168]                 ; 8-byte Folded Reload
	add	x19, x8, x19
	ldr	x24, [sp, #152]                 ; 8-byte Folded Reload
	cmp	x26, x24
	b.lt	LBB0_132
	b	LBB0_152
LBB0_149:                               ;   in Loop: Header=BB0_132 Depth=1
	ldr	x8, [sp, #88]                   ; 8-byte Folded Reload
	add	x9, x8, x26
	mov	x11, x24
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
	mov	x13, #44233                     ; =0xacc9
	movk	x13, #38446, lsl #16
	movk	x13, #19347, lsl #32
	movk	x13, #35768, lsl #48
LBB0_150:                               ;   Parent Loop BB0_132 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x10, x11
	ldp	x11, x12, [x9, #16]!
	eor	x11, x11, x13
	eor	x8, x12, x8
	mul	x12, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x12
	sub	x11, x10, #16
	cmp	x11, #16
	b.hi	LBB0_150
; %bb.151:                              ;   in Loop: Header=BB0_132 Depth=1
	add	x9, x9, x10
	ldp	x10, x9, [x9, #-16]
	b	LBB0_139
LBB0_152:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x23, x0
	ldr	x25, [sp, #136]                 ; 8-byte Folded Reload
	cmp	x25, #1
	b.lt	LBB0_159
; %bb.153:
	mov	w20, #24                        ; =0x18
	mov	x24, x25
	b	LBB0_156
LBB0_154:                               ;   in Loop: Header=BB0_156 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_155:                               ;   in Loop: Header=BB0_156 Depth=1
	add	x20, x20, #40
	subs	x24, x24, #1
	b.eq	LBB0_159
LBB0_156:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x22, x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_154
; %bb.157:                              ;   in Loop: Header=BB0_156 Depth=1
	cmp	w8, #1
	b.ne	LBB0_155
; %bb.158:                              ;   in Loop: Header=BB0_156 Depth=1
	bl	_bown_free
	b	LBB0_155
LBB0_159:
	ldr	x20, [sp, #96]                  ; 8-byte Folded Reload
	ldr	x24, [sp, #120]                 ; 8-byte Folded Reload
	b	LBB0_230
LBB0_160:
	mov	x0, #0                          ; =0x0
	mov	x23, #0                         ; =0x0
LBB0_161:
	mov	x27, x0
	ldur	x0, [x29, #-144]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_163
; %bb.162:
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_165
LBB0_163:
	cmp	w8, #1
	b.ne	LBB0_165
; %bb.164:
	bl	_bown_free
LBB0_165:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	cmp	x23, #1
	b.lt	LBB0_179
; %bb.166:
	mov	x19, #0                         ; =0x0
	mov	x24, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	add	x8, x27, #8
	mov	x9, x23
	b	LBB0_169
LBB0_167:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	w11, #0                         ; =0x0
LBB0_168:                               ;   in Loop: Header=BB0_169 Depth=1
	add	x25, x25, w11, uxtw
	ldur	x11, [x8, #-8]
	cmp	x11, #0
	cinc	x24, x24, eq
	add	x19, x10, x19
	add	x8, x8, #32
	subs	x9, x9, #1
	b.eq	LBB0_173
LBB0_169:                               ; =>This Inner Loop Header: Depth=1
	ldr	x10, [x8, #8]
	cmp	x10, #6
	b.ne	LBB0_167
; %bb.170:                              ;   in Loop: Header=BB0_169 Depth=1
	ldr	x11, [x8]
	cmp	x11, x22
	b.eq	LBB0_172
; %bb.171:                              ;   in Loop: Header=BB0_169 Depth=1
	ldr	w12, [x11]
	ldr	w13, [x22]
	ldrh	w11, [x11, #4]
	ldrh	w14, [x22, #4]
	cmp	w12, w13
	ccmp	w11, w14, #0, eq
	cset	w11, eq
	b	LBB0_168
LBB0_172:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	w11, #1                         ; =0x1
	b	LBB0_168
LBB0_173:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	add	x20, x27, #24
	mov	x26, x23
	b	LBB0_176
LBB0_174:                               ;   in Loop: Header=BB0_176 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_175:                               ;   in Loop: Header=BB0_176 Depth=1
	add	x20, x20, #32
	subs	x26, x26, #1
	b.eq	LBB0_180
LBB0_176:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_174
; %bb.177:                              ;   in Loop: Header=BB0_176 Depth=1
	cmp	w8, #1
	b.ne	LBB0_175
; %bb.178:                              ;   in Loop: Header=BB0_176 Depth=1
	bl	_bown_free
	b	LBB0_175
LBB0_179:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	mov	x19, #0                         ; =0x0
	mov	x24, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
LBB0_180:
	mov	x0, x27
	bl	_free
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x24, x19, [sp, #16]
	stp	x23, x25, [sp]
Lloh23:
	adrp	x0, l_.str.10@PAGE
Lloh24:
	add	x0, x0, l_.str.10@PAGEOFF
	bl	_printf
	ldr	x19, [sp, #168]                 ; 8-byte Folded Reload
	sub	x8, x21, x19
Lloh25:
	adrp	x9, l_.str.12@PAGE
Lloh26:
	add	x9, x9, l_.str.12@PAGEOFF
	stp	x9, x8, [sp]
Lloh27:
	adrp	x23, l_.str.11@PAGE
Lloh28:
	add	x23, x23, l_.str.11@PAGEOFF
	mov	x0, x23
	bl	_printf
	sub	x8, x22, x21
Lloh29:
	adrp	x9, l_.str.13@PAGE
Lloh30:
	add	x9, x9, l_.str.13@PAGEOFF
LBB0_181:
	stp	x9, x8, [sp]
	mov	x0, x23
	bl	_printf
	sub	x8, x20, x22
Lloh31:
	adrp	x9, l_.str.14@PAGE
Lloh32:
	add	x9, x9, l_.str.14@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x23
	bl	_printf
	sub	x8, x20, x19
Lloh33:
	adrp	x9, l_.str.15@PAGE
Lloh34:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x23
	b	LBB0_325
LBB0_182:
Lloh35:
	adrp	x1, l_.str.24@PAGE
Lloh36:
	add	x1, x1, l_.str.24@PAGEOFF
	sub	x8, x29, #112
	mov	x0, x20
	bl	_load
	ldp	x19, x21, [x29, #-112]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x23, x0
	stur	xzr, [x29, #-128]
	movi.2d	v0, #0000000000000000
	stp	q0, q0, [x29, #-160]
	cmp	x21, #1
	b.lt	LBB0_260
; %bb.183:
	stp	xzr, xzr, [sp, #128]            ; 16-byte Folded Spill
	str	xzr, [sp, #144]                 ; 8-byte Folded Spill
	mov	x27, #0                         ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	mov	x26, #44233                     ; =0xacc9
	movk	x26, #38446, lsl #16
	movk	x26, #19347, lsl #32
	movk	x26, #35768, lsl #48
	ldur	x8, [x29, #-96]
	stp	x23, x8, [sp, #96]              ; 16-byte Folded Spill
	sub	x28, x19, #1
	sub	x8, x19, #16
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	mov	w22, #10                        ; =0xa
                                        ; implicit-def: $x20
	mov	w23, #40                        ; =0x28
	stp	x21, x19, [sp, #112]            ; 16-byte Folded Spill
LBB0_184:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_185 Depth 2
                                        ;     Child Loop BB0_188 Depth 2
                                        ;     Child Loop BB0_227 Depth 2
                                        ;     Child Loop BB0_201 Depth 2
                                        ;     Child Loop BB0_212 Depth 2
	str	x10, [sp, #160]                 ; 8-byte Folded Spill
	add	x24, x19, x25
	sub	x2, x21, x25
	mov	x0, x24
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x19
	cmp	x0, #0
	csel	x21, x21, x8, eq
	sub	x2, x21, x25
	str	x24, [sp, #168]                 ; 8-byte Folded Spill
	mov	x0, x24
	mov	w1, #44                         ; =0x2c
	bl	_memchr
	mov	x11, #0                         ; =0x0
	mov	x10, x21
LBB0_185:                               ;   Parent Loop BB0_184 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x9, x10
	mov	x8, x11
	sub	x10, x10, #1
	ldrb	w12, [x28, x9]
	sub	x11, x11, #1
	cmp	w12, #44
	b.ne	LBB0_185
; %bb.186:                              ;   in Loop: Header=BB0_184 Depth=1
	cmp	x9, x21
	b.ge	LBB0_189
; %bb.187:                              ;   in Loop: Header=BB0_184 Depth=1
	mov	x24, #0                         ; =0x0
	add	x9, x19, x21
LBB0_188:                               ;   Parent Loop BB0_184 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrsb	x10, [x9, x8]
	madd	x10, x24, x22, x10
	sub	x24, x10, #48
	adds	x8, x8, #1
	b.lo	LBB0_188
	b	LBB0_190
LBB0_189:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x24, #0                         ; =0x0
LBB0_190:                               ;   in Loop: Header=BB0_184 Depth=1
	add	x8, x25, x19
	sub	x22, x0, x8
	cmp	x22, #17
	b.hs	LBB0_226
; %bb.191:                              ;   in Loop: Header=BB0_184 Depth=1
	cmp	x22, #4
	ldr	x13, [sp, #136]                 ; 8-byte Folded Reload
	b.lo	LBB0_193
; %bb.192:                              ;   in Loop: Header=BB0_184 Depth=1
	lsr	x8, x22, #1
	and	x8, x8, #0x7ffffffffffffffc
	ldr	x11, [sp, #168]                 ; 8-byte Folded Reload
	ldr	w9, [x11]
	ldr	w10, [x11, x8]
	orr	x10, x10, x9, lsl #32
	add	x9, x11, x22
	ldr	w11, [x9, #-4]!
	sub	x8, x9, x8
	ldr	w8, [x8]
	orr	x9, x8, x11, lsl #32
	b	LBB0_196
LBB0_193:                               ;   in Loop: Header=BB0_184 Depth=1
	cbz	x22, LBB0_195
; %bb.194:                              ;   in Loop: Header=BB0_184 Depth=1
	mov	x9, #0                          ; =0x0
	ldr	x11, [sp, #168]                 ; 8-byte Folded Reload
	ldrb	w8, [x11]
	lsr	x10, x22, #1
	ldrb	w10, [x11, x10]
	lsl	x8, x8, #16
	orr	x8, x8, x10, lsl #8
	add	x10, x22, x11
	ldurb	w10, [x10, #-1]
	orr	x10, x8, x10
	b	LBB0_196
LBB0_195:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x10, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
LBB0_196:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_197:                               ;   in Loop: Header=BB0_184 Depth=1
	eor	x11, x22, x26
	eor	x10, x10, x26
	eor	x8, x9, x8
	mul	x9, x8, x10
	umulh	x8, x8, x10
	eor	x8, x9, x8
	mul	x9, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x9
	mov	x9, #30886                      ; =0x78a6
	movk	x9, #43628, lsl #16
	movk	x9, #36300, lsl #32
	movk	x9, #11573, lsl #48
	eor	x8, x8, x9
	mov	x10, #53468                     ; =0xd0dc
	movk	x10, #59748, lsl #16
	movk	x10, #12842, lsl #32
	movk	x10, #5519, lsl #48
	mul	x9, x8, x10
	umulh	x8, x8, x10
	eor	x8, x8, x9
	cmp	x8, #1
	csinc	x26, x8, xzr, hi
	str	x21, [sp, #152]                 ; 8-byte Folded Spill
	cbz	w13, LBB0_206
; %bb.198:                              ;   in Loop: Header=BB0_184 Depth=1
	neg	w8, w13
	lsr	x25, x26, x8
	ldr	x10, [sp, #160]                 ; 8-byte Folded Reload
	ldr	w8, [x10, x25, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_207
; %bb.199:                              ;   in Loop: Header=BB0_184 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	lsl	x9, x9, x13
	mvn	x21, x9
	b	LBB0_201
LBB0_200:                               ;   in Loop: Header=BB0_201 Depth=2
	add	x8, x25, #1
	and	x25, x8, x21
	ldr	w8, [x10, x25, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_207
LBB0_201:                               ;   Parent Loop BB0_184 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	smull	x9, w8, w23
	ldr	x9, [x27, x9]
	cmp	x9, x26
	b.ne	LBB0_200
; %bb.202:                              ;   in Loop: Header=BB0_201 Depth=2
	sxtw	x19, w8
	smaddl	x8, w19, w23, x27
	ldr	x8, [x8, #16]
	cmp	x8, x22
	b.ne	LBB0_200
; %bb.203:                              ;   in Loop: Header=BB0_201 Depth=2
	smaddl	x8, w19, w23, x27
	ldr	x0, [x8, #8]
	ldr	x1, [sp, #168]                  ; 8-byte Folded Reload
	mov	x2, x22
	bl	_memcmp
	ldr	x10, [sp, #160]                 ; 8-byte Folded Reload
	cbnz	w0, LBB0_200
; %bb.204:                              ;   in Loop: Header=BB0_184 Depth=1
	tbnz	w19, #31, LBB0_225
; %bb.205:                              ;   in Loop: Header=BB0_184 Depth=1
	smaddl	x8, w19, w23, x27
	ldr	x9, [x8, #32]
	add	x9, x9, x24
	str	x9, [x8, #32]
	b	LBB0_224
LBB0_206:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x25, #0                         ; =0x0
LBB0_207:                               ;   in Loop: Header=BB0_184 Depth=1
	ldur	x8, [x29, #-152]
	ldr	x9, [sp, #144]                  ; 8-byte Folded Reload
	cmp	x9, x8
	b.ne	LBB0_216
; %bb.208:                              ;   in Loop: Header=BB0_184 Depth=1
	sub	x0, x29, #160
	bl	_smap_room
	ldur	w10, [x29, #-144]
	cbz	w10, LBB0_217
; %bb.209:                              ;   in Loop: Header=BB0_184 Depth=1
	neg	w8, w10
	lsr	x20, x26, x8
	ldp	x19, x27, [x29, #-136]
	ldr	w8, [x27, x20, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_219
; %bb.210:                              ;   in Loop: Header=BB0_184 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	str	x10, [sp, #160]                 ; 8-byte Folded Spill
	lsl	x9, x9, x10
	mvn	x21, x9
	b	LBB0_212
LBB0_211:                               ;   in Loop: Header=BB0_212 Depth=2
	add	x8, x20, #1
	and	x20, x8, x21
	ldr	w8, [x27, x20, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_218
LBB0_212:                               ;   Parent Loop BB0_184 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	smull	x9, w8, w23
	ldr	x9, [x19, x9]
	cmp	x9, x26
	b.ne	LBB0_211
; %bb.213:                              ;   in Loop: Header=BB0_212 Depth=2
	sxtw	x8, w8
	smaddl	x9, w8, w23, x19
	ldr	x9, [x9, #16]
	cmp	x9, x22
	b.ne	LBB0_211
; %bb.214:                              ;   in Loop: Header=BB0_212 Depth=2
	smaddl	x8, w8, w23, x19
	ldr	x0, [x8, #8]
	ldr	x1, [sp, #168]                  ; 8-byte Folded Reload
	mov	x2, x22
	bl	_memcmp
	cbnz	w0, LBB0_211
; %bb.215:                              ;   in Loop: Header=BB0_184 Depth=1
	ldr	x8, [sp, #160]                  ; 8-byte Folded Reload
                                        ; kill: def $w8 killed $w8 killed $x8 def $x8
	str	x8, [sp, #136]                  ; 8-byte Folded Spill
	mov	x20, x25
	b	LBB0_221
LBB0_216:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x20, x25
	ldr	x19, [sp, #128]                 ; 8-byte Folded Reload
	b	LBB0_221
LBB0_217:                               ;   in Loop: Header=BB0_184 Depth=1
	str	xzr, [sp, #136]                 ; 8-byte Folded Spill
	mov	x20, #0                         ; =0x0
	ldur	x19, [x29, #-136]
	b	LBB0_221
LBB0_218:                               ;   in Loop: Header=BB0_184 Depth=1
	ldr	x8, [sp, #160]                  ; 8-byte Folded Reload
                                        ; kill: def $w8 killed $w8 killed $x8 def $x8
	b	LBB0_220
LBB0_219:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x8, x10
LBB0_220:                               ;   in Loop: Header=BB0_184 Depth=1
	str	x8, [sp, #136]                  ; 8-byte Folded Spill
LBB0_221:                               ;   in Loop: Header=BB0_184 Depth=1
	ldur	x8, [x29, #-160]
	madd	x9, x8, x23, x19
	str	x26, [x9], #8
	ldr	x11, [sp, #104]                 ; 8-byte Folded Reload
	ldr	w10, [x11]
	cmp	w10, #1
	b.lt	LBB0_223
; %bb.222:                              ;   in Loop: Header=BB0_184 Depth=1
	add	w10, w10, #1
	str	w10, [x11]
LBB0_223:                               ;   in Loop: Header=BB0_184 Depth=1
	ldr	x10, [sp, #168]                 ; 8-byte Folded Reload
	stp	x10, x22, [x9]
	str	x11, [x9, #16]
	madd	x9, x8, x23, x19
	str	x24, [x9, #32]
	ldur	x10, [x29, #-128]
	str	w8, [x10, x20, lsl #2]
	add	x8, x8, #1
	str	x8, [sp, #144]                  ; 8-byte Folded Spill
	stur	x8, [x29, #-160]
	str	x19, [sp, #128]                 ; 8-byte Folded Spill
	mov	x27, x19
LBB0_224:                               ;   in Loop: Header=BB0_184 Depth=1
	ldp	x21, x19, [sp, #112]            ; 16-byte Folded Reload
	mov	x26, #44233                     ; =0xacc9
	movk	x26, #38446, lsl #16
	movk	x26, #19347, lsl #32
	movk	x26, #35768, lsl #48
	ldr	x8, [sp, #152]                  ; 8-byte Folded Reload
	add	x25, x8, #1
	cmp	x25, x21
	mov	w22, #10                        ; =0xa
	b.lt	LBB0_184
	b	LBB0_235
LBB0_225:                               ;   in Loop: Header=BB0_184 Depth=1
	mov	x25, x20
	b	LBB0_207
LBB0_226:                               ;   in Loop: Header=BB0_184 Depth=1
	ldr	x8, [sp, #88]                   ; 8-byte Folded Reload
	add	x9, x8, x25
	mov	x11, x22
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
	ldr	x13, [sp, #136]                 ; 8-byte Folded Reload
LBB0_227:                               ;   Parent Loop BB0_184 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x10, x11
	ldp	x11, x12, [x9, #16]!
	eor	x11, x11, x26
	eor	x8, x12, x8
	mul	x12, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x12
	sub	x11, x10, #16
	cmp	x11, #16
	b.hi	LBB0_227
; %bb.228:                              ;   in Loop: Header=BB0_184 Depth=1
	add	x9, x9, x10
	ldp	x10, x9, [x9, #-16]
	b	LBB0_197
LBB0_229:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x24, x0
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x23, x0
	mov	x19, #0                         ; =0x0
	mov	x21, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
LBB0_230:
	mov	x0, x22
	bl	_free
	mov	x0, x21
	bl	_free
	ldur	x0, [x29, #-96]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_232
; %bb.231:
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_234
LBB0_232:
	cmp	w8, #1
	b.ne	LBB0_234
; %bb.233:
	bl	_bown_free
LBB0_234:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	stp	x25, x19, [sp]
Lloh37:
	adrp	x0, l_.str.19@PAGE
Lloh38:
	add	x0, x0, l_.str.19@PAGEOFF
	bl	_printf
	sub	x8, x24, x20
Lloh39:
	adrp	x9, l_.str.20@PAGE
Lloh40:
	add	x9, x9, l_.str.20@PAGEOFF
	stp	x9, x8, [sp]
Lloh41:
	adrp	x22, l_.str.11@PAGE
Lloh42:
	add	x22, x22, l_.str.11@PAGEOFF
	mov	x0, x22
	bl	_printf
	sub	x8, x23, x24
Lloh43:
	adrp	x9, l_.str.21@PAGE
Lloh44:
	add	x9, x9, l_.str.21@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x22
	bl	_printf
	sub	x8, x21, x23
Lloh45:
	adrp	x9, l_.str.14@PAGE
Lloh46:
	add	x9, x9, l_.str.14@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x22
	bl	_printf
	sub	x8, x21, x20
Lloh47:
	adrp	x9, l_.str.15@PAGE
Lloh48:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x22
	b	LBB0_325
LBB0_235:
	ldur	x21, [x29, #-136]
	ldr	x24, [sp, #144]                 ; 8-byte Folded Reload
	cmp	x24, #1
	b.lt	LBB0_305
; %bb.236:
	mov	x25, x10
	mov	w8, #16963                      ; =0x4243
	movk	w8, #15, lsl #16
	cmp	x24, #4
	b.hs	LBB0_308
; %bb.237:
	mov	x9, #0                          ; =0x0
	mov	x22, #0                         ; =0x0
	mov	x19, #0                         ; =0x0
	b	LBB0_311
LBB0_238:
	str	xzr, [sp, #168]                 ; 8-byte Folded Spill
	mov	x21, #0                         ; =0x0
	b	LBB0_240
LBB0_239:
	mov	w21, #1                         ; =0x1
LBB0_240:
	ldur	x0, [x29, #-144]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_242
; %bb.241:
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_244
LBB0_242:
	cmp	w8, #1
	b.ne	LBB0_244
; %bb.243:
	bl	_bown_free
LBB0_244:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x23, x0
	ldr	x0, [sp, #168]                  ; 8-byte Folded Reload
	mov	x1, x21
	bl	_qsort_s
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x24, x0
	cbz	x21, LBB0_247
; %bb.245:
	cmp	x21, #3001
	b.hs	LBB0_249
; %bb.246:
	mov	x8, #0                          ; =0x0
	mov	x25, #0                         ; =0x0
	b	LBB0_252
LBB0_247:
	mov	x25, #0                         ; =0x0
LBB0_248:
	ldr	x0, [sp, #168]                  ; 8-byte Folded Reload
	bl	_free
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	stp	x21, x25, [sp]
Lloh49:
	adrp	x0, l_.str.19@PAGE
Lloh50:
	add	x0, x0, l_.str.19@PAGEOFF
	bl	_printf
	ldr	x19, [sp, #152]                 ; 8-byte Folded Reload
	sub	x8, x23, x19
Lloh51:
	adrp	x9, l_.str.23@PAGE
Lloh52:
	add	x9, x9, l_.str.23@PAGEOFF
	stp	x9, x8, [sp]
Lloh53:
	adrp	x21, l_.str.11@PAGE
Lloh54:
	add	x21, x21, l_.str.11@PAGEOFF
	mov	x0, x21
	bl	_printf
	sub	x8, x24, x23
	str	x8, [sp, #8]
Lloh55:
	adrp	x8, l_.str.3@PAGE
Lloh56:
	add	x8, x8, l_.str.3@PAGEOFF
	str	x8, [sp]
	mov	x0, x21
	bl	_printf
	sub	x8, x22, x24
Lloh57:
	adrp	x9, l_.str.14@PAGE
Lloh58:
	add	x9, x9, l_.str.14@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x21
	bl	_printf
	sub	x8, x22, x19
Lloh59:
	adrp	x9, l_.str.15@PAGE
Lloh60:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x21
	b	LBB0_325
LBB0_249:
	mov	x9, #0                          ; =0x0
	mov	x12, #0                         ; =0x0
	mov	x13, #0                         ; =0x0
	mov	x14, #0                         ; =0x0
	mov	x15, #0                         ; =0x0
	sub	x8, x21, #1
	lsr	x8, x8, #3
	mov	x10, #63439                     ; =0xf7cf
	movk	x10, #58195, lsl #16
	movk	x10, #39845, lsl #32
	movk	x10, #8388, lsl #48
	umulh	x8, x8, x10
	lsr	x8, x8, #4
	add	x10, x8, #1
	and	x11, x10, #0xfffffffffffffc
	mov	w8, #1000                       ; =0x3e8
	mul	x8, x11, x8
	mov	w16, #30464                     ; =0x7700
	movk	w16, #1, lsl #16
	mov	w17, #48008                     ; =0xbb88
	ldr	x1, [sp, #168]                  ; 8-byte Folded Reload
	mov	x0, x11
LBB0_250:                               ; =>This Inner Loop Header: Depth=1
	add	x2, x1, x17
	ldr	x3, [x1, #24008]
	ldp	x5, x4, [x1]
	ldr	x6, [x1, #24000]
	add	x1, x1, x16
	add	x7, x9, #1000
	add	x19, x9, #2000
	add	x20, x9, #3000
	ldp	x26, x22, [x2, #-8]
	ldr	x25, [x2, #24000]
	ldr	x2, [x2, #23992]
	ldrb	w5, [x5]
	ldrb	w6, [x6]
	ldrb	w26, [x26]
	madd	x12, x4, x9, x12
	madd	x13, x3, x7, x13
	madd	x14, x22, x19, x14
	madd	x15, x25, x20, x15
	add	x12, x12, x5
	add	x13, x13, x6
	add	x14, x14, x26
	ldrb	w2, [x2]
	add	x15, x15, x2
	add	x9, x9, #4000
	subs	x0, x0, #4
	b.ne	LBB0_250
; %bb.251:
	add	x9, x13, x12
	add	x9, x14, x9
	add	x25, x15, x9
	cmp	x10, x11
	b.eq	LBB0_254
LBB0_252:
	mov	w9, #24                         ; =0x18
	ldr	x10, [sp, #168]                 ; 8-byte Folded Reload
	madd	x9, x8, x9, x10
	add	x9, x9, #8
	mov	w10, #24000                     ; =0x5dc0
LBB0_253:                               ; =>This Inner Loop Header: Depth=1
	ldp	x12, x11, [x9, #-8]
	ldrb	w12, [x12]
	madd	x11, x11, x8, x25
	add	x25, x11, x12
	add	x8, x8, #1000
	add	x9, x9, x10
	cmp	x8, x21
	b.lo	LBB0_253
LBB0_254:
	ldr	x8, [sp, #168]                  ; 8-byte Folded Reload
	add	x19, x8, #16
	mov	x20, x21
	b	LBB0_257
LBB0_255:                               ;   in Loop: Header=BB0_257 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_256:                               ;   in Loop: Header=BB0_257 Depth=1
	add	x19, x19, #24
	subs	x20, x20, #1
	b.eq	LBB0_248
LBB0_257:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x19]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_255
; %bb.258:                              ;   in Loop: Header=BB0_257 Depth=1
	cmp	w8, #1
	b.ne	LBB0_256
; %bb.259:                              ;   in Loop: Header=BB0_257 Depth=1
	bl	_bown_free
	b	LBB0_256
LBB0_260:
	mov	x22, #0                         ; =0x0
	mov	x19, #0                         ; =0x0
	mov	x20, #0                         ; =0x0
	mov	x24, #0                         ; =0x0
	mov	x21, #0                         ; =0x0
	b	LBB0_320
LBB0_261:
	str	xzr, [sp, #152]                 ; 8-byte Folded Spill
	mov	x27, #0                         ; =0x0
LBB0_262:
	ldur	x0, [x29, #-144]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_264
; %bb.263:
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_266
LBB0_264:
	cmp	w8, #1
	b.ne	LBB0_266
; %bb.265:
	bl	_bown_free
LBB0_266:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	cbz	x27, LBB0_306
; %bb.267:
	mov	x23, #0                         ; =0x0
	mov	x24, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	ldr	x8, [sp, #152]                  ; 8-byte Folded Reload
	add	x8, x8, #152
	mov	x9, #30255                      ; =0x762f
	movk	x9, #12081, lsl #16
	movk	x9, #29557, lsl #32
	movk	x9, #29285, lsl #48
	mov	w10, #115                       ; =0x73
	mov	x11, x27
	ldr	x16, [sp, #72]                  ; 8-byte Folded Reload
	b	LBB0_270
LBB0_268:                               ;   in Loop: Header=BB0_270 Depth=1
	ldur	x13, [x8, #-56]
	ldr	x14, [x13]
	ldrb	w13, [x13, #8]
	cmp	x14, x9
	ccmp	w13, w10, #0, eq
	cset	w13, eq
LBB0_269:                               ;   in Loop: Header=BB0_270 Depth=1
	add	x25, x25, w12, uxtw
	add	x8, x8, #160
	add	x23, x23, w13, uxtw
	subs	x11, x11, #1
	b.eq	LBB0_279
LBB0_270:                               ; =>This Inner Loop Header: Depth=1
	ldur	x12, [x8, #-120]
	cmp	x12, #5
	b.ne	LBB0_273
; %bb.271:                              ;   in Loop: Header=BB0_270 Depth=1
	ldur	x12, [x8, #-128]
	cmp	x12, x16
	b.eq	LBB0_274
; %bb.272:                              ;   in Loop: Header=BB0_270 Depth=1
	ldr	w13, [x12]
	ldr	w14, [x16]
	ldrb	w12, [x12, #4]
	ldrb	w15, [x16, #4]
	cmp	w13, w14
	ccmp	w12, w15, #0, eq
	cset	w12, eq
	b	LBB0_275
LBB0_273:                               ;   in Loop: Header=BB0_270 Depth=1
	mov	w12, #0                         ; =0x0
	b	LBB0_275
LBB0_274:                               ;   in Loop: Header=BB0_270 Depth=1
	mov	w12, #1                         ; =0x1
LBB0_275:                               ;   in Loop: Header=BB0_270 Depth=1
	ldur	x13, [x8, #-8]
	cmp	x13, #500
	b.lt	LBB0_277
; %bb.276:                              ;   in Loop: Header=BB0_270 Depth=1
	ldr	x13, [x8]
	add	x24, x13, x24
LBB0_277:                               ;   in Loop: Header=BB0_270 Depth=1
	ldur	x13, [x8, #-48]
	cmp	x13, #9
	b.ge	LBB0_268
; %bb.278:                              ;   in Loop: Header=BB0_270 Depth=1
	mov	w13, #0                         ; =0x0
	b	LBB0_269
LBB0_279:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	ldr	x8, [sp, #152]                  ; 8-byte Folded Reload
	add	x20, x8, #88
	mov	x26, x27
	b	LBB0_282
LBB0_280:                               ;   in Loop: Header=BB0_282 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_281:                               ;   in Loop: Header=BB0_282 Depth=1
	add	x20, x20, #160
	subs	x26, x26, #1
	b.eq	LBB0_307
LBB0_282:                               ; =>This Inner Loop Header: Depth=1
	ldur	x0, [x20, #-72]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_284
; %bb.283:                              ;   in Loop: Header=BB0_282 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_286
LBB0_284:                               ;   in Loop: Header=BB0_282 Depth=1
	cmp	w8, #1
	b.ne	LBB0_286
; %bb.285:                              ;   in Loop: Header=BB0_282 Depth=1
	bl	_bown_free
LBB0_286:                               ;   in Loop: Header=BB0_282 Depth=1
	ldur	x0, [x20, #-48]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_288
; %bb.287:                              ;   in Loop: Header=BB0_282 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_290
LBB0_288:                               ;   in Loop: Header=BB0_282 Depth=1
	cmp	w8, #1
	b.ne	LBB0_290
; %bb.289:                              ;   in Loop: Header=BB0_282 Depth=1
	bl	_bown_free
LBB0_290:                               ;   in Loop: Header=BB0_282 Depth=1
	ldur	x0, [x20, #-24]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_292
; %bb.291:                              ;   in Loop: Header=BB0_282 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_294
LBB0_292:                               ;   in Loop: Header=BB0_282 Depth=1
	cmp	w8, #1
	b.ne	LBB0_294
; %bb.293:                              ;   in Loop: Header=BB0_282 Depth=1
	bl	_bown_free
LBB0_294:                               ;   in Loop: Header=BB0_282 Depth=1
	ldr	x0, [x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_296
; %bb.295:                              ;   in Loop: Header=BB0_282 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_298
LBB0_296:                               ;   in Loop: Header=BB0_282 Depth=1
	cmp	w8, #1
	b.ne	LBB0_298
; %bb.297:                              ;   in Loop: Header=BB0_282 Depth=1
	bl	_bown_free
LBB0_298:                               ;   in Loop: Header=BB0_282 Depth=1
	ldr	x0, [x20, #24]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_300
; %bb.299:                              ;   in Loop: Header=BB0_282 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_302
LBB0_300:                               ;   in Loop: Header=BB0_282 Depth=1
	cmp	w8, #1
	b.ne	LBB0_302
; %bb.301:                              ;   in Loop: Header=BB0_282 Depth=1
	bl	_bown_free
LBB0_302:                               ;   in Loop: Header=BB0_282 Depth=1
	ldr	x0, [x20, #48]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_280
; %bb.303:                              ;   in Loop: Header=BB0_282 Depth=1
	cmp	w8, #1
	b.ne	LBB0_281
; %bb.304:                              ;   in Loop: Header=BB0_282 Depth=1
	bl	_bown_free
	b	LBB0_281
LBB0_305:
	mov	x22, #0                         ; =0x0
	mov	x19, #0                         ; =0x0
	ldr	x23, [sp, #96]                  ; 8-byte Folded Reload
	mov	x20, x10
	b	LBB0_320
LBB0_306:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	mov	x23, #0                         ; =0x0
	mov	x24, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
LBB0_307:
	ldr	x0, [sp, #152]                  ; 8-byte Folded Reload
	bl	_free
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x24, x23, [sp, #16]
	stp	x27, x25, [sp]
Lloh61:
	adrp	x0, l_.str.10@PAGE
Lloh62:
	add	x0, x0, l_.str.10@PAGEOFF
	bl	_printf
	ldr	x19, [sp, #80]                  ; 8-byte Folded Reload
	sub	x8, x21, x19
Lloh63:
	adrp	x9, l_.str.29@PAGE
Lloh64:
	add	x9, x9, l_.str.29@PAGEOFF
	stp	x9, x8, [sp]
Lloh65:
	adrp	x23, l_.str.11@PAGE
Lloh66:
	add	x23, x23, l_.str.11@PAGEOFF
	mov	x0, x23
	bl	_printf
	sub	x8, x22, x21
Lloh67:
	adrp	x9, l_.str.30@PAGE
Lloh68:
	add	x9, x9, l_.str.30@PAGEOFF
	b	LBB0_181
LBB0_308:
	mov	x11, #0                         ; =0x0
	mov	x13, #0                         ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x12, #0                         ; =0x0
	mov	x15, #0                         ; =0x0
	mov	x17, #0                         ; =0x0
	mov	x14, #0                         ; =0x0
	mov	x16, #0                         ; =0x0
	and	x9, x24, #0xfffffffffffffffc
	add	x0, x21, #96
	mov	x1, x9
LBB0_309:                               ; =>This Inner Loop Header: Depth=1
	ldur	x2, [x0, #-80]
	ldur	x3, [x0, #-40]
	ldr	x4, [x0]
	ldr	x5, [x0, #40]
	ldur	x6, [x0, #-64]
	ldur	x7, [x0, #-24]
	ldr	x19, [x0, #16]
	ldr	x20, [x0, #56]
	madd	x2, x2, x8, x6
	madd	x3, x3, x8, x7
	madd	x4, x4, x8, x19
	madd	x5, x5, x8, x20
	eor	x15, x2, x15
	eor	x17, x3, x17
	eor	x14, x4, x14
	eor	x16, x5, x16
	add	x11, x6, x11
	add	x13, x7, x13
	add	x10, x19, x10
	add	x12, x20, x12
	add	x0, x0, #160
	subs	x1, x1, #4
	b.ne	LBB0_309
; %bb.310:
	eor	x15, x17, x15
	eor	x14, x16, x14
	eor	x19, x14, x15
	add	x11, x13, x11
	add	x10, x12, x10
	add	x22, x10, x11
	cmp	x24, x9
	b.eq	LBB0_313
LBB0_311:
	sub	x10, x24, x9
	mov	w11, #40                        ; =0x28
	madd	x9, x9, x11, x21
	add	x9, x9, #32
LBB0_312:                               ; =>This Inner Loop Header: Depth=1
	ldur	x11, [x9, #-16]
	ldr	x12, [x9], #40
	madd	x11, x11, x8, x12
	eor	x19, x11, x19
	add	x22, x12, x22
	subs	x10, x10, #1
	b.ne	LBB0_312
LBB0_313:
	mov	w20, #24                        ; =0x18
	mov	x23, x24
	b	LBB0_316
LBB0_314:                               ;   in Loop: Header=BB0_316 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_315:                               ;   in Loop: Header=BB0_316 Depth=1
	add	x20, x20, #40
	subs	x23, x23, #1
	b.eq	LBB0_319
LBB0_316:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x21, x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_314
; %bb.317:                              ;   in Loop: Header=BB0_316 Depth=1
	cmp	w8, #1
	b.ne	LBB0_315
; %bb.318:                              ;   in Loop: Header=BB0_316 Depth=1
	bl	_bown_free
	b	LBB0_315
LBB0_319:
	ldr	x23, [sp, #96]                  ; 8-byte Folded Reload
	mov	x20, x25
LBB0_320:
	mov	x0, x21
	bl	_free
	mov	x0, x20
	bl	_free
	ldur	x0, [x29, #-96]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_322
; %bb.321:
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_324
LBB0_322:
	cmp	w8, #1
	b.ne	LBB0_324
; %bb.323:
	bl	_bown_free
LBB0_324:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x22, x19, [sp, #8]
	str	x24, [sp]
Lloh69:
	adrp	x0, l_.str.25@PAGE
Lloh70:
	add	x0, x0, l_.str.25@PAGEOFF
	bl	_printf
	sub	x8, x20, x23
Lloh71:
	adrp	x9, l_.str.15@PAGE
Lloh72:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
Lloh73:
	adrp	x0, l_.str.11@PAGE
Lloh74:
	add	x0, x0, l_.str.11@PAGEOFF
LBB0_325:
	bl	_printf
LBB0_326:
Lloh75:
	adrp	x8, l_.str.7@PAGE
Lloh76:
	add	x8, x8, l_.str.7@PAGEOFF
	str	x8, [sp]
Lloh77:
	adrp	x0, l_.str.6@PAGE
Lloh78:
	add	x0, x0, l_.str.6@PAGEOFF
	bl	_printf
	mov	w0, #0                          ; =0x0
LBB0_327:
	ldp	x29, x30, [sp, #336]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #320]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #304]            ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #288]            ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #272]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #256]            ; 16-byte Folded Reload
	add	sp, sp, #352
	ret
LBB0_328:
	mov	w0, #3                          ; =0x3
	bl	_alloc_slow
	b	LBB0_42
LBB0_329:
	mov	w0, #3                          ; =0x3
	bl	_alloc_slow
	b	LBB0_9
	.loh AdrpAdd	Lloh3, Lloh4
	.loh AdrpLdrGotLdr	Lloh0, Lloh1, Lloh2
	.loh AdrpAdd	Lloh5, Lloh6
	.loh AdrpAdd	Lloh7, Lloh8
	.loh AdrpAdd	Lloh9, Lloh10
	.loh AdrpAdd	Lloh11, Lloh12
	.loh AdrpAdd	Lloh13, Lloh14
	.loh AdrpAdd	Lloh15, Lloh16
	.loh AdrpAdd	Lloh17, Lloh18
	.loh AdrpAdd	Lloh19, Lloh20
	.loh AdrpAdd	Lloh21, Lloh22
	.loh AdrpAdd	Lloh29, Lloh30
	.loh AdrpAdd	Lloh27, Lloh28
	.loh AdrpAdd	Lloh25, Lloh26
	.loh AdrpAdd	Lloh23, Lloh24
	.loh AdrpAdd	Lloh33, Lloh34
	.loh AdrpAdd	Lloh31, Lloh32
	.loh AdrpAdd	Lloh35, Lloh36
	.loh AdrpAdd	Lloh47, Lloh48
	.loh AdrpAdd	Lloh45, Lloh46
	.loh AdrpAdd	Lloh43, Lloh44
	.loh AdrpAdd	Lloh41, Lloh42
	.loh AdrpAdd	Lloh39, Lloh40
	.loh AdrpAdd	Lloh37, Lloh38
	.loh AdrpAdd	Lloh59, Lloh60
	.loh AdrpAdd	Lloh57, Lloh58
	.loh AdrpAdd	Lloh55, Lloh56
	.loh AdrpAdd	Lloh53, Lloh54
	.loh AdrpAdd	Lloh51, Lloh52
	.loh AdrpAdd	Lloh49, Lloh50
	.loh AdrpAdd	Lloh67, Lloh68
	.loh AdrpAdd	Lloh65, Lloh66
	.loh AdrpAdd	Lloh63, Lloh64
	.loh AdrpAdd	Lloh61, Lloh62
	.loh AdrpAdd	Lloh73, Lloh74
	.loh AdrpAdd	Lloh71, Lloh72
	.loh AdrpAdd	Lloh69, Lloh70
	.loh AdrpAdd	Lloh77, Lloh78
	.loh AdrpAdd	Lloh75, Lloh76
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function load
_load:                                  ; @load
	.cfi_startproc
; %bb.0:
	stp	x24, x23, [sp, #-64]!           ; 16-byte Folded Spill
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	add	x29, sp, #48
	sub	sp, sp, #688
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	x19, x8
Lloh79:
	adrp	x8, ___stack_chk_guard@GOTPAGE
Lloh80:
	ldr	x8, [x8, ___stack_chk_guard@GOTPAGEOFF]
Lloh81:
	ldr	x8, [x8]
	stur	x8, [x29, #-56]
	stp	x0, x1, [sp]
Lloh82:
	adrp	x2, l_.str.16@PAGE
Lloh83:
	add	x2, x2, l_.str.16@PAGEOFF
	add	x0, sp, #168
	mov	w1, #512                        ; =0x200
	bl	_snprintf
	add	x0, sp, #168
	mov	w1, #0                          ; =0x0
	bl	_open
	tbnz	w0, #31, LBB1_13
; %bb.1:
	mov	x22, x0
	add	x1, sp, #24
	bl	_fstat
	ldr	x8, [sp, #120]
	add	x0, x8, #1
	bl	_malloc
	cbz	x0, LBB1_14
; %bb.2:
	mov	x20, x0
	mov	x8, #0                          ; =0x0
LBB1_3:                                 ; =>This Inner Loop Header: Depth=1
	mov	x21, x8
	ldr	x8, [sp, #120]
	subs	x2, x8, x21
	b.le	LBB1_5
; %bb.4:                                ;   in Loop: Header=BB1_3 Depth=1
	add	x1, x20, x21
	mov	x0, x22
	bl	_read
	add	x8, x0, x21
	cmp	x0, #0
	b.gt	LBB1_3
LBB1_5:
	mov	x0, x22
	bl	_close
	strb	wzr, [x20, x21]
	add	x8, x21, #23
	cmp	x8, #519
	b.hi	LBB1_10
; %bb.6:
	lsr	x0, x8, #3
Lloh84:
	adrp	x8, _heap@PAGE
Lloh85:
	add	x8, x8, _heap@PAGEOFF
	ldr	x22, [x8, x0, lsl #3]
	cbz	x22, LBB1_11
; %bb.7:
	ldr	x9, [x22]
	str	x9, [x8, x0, lsl #3]
LBB1_8:
	mov	w8, #1                          ; =0x1
	str	w8, [x22]
	mov	w8, #2                          ; =0x2
	strh	w8, [x22, #4]
	str	x21, [x22, #8]
	add	x23, x22, #16
	mov	x0, x23
	mov	x1, x20
	mov	x2, x21
	bl	_memcpy
	stp	x23, x21, [x19]
	str	x22, [x19, #16]
	mov	x0, x20
	bl	_free
	ldur	x8, [x29, #-56]
Lloh86:
	adrp	x9, ___stack_chk_guard@GOTPAGE
Lloh87:
	ldr	x9, [x9, ___stack_chk_guard@GOTPAGEOFF]
Lloh88:
	ldr	x9, [x9]
	cmp	x9, x8
	b.ne	LBB1_15
; %bb.9:
	add	sp, sp, #688
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	ret
LBB1_10:
	add	x0, x21, #16
	bl	_xmalloc
	b	LBB1_12
LBB1_11:
	bl	_alloc_slow
LBB1_12:
	mov	x22, x0
	b	LBB1_8
LBB1_13:
	add	x0, sp, #168
	bl	_load.cold.1
LBB1_14:
Lloh89:
	adrp	x8, ___stderrp@GOTPAGE
Lloh90:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh91:
	ldr	x1, [x8]
Lloh92:
	adrp	x0, l_.str.17@PAGE
Lloh93:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
LBB1_15:
	bl	___stack_chk_fail
	.loh AdrpAdd	Lloh82, Lloh83
	.loh AdrpLdrGotLdr	Lloh79, Lloh80, Lloh81
	.loh AdrpAdd	Lloh84, Lloh85
	.loh AdrpLdrGotLdr	Lloh86, Lloh87, Lloh88
	.loh AdrpAdd	Lloh92, Lloh93
	.loh AdrpLdrGotLdr	Lloh89, Lloh90, Lloh91
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function xmalloc
_xmalloc:                               ; @xmalloc
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_malloc
	cbz	x0, LBB2_2
; %bb.1:
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
LBB2_2:
Lloh94:
	adrp	x8, ___stderrp@GOTPAGE
Lloh95:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh96:
	ldr	x1, [x8]
Lloh97:
	adrp	x0, l_.str.17@PAGE
Lloh98:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
	.loh AdrpAdd	Lloh97, Lloh98
	.loh AdrpLdrGotLdr	Lloh94, Lloh95, Lloh96
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function alloc_slow
_alloc_slow:                            ; @alloc_slow
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	add	x29, sp, #16
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	lsl	x19, x0, #3
Lloh99:
	adrp	x8, _heap@PAGE+520
Lloh100:
	add	x8, x8, _heap@PAGEOFF+520
	ldp	x0, x9, [x8]
	sub	x8, x9, x0
	cmp	x8, x19
	b.hs	LBB3_3
; %bb.1:
	mov	w0, #1048576                    ; =0x100000
	bl	_malloc
	cbz	x0, LBB3_4
; %bb.2:
	add	x8, x0, #256, lsl #12           ; =1048576
	adrp	x9, _heap@PAGE+528
	str	x8, [x9, _heap@PAGEOFF+528]
LBB3_3:
	add	x8, x0, x19
	adrp	x9, _heap@PAGE+520
	str	x8, [x9, _heap@PAGEOFF+520]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB3_4:
Lloh101:
	adrp	x8, ___stderrp@GOTPAGE
Lloh102:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh103:
	ldr	x1, [x8]
Lloh104:
	adrp	x0, l_.str.17@PAGE
Lloh105:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
	.loh AdrpAdd	Lloh99, Lloh100
	.loh AdrpAdd	Lloh104, Lloh105
	.loh AdrpLdrGotLdr	Lloh101, Lloh102, Lloh103
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function bown_free
_bown_free:                             ; @bown_free
	.cfi_startproc
; %bb.0:
	ldr	x8, [x0, #8]
	add	x8, x8, #23
	cmp	x8, #519
	b.hi	LBB4_2
; %bb.1:
Lloh106:
	adrp	x9, _heap@PAGE
Lloh107:
	add	x9, x9, _heap@PAGEOFF
	and	x8, x8, #0xfffffffffffffff8
	ldr	x10, [x9, x8]
	str	x10, [x0]
	str	x0, [x9, x8]
	ret
LBB4_2:
	b	_free
	.loh AdrpAdd	Lloh106, Lloh107
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function smap_room
_smap_room:                             ; @smap_room
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	add	x29, sp, #32
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x0
	ldr	x8, [x0, #8]
	lsl	x9, x8, #1
	mov	w10, #8                         ; =0x8
	cmp	x8, #8
	csel	x20, x10, x9, lt
	ldr	x0, [x0, #24]
	add	x8, x20, x20, lsl #2
	lsl	x1, x8, #3
	bl	_realloc
	str	x0, [x19, #24]
	str	x20, [x19, #8]
	add	x8, x20, x20, lsl #1
	mov	x21, #-62                       ; =0xffffffffffffffc2
	mov	w9, #2                          ; =0x2
LBB5_1:                                 ; =>This Inner Loop Header: Depth=1
	add	x10, x21, #65
	lsl	x10, x9, x10
	add	x21, x21, #1
	cmp	x10, x8
	b.lt	LBB5_1
; %bb.2:
	add	x22, x21, #64
	ldr	w8, [x19, #16]
	sub	w8, w21, w8
	ldr	x0, [x19, #32]
	cmn	w8, #64
	b.ne	LBB5_4
; %bb.3:
	mov	w8, #4                          ; =0x4
	lsl	x20, x8, x22
	b	LBB5_6
LBB5_4:
	bl	_free
	mov	w8, #4                          ; =0x4
	lsl	x20, x8, x22
	mov	x0, x20
	bl	_malloc
	cbz	x0, LBB5_13
; %bb.5:
	str	x0, [x19, #32]
	str	w22, [x19, #16]
LBB5_6:
	mov	w1, #255                        ; =0xff
	mov	x2, x20
	bl	_memset
	ldr	x8, [x19]
	cmp	x8, #1
	b.lt	LBB5_12
; %bb.7:
	mov	x9, #0                          ; =0x0
	mov	x10, #-1                        ; =0xffffffffffffffff
	lsl	x10, x10, x22
	mvn	x10, x10
	neg	w11, w21
	ldp	x12, x13, [x19, #24]
	mov	w14, #40                        ; =0x28
	b	LBB5_9
LBB5_8:                                 ;   in Loop: Header=BB5_9 Depth=1
	str	w9, [x13, x15, lsl #2]
	add	x9, x9, #1
	cmp	x9, x8
	b.eq	LBB5_12
LBB5_9:                                 ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB5_10 Depth 2
	mul	x15, x9, x14
	ldr	x15, [x12, x15]
	lsr	x15, x15, x11
LBB5_10:                                ;   Parent Loop BB5_9 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w16, [x13, x15, lsl #2]
	cmn	w16, #1
	b.eq	LBB5_8
; %bb.11:                               ;   in Loop: Header=BB5_10 Depth=2
	add	x15, x15, #1
	and	x15, x15, x10
	b	LBB5_10
LBB5_12:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
LBB5_13:
Lloh108:
	adrp	x8, ___stderrp@GOTPAGE
Lloh109:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh110:
	ldr	x1, [x8]
Lloh111:
	adrp	x0, l_.str.17@PAGE
Lloh112:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
	.loh AdrpAdd	Lloh111, Lloh112
	.loh AdrpLdrGotLdr	Lloh108, Lloh109, Lloh110
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function qsort_s
_qsort_s:                               ; @qsort_s
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #144
	stp	x28, x27, [sp, #48]             ; 16-byte Folded Spill
	stp	x26, x25, [sp, #64]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #80]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #96]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #112]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #128]            ; 16-byte Folded Spill
	add	x29, sp, #128
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	mov	x26, x1
	mov	x24, x0
	cmp	x1, #17
	b.ge	LBB6_12
; %bb.1:
	mov	x22, x26
	mov	x23, x24
LBB6_2:
	cmp	x22, #2
	b.lt	LBB6_26
; %bb.3:
	mov	w20, #1                         ; =0x1
	mov	w21, #2                         ; =0x2
	mov	w9, #24                         ; =0x18
	mov	x24, x23
	b	LBB6_6
LBB6_4:                                 ;   in Loop: Header=BB6_6 Depth=1
	sub	x8, x28, #1
LBB6_5:                                 ;   in Loop: Header=BB6_6 Depth=1
	mov	w9, #24                         ; =0x18
	madd	x8, x8, x9, x23
	stp	x19, x26, [x8]
	ldr	x10, [sp, #8]                   ; 8-byte Folded Reload
	str	x10, [x8, #16]
	add	x20, x20, #1
	add	x21, x21, #1
	add	x24, x24, #24
	cmp	x20, x22
	b.eq	LBB6_26
LBB6_6:                                 ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB6_7 Depth 2
	madd	x8, x20, x9, x23
	ldp	x19, x26, [x8]
	ldr	x8, [x8, #16]
	str	x8, [sp, #8]                    ; 8-byte Folded Spill
	mov	x25, x24
	mov	x28, x21
LBB6_7:                                 ;   Parent Loop BB6_6 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldp	x1, x8, [x25]
	cmp	x26, x8
	csel	x2, x26, x8, lt
	cset	w27, lt
	mov	x0, x19
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w27, w8, eq
	cmp	w8, #1
	b.ne	LBB6_4
; %bb.8:                                ;   in Loop: Header=BB6_7 Depth=2
	ldr	q0, [x25]
	stur	q0, [x25, #24]
	ldr	x8, [x25, #16]
	str	x8, [x25, #40]
	sub	x28, x28, #1
	sub	x25, x25, #24
	cmp	x28, #1
	b.gt	LBB6_7
; %bb.9:                                ;   in Loop: Header=BB6_6 Depth=1
	mov	x8, #0                          ; =0x0
	b	LBB6_5
LBB6_10:                                ;   in Loop: Header=BB6_12 Depth=1
	mov	x0, x23
	mov	x1, x20
	bl	_qsort_s
	ldr	x24, [sp]                       ; 8-byte Folded Reload
	mov	x23, x24
LBB6_11:                                ;   in Loop: Header=BB6_12 Depth=1
	mov	x26, x22
	cmp	x22, #16
	b.le	LBB6_2
LBB6_12:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB6_18 Depth 2
                                        ;       Child Loop BB6_19 Depth 3
                                        ;       Child Loop BB6_21 Depth 3
	lsr	x8, x26, #1
	mov	w23, #24                        ; =0x18
	madd	x22, x8, x23, x24
	mov	x20, x22
	ldr	x25, [x20, #8]!
	ldr	x21, [x22]
	ldp	x1, x8, [x24]
	cmp	x25, x8
	csel	x2, x25, x8, lt
	cset	w19, lt
	mov	x0, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w19, w8, eq
	cmp	w8, #1
	b.ne	LBB6_14
; %bb.13:                               ;   in Loop: Header=BB6_12 Depth=1
	ldr	q0, [x22]
	ldr	x8, [x22, #16]
	str	x8, [sp, #32]
	str	q0, [sp, #16]
	ldr	q0, [x24]
	ldr	x8, [x24, #16]
	str	x8, [x22, #16]
	str	q0, [x22]
	ldr	q0, [sp, #16]
	ldr	x8, [sp, #32]
	str	x8, [x24, #16]
	str	q0, [x24]
	ldr	x25, [x20]
	ldr	x21, [x22]
LBB6_14:                                ;   in Loop: Header=BB6_12 Depth=1
	str	x26, [sp, #8]                   ; 8-byte Folded Spill
	sub	x26, x26, #1
	madd	x19, x26, x23, x24
	ldp	x0, x8, [x19]
	cmp	x8, x25
	csel	x2, x8, x25, lt
	cset	w23, lt
	mov	x1, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w23, w8, eq
	cmp	w8, #1
	b.ne	LBB6_17
; %bb.15:                               ;   in Loop: Header=BB6_12 Depth=1
	ldr	q0, [x19]
	ldr	x8, [x19, #16]
	str	x8, [sp, #32]
	str	q0, [sp, #16]
	ldr	q0, [x22]
	ldr	x8, [x22, #16]
	str	x8, [x19, #16]
	str	q0, [x19]
	ldr	q0, [sp, #16]
	ldr	x8, [sp, #32]
	str	x8, [x22, #16]
	str	q0, [x22]
	ldr	x25, [x20]
	ldr	x21, [x22]
	ldp	x1, x8, [x24]
	cmp	x25, x8
	csel	x2, x25, x8, lt
	cset	w19, lt
	mov	x0, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w19, w8, eq
	cmp	w8, #1
	b.ne	LBB6_17
; %bb.16:                               ;   in Loop: Header=BB6_12 Depth=1
	ldr	q0, [x22]
	ldr	x8, [x22, #16]
	str	x8, [sp, #32]
	str	q0, [sp, #16]
	ldr	q0, [x24]
	ldr	x8, [x24, #16]
	str	x8, [x22, #16]
	str	q0, [x22]
	ldr	q0, [sp, #16]
	ldr	x8, [sp, #32]
	str	x8, [x24, #16]
	str	q0, [x24]
	ldp	x21, x25, [x22]
LBB6_17:                                ;   in Loop: Header=BB6_12 Depth=1
	mov	x27, #0                         ; =0x0
	sub	x28, x24, #24
	str	x24, [sp]                       ; 8-byte Folded Spill
	add	x20, x24, #48
LBB6_18:                                ;   Parent Loop BB6_12 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB6_19 Depth 3
                                        ;       Child Loop BB6_21 Depth 3
	mov	w8, #24                         ; =0x18
	madd	x19, x27, x8, x28
LBB6_19:                                ;   Parent Loop BB6_12 Depth=1
                                        ;     Parent Loop BB6_18 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldp	x0, x8, [x19, #24]!
	cmp	x8, x25
	csel	x2, x8, x25, lt
	cset	w22, lt
	mov	x1, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w22, w8, eq
	add	x27, x27, #1
	tbnz	w8, #0, LBB6_19
; %bb.20:                               ;   in Loop: Header=BB6_18 Depth=2
	sub	x24, x27, #1
	add	x22, x26, #2
	mov	w8, #24                         ; =0x18
	madd	x23, x26, x8, x20
LBB6_21:                                ;   Parent Loop BB6_12 Depth=1
                                        ;     Parent Loop BB6_18 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldp	x1, x8, [x23, #-48]
	cmp	x25, x8
	csel	x2, x25, x8, lt
	cset	w26, lt
	mov	x0, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w26, w8, eq
	sub	x22, x22, #1
	sub	x23, x23, #24
	tbnz	w8, #0, LBB6_21
; %bb.22:                               ;   in Loop: Header=BB6_18 Depth=2
	sub	x8, x22, #1
	cmp	x24, x8
	b.ge	LBB6_24
; %bb.23:                               ;   in Loop: Header=BB6_18 Depth=2
	sub	x26, x22, #2
	sub	x8, x23, #24
	ldr	q0, [x19]
	ldr	x9, [x19, #16]
	str	x9, [sp, #32]
	str	q0, [sp, #16]
	ldr	q0, [x8]
	ldr	x9, [x8, #16]
	str	x9, [x19, #16]
	str	q0, [x19]
	ldr	q0, [sp, #16]
	ldr	x9, [sp, #32]
	str	x9, [x8, #16]
	str	q0, [x8]
	b	LBB6_18
LBB6_24:                                ;   in Loop: Header=BB6_12 Depth=1
	ldr	x8, [sp, #8]                    ; 8-byte Folded Reload
	sub	x20, x8, x22
	cmp	x22, x20
	b.ge	LBB6_10
; %bb.25:                               ;   in Loop: Header=BB6_12 Depth=1
	ldr	x0, [sp]                        ; 8-byte Folded Reload
	mov	x1, x22
	bl	_qsort_s
	mov	x22, x20
	mov	x24, x23
	b	LBB6_11
LBB6_26:
	ldp	x29, x30, [sp, #128]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #112]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #96]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #80]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #64]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #48]             ; 16-byte Folded Reload
	add	sp, sp, #144
	ret
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function load.cold.1
_load.cold.1:                           ; @load.cold.1
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_perror
	mov	w0, #1                          ; =0x1
	bl	_exit
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
l_.str:                                 ; @.str
	.asciz	"usage: b1 tok|map|sort|group|logs <datadir>\n"

l_.str.1:                               ; @.str.1
	.asciz	"tok"

l_.str.2:                               ; @.str.2
	.asciz	"map"

l_.str.3:                               ; @.str.3
	.asciz	"sort"

l_.str.4:                               ; @.str.4
	.asciz	"group"

l_.str.5:                               ; @.str.5
	.asciz	"logs"

l_.str.6:                               ; @.str.6
	.asciz	"repr=%s\n"

l_.str.7:                               ; @.str.7
	.asciz	"B24"

l_.str.8:                               ; @.str.8
	.asciz	"tok.txt"

l_.str.9:                               ; @.str.9
	.asciz	"return"

l_.str.10:                              ; @.str.10
	.asciz	"check=%lld,%lld,%lld,%lld\n"

l_.str.11:                              ; @.str.11
	.asciz	"%s_ns=%llu\n"

l_.str.12:                              ; @.str.12
	.asciz	"scan"

l_.str.13:                              ; @.str.13
	.asciz	"use"

l_.str.14:                              ; @.str.14
	.asciz	"drop"

l_.str.15:                              ; @.str.15
	.asciz	"total"

l_.str.16:                              ; @.str.16
	.asciz	"%s/%s"

l_.str.17:                              ; @.str.17
	.asciz	"out of memory\n"

.zerofill __DATA,__bss,_heap,536,3      ; @heap
l_.str.18:                              ; @.str.18
	.asciz	"keys.txt"

l_.str.19:                              ; @.str.19
	.asciz	"check=%lld,%lld\n"

l_.str.20:                              ; @.str.20
	.asciz	"build"

l_.str.21:                              ; @.str.21
	.asciz	"lookup"

l_.str.22:                              ; @.str.22
	.asciz	"sort.txt"

l_.str.23:                              ; @.str.23
	.asciz	"slice"

l_.str.24:                              ; @.str.24
	.asciz	"rows.csv"

l_.str.25:                              ; @.str.25
	.asciz	"check=%lld,%lld,%lld\n"

l_.str.26:                              ; @.str.26
	.asciz	"logs.txt"

l_.str.27:                              ; @.str.27
	.asciz	"ERROR"

l_.str.28:                              ; @.str.28
	.asciz	"/v1/users"

l_.str.29:                              ; @.str.29
	.asciz	"parse"

l_.str.30:                              ; @.str.30
	.asciz	"query"

.subsections_via_symbols
