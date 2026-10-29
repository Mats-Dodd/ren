	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 15, 0	sdk_version 15, 2
	.globl	_main                           ; -- Begin function main
	.p2align	2
_main:                                  ; @main
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #432
	stp	d15, d14, [sp, #272]            ; 16-byte Folded Spill
	stp	d13, d12, [sp, #288]            ; 16-byte Folded Spill
	stp	d11, d10, [sp, #304]            ; 16-byte Folded Spill
	stp	d9, d8, [sp, #320]              ; 16-byte Folded Spill
	stp	x28, x27, [sp, #336]            ; 16-byte Folded Spill
	stp	x26, x25, [sp, #352]            ; 16-byte Folded Spill
	stp	x24, x23, [sp, #368]            ; 16-byte Folded Spill
	stp	x22, x21, [sp, #384]            ; 16-byte Folded Spill
	stp	x20, x19, [sp, #400]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #416]            ; 16-byte Folded Spill
	add	x29, sp, #416
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
	.cfi_offset b8, -104
	.cfi_offset b9, -112
	.cfi_offset b10, -120
	.cfi_offset b11, -128
	.cfi_offset b12, -136
	.cfi_offset b13, -144
	.cfi_offset b14, -152
	.cfi_offset b15, -160
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
	b	LBB0_335
LBB0_2:
	ldp	x21, x20, [x1, #8]
Lloh5:
	adrp	x1, l_.str.1@PAGE
Lloh6:
	add	x1, x1, l_.str.1@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_13
; %bb.3:
Lloh7:
	adrp	x1, l_.str.2@PAGE
Lloh8:
	add	x1, x1, l_.str.2@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_19
; %bb.4:
Lloh9:
	adrp	x27, l_.str.3@PAGE
Lloh10:
	add	x27, x27, l_.str.3@PAGEOFF
	mov	x0, x21
	mov	x1, x27
	bl	_strcmp
	cbz	w0, LBB0_82
; %bb.5:
Lloh11:
	adrp	x1, l_.str.4@PAGE
Lloh12:
	add	x1, x1, l_.str.4@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbz	w0, LBB0_156
; %bb.6:
Lloh13:
	adrp	x1, l_.str.5@PAGE
Lloh14:
	add	x1, x1, l_.str.5@PAGEOFF
	mov	x0, x21
	bl	_strcmp
	cbnz	w0, LBB0_334
; %bb.7:
Lloh15:
	adrp	x1, l_.str.26@PAGE
Lloh16:
	add	x1, x1, l_.str.26@PAGEOFF
	mov	x0, x20
	bl	_load
	str	x0, [sp, #168]                  ; 8-byte Folded Spill
	mov	x19, x1
	adrp	x8, _heap@PAGE+24
	ldr	x0, [x8, _heap@PAGEOFF+24]
	cbz	x0, LBB0_337
; %bb.8:
	ldr	x9, [x0]
	str	x9, [x8, _heap@PAGEOFF+24]
LBB0_9:
	mov	w8, #2                          ; =0x2
	strh	w8, [x0, #4]
	mov	w8, #5                          ; =0x5
	str	x8, [x0, #8]
	mov	w8, #21061                      ; =0x5245
	movk	w8, #20306, lsl #16
	mov	x9, x0
	str	w8, [x9, #16]!
	stp	x9, x0, [sp, #40]               ; 16-byte Folded Spill
	mov	w8, #82                         ; =0x52
	strb	w8, [x0, #20]
	lsr	x20, x19, #32
	str	wzr, [x0]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	str	x0, [sp, #56]                   ; 8-byte Folded Spill
	cbnz	x20, LBB0_242
; %bb.10:
	str	xzr, [sp, #176]                 ; 8-byte Folded Spill
	mov	x24, #0                         ; =0x0
	ldr	x0, [sp, #168]                  ; 8-byte Folded Reload
LBB0_11:
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_272
; %bb.12:
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_274
LBB0_13:
Lloh17:
	adrp	x1, l_.str.8@PAGE
Lloh18:
	add	x1, x1, l_.str.8@PAGEOFF
	mov	x0, x20
	bl	_load
	mov	x22, x0
	stur	x1, [x29, #-200]                ; 8-byte Folded Spill
	adrp	x8, _heap@PAGE+24
	ldr	x21, [x8, _heap@PAGEOFF+24]
	cbz	x21, LBB0_336
; %bb.14:
	ldr	x9, [x21]
	str	x9, [x8, _heap@PAGEOFF+24]
LBB0_15:
	mov	w8, #2                          ; =0x2
	strh	w8, [x21, #4]
	mov	w8, #6                          ; =0x6
	str	x8, [x21, #8]
	mov	w8, #25970                      ; =0x6572
	movk	w8, #30068, lsl #16
	mov	x9, x21
	str	w8, [x9, #16]!
	str	x9, [sp, #200]                  ; 8-byte Folded Spill
	mov	w8, #28274                      ; =0x6e72
	strh	w8, [x21, #20]
	str	wzr, [x21]
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	str	x0, [sp, #208]                  ; 8-byte Folded Spill
	ldur	x11, [x29, #-200]               ; 8-byte Folded Reload
	lsr	x20, x11, #32
	cbnz	x20, LBB0_21
; %bb.16:
	mov	x0, #0                          ; =0x0
	mov	x24, #0                         ; =0x0
LBB0_17:
	ldr	w8, [x22]
	mov	x27, x0
	cmp	w8, #2
	b.lt	LBB0_66
; %bb.18:
	sub	w8, w8, #1
	str	w8, [x22]
	b	LBB0_68
LBB0_19:
Lloh19:
	adrp	x1, l_.str.18@PAGE
Lloh20:
	add	x1, x1, l_.str.18@PAGEOFF
	mov	x0, x20
	bl	_load
	mov	x28, x0
	mov	x19, x1
	lsr	x20, x1, #32
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	stur	xzr, [x29, #-160]
	movi.2d	v0, #0000000000000000
	stp	q0, q0, [x29, #-192]
	cbnz	x20, LBB0_89
; %bb.20:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x26, x0
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x24, x0
	mov	x19, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	mov	x23, #0                         ; =0x0
	b	LBB0_217
LBB0_21:
	mov	x24, #0                         ; =0x0
	mov	x12, #0                         ; =0x0
	mov	x0, #0                          ; =0x0
	mov	x23, #0                         ; =0x0
	and	x8, x11, #0xffffffff
	add	x9, x22, x8
	add	x28, x9, #16
	sub	x19, x20, #1
	add	x8, x8, x22
	add	x27, x8, #17
	mov	w13, #1                         ; =0x1
	mov	x14, #1536                      ; =0x600
	movk	x14, #1, lsl #32
	mov	w15, #24                        ; =0x18
	mov	x16, #8804682956800             ; =0x80200000000
	movk	x16, #28672, lsl #48
	b	LBB0_24
LBB0_22:                                ;   in Loop: Header=BB0_24 Depth=1
	add	x26, x23, #1
LBB0_23:                                ;   in Loop: Header=BB0_24 Depth=1
	mov	x23, x26
	cmp	x26, x20
	b.ge	LBB0_17
LBB0_24:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_44 Depth 2
                                        ;     Child Loop BB0_37 Depth 2
                                        ;     Child Loop BB0_30 Depth 2
	ldrb	w8, [x28, x23]
	cmp	w8, #32
	lsl	x9, x13, x8
	and	x9, x9, x14
	ccmp	x9, #0, #4, ls
	b.ne	LBB0_22
; %bb.25:                               ;   in Loop: Header=BB0_24 Depth=1
	add	x26, x23, #1
	cmp	w8, #95
	b.eq	LBB0_27
; %bb.26:                               ;   in Loop: Header=BB0_24 Depth=1
	orr	w9, w8, #0x20
	sub	w9, w9, #97
	cmp	w9, #25
	b.hi	LBB0_34
LBB0_27:                                ;   in Loop: Header=BB0_24 Depth=1
	cmp	x26, x20
	b.ge	LBB0_33
; %bb.28:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	x8, x23
	b	LBB0_30
LBB0_29:                                ;   in Loop: Header=BB0_30 Depth=2
	add	x8, x8, #1
	cmp	x19, x8
	b.eq	LBB0_40
LBB0_30:                                ;   Parent Loop BB0_24 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x27, x8]
	cmp	w9, #95
	b.eq	LBB0_29
; %bb.31:                               ;   in Loop: Header=BB0_30 Depth=2
	orr	w10, w9, #0x20
	sub	w10, w10, #97
	sub	w9, w9, #48
	cmp	w10, #26
	ccmp	w9, #9, #0, hs
	b.ls	LBB0_29
; %bb.32:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	x25, #0                         ; =0x0
	add	x26, x8, #1
	b	LBB0_61
LBB0_33:                                ;   in Loop: Header=BB0_24 Depth=1
	mov	x25, #0                         ; =0x0
	b	LBB0_61
LBB0_34:                                ;   in Loop: Header=BB0_24 Depth=1
	sub	w9, w8, #48
	cmp	w9, #9
	b.hi	LBB0_41
; %bb.35:                               ;   in Loop: Header=BB0_24 Depth=1
	cmp	x26, x20
	b.ge	LBB0_53
; %bb.36:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	x8, x23
LBB0_37:                                ;   Parent Loop BB0_24 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x27, x8]
	sub	w9, w9, #48
	cmp	w9, #9
	b.hi	LBB0_52
; %bb.38:                               ;   in Loop: Header=BB0_37 Depth=2
	add	x8, x8, #1
	cmp	x19, x8
	b.ne	LBB0_37
; %bb.39:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	w25, #1                         ; =0x1
	mov	x26, x20
	b	LBB0_61
LBB0_40:                                ;   in Loop: Header=BB0_24 Depth=1
	mov	x25, #0                         ; =0x0
	mov	x26, x20
	b	LBB0_61
LBB0_41:                                ;   in Loop: Header=BB0_24 Depth=1
	cmp	w8, #34
	b.ne	LBB0_47
; %bb.42:                               ;   in Loop: Header=BB0_24 Depth=1
	cmp	x26, x20
	b.ge	LBB0_55
; %bb.43:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	x8, x23
LBB0_44:                                ;   Parent Loop BB0_24 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x27, x8]
	cmp	w9, #34
	b.eq	LBB0_54
; %bb.45:                               ;   in Loop: Header=BB0_44 Depth=2
	add	x8, x8, #1
	cmp	x19, x8
	b.ne	LBB0_44
; %bb.46:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	x26, x20
	b	LBB0_55
LBB0_47:                                ;   in Loop: Header=BB0_24 Depth=1
	cmp	x26, x20
	b.ge	LBB0_60
; %bb.48:                               ;   in Loop: Header=BB0_24 Depth=1
	cmp	w8, #62
	b.hi	LBB0_60
; %bb.49:                               ;   in Loop: Header=BB0_24 Depth=1
	mov	w9, w8
	lsl	x10, x13, x9
	tst	x10, x16
	b.eq	LBB0_56
; %bb.50:                               ;   in Loop: Header=BB0_24 Depth=1
	ldrb	w9, [x28, x26]
	cmp	w9, #61
	b.eq	LBB0_59
; %bb.51:                               ;   in Loop: Header=BB0_24 Depth=1
	cmp	w8, #45
	b.eq	LBB0_58
	b	LBB0_60
LBB0_52:                                ;   in Loop: Header=BB0_24 Depth=1
	add	x26, x8, #1
LBB0_53:                                ;   in Loop: Header=BB0_24 Depth=1
	mov	w25, #1                         ; =0x1
	b	LBB0_61
LBB0_54:                                ;   in Loop: Header=BB0_24 Depth=1
	add	x26, x8, #1
LBB0_55:                                ;   in Loop: Header=BB0_24 Depth=1
	add	x26, x26, #1
	mov	w25, #2                         ; =0x2
	b	LBB0_61
LBB0_56:                                ;   in Loop: Header=BB0_24 Depth=1
	cmp	x9, #45
	b.ne	LBB0_60
; %bb.57:                               ;   in Loop: Header=BB0_24 Depth=1
	ldrb	w9, [x28, x26]
LBB0_58:                                ;   in Loop: Header=BB0_24 Depth=1
	cmp	w9, #62
	b.ne	LBB0_60
LBB0_59:                                ;   in Loop: Header=BB0_24 Depth=1
	add	x26, x23, #2
LBB0_60:                                ;   in Loop: Header=BB0_24 Depth=1
	mov	w25, #3                         ; =0x3
LBB0_61:                                ;   in Loop: Header=BB0_24 Depth=1
	ldr	w8, [x22]
	cmp	w8, #1
	b.lt	LBB0_63
; %bb.62:                               ;   in Loop: Header=BB0_24 Depth=1
	add	w8, w8, #1
	str	w8, [x22]
LBB0_63:                                ;   in Loop: Header=BB0_24 Depth=1
	cmp	x24, x12
	b.eq	LBB0_65
LBB0_64:                                ;   in Loop: Header=BB0_24 Depth=1
	add	w8, w23, w11
	sub	w9, w26, w23
	orr	x8, x8, x9, lsl #32
	madd	x9, x24, x15, x0
	add	x24, x24, #1
	stp	x25, x22, [x9]
	str	x8, [x9, #16]
	b	LBB0_23
LBB0_65:                                ;   in Loop: Header=BB0_24 Depth=1
	lsl	x8, x24, #1
	cmp	x24, #0
	csinc	x8, x8, xzr, ne
	str	x8, [sp, #192]                  ; 8-byte Folded Spill
	add	x8, x8, x8, lsl #1
	lsl	x1, x8, #3
	bl	_realloc
	mov	x16, #8804682956800             ; =0x80200000000
	movk	x16, #28672, lsl #48
	mov	w15, #24                        ; =0x18
	mov	x14, #1536                      ; =0x600
	movk	x14, #1, lsl #32
	mov	w13, #1                         ; =0x1
	ldr	x12, [sp, #192]                 ; 8-byte Folded Reload
	ldur	x11, [x29, #-200]               ; 8-byte Folded Reload
	b	LBB0_64
LBB0_66:
	cmp	w8, #1
	b.ne	LBB0_68
; %bb.67:
	mov	x0, x22
	bl	_bown_free
LBB0_68:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	cmp	x24, #1
	b.lt	LBB0_86
; %bb.69:
	mov	x19, #0                         ; =0x0
	mov	x23, #0                         ; =0x0
	mov	x26, #0                         ; =0x0
	add	x8, x27, #16
	mov	x9, x24
	ldr	x15, [sp, #200]                 ; 8-byte Folded Reload
	b	LBB0_72
LBB0_70:                                ;   in Loop: Header=BB0_72 Depth=1
	mov	w11, #0                         ; =0x0
LBB0_71:                                ;   in Loop: Header=BB0_72 Depth=1
	add	x26, x26, w11, uxtw
	ldur	x11, [x8, #-16]
	cmp	x11, #0
	cinc	x23, x23, eq
	add	x19, x19, x10
	add	x8, x8, #24
	subs	x9, x9, #1
	b.eq	LBB0_76
LBB0_72:                                ; =>This Inner Loop Header: Depth=1
	ldr	w10, [x8, #4]
	cmp	w10, #6
	b.ne	LBB0_70
; %bb.73:                               ;   in Loop: Header=BB0_72 Depth=1
	ldur	x11, [x8, #-8]
	ldr	w12, [x8]
	cmp	x11, x21
	ccmp	w12, #0, #0, eq
	b.eq	LBB0_75
; %bb.74:                               ;   in Loop: Header=BB0_72 Depth=1
	add	x11, x11, x12
	ldr	w12, [x11, #16]
	ldr	w13, [x15]
	ldrh	w11, [x11, #20]
	ldrh	w14, [x15, #4]
	cmp	w12, w13
	ccmp	w11, w14, #0, eq
	cset	w11, eq
	b	LBB0_71
LBB0_75:                                ;   in Loop: Header=BB0_72 Depth=1
	mov	w11, #1                         ; =0x1
	b	LBB0_71
LBB0_76:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	add	x20, x27, #8
	mov	x25, x24
	b	LBB0_79
LBB0_77:                                ;   in Loop: Header=BB0_79 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_78:                                ;   in Loop: Header=BB0_79 Depth=1
	add	x20, x20, #24
	subs	x25, x25, #1
	b.eq	LBB0_87
LBB0_79:                                ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_77
; %bb.80:                               ;   in Loop: Header=BB0_79 Depth=1
	cmp	w8, #1
	b.ne	LBB0_78
; %bb.81:                               ;   in Loop: Header=BB0_79 Depth=1
	bl	_bown_free
	b	LBB0_78
LBB0_82:
Lloh21:
	adrp	x1, l_.str.22@PAGE
Lloh22:
	add	x1, x1, l_.str.22@PAGEOFF
	mov	x0, x20
	bl	_load
	mov	x23, x0
	mov	x21, x1
	lsr	x25, x1, #32
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x26, x0
	ldr	w19, [x23]
	cbnz	x25, LBB0_158
; %bb.83:
	mov	x22, #0                         ; =0x0
	mov	x21, #0                         ; =0x0
	cmp	w19, #2
	b.ge	LBB0_225
LBB0_84:
	cmp	w19, #1
	b.ne	LBB0_226
; %bb.85:
	mov	x0, x23
	bl	_bown_free
	b	LBB0_226
LBB0_86:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	mov	x19, #0                         ; =0x0
	mov	x23, #0                         ; =0x0
	mov	x26, #0                         ; =0x0
LBB0_87:
	mov	x0, x27
	bl	_free
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x23, x19, [sp, #16]
	stp	x24, x26, [sp]
Lloh23:
	adrp	x0, l_.str.10@PAGE
Lloh24:
	add	x0, x0, l_.str.10@PAGEOFF
	bl	_printf
	ldr	x19, [sp, #208]                 ; 8-byte Folded Reload
	sub	x8, x22, x19
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
	sub	x8, x21, x22
Lloh29:
	adrp	x9, l_.str.13@PAGE
Lloh30:
	add	x9, x9, l_.str.13@PAGEOFF
LBB0_88:
	stp	x9, x8, [sp]
	mov	x0, x23
	bl	_printf
	sub	x8, x20, x21
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
	b	LBB0_333
LBB0_89:
	stp	x21, x19, [sp, #144]            ; 16-byte Folded Spill
	mov	x27, #0                         ; =0x0
	str	xzr, [sp, #192]                 ; 8-byte Folded Spill
	mov	x25, #0                         ; =0x0
	mov	x21, #0                         ; =0x0
	str	xzr, [sp, #176]                 ; 8-byte Folded Spill
	mov	x24, #0                         ; =0x0
	and	x8, x19, #0xffffffff
	str	x8, [sp, #136]                  ; 8-byte Folded Spill
	add	x9, x28, x8
	add	x8, x9, #16
	stur	x8, [x29, #-200]                ; 8-byte Folded Spill
	str	x9, [sp, #128]                  ; 8-byte Folded Spill
	add	x8, x9, #12
	stp	x8, x28, [sp, #160]             ; 16-byte Folded Spill
                                        ; implicit-def: $x26
	str	x20, [sp, #208]                 ; 8-byte Folded Spill
LBB0_90:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_125 Depth 2
                                        ;     Child Loop BB0_101 Depth 2
                                        ;     Child Loop BB0_112 Depth 2
	ldur	x19, [x29, #-200]               ; 8-byte Folded Reload
	add	x23, x19, x24
	sub	x2, x20, x24
	mov	x0, x23
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x19
	cmp	x0, #0
	csel	x14, x20, x8, eq
	sub	x22, x14, x24
	cmp	x22, #17
	b.hs	LBB0_124
; %bb.91:                               ;   in Loop: Header=BB0_90 Depth=1
	cmp	x22, #4
	ldr	x15, [sp, #176]                 ; 8-byte Folded Reload
	b.lo	LBB0_93
; %bb.92:                               ;   in Loop: Header=BB0_90 Depth=1
	lsr	x8, x22, #1
	and	x8, x8, #0x7ffffffffffffffc
	ldr	w9, [x23]
	ldr	w10, [x23, x8]
	orr	x10, x10, x9, lsl #32
	ldr	x9, [sp, #160]                  ; 8-byte Folded Reload
	add	x9, x9, x14
	sub	x8, x9, x8
	ldr	w9, [x9]
	ldr	w8, [x8]
	orr	x9, x8, x9, lsl #32
	b	LBB0_96
LBB0_93:                                ;   in Loop: Header=BB0_90 Depth=1
	cbz	x22, LBB0_95
; %bb.94:                               ;   in Loop: Header=BB0_90 Depth=1
	mov	x9, #0                          ; =0x0
	ldrb	w8, [x23]
	lsr	x10, x22, #1
	ldrb	w10, [x23, x10]
	lsl	x8, x8, #16
	orr	x8, x8, x10, lsl #8
	add	x10, x22, x23
	ldurb	w10, [x10, #-1]
	orr	x10, x8, x10
	b	LBB0_96
LBB0_95:                                ;   in Loop: Header=BB0_90 Depth=1
	mov	x10, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
LBB0_96:                                ;   in Loop: Header=BB0_90 Depth=1
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_97:                                ;   in Loop: Header=BB0_90 Depth=1
	mov	x12, #44233                     ; =0xacc9
	movk	x12, #38446, lsl #16
	movk	x12, #19347, lsl #32
	movk	x12, #35768, lsl #48
	eor	x11, x22, x12
	eor	x10, x10, x12
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
	csinc	x20, x8, xzr, hi
	str	x24, [sp, #184]                 ; 8-byte Folded Spill
	str	x14, [sp, #200]                 ; 8-byte Folded Spill
	cbz	w15, LBB0_106
; %bb.98:                               ;   in Loop: Header=BB0_90 Depth=1
	neg	w8, w15
	lsr	x28, x20, x8
	ldr	w8, [x21, x28, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_107
; %bb.99:                               ;   in Loop: Header=BB0_90 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	lsl	x9, x9, x15
	mvn	x19, x9
	b	LBB0_101
LBB0_100:                               ;   in Loop: Header=BB0_101 Depth=2
	add	x8, x28, #1
	and	x28, x8, x19
	ldr	w8, [x21, x28, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_107
LBB0_101:                               ;   Parent Loop BB0_90 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	sbfiz	x9, x8, #5, #32
	ldr	x9, [x25, x9]
	cmp	x9, x20
	b.ne	LBB0_100
; %bb.102:                              ;   in Loop: Header=BB0_101 Depth=2
	sxtw	x24, w8
	add	x8, x25, x24, lsl #5
	ldr	w9, [x8, #20]
	cmp	x22, x9
	b.ne	LBB0_100
; %bb.103:                              ;   in Loop: Header=BB0_101 Depth=2
	ldr	x9, [x8, #8]
	ldr	w8, [x8, #16]
	add	x8, x9, x8
	add	x0, x8, #16
	mov	x1, x23
	mov	x2, x22
	bl	_memcmp
	cbnz	w0, LBB0_100
; %bb.104:                              ;   in Loop: Header=BB0_90 Depth=1
	tbnz	w24, #31, LBB0_123
; %bb.105:                              ;   in Loop: Header=BB0_90 Depth=1
	add	x8, x25, x24, lsl #5
	ldr	x9, [x8, #24]
	add	x9, x9, #1
	str	x9, [x8, #24]
	ldr	x28, [sp, #168]                 ; 8-byte Folded Reload
	ldp	x12, x20, [sp, #200]            ; 16-byte Folded Reload
	b	LBB0_122
LBB0_106:                               ;   in Loop: Header=BB0_90 Depth=1
	mov	x28, #0                         ; =0x0
LBB0_107:                               ;   in Loop: Header=BB0_90 Depth=1
	ldur	x8, [x29, #-184]
	ldr	x9, [sp, #192]                  ; 8-byte Folded Reload
	cmp	x9, x8
	b.ne	LBB0_116
; %bb.108:                              ;   in Loop: Header=BB0_90 Depth=1
	sub	x0, x29, #192
	bl	_smap_room
	ldur	w21, [x29, #-176]
	ldr	x24, [sp, #184]                 ; 8-byte Folded Reload
	cbz	w21, LBB0_118
; %bb.109:                              ;   in Loop: Header=BB0_90 Depth=1
	neg	w8, w21
	lsr	x26, x20, x8
	ldp	x27, x25, [x29, #-168]
	ldr	w8, [x25, x26, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_117
; %bb.110:                              ;   in Loop: Header=BB0_90 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	lsl	x9, x9, x21
	mvn	x19, x9
	b	LBB0_112
LBB0_111:                               ;   in Loop: Header=BB0_112 Depth=2
	add	x8, x26, #1
	and	x26, x8, x19
	ldr	w8, [x25, x26, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_117
LBB0_112:                               ;   Parent Loop BB0_90 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	sbfiz	x9, x8, #5, #32
	ldr	x9, [x27, x9]
	cmp	x9, x20
	b.ne	LBB0_111
; %bb.113:                              ;   in Loop: Header=BB0_112 Depth=2
	sxtw	x8, w8
	add	x8, x27, x8, lsl #5
	ldr	w9, [x8, #20]
	cmp	x22, x9
	b.ne	LBB0_111
; %bb.114:                              ;   in Loop: Header=BB0_112 Depth=2
	ldr	x9, [x8, #8]
	ldr	w8, [x8, #16]
	add	x8, x9, x8
	add	x0, x8, #16
	mov	x1, x23
	mov	x2, x22
	bl	_memcmp
	cbnz	w0, LBB0_111
; %bb.115:                              ;   in Loop: Header=BB0_90 Depth=1
                                        ; kill: def $w21 killed $w21 killed $x21 def $x21
	str	x21, [sp, #176]                 ; 8-byte Folded Spill
	mov	x26, x28
	b	LBB0_119
LBB0_116:                               ;   in Loop: Header=BB0_90 Depth=1
	mov	x26, x28
	ldr	x24, [sp, #184]                 ; 8-byte Folded Reload
	b	LBB0_119
LBB0_117:                               ;   in Loop: Header=BB0_90 Depth=1
                                        ; kill: def $w21 killed $w21 killed $x21 def $x21
	str	x21, [sp, #176]                 ; 8-byte Folded Spill
	b	LBB0_119
LBB0_118:                               ;   in Loop: Header=BB0_90 Depth=1
	str	xzr, [sp, #176]                 ; 8-byte Folded Spill
	mov	x26, #0                         ; =0x0
	ldur	x27, [x29, #-168]
LBB0_119:                               ;   in Loop: Header=BB0_90 Depth=1
	ldur	x8, [x29, #-192]
	add	x9, x27, x8, lsl #5
	mov	x10, x9
	str	x20, [x10], #8
	ldr	x28, [sp, #168]                 ; 8-byte Folded Reload
	ldr	w11, [x28]
	cmp	w11, #1
	ldr	x12, [sp, #200]                 ; 8-byte Folded Reload
	b.lt	LBB0_121
; %bb.120:                              ;   in Loop: Header=BB0_90 Depth=1
	add	w11, w11, #1
	str	w11, [x28]
LBB0_121:                               ;   in Loop: Header=BB0_90 Depth=1
	ldr	x11, [sp, #152]                 ; 8-byte Folded Reload
	add	w11, w24, w11
	orr	x11, x11, x22, lsl #32
	stp	x28, x11, [x10]
	mov	w10, #1                         ; =0x1
	str	x10, [x9, #24]
	ldur	x21, [x29, #-160]
	str	w8, [x21, x26, lsl #2]
	add	x8, x8, #1
	str	x8, [sp, #192]                  ; 8-byte Folded Spill
	stur	x8, [x29, #-192]
	mov	x25, x27
	ldr	x20, [sp, #208]                 ; 8-byte Folded Reload
LBB0_122:                               ;   in Loop: Header=BB0_90 Depth=1
	add	x24, x12, #1
	cmp	x24, x20
	b.lt	LBB0_90
	b	LBB0_127
LBB0_123:                               ;   in Loop: Header=BB0_90 Depth=1
	mov	x28, x26
	b	LBB0_107
LBB0_124:                               ;   in Loop: Header=BB0_90 Depth=1
	ldr	x8, [sp, #128]                  ; 8-byte Folded Reload
	add	x9, x8, x24
	mov	x11, x22
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
	mov	x13, #44233                     ; =0xacc9
	movk	x13, #38446, lsl #16
	movk	x13, #19347, lsl #32
	movk	x13, #35768, lsl #48
	ldr	x15, [sp, #176]                 ; 8-byte Folded Reload
LBB0_125:                               ;   Parent Loop BB0_90 Depth=1
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
	b.hi	LBB0_125
; %bb.126:                              ;   in Loop: Header=BB0_90 Depth=1
	add	x9, x9, x10
	ldp	x10, x9, [x9, #-16]
	b	LBB0_97
LBB0_127:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x19, #0                         ; =0x0
	mov	x26, #0                         ; =0x0
	ldur	w9, [x29, #-176]
	mov	x8, #-1                         ; =0xffffffffffffffff
	lsl	x8, x8, x9
	mvn	x21, x8
	mov	w8, #64                         ; =0x40
	str	x9, [sp, #200]                  ; 8-byte Folded Spill
	sub	w8, w8, w9
	stp	x0, x8, [sp, #176]              ; 16-byte Folded Spill
	ldp	x23, x22, [x29, #-168]
	ldr	x8, [sp, #136]                  ; 8-byte Folded Reload
	add	x8, x28, x8
	str	x8, [sp, #152]                  ; 8-byte Folded Spill
	mov	x27, #44233                     ; =0xacc9
	movk	x27, #38446, lsl #16
	movk	x27, #19347, lsl #32
	movk	x27, #35768, lsl #48
	b	LBB0_130
LBB0_128:                               ;   in Loop: Header=BB0_130 Depth=1
	mov	x20, #-1                        ; =0xffffffffffffffff
LBB0_129:                               ;   in Loop: Header=BB0_130 Depth=1
	add	x26, x28, #1
	add	x8, x23, x20, lsl #5
	ldr	x8, [x8, #24]
	add	x19, x8, x19
	ldr	x20, [sp, #208]                 ; 8-byte Folded Reload
	cmp	x26, x20
	b.ge	LBB0_149
LBB0_130:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_147 Depth 2
                                        ;     Child Loop BB0_140 Depth 2
	ldur	x25, [x29, #-200]               ; 8-byte Folded Reload
	add	x24, x25, x26
	sub	x2, x20, x26
	mov	x0, x24
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x25
	cmp	x0, #0
	csel	x28, x20, x8, eq
	sub	x25, x28, x26
	cmp	x25, #17
	b.hs	LBB0_146
; %bb.131:                              ;   in Loop: Header=BB0_130 Depth=1
	cmp	x25, #4
	b.lo	LBB0_133
; %bb.132:                              ;   in Loop: Header=BB0_130 Depth=1
	lsr	x8, x25, #1
	and	x8, x8, #0x7ffffffffffffffc
	ldr	w9, [x24]
	ldr	w10, [x24, x8]
	orr	x10, x10, x9, lsl #32
	ldr	x9, [sp, #160]                  ; 8-byte Folded Reload
	add	x9, x9, x28
	sub	x8, x9, x8
	ldr	w9, [x9]
	ldr	w8, [x8]
	orr	x9, x8, x9, lsl #32
	b	LBB0_136
LBB0_133:                               ;   in Loop: Header=BB0_130 Depth=1
	cbz	x25, LBB0_135
; %bb.134:                              ;   in Loop: Header=BB0_130 Depth=1
	mov	x9, #0                          ; =0x0
	ldrb	w8, [x24]
	lsr	x10, x25, #1
	ldrb	w10, [x24, x10]
	lsl	x8, x8, #16
	orr	x8, x8, x10, lsl #8
	add	x10, x25, x24
	ldurb	w10, [x10, #-1]
	orr	x10, x8, x10
	b	LBB0_136
LBB0_135:                               ;   in Loop: Header=BB0_130 Depth=1
	mov	x10, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
LBB0_136:                               ;   in Loop: Header=BB0_130 Depth=1
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_137:                               ;   in Loop: Header=BB0_130 Depth=1
	eor	x11, x25, x27
	eor	x10, x10, x27
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
	ldr	x8, [sp, #200]                  ; 8-byte Folded Reload
	cbz	w8, LBB0_128
; %bb.138:                              ;   in Loop: Header=BB0_130 Depth=1
	ldr	x8, [sp, #184]                  ; 8-byte Folded Reload
	lsr	x27, x26, x8
	b	LBB0_140
LBB0_139:                               ;   in Loop: Header=BB0_140 Depth=2
	add	x8, x27, #1
	and	x27, x8, x21
LBB0_140:                               ;   Parent Loop BB0_130 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w8, [x22, x27, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_144
; %bb.141:                              ;   in Loop: Header=BB0_140 Depth=2
	sbfiz	x9, x8, #5, #32
	ldr	x9, [x23, x9]
	cmp	x9, x26
	b.ne	LBB0_139
; %bb.142:                              ;   in Loop: Header=BB0_140 Depth=2
	sxtw	x20, w8
	add	x8, x23, x20, lsl #5
	ldr	w9, [x8, #20]
	cmp	x25, x9
	b.ne	LBB0_139
; %bb.143:                              ;   in Loop: Header=BB0_140 Depth=2
	ldr	x9, [x8, #8]
	ldr	w8, [x8, #16]
	add	x8, x9, x8
	add	x0, x8, #16
	mov	x1, x24
	mov	x2, x25
	bl	_memcmp
	cbnz	w0, LBB0_139
	b	LBB0_145
LBB0_144:                               ;   in Loop: Header=BB0_130 Depth=1
	mov	x20, #-1                        ; =0xffffffffffffffff
LBB0_145:                               ;   in Loop: Header=BB0_130 Depth=1
	mov	x27, #44233                     ; =0xacc9
	movk	x27, #38446, lsl #16
	movk	x27, #19347, lsl #32
	movk	x27, #35768, lsl #48
	b	LBB0_129
LBB0_146:                               ;   in Loop: Header=BB0_130 Depth=1
	ldr	x8, [sp, #152]                  ; 8-byte Folded Reload
	add	x9, x8, x26
	mov	x11, x25
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_147:                               ;   Parent Loop BB0_130 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x10, x11
	ldp	x11, x12, [x9, #16]!
	eor	x11, x11, x27
	eor	x8, x12, x8
	mul	x12, x8, x11
	umulh	x8, x8, x11
	eor	x8, x8, x12
	sub	x11, x10, #16
	cmp	x11, #16
	b.hi	LBB0_147
; %bb.148:                              ;   in Loop: Header=BB0_130 Depth=1
	add	x9, x9, x10
	ldp	x10, x9, [x9, #-16]
	b	LBB0_137
LBB0_149:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x24, x0
	ldr	x25, [sp, #192]                 ; 8-byte Folded Reload
	cmp	x25, #1
	b.lt	LBB0_216
; %bb.150:
	mov	w20, #8                         ; =0x8
	mov	x21, x25
	ldp	x28, x26, [sp, #168]            ; 16-byte Folded Reload
	b	LBB0_153
LBB0_151:                               ;   in Loop: Header=BB0_153 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_152:                               ;   in Loop: Header=BB0_153 Depth=1
	add	x20, x20, #32
	subs	x21, x21, #1
	b.eq	LBB0_167
LBB0_153:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x23, x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_151
; %bb.154:                              ;   in Loop: Header=BB0_153 Depth=1
	cmp	w8, #1
	b.ne	LBB0_152
; %bb.155:                              ;   in Loop: Header=BB0_153 Depth=1
	bl	_bown_free
	b	LBB0_152
LBB0_156:
Lloh35:
	adrp	x1, l_.str.24@PAGE
Lloh36:
	add	x1, x1, l_.str.24@PAGEOFF
	mov	x0, x20
	bl	_load
	mov	x21, x0
	mov	x19, x1
	lsr	x24, x1, #32
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	str	x0, [sp, #128]                  ; 8-byte Folded Spill
	stur	xzr, [x29, #-160]
	movi.2d	v0, #0000000000000000
	stp	q0, q0, [x29, #-192]
	cbnz	x24, LBB0_168
; %bb.157:
	mov	x23, #0                         ; =0x0
	mov	x19, #0                         ; =0x0
	mov	x20, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
	b	LBB0_328
LBB0_158:
	str	x26, [sp, #208]                 ; 8-byte Folded Spill
	and	x20, x21, #0xffffffff
	add	x8, x23, x20
	add	x26, x8, #16
	mov	x0, x26
	mov	w1, #10                         ; =0xa
	mov	x2, x25
	bl	_memchr
	sub	x8, x0, x26
	cmp	x0, #0
	csel	x8, x25, x8, eq
	add	x28, x8, #1
	orr	x20, x20, x8, lsl #32
	cmp	w19, #1
	b.lt	LBB0_160
; %bb.159:
	add	w19, w19, #1
	str	w19, [x23]
LBB0_160:
	mov	w0, #16                         ; =0x10
	bl	_malloc
	mov	x22, x0
	stp	x23, x20, [x0]
	cmp	x28, x25
	b.ge	LBB0_222
; %bb.161:
	stur	x21, [x29, #-200]               ; 8-byte Folded Spill
	mov	x20, #0                         ; =0x0
	mov	w21, #1                         ; =0x1
	mov	w27, #32                        ; =0x20
	mov	w19, #1                         ; =0x1
LBB0_162:                               ; =>This Inner Loop Header: Depth=1
	add	x0, x26, x28
	sub	x2, x25, x28
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x26
	cmp	x0, #0
	csel	x24, x25, x8, eq
	ldr	w8, [x23]
	cmp	w8, #1
	b.lt	LBB0_164
; %bb.163:                              ;   in Loop: Header=BB0_162 Depth=1
	add	w8, w8, #1
	str	w8, [x23]
LBB0_164:                               ;   in Loop: Header=BB0_162 Depth=1
	cmp	x21, x19
	b.eq	LBB0_166
LBB0_165:                               ;   in Loop: Header=BB0_162 Depth=1
	ldur	x8, [x29, #-200]                ; 8-byte Folded Reload
	add	w8, w28, w8
	sub	w9, w24, w28
	add	x10, x24, #1
	orr	x8, x8, x9, lsl #32
	add	x21, x21, #1
	add	x9, x22, x20, lsl #3
	stp	x23, x8, [x9, #16]
	add	x27, x27, #32
	add	x20, x20, #2
	mov	x28, x10
	cmp	x10, x25
	b.lt	LBB0_162
	b	LBB0_223
LBB0_166:                               ;   in Loop: Header=BB0_162 Depth=1
	add	x19, x20, #2
	mov	x0, x22
	mov	x1, x27
	bl	_realloc
	mov	x22, x0
	b	LBB0_165
LBB0_167:
	ldr	x21, [sp, #144]                 ; 8-byte Folded Reload
	b	LBB0_217
LBB0_168:
	str	xzr, [sp, #200]                 ; 8-byte Folded Spill
	mov	x25, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
	mov	x10, #0                         ; =0x0
	stp	x21, xzr, [sp, #168]            ; 16-byte Folded Spill
	mov	x28, #0                         ; =0x0
	and	x8, x19, #0xffffffff
	add	x8, x21, x8
	neg	x9, x8
	str	x9, [sp, #120]                  ; 8-byte Folded Spill
	add	x26, x8, #16
	mov	x27, #44233                     ; =0xacc9
	movk	x27, #38446, lsl #16
	movk	x27, #19347, lsl #32
	movk	x27, #35768, lsl #48
	stp	x8, x19, [sp, #136]             ; 16-byte Folded Spill
	add	x19, x8, #15
                                        ; implicit-def: $x20
	stp	x26, x24, [sp, #152]            ; 16-byte Folded Spill
LBB0_169:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_170 Depth 2
                                        ;     Child Loop BB0_173 Depth 2
                                        ;     Child Loop BB0_211 Depth 2
                                        ;     Child Loop BB0_185 Depth 2
                                        ;     Child Loop BB0_196 Depth 2
	stur	x10, [x29, #-200]               ; 8-byte Folded Spill
	add	x23, x26, x28
	sub	x2, x24, x28
	mov	x0, x23
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x26
	cmp	x0, #0
	csel	x21, x24, x8, eq
	sub	x2, x21, x28
	mov	x0, x23
	mov	w1, #44                         ; =0x2c
	bl	_memchr
	mov	x10, #-1                        ; =0xffffffffffffffff
	mov	x11, x21
LBB0_170:                               ;   Parent Loop BB0_169 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x9, x11
	mov	x8, x10
	sub	x11, x11, #1
	ldrb	w12, [x19, x9]
	sub	x10, x10, #1
	cmp	w12, #44
	b.ne	LBB0_170
; %bb.171:                              ;   in Loop: Header=BB0_169 Depth=1
	str	x28, [sp, #208]                 ; 8-byte Folded Spill
	cmp	x9, x21
	mov	w11, #10                        ; =0xa
	mov	x28, #0                         ; =0x0
	b.ge	LBB0_174
; %bb.172:                              ;   in Loop: Header=BB0_169 Depth=1
	ldr	x9, [sp, #136]                  ; 8-byte Folded Reload
	add	x9, x9, x21
LBB0_173:                               ;   Parent Loop BB0_169 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	add	x10, x9, x8
	ldrsb	x10, [x10, #17]
	madd	x10, x28, x11, x10
	sub	x28, x10, #48
	add	x8, x8, #1
	cmn	x8, #1
	b.ne	LBB0_173
LBB0_174:                               ;   in Loop: Header=BB0_169 Depth=1
	ldr	x8, [sp, #208]                  ; 8-byte Folded Reload
	add	x8, x8, x26
	sub	x24, x0, x8
	cmp	x24, #17
	str	x25, [sp, #192]                 ; 8-byte Folded Spill
	b.hs	LBB0_210
; %bb.175:                              ;   in Loop: Header=BB0_169 Depth=1
	cmp	x24, #4
	b.lo	LBB0_177
; %bb.176:                              ;   in Loop: Header=BB0_169 Depth=1
	lsr	x8, x24, #1
	and	x8, x8, #0x7ffffffffffffffc
	ldr	w9, [x23]
	ldr	w10, [x23, x8]
	orr	x10, x10, x9, lsl #32
	add	x9, x23, x24
	ldr	w11, [x9, #-4]!
	sub	x8, x9, x8
	ldr	w8, [x8]
	orr	x9, x8, x11, lsl #32
	b	LBB0_180
LBB0_177:                               ;   in Loop: Header=BB0_169 Depth=1
	cbz	x24, LBB0_179
; %bb.178:                              ;   in Loop: Header=BB0_169 Depth=1
	mov	x9, #0                          ; =0x0
	ldrb	w8, [x23]
	lsr	x10, x24, #1
	ldrb	w10, [x23, x10]
	lsl	x8, x8, #16
	orr	x8, x8, x10, lsl #8
	add	x10, x24, x23
	ldurb	w10, [x10, #-1]
	orr	x10, x8, x10
	b	LBB0_180
LBB0_179:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x10, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
LBB0_180:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_181:                               ;   in Loop: Header=BB0_169 Depth=1
	ldr	x12, [sp, #176]                 ; 8-byte Folded Reload
	eor	x11, x24, x27
	eor	x10, x10, x27
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
	csinc	x27, x8, xzr, hi
	str	x21, [sp, #184]                 ; 8-byte Folded Spill
	cbz	w12, LBB0_190
; %bb.182:                              ;   in Loop: Header=BB0_169 Depth=1
	neg	w8, w12
	lsr	x26, x27, x8
	ldur	x10, [x29, #-200]               ; 8-byte Folded Reload
	ldr	w8, [x10, x26, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_191
; %bb.183:                              ;   in Loop: Header=BB0_169 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	lsl	x9, x9, x12
	mvn	x25, x9
	b	LBB0_185
LBB0_184:                               ;   in Loop: Header=BB0_185 Depth=2
	add	x8, x26, #1
	and	x26, x8, x25
	ldr	w8, [x10, x26, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_191
LBB0_185:                               ;   Parent Loop BB0_169 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	sbfiz	x9, x8, #5, #32
	ldr	x9, [x22, x9]
	cmp	x9, x27
	b.ne	LBB0_184
; %bb.186:                              ;   in Loop: Header=BB0_185 Depth=2
	sxtw	x21, w8
	add	x8, x22, x21, lsl #5
	ldr	w9, [x8, #20]
	cmp	x24, x9
	b.ne	LBB0_184
; %bb.187:                              ;   in Loop: Header=BB0_185 Depth=2
	ldr	x9, [x8, #8]
	ldr	w8, [x8, #16]
	add	x8, x9, x8
	add	x0, x8, #16
	mov	x1, x23
	mov	x2, x24
	bl	_memcmp
	ldur	x10, [x29, #-200]               ; 8-byte Folded Reload
	cbnz	w0, LBB0_184
; %bb.188:                              ;   in Loop: Header=BB0_169 Depth=1
	tbnz	w21, #31, LBB0_209
; %bb.189:                              ;   in Loop: Header=BB0_169 Depth=1
	add	x8, x22, x21, lsl #5
	ldr	x9, [x8, #24]
	add	x9, x9, x28
	str	x9, [x8, #24]
	ldr	x21, [sp, #168]                 ; 8-byte Folded Reload
	ldr	x25, [sp, #192]                 ; 8-byte Folded Reload
	ldr	x26, [sp, #152]                 ; 8-byte Folded Reload
	b	LBB0_208
LBB0_190:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x26, #0                         ; =0x0
LBB0_191:                               ;   in Loop: Header=BB0_169 Depth=1
	ldur	x8, [x29, #-184]
	ldr	x9, [sp, #192]                  ; 8-byte Folded Reload
	cmp	x9, x8
	b.ne	LBB0_200
; %bb.192:                              ;   in Loop: Header=BB0_169 Depth=1
	sub	x0, x29, #192
	bl	_smap_room
	ldur	w11, [x29, #-176]
	cbz	w11, LBB0_201
; %bb.193:                              ;   in Loop: Header=BB0_169 Depth=1
	neg	w8, w11
	lsr	x20, x27, x8
	ldp	x21, x22, [x29, #-168]
	ldr	w8, [x22, x20, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_203
; %bb.194:                              ;   in Loop: Header=BB0_169 Depth=1
	mov	x9, #-1                         ; =0xffffffffffffffff
	stur	x11, [x29, #-200]               ; 8-byte Folded Spill
	lsl	x9, x9, x11
	mvn	x25, x9
	b	LBB0_196
LBB0_195:                               ;   in Loop: Header=BB0_196 Depth=2
	add	x8, x20, #1
	and	x20, x8, x25
	ldr	w8, [x22, x20, lsl #2]
	cmn	w8, #1
	b.eq	LBB0_202
LBB0_196:                               ;   Parent Loop BB0_169 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	sbfiz	x9, x8, #5, #32
	ldr	x9, [x21, x9]
	cmp	x9, x27
	b.ne	LBB0_195
; %bb.197:                              ;   in Loop: Header=BB0_196 Depth=2
	sxtw	x8, w8
	add	x8, x21, x8, lsl #5
	ldr	w9, [x8, #20]
	cmp	x24, x9
	b.ne	LBB0_195
; %bb.198:                              ;   in Loop: Header=BB0_196 Depth=2
	ldr	x9, [x8, #8]
	ldr	w8, [x8, #16]
	add	x8, x9, x8
	add	x0, x8, #16
	mov	x1, x23
	mov	x2, x24
	bl	_memcmp
	cbnz	w0, LBB0_195
; %bb.199:                              ;   in Loop: Header=BB0_169 Depth=1
	ldur	x8, [x29, #-200]                ; 8-byte Folded Reload
                                        ; kill: def $w8 killed $w8 killed $x8 def $x8
	str	x8, [sp, #176]                  ; 8-byte Folded Spill
	mov	x20, x26
	b	LBB0_205
LBB0_200:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x20, x26
	ldr	x21, [sp, #200]                 ; 8-byte Folded Reload
	b	LBB0_205
LBB0_201:                               ;   in Loop: Header=BB0_169 Depth=1
	str	xzr, [sp, #176]                 ; 8-byte Folded Spill
	mov	x20, #0                         ; =0x0
	ldur	x21, [x29, #-168]
	b	LBB0_205
LBB0_202:                               ;   in Loop: Header=BB0_169 Depth=1
	ldur	x8, [x29, #-200]                ; 8-byte Folded Reload
                                        ; kill: def $w8 killed $w8 killed $x8 def $x8
	b	LBB0_204
LBB0_203:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x8, x11
LBB0_204:                               ;   in Loop: Header=BB0_169 Depth=1
	str	x8, [sp, #176]                  ; 8-byte Folded Spill
LBB0_205:                               ;   in Loop: Header=BB0_169 Depth=1
	ldur	x8, [x29, #-192]
	str	x21, [sp, #200]                 ; 8-byte Folded Spill
	add	x9, x21, x8, lsl #5
	mov	x10, x9
	str	x27, [x10], #8
	ldr	x21, [sp, #168]                 ; 8-byte Folded Reload
	ldr	w11, [x21]
	cmp	w11, #1
	ldr	x26, [sp, #152]                 ; 8-byte Folded Reload
	b.lt	LBB0_207
; %bb.206:                              ;   in Loop: Header=BB0_169 Depth=1
	add	w11, w11, #1
	str	w11, [x21]
LBB0_207:                               ;   in Loop: Header=BB0_169 Depth=1
	ldr	x11, [sp, #144]                 ; 8-byte Folded Reload
	ldp	x22, x12, [sp, #200]            ; 16-byte Folded Reload
	add	w11, w12, w11
	orr	x11, x11, x24, lsl #32
	stp	x21, x11, [x10]
	str	x28, [x9, #24]
	ldur	x10, [x29, #-160]
	str	w8, [x10, x20, lsl #2]
	add	x25, x8, #1
	stur	x25, [x29, #-192]
LBB0_208:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x27, #44233                     ; =0xacc9
	movk	x27, #38446, lsl #16
	movk	x27, #19347, lsl #32
	movk	x27, #35768, lsl #48
	ldr	x8, [sp, #184]                  ; 8-byte Folded Reload
	add	x28, x8, #1
	ldr	x24, [sp, #160]                 ; 8-byte Folded Reload
	cmp	x28, x24
	b.lt	LBB0_169
	b	LBB0_213
LBB0_209:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x26, x20
	b	LBB0_191
LBB0_210:                               ;   in Loop: Header=BB0_169 Depth=1
	mov	x9, #0                          ; =0x0
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	add	x8, x8, x0
	ldr	x11, [sp, #208]                 ; 8-byte Folded Reload
	sub	x10, x8, x11
	ldr	x8, [sp, #136]                  ; 8-byte Folded Reload
	add	x11, x8, x11
	mov	w12, #16                        ; =0x10
	mov	x8, #35252                      ; =0x89b4
	movk	x8, #25111, lsl #16
	movk	x8, #61520, lsl #32
	movk	x8, #2001, lsl #48
LBB0_211:                               ;   Parent Loop BB0_169 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	add	x13, x11, x12
	ldp	x14, x13, [x13]
	eor	x14, x14, x27
	eor	x8, x13, x8
	mul	x13, x8, x14
	umulh	x8, x8, x14
	eor	x8, x8, x13
	sub	x9, x9, #16
	add	x13, x10, x9
	sub	x13, x13, #16
	add	x12, x12, #16
	cmp	x13, #16
	b.hi	LBB0_211
; %bb.212:                              ;   in Loop: Header=BB0_169 Depth=1
	ldr	x10, [sp, #120]                 ; 8-byte Folded Reload
	add	x10, x10, x0
	ldr	x12, [sp, #208]                 ; 8-byte Folded Reload
	sub	x10, x10, x12
	ldr	x11, [sp, #136]                 ; 8-byte Folded Reload
	add	x11, x11, x12
	sub	x11, x11, x9
	add	x9, x10, x9
	add	x9, x11, x9
	ldp	x10, x9, [x9, #-16]
	b	LBB0_181
LBB0_213:
	ldur	x22, [x29, #-168]
	cmp	x25, #1
	b.lt	LBB0_315
; %bb.214:
	mov	x26, x10
	cmp	x25, #9
	b.hs	LBB0_316
; %bb.215:
	mov	x8, #0                          ; =0x0
	mov	x23, #0                         ; =0x0
	mov	x19, #0                         ; =0x0
	b	LBB0_319
LBB0_216:
	ldr	x21, [sp, #144]                 ; 8-byte Folded Reload
	ldp	x28, x26, [sp, #168]            ; 16-byte Folded Reload
LBB0_217:
	mov	x0, x23
	bl	_free
	mov	x0, x22
	bl	_free
	ldr	w8, [x28]
	cmp	w8, #2
	b.lt	LBB0_219
; %bb.218:
	sub	w8, w8, #1
	str	w8, [x28]
	b	LBB0_221
LBB0_219:
	cmp	w8, #1
	b.ne	LBB0_221
; %bb.220:
	mov	x0, x28
	bl	_bown_free
LBB0_221:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x25, x19, [sp]
Lloh37:
	adrp	x0, l_.str.19@PAGE
Lloh38:
	add	x0, x0, l_.str.19@PAGEOFF
	bl	_printf
	sub	x8, x26, x21
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
	sub	x8, x24, x26
Lloh43:
	adrp	x9, l_.str.21@PAGE
Lloh44:
	add	x9, x9, l_.str.21@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x22
	bl	_printf
	sub	x8, x20, x24
Lloh45:
	adrp	x9, l_.str.14@PAGE
Lloh46:
	add	x9, x9, l_.str.14@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x22
	bl	_printf
	sub	x8, x20, x21
Lloh47:
	adrp	x9, l_.str.15@PAGE
Lloh48:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x22
	b	LBB0_333
LBB0_222:
	mov	w21, #1                         ; =0x1
	b	LBB0_224
LBB0_223:
	ldr	w19, [x23]
Lloh49:
	adrp	x27, l_.str.3@PAGE
Lloh50:
	add	x27, x27, l_.str.3@PAGEOFF
LBB0_224:
	ldr	x26, [sp, #208]                 ; 8-byte Folded Reload
	cmp	w19, #2
	b.lt	LBB0_84
LBB0_225:
	sub	w8, w19, #1
	str	w8, [x23]
LBB0_226:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x23, x0
	mov	x0, x22
	mov	x1, x21
	bl	_qsort_s
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x24, x0
	cbz	x21, LBB0_229
; %bb.227:
	cmp	x21, #3001
	b.hs	LBB0_231
; %bb.228:
	mov	x8, #0                          ; =0x0
	mov	x25, #0                         ; =0x0
	b	LBB0_234
LBB0_229:
	mov	x25, #0                         ; =0x0
LBB0_230:
	mov	x0, x22
	bl	_free
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	stp	x21, x25, [sp]
Lloh51:
	adrp	x0, l_.str.19@PAGE
Lloh52:
	add	x0, x0, l_.str.19@PAGEOFF
	bl	_printf
	sub	x8, x23, x26
Lloh53:
	adrp	x9, l_.str.23@PAGE
Lloh54:
	add	x9, x9, l_.str.23@PAGEOFF
	stp	x9, x8, [sp]
Lloh55:
	adrp	x21, l_.str.11@PAGE
Lloh56:
	add	x21, x21, l_.str.11@PAGEOFF
	mov	x0, x21
	bl	_printf
	sub	x8, x24, x23
	stp	x27, x8, [sp]
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
	sub	x8, x22, x26
Lloh59:
	adrp	x9, l_.str.15@PAGE
Lloh60:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
	mov	x0, x21
	b	LBB0_333
LBB0_231:
	str	x26, [sp, #208]                 ; 8-byte Folded Spill
	mov	x9, #0                          ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x13, #0                         ; =0x0
	mov	x14, #0                         ; =0x0
	mov	x15, #0                         ; =0x0
	mov	x16, #0                         ; =0x0
	sub	x8, x21, #1
	lsr	x8, x8, #3
	mov	x11, #63439                     ; =0xf7cf
	movk	x11, #58195, lsl #16
	movk	x11, #39845, lsl #32
	movk	x11, #8388, lsl #48
	umulh	x8, x8, x11
	lsr	x8, x8, #4
	add	x8, x8, #1
	stur	x8, [x29, #-200]                ; 8-byte Folded Spill
	and	x12, x8, #0xfffffffffffffc
	mov	w8, #1000                       ; =0x3e8
	mul	x8, x12, x8
	mov	w17, #32008                     ; =0x7d08
	add	x17, x22, x17
	mov	w0, #32000                      ; =0x7d00
	add	x0, x22, x0
	mov	w1, #64000                      ; =0xfa00
	mov	x2, x12
LBB0_232:                               ; =>This Inner Loop Header: Depth=1
	add	x3, x9, #1000
	add	x4, x9, #2000
	add	x5, x9, #3000
	add	x6, x22, x10
	add	x7, x0, x10
	add	x19, x17, x10
	ldr	w20, [x6, #16012]
	ldr	w25, [x19, #16004]
	ldr	x26, [x6]
	ldr	x27, [x6, #16000]
	ldr	x28, [x7]
	ldr	x7, [x7, #16000]
	ldp	w11, w30, [x6, #8]
	add	x11, x26, x11
	ldr	w6, [x6, #16008]
	add	x6, x27, x6
	ldp	w27, w26, [x19]
	add	x27, x28, x27
	ldr	w19, [x19, #16000]
	add	x7, x7, x19
	ldrb	w11, [x11, #16]
	ldrb	w6, [x6, #16]
	ldrb	w19, [x27, #16]
	madd	x13, x9, x30, x13
	madd	x14, x3, x20, x14
	madd	x15, x4, x26, x15
	madd	x16, x5, x25, x16
	add	x13, x13, x11
	add	x14, x14, x6
	add	x15, x15, x19
	ldrb	w11, [x7, #16]
	add	x16, x16, x11
	add	x10, x10, x1
	add	x9, x9, #4000
	subs	x2, x2, #4
	b.ne	LBB0_232
; %bb.233:
	add	x9, x14, x13
	add	x10, x16, x15
	add	x25, x10, x9
	ldur	x9, [x29, #-200]                ; 8-byte Folded Reload
	cmp	x9, x12
Lloh61:
	adrp	x27, l_.str.3@PAGE
Lloh62:
	add	x27, x27, l_.str.3@PAGEOFF
	ldr	x26, [sp, #208]                 ; 8-byte Folded Reload
	b.eq	LBB0_236
LBB0_234:
	add	x9, x22, x8, lsl #4
	add	x9, x9, #8
	mov	w10, #16000                     ; =0x3e80
LBB0_235:                               ; =>This Inner Loop Header: Depth=1
	ldur	x11, [x9, #-8]
	ldp	w13, w12, [x9]
	add	x11, x11, x13
	ldrb	w11, [x11, #16]
	madd	x12, x8, x12, x25
	add	x25, x12, x11
	add	x8, x8, #1000
	add	x9, x9, x10
	cmp	x8, x21
	b.lo	LBB0_235
LBB0_236:
	mov	x19, x22
	mov	x20, x21
	b	LBB0_239
LBB0_237:                               ;   in Loop: Header=BB0_239 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_238:                               ;   in Loop: Header=BB0_239 Depth=1
	add	x19, x19, #16
	subs	x20, x20, #1
	b.eq	LBB0_230
LBB0_239:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x19]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_237
; %bb.240:                              ;   in Loop: Header=BB0_239 Depth=1
	cmp	w8, #1
	b.ne	LBB0_238
; %bb.241:                              ;   in Loop: Header=BB0_239 Depth=1
	bl	_bown_free
	b	LBB0_238
LBB0_242:
	mov	x15, x20
	mov	x11, #0                         ; =0x0
	str	xzr, [sp, #152]                 ; 8-byte Folded Spill
	str	xzr, [sp, #176]                 ; 8-byte Folded Spill
	mov	x20, #0                         ; =0x0
	and	x8, x19, #0xffffffff
	ldr	x10, [sp, #168]                 ; 8-byte Folded Reload
	add	x9, x10, x8
	add	x9, x9, #16
	stur	x9, [x29, #-200]                ; 8-byte Folded Spill
	add	x9, x19, #1
	stp	x9, x19, [sp, #136]             ; 16-byte Folded Spill
	add	x9, x19, #2
	str	x9, [sp, #128]                  ; 8-byte Folded Spill
	add	x8, x8, x10
	add	x10, x8, #18
	add	x9, x19, #3
	stp	x9, x10, [sp, #112]             ; 16-byte Folded Spill
	add	x10, x8, #19
	add	x9, x19, #4
	stp	x9, x10, [sp, #96]              ; 16-byte Folded Spill
	add	x10, x8, #20
	add	x9, x8, #21
	stp	x9, x10, [sp, #80]              ; 16-byte Folded Spill
	add	x9, x19, #13
	add	x8, x8, #22
	stp	x8, x9, [sp, #64]               ; 16-byte Folded Spill
	str	x15, [sp, #160]                 ; 8-byte Folded Spill
LBB0_243:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_244 Depth 2
                                        ;     Child Loop BB0_246 Depth 2
                                        ;     Child Loop BB0_248 Depth 2
                                        ;     Child Loop BB0_250 Depth 2
                                        ;     Child Loop BB0_252 Depth 2
                                        ;     Child Loop BB0_254 Depth 2
                                        ;     Child Loop BB0_256 Depth 2
                                        ;     Child Loop BB0_261 Depth 2
                                        ;     Child Loop BB0_265 Depth 2
	str	x11, [sp, #208]                 ; 8-byte Folded Spill
	ldur	x21, [x29, #-200]               ; 8-byte Folded Reload
	add	x0, x21, x20
	sub	x2, x15, x20
	mov	w1, #10                         ; =0xa
	bl	_memchr
	sub	x8, x0, x21
	stp	x8, x0, [sp, #184]              ; 16-byte Folded Spill
	add	w8, w19, w20
	orr	x9, x8, #0xffffffff00000000
	ldr	x8, [sp, #136]                  ; 8-byte Folded Reload
	add	w0, w8, w20
	ldr	x8, [sp, #128]                  ; 8-byte Folded Reload
	add	x10, x8, x20
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	add	x1, x8, x20
	ldr	x8, [sp, #112]                  ; 8-byte Folded Reload
	add	x3, x8, x20
	ldr	x8, [sp, #104]                  ; 8-byte Folded Reload
	add	x5, x8, x20
	ldr	x8, [sp, #96]                   ; 8-byte Folded Reload
	add	w7, w8, w20
	ldr	x8, [sp, #88]                   ; 8-byte Folded Reload
	add	x19, x8, x20
	ldr	x8, [sp, #80]                   ; 8-byte Folded Reload
	add	x25, x8, x20
	add	x26, x20, #13
	ldr	x8, [sp, #72]                   ; 8-byte Folded Reload
	add	x27, x8, x20
	ldr	x8, [sp, #64]                   ; 8-byte Folded Reload
	add	x28, x8, x20
	mov	x30, x3
	mov	x8, x10
LBB0_244:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x21, x0
	mov	x11, x8
	mov	x12, x10
	mov	x13, x1
	mov	x14, x30
	mov	x15, x3
	mov	x16, x5
	mov	x17, x7
	mov	x2, x19
	mov	x4, x25
	mov	x6, x26
	mov	x22, x27
	mov	x23, x28
	ldur	x8, [x29, #-200]                ; 8-byte Folded Reload
	ldrb	w24, [x8, x20]
	add	x20, x20, #1
	mov	x8, #4294967296                 ; =0x100000000
	add	x9, x9, x8
	add	w0, w0, #1
	add	w8, w11, #1
	add	x10, x10, #1
	add	x1, x1, #1
	add	w30, w30, #1
	add	x3, x3, #1
	add	x5, x5, #1
	add	w7, w7, #1
	add	x19, x19, #1
	add	x25, x25, #1
	add	x26, x26, #1
	add	x27, x27, #1
	add	x28, x28, #1
	cmp	w24, #32
	ldur	x24, [x29, #-200]               ; 8-byte Folded Reload
	b.ne	LBB0_244
; %bb.245:                              ;   in Loop: Header=BB0_243 Depth=1
	str	x9, [sp, #200]                  ; 8-byte Folded Spill
	orr	x21, x21, #0xffffffff00000000
	mov	x0, #4294967296                 ; =0x100000000
LBB0_246:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x19, x11
	mov	x9, x12
	mov	x10, x13
	mov	x1, x14
	mov	x3, x15
	mov	x5, x16
	mov	x7, x17
	mov	x25, x2
	mov	x26, x4
	mov	x27, x6
	mov	x28, x22
	mov	x30, x23
	ldrb	w8, [x24, x20]
	add	x20, x20, #1
	add	x21, x21, x0
	add	w11, w11, #1
	add	x12, x12, #1
	add	x13, x13, #1
	add	w14, w14, #1
	add	x15, x15, #1
	add	x16, x16, #1
	add	w17, w17, #1
	add	x2, x2, #1
	add	x4, x4, #1
	add	x6, x6, #1
	add	x22, x22, #1
	add	x23, x23, #1
	cmp	w8, #32
	b.ne	LBB0_246
; %bb.247:                              ;   in Loop: Header=BB0_243 Depth=1
	orr	x23, x19, #0xffffffff00000000
	mov	x6, #4294967296                 ; =0x100000000
LBB0_248:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x4, x1
	mov	x11, x3
	mov	x12, x5
	mov	x13, x7
	mov	x14, x25
	mov	x15, x26
	mov	x16, x27
	mov	x17, x28
	mov	x2, x30
	ldrb	w8, [x10], #1
	add	x20, x20, #1
	add	x23, x23, x6
	add	x9, x9, #1
	add	w1, w1, #1
	add	x3, x3, #1
	add	x5, x5, #1
	add	w7, w7, #1
	add	x25, x25, #1
	add	x26, x26, #1
	add	x27, x27, #1
	add	x28, x28, #1
	add	x30, x30, #1
	cmp	w8, #32
	b.ne	LBB0_248
; %bb.249:                              ;   in Loop: Header=BB0_243 Depth=1
	orr	x25, x4, #0xffffffff00000000
LBB0_250:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x8, x13
	mov	x10, x14
	mov	x1, x15
	mov	x3, x16
	mov	x4, x17
	mov	x5, x2
	ldrb	w9, [x12], #1
	add	x20, x20, #1
	add	x25, x25, x6
	add	x11, x11, #1
	add	w13, w13, #1
	add	x14, x14, #1
	add	x15, x15, #1
	add	x16, x16, #1
	add	x17, x17, #1
	add	x2, x2, #1
	cmp	w9, #32
	b.ne	LBB0_250
; %bb.251:                              ;   in Loop: Header=BB0_243 Depth=1
	orr	x28, x8, #0xffffffff00000000
LBB0_252:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x9, x1
	mov	x12, x3
	mov	x15, x4
	mov	x16, x5
	ldrb	w8, [x10], #1
	add	x20, x20, #1
	add	x28, x28, x6
	add	x1, x1, #1
	add	x3, x3, #1
	add	x4, x4, #1
	add	x5, x5, #1
	cmp	w8, #32
	b.ne	LBB0_252
; %bb.253:                              ;   in Loop: Header=BB0_243 Depth=1
	mov	x17, #0                         ; =0x0
	mov	x8, x9
	mov	x11, x20
LBB0_254:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x14, x11
	mov	x26, x12
	mov	x22, x15
	mov	x10, x16
	mov	x13, x17
	ldrb	w1, [x8], #1
	add	x11, x11, #1
	add	x12, x12, #1
	add	x15, x15, #1
	add	x16, x16, #1
	add	x17, x17, #1
	cmp	w1, #32
	b.ne	LBB0_254
; %bb.255:                              ;   in Loop: Header=BB0_243 Depth=1
	mov	x15, #-2                        ; =0xfffffffffffffffe
	mov	x8, x10
LBB0_256:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x12, x15
	ldrb	w16, [x8], #1
	add	x26, x26, #1
	add	x22, x22, #1
	add	x15, x15, #1
	cmp	w16, #32
	b.ne	LBB0_256
; %bb.257:                              ;   in Loop: Header=BB0_243 Depth=1
	ldr	x8, [sp, #192]                  ; 8-byte Folded Reload
	cmp	x8, #0
	ldp	x15, x0, [sp, #160]             ; 16-byte Folded Reload
	ldr	x8, [sp, #184]                  ; 8-byte Folded Reload
	csel	x24, x15, x8, eq
	ldr	w8, [x0]
	cmp	w8, #1
	b.lt	LBB0_259
; %bb.258:                              ;   in Loop: Header=BB0_243 Depth=1
	add	w8, w8, #5
	str	w8, [x0]
LBB0_259:                               ;   in Loop: Header=BB0_243 Depth=1
	mov	w16, #10                        ; =0xa
	cmp	x20, x14
	b.ge	LBB0_262
; %bb.260:                              ;   in Loop: Header=BB0_243 Depth=1
	mov	x27, #0                         ; =0x0
	ldr	x20, [sp, #200]                 ; 8-byte Folded Reload
LBB0_261:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrsb	x14, [x9], #1
	madd	x14, x27, x16, x14
	sub	x27, x14, #48
	subs	x13, x13, #1
	b.ne	LBB0_261
	b	LBB0_263
LBB0_262:                               ;   in Loop: Header=BB0_243 Depth=1
	mov	x27, #0                         ; =0x0
	ldr	x20, [sp, #200]                 ; 8-byte Folded Reload
LBB0_263:                               ;   in Loop: Header=BB0_243 Depth=1
	sub	x9, x26, #10
	cmp	x11, x9
	b.ge	LBB0_270
; %bb.264:                              ;   in Loop: Header=BB0_243 Depth=1
	mov	x19, #0                         ; =0x0
	ldr	x11, [sp, #208]                 ; 8-byte Folded Reload
LBB0_265:                               ;   Parent Loop BB0_243 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrsb	x9, [x10], #1
	madd	x9, x19, x16, x9
	sub	x19, x9, #48
	subs	x12, x12, #1
	b.ne	LBB0_265
; %bb.266:                              ;   in Loop: Header=BB0_243 Depth=1
	cmp	w8, #1
	b.lt	LBB0_268
LBB0_267:                               ;   in Loop: Header=BB0_243 Depth=1
	add	w8, w8, #1
	str	w8, [x0]
LBB0_268:                               ;   in Loop: Header=BB0_243 Depth=1
	ldr	x8, [sp, #152]                  ; 8-byte Folded Reload
	cmp	x11, x8
	b.eq	LBB0_271
LBB0_269:                               ;   in Loop: Header=BB0_243 Depth=1
	ldr	x8, [sp, #176]                  ; 8-byte Folded Reload
	mov	w9, #112                        ; =0x70
	madd	x8, x11, x9, x8
	stp	x0, x20, [x8]
	add	x20, x24, #1
	sub	w9, w24, w26
	bfi	x22, x9, #32, #32
	add	x24, x11, #1
	stp	x0, x21, [x8, #16]
	stp	x0, x23, [x8, #32]
	stp	x0, x25, [x8, #48]
	stp	x0, x28, [x8, #64]
	stp	x0, x22, [x8, #80]
	mov	x11, x24
	stp	x27, x19, [x8, #96]
	cmp	x20, x15
	ldr	x19, [sp, #144]                 ; 8-byte Folded Reload
	b.lt	LBB0_243
	b	LBB0_11
LBB0_270:                               ;   in Loop: Header=BB0_243 Depth=1
	mov	x19, #0                         ; =0x0
	ldr	x11, [sp, #208]                 ; 8-byte Folded Reload
	cmp	w8, #1
	b.ge	LBB0_267
	b	LBB0_268
LBB0_271:                               ;   in Loop: Header=BB0_243 Depth=1
	lsl	x8, x11, #1
	cmp	x11, #0
	csinc	x9, x8, xzr, ne
	lsl	x8, x9, #7
	str	x9, [sp, #152]                  ; 8-byte Folded Spill
	sub	x1, x8, x9, lsl #4
	ldr	x0, [sp, #176]                  ; 8-byte Folded Reload
	bl	_realloc
	ldr	x11, [sp, #208]                 ; 8-byte Folded Reload
	str	x0, [sp, #176]                  ; 8-byte Folded Spill
	ldp	x15, x0, [sp, #160]             ; 16-byte Folded Reload
	b	LBB0_269
LBB0_272:
	cmp	w8, #1
	b.ne	LBB0_274
; %bb.273:
	bl	_bown_free
LBB0_274:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x22, x0
	cbz	x24, LBB0_313
; %bb.275:
	mov	x19, #0                         ; =0x0
	mov	x23, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
	ldr	x8, [sp, #176]                  ; 8-byte Folded Reload
	add	x8, x8, #64
	mov	x9, #30255                      ; =0x762f
	movk	x9, #12081, lsl #16
	movk	x9, #29557, lsl #32
	movk	x9, #29285, lsl #48
	mov	w10, #115                       ; =0x73
	mov	x11, x24
	ldp	x17, x16, [sp, #40]             ; 16-byte Folded Reload
	b	LBB0_278
LBB0_276:                               ;   in Loop: Header=BB0_278 Depth=1
	ldr	x13, [x8]
	ldr	w14, [x8, #8]
	add	x13, x13, x14
	ldr	x14, [x13, #16]
	ldrb	w13, [x13, #24]
	cmp	x14, x9
	ccmp	w13, w10, #0, eq
	cset	w13, eq
LBB0_277:                               ;   in Loop: Header=BB0_278 Depth=1
	add	x25, x25, w12, uxtw
	add	x8, x8, #112
	add	x19, x19, w13, uxtw
	subs	x11, x11, #1
	b.eq	LBB0_287
LBB0_278:                               ; =>This Inner Loop Header: Depth=1
	ldur	w12, [x8, #-36]
	cmp	w12, #5
	b.ne	LBB0_281
; %bb.279:                              ;   in Loop: Header=BB0_278 Depth=1
	ldur	x12, [x8, #-48]
	ldur	w13, [x8, #-40]
	cmp	x12, x16
	ccmp	w13, #0, #0, eq
	b.eq	LBB0_282
; %bb.280:                              ;   in Loop: Header=BB0_278 Depth=1
	add	x12, x12, x13
	ldr	w13, [x12, #16]
	ldr	w14, [x17]
	ldrb	w12, [x12, #20]
	ldrb	w15, [x17, #4]
	cmp	w13, w14
	ccmp	w12, w15, #0, eq
	cset	w12, eq
	b	LBB0_283
LBB0_281:                               ;   in Loop: Header=BB0_278 Depth=1
	mov	w12, #0                         ; =0x0
	b	LBB0_283
LBB0_282:                               ;   in Loop: Header=BB0_278 Depth=1
	mov	w12, #1                         ; =0x1
LBB0_283:                               ;   in Loop: Header=BB0_278 Depth=1
	ldr	x13, [x8, #32]
	cmp	x13, #500
	b.lt	LBB0_285
; %bb.284:                              ;   in Loop: Header=BB0_278 Depth=1
	ldr	x13, [x8, #40]
	add	x23, x13, x23
LBB0_285:                               ;   in Loop: Header=BB0_278 Depth=1
	ldr	w13, [x8, #12]
	cmp	w13, #9
	b.hs	LBB0_276
; %bb.286:                              ;   in Loop: Header=BB0_278 Depth=1
	mov	w13, #0                         ; =0x0
	b	LBB0_277
LBB0_287:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	ldr	x8, [sp, #176]                  ; 8-byte Folded Reload
	add	x20, x8, #48
	mov	x26, x24
	b	LBB0_290
LBB0_288:                               ;   in Loop: Header=BB0_290 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_289:                               ;   in Loop: Header=BB0_290 Depth=1
	add	x20, x20, #112
	subs	x26, x26, #1
	b.eq	LBB0_314
LBB0_290:                               ; =>This Inner Loop Header: Depth=1
	ldur	x0, [x20, #-48]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_292
; %bb.291:                              ;   in Loop: Header=BB0_290 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_294
LBB0_292:                               ;   in Loop: Header=BB0_290 Depth=1
	cmp	w8, #1
	b.ne	LBB0_294
; %bb.293:                              ;   in Loop: Header=BB0_290 Depth=1
	bl	_bown_free
LBB0_294:                               ;   in Loop: Header=BB0_290 Depth=1
	ldur	x0, [x20, #-32]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_296
; %bb.295:                              ;   in Loop: Header=BB0_290 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_298
LBB0_296:                               ;   in Loop: Header=BB0_290 Depth=1
	cmp	w8, #1
	b.ne	LBB0_298
; %bb.297:                              ;   in Loop: Header=BB0_290 Depth=1
	bl	_bown_free
LBB0_298:                               ;   in Loop: Header=BB0_290 Depth=1
	ldur	x0, [x20, #-16]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_300
; %bb.299:                              ;   in Loop: Header=BB0_290 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_302
LBB0_300:                               ;   in Loop: Header=BB0_290 Depth=1
	cmp	w8, #1
	b.ne	LBB0_302
; %bb.301:                              ;   in Loop: Header=BB0_290 Depth=1
	bl	_bown_free
LBB0_302:                               ;   in Loop: Header=BB0_290 Depth=1
	ldr	x0, [x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_304
; %bb.303:                              ;   in Loop: Header=BB0_290 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_306
LBB0_304:                               ;   in Loop: Header=BB0_290 Depth=1
	cmp	w8, #1
	b.ne	LBB0_306
; %bb.305:                              ;   in Loop: Header=BB0_290 Depth=1
	bl	_bown_free
LBB0_306:                               ;   in Loop: Header=BB0_290 Depth=1
	ldr	x0, [x20, #16]
	ldr	w8, [x0]
	cmp	w8, #2
	b.lt	LBB0_308
; %bb.307:                              ;   in Loop: Header=BB0_290 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
	b	LBB0_310
LBB0_308:                               ;   in Loop: Header=BB0_290 Depth=1
	cmp	w8, #1
	b.ne	LBB0_310
; %bb.309:                              ;   in Loop: Header=BB0_290 Depth=1
	bl	_bown_free
LBB0_310:                               ;   in Loop: Header=BB0_290 Depth=1
	ldr	x0, [x20, #32]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_288
; %bb.311:                              ;   in Loop: Header=BB0_290 Depth=1
	cmp	w8, #1
	b.ne	LBB0_289
; %bb.312:                              ;   in Loop: Header=BB0_290 Depth=1
	bl	_bown_free
	b	LBB0_289
LBB0_313:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x21, x0
	mov	x19, #0                         ; =0x0
	mov	x23, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
LBB0_314:
	ldr	x0, [sp, #176]                  ; 8-byte Folded Reload
	bl	_free
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x23, x19, [sp, #16]
	stp	x24, x25, [sp]
Lloh63:
	adrp	x0, l_.str.10@PAGE
Lloh64:
	add	x0, x0, l_.str.10@PAGEOFF
	bl	_printf
	ldr	x19, [sp, #56]                  ; 8-byte Folded Reload
	sub	x8, x22, x19
Lloh65:
	adrp	x9, l_.str.29@PAGE
Lloh66:
	add	x9, x9, l_.str.29@PAGEOFF
	stp	x9, x8, [sp]
Lloh67:
	adrp	x23, l_.str.11@PAGE
Lloh68:
	add	x23, x23, l_.str.11@PAGEOFF
	mov	x0, x23
	bl	_printf
	sub	x8, x21, x22
Lloh69:
	adrp	x9, l_.str.30@PAGE
Lloh70:
	add	x9, x9, l_.str.30@PAGEOFF
	b	LBB0_88
LBB0_315:
	mov	x23, #0                         ; =0x0
	mov	x19, #0                         ; =0x0
	mov	x20, x10
	b	LBB0_328
LBB0_316:
	ands	x8, x25, #0x7
	mov	w9, #8                          ; =0x8
	mov	w10, #16963                     ; =0x4243
	movk	w10, #15, lsl #16
	dup.2s	v4, w10
	movi.2d	v0, #0000000000000000
	movi.2d	v1, #0000000000000000
	csel	x8, x9, x8, eq
	sub	x8, x25, x8
	add	x9, x22, #148
	mov	x10, x8
	movi.2d	v3, #0000000000000000
	movi.2d	v2, #0000000000000000
	movi.2d	v5, #0000000000000000
	movi.2d	v6, #0000000000000000
	movi.2d	v7, #0000000000000000
	movi.2d	v16, #0000000000000000
LBB0_317:                               ; =>This Inner Loop Header: Depth=1
	ldur	d17, [x9, #-96]
	ldur	d18, [x9, #-128]
	zip1.2s	v17, v18, v17
	ldur	d18, [x9, #-32]
	ldur	d19, [x9, #-64]
	zip1.2s	v18, v19, v18
	ldr	d19, [x9, #32]
	ldr	d20, [x9]
	sub	x11, x9, #124
	sub	x12, x9, #60
	add	x13, x9, #4
	add	x14, x9, #68
	ld4.2d	{ v21, v22, v23, v24 }, [x11]
	ld4.2d	{ v25, v26, v27, v28 }, [x12]
	ld4.2d	{ v8, v9, v10, v11 }, [x13]
	ld4.2d	{ v12, v13, v14, v15 }, [x14]
	zip1.2s	v19, v20, v19
	ldr	d20, [x9, #96]
	ldr	d29, [x9, #64]
	zip1.2s	v20, v29, v20
	add.2d	v0, v21, v0
	umlal.2d	v21, v17, v4
	add.2d	v1, v25, v1
	umlal.2d	v25, v18, v4
	add.2d	v3, v8, v3
	umlal.2d	v8, v19, v4
	add.2d	v2, v12, v2
	umlal.2d	v12, v20, v4
	eor.16b	v5, v21, v5
	eor.16b	v6, v25, v6
	eor.16b	v7, v8, v7
	add	x9, x9, #256
	eor.16b	v16, v12, v16
	subs	x10, x10, #8
	b.ne	LBB0_317
; %bb.318:
	eor.16b	v4, v6, v5
	eor3.16b	v4, v7, v4, v16
	ext.16b	v5, v4, v4, #8
	eor.8b	v4, v4, v5
	fmov	x19, d4
	add.2d	v0, v1, v0
	add.2d	v0, v3, v0
	add.2d	v0, v2, v0
	addp.2d	d0, v0
	fmov	x23, d0
LBB0_319:
	add	x9, x22, x8, lsl #5
	add	x9, x9, #24
	mov	w10, #16963                     ; =0x4243
	movk	w10, #15, lsl #16
LBB0_320:                               ; =>This Inner Loop Header: Depth=1
	ldur	w11, [x9, #-4]
	ldr	x12, [x9], #32
	umaddl	x11, w11, w10, x12
	eor	x19, x11, x19
	add	x23, x12, x23
	add	x8, x8, #1
	cmp	x25, x8
	b.ne	LBB0_320
; %bb.321:
	mov	w20, #8                         ; =0x8
	mov	x24, x25
	b	LBB0_324
LBB0_322:                               ;   in Loop: Header=BB0_324 Depth=1
	sub	w8, w8, #1
	str	w8, [x0]
LBB0_323:                               ;   in Loop: Header=BB0_324 Depth=1
	add	x20, x20, #32
	subs	x24, x24, #1
	b.eq	LBB0_327
LBB0_324:                               ; =>This Inner Loop Header: Depth=1
	ldr	x0, [x22, x20]
	ldr	w8, [x0]
	cmp	w8, #2
	b.ge	LBB0_322
; %bb.325:                              ;   in Loop: Header=BB0_324 Depth=1
	cmp	w8, #1
	b.ne	LBB0_323
; %bb.326:                              ;   in Loop: Header=BB0_324 Depth=1
	bl	_bown_free
	b	LBB0_323
LBB0_327:
	mov	x20, x26
LBB0_328:
	mov	x0, x22
	bl	_free
	mov	x0, x20
	bl	_free
	ldr	w8, [x21]
	cmp	w8, #2
	b.lt	LBB0_330
; %bb.329:
	sub	w8, w8, #1
	str	w8, [x21]
	b	LBB0_332
LBB0_330:
	cmp	w8, #1
	b.ne	LBB0_332
; %bb.331:
	mov	x0, x21
	bl	_bown_free
LBB0_332:
	mov	w0, #8                          ; =0x8
	bl	_clock_gettime_nsec_np
	mov	x20, x0
	stp	x23, x19, [sp, #8]
	str	x25, [sp]
Lloh71:
	adrp	x0, l_.str.25@PAGE
Lloh72:
	add	x0, x0, l_.str.25@PAGEOFF
	bl	_printf
	ldr	x8, [sp, #128]                  ; 8-byte Folded Reload
	sub	x8, x20, x8
Lloh73:
	adrp	x9, l_.str.15@PAGE
Lloh74:
	add	x9, x9, l_.str.15@PAGEOFF
	stp	x9, x8, [sp]
Lloh75:
	adrp	x0, l_.str.11@PAGE
Lloh76:
	add	x0, x0, l_.str.11@PAGEOFF
LBB0_333:
	bl	_printf
LBB0_334:
Lloh77:
	adrp	x8, l_.str.7@PAGE
Lloh78:
	add	x8, x8, l_.str.7@PAGEOFF
	str	x8, [sp]
Lloh79:
	adrp	x0, l_.str.6@PAGE
Lloh80:
	add	x0, x0, l_.str.6@PAGEOFF
	bl	_printf
	mov	w0, #0                          ; =0x0
LBB0_335:
	ldp	x29, x30, [sp, #416]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #400]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #384]            ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #368]            ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #352]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #336]            ; 16-byte Folded Reload
	ldp	d9, d8, [sp, #320]              ; 16-byte Folded Reload
	ldp	d11, d10, [sp, #304]            ; 16-byte Folded Reload
	ldp	d13, d12, [sp, #288]            ; 16-byte Folded Reload
	ldp	d15, d14, [sp, #272]            ; 16-byte Folded Reload
	add	sp, sp, #432
	ret
LBB0_336:
	mov	w0, #3                          ; =0x3
	bl	_alloc_slow
	mov	x21, x0
	b	LBB0_15
LBB0_337:
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
	.loh AdrpAdd	Lloh49, Lloh50
	.loh AdrpAdd	Lloh59, Lloh60
	.loh AdrpAdd	Lloh57, Lloh58
	.loh AdrpAdd	Lloh55, Lloh56
	.loh AdrpAdd	Lloh53, Lloh54
	.loh AdrpAdd	Lloh51, Lloh52
	.loh AdrpAdd	Lloh61, Lloh62
	.loh AdrpAdd	Lloh69, Lloh70
	.loh AdrpAdd	Lloh67, Lloh68
	.loh AdrpAdd	Lloh65, Lloh66
	.loh AdrpAdd	Lloh63, Lloh64
	.loh AdrpAdd	Lloh75, Lloh76
	.loh AdrpAdd	Lloh73, Lloh74
	.loh AdrpAdd	Lloh71, Lloh72
	.loh AdrpAdd	Lloh79, Lloh80
	.loh AdrpAdd	Lloh77, Lloh78
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function load
_load:                                  ; @load
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	add	x29, sp, #32
	sub	sp, sp, #688
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
Lloh81:
	adrp	x8, ___stack_chk_guard@GOTPAGE
Lloh82:
	ldr	x8, [x8, ___stack_chk_guard@GOTPAGEOFF]
Lloh83:
	ldr	x8, [x8]
	stur	x8, [x29, #-40]
	stp	x0, x1, [sp]
Lloh84:
	adrp	x2, l_.str.16@PAGE
Lloh85:
	add	x2, x2, l_.str.16@PAGEOFF
	add	x0, sp, #168
	mov	w1, #512                        ; =0x200
	bl	_snprintf
	add	x0, sp, #168
	mov	w1, #0                          ; =0x0
	bl	_open
	tbnz	w0, #31, LBB1_13
; %bb.1:
	mov	x21, x0
	add	x1, sp, #24
	bl	_fstat
	ldr	x8, [sp, #120]
	add	x0, x8, #1
	bl	_malloc
	cbz	x0, LBB1_14
; %bb.2:
	mov	x19, x0
	mov	x8, #0                          ; =0x0
LBB1_3:                                 ; =>This Inner Loop Header: Depth=1
	mov	x20, x8
	ldr	x8, [sp, #120]
	subs	x2, x8, x20
	b.le	LBB1_5
; %bb.4:                                ;   in Loop: Header=BB1_3 Depth=1
	add	x1, x19, x20
	mov	x0, x21
	bl	_read
	add	x8, x0, x20
	cmp	x0, #0
	b.gt	LBB1_3
LBB1_5:
	mov	x0, x21
	bl	_close
	strb	wzr, [x19, x20]
	add	x8, x20, #23
	cmp	x8, #519
	b.hi	LBB1_10
; %bb.6:
	lsr	x0, x8, #3
Lloh86:
	adrp	x8, _heap@PAGE
Lloh87:
	add	x8, x8, _heap@PAGEOFF
	ldr	x21, [x8, x0, lsl #3]
	cbz	x21, LBB1_11
; %bb.7:
	ldr	x9, [x21]
	str	x9, [x8, x0, lsl #3]
LBB1_8:
	mov	w8, #1                          ; =0x1
	str	w8, [x21]
	mov	w8, #2                          ; =0x2
	strh	w8, [x21, #4]
	str	x20, [x21, #8]
	add	x0, x21, #16
	mov	x1, x19
	mov	x2, x20
	bl	_memcpy
	mov	x0, x19
	bl	_free
	ldur	x8, [x29, #-40]
Lloh88:
	adrp	x9, ___stack_chk_guard@GOTPAGE
Lloh89:
	ldr	x9, [x9, ___stack_chk_guard@GOTPAGEOFF]
Lloh90:
	ldr	x9, [x9]
	cmp	x9, x8
	b.ne	LBB1_15
; %bb.9:
	lsl	x1, x20, #32
	mov	x0, x21
	add	sp, sp, #688
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
LBB1_10:
	add	x0, x20, #16
	bl	_xmalloc
	b	LBB1_12
LBB1_11:
	bl	_alloc_slow
LBB1_12:
	mov	x21, x0
	b	LBB1_8
LBB1_13:
	add	x0, sp, #168
	bl	_load.cold.1
LBB1_14:
Lloh91:
	adrp	x8, ___stderrp@GOTPAGE
Lloh92:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh93:
	ldr	x1, [x8]
Lloh94:
	adrp	x0, l_.str.17@PAGE
Lloh95:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
LBB1_15:
	bl	___stack_chk_fail
	.loh AdrpAdd	Lloh84, Lloh85
	.loh AdrpLdrGotLdr	Lloh81, Lloh82, Lloh83
	.loh AdrpAdd	Lloh86, Lloh87
	.loh AdrpLdrGotLdr	Lloh88, Lloh89, Lloh90
	.loh AdrpAdd	Lloh94, Lloh95
	.loh AdrpLdrGotLdr	Lloh91, Lloh92, Lloh93
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
Lloh96:
	adrp	x8, ___stderrp@GOTPAGE
Lloh97:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh98:
	ldr	x1, [x8]
Lloh99:
	adrp	x0, l_.str.17@PAGE
Lloh100:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
	.loh AdrpAdd	Lloh99, Lloh100
	.loh AdrpLdrGotLdr	Lloh96, Lloh97, Lloh98
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
Lloh101:
	adrp	x8, _heap@PAGE+520
Lloh102:
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
Lloh103:
	adrp	x8, ___stderrp@GOTPAGE
Lloh104:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh105:
	ldr	x1, [x8]
Lloh106:
	adrp	x0, l_.str.17@PAGE
Lloh107:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
	.loh AdrpAdd	Lloh101, Lloh102
	.loh AdrpAdd	Lloh106, Lloh107
	.loh AdrpLdrGotLdr	Lloh103, Lloh104, Lloh105
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
Lloh108:
	adrp	x9, _heap@PAGE
Lloh109:
	add	x9, x9, _heap@PAGEOFF
	and	x8, x8, #0xfffffffffffffff8
	ldr	x10, [x9, x8]
	str	x10, [x0]
	str	x0, [x9, x8]
	ret
LBB4_2:
	b	_free
	.loh AdrpAdd	Lloh108, Lloh109
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
	lsl	x1, x20, #5
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
	b	LBB5_9
LBB5_8:                                 ;   in Loop: Header=BB5_9 Depth=1
	str	w9, [x13, x14, lsl #2]
	add	x9, x9, #1
	cmp	x9, x8
	b.eq	LBB5_12
LBB5_9:                                 ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB5_10 Depth 2
	lsl	x14, x9, #5
	ldr	x14, [x12, x14]
	lsr	x14, x14, x11
LBB5_10:                                ;   Parent Loop BB5_9 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w15, [x13, x14, lsl #2]
	cmn	w15, #1
	b.eq	LBB5_8
; %bb.11:                               ;   in Loop: Header=BB5_10 Depth=2
	add	x14, x14, #1
	and	x14, x14, x10
	b	LBB5_10
LBB5_12:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
LBB5_13:
Lloh110:
	adrp	x8, ___stderrp@GOTPAGE
Lloh111:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh112:
	ldr	x1, [x8]
Lloh113:
	adrp	x0, l_.str.17@PAGE
Lloh114:
	add	x0, x0, l_.str.17@PAGEOFF
	bl	_fputs
	mov	w0, #1                          ; =0x1
	bl	_exit
	.loh AdrpAdd	Lloh113, Lloh114
	.loh AdrpLdrGotLdr	Lloh110, Lloh111, Lloh112
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function qsort_s
_qsort_s:                               ; @qsort_s
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #128
	stp	x28, x27, [sp, #32]             ; 16-byte Folded Spill
	stp	x26, x25, [sp, #48]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #64]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #80]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #96]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #112]            ; 16-byte Folded Spill
	add	x29, sp, #112
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
	mov	x28, x1
	mov	x19, x0
	cmp	x1, #17
	b.ge	LBB6_11
LBB6_1:
	cmp	x28, #2
	b.lt	LBB6_25
; %bb.2:
	mov	w22, #1                         ; =0x1
	mov	w23, #2                         ; =0x2
	mov	x20, x19
	str	x28, [sp, #8]                   ; 8-byte Folded Spill
	b	LBB6_5
LBB6_3:                                 ;   in Loop: Header=BB6_5 Depth=1
	sub	x8, x28, #1
LBB6_4:                                 ;   in Loop: Header=BB6_5 Depth=1
	add	x8, x19, x8, lsl #4
	ldp	x9, x28, [sp]                   ; 16-byte Folded Reload
	str	x9, [x8]
	stp	w26, w27, [x8, #8]
	add	x22, x22, #1
	add	x23, x23, #1
	add	x20, x20, #16
	cmp	x22, x28
	b.eq	LBB6_25
LBB6_5:                                 ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB6_6 Depth 2
	add	x8, x19, x22, lsl #4
	ldr	x9, [x8]
	ldp	w26, w27, [x8, #8]
	str	x9, [sp]                        ; 8-byte Folded Spill
	add	x8, x9, x26
	add	x21, x8, #16
	mov	x24, x20
	mov	x28, x23
LBB6_6:                                 ;   Parent Loop BB6_5 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x8, [x24]
	ldp	w10, w9, [x24, #8]
	add	x8, x8, x10
	add	x1, x8, #16
	cmp	w27, w9
	csel	w2, w27, w9, lo
	cset	w25, lo
	mov	x0, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w25, w8, eq
	cmp	w8, #1
	b.ne	LBB6_3
; %bb.7:                                ;   in Loop: Header=BB6_6 Depth=2
	ldr	q0, [x24]
	str	q0, [x24, #16]
	sub	x24, x24, #16
	sub	x28, x28, #1
	cmp	x28, #1
	b.gt	LBB6_6
; %bb.8:                                ;   in Loop: Header=BB6_5 Depth=1
	mov	x8, #0                          ; =0x0
	b	LBB6_4
LBB6_9:                                 ;   in Loop: Header=BB6_11 Depth=1
	add	x8, x19, x27
	add	x0, x8, #32
	mov	x1, x28
	bl	_qsort_s
	mov	x28, x21
LBB6_10:                                ;   in Loop: Header=BB6_11 Depth=1
	cmp	x28, #16
	b.le	LBB6_1
LBB6_11:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB6_17 Depth 2
                                        ;       Child Loop BB6_18 Depth 3
                                        ;       Child Loop BB6_20 Depth 3
	lsr	x8, x28, #1
	add	x21, x19, x8, lsl #4
	mov	x26, x21
	ldr	w22, [x26, #12]!
	ldr	x24, [x21]
	mov	x27, x21
	ldr	w25, [x27, #8]!
	add	x8, x24, x25
	add	x0, x8, #16
	ldr	x8, [x19]
	ldp	w10, w9, [x19, #8]
	add	x8, x8, x10
	add	x1, x8, #16
	cmp	w22, w9
	csel	w2, w22, w9, lo
	cset	w20, lo
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w20, w8, eq
	cmp	w8, #1
	b.ne	LBB6_13
; %bb.12:                               ;   in Loop: Header=BB6_11 Depth=1
	ldr	q0, [x21]
	str	q0, [sp, #16]
	ldr	q0, [x19]
	str	q0, [x21]
	ldr	q0, [sp, #16]
	str	q0, [x19]
	ldr	w22, [x26]
	ldr	x24, [x21]
	ldr	w25, [x27]
LBB6_13:                                ;   in Loop: Header=BB6_11 Depth=1
	str	x28, [sp, #8]                   ; 8-byte Folded Spill
	sub	x23, x28, #1
	add	x20, x19, x23, lsl #4
	ldr	x8, [x20]
	ldp	w10, w9, [x20, #8]
	add	x8, x8, x10
	add	x0, x8, #16
	add	x8, x24, x25
	add	x1, x8, #16
	cmp	w9, w22
	csel	w2, w9, w22, lo
	cset	w28, lo
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w28, w8, eq
	cmp	w8, #1
	b.ne	LBB6_16
; %bb.14:                               ;   in Loop: Header=BB6_11 Depth=1
	ldr	q0, [x20]
	str	q0, [sp, #16]
	ldr	q0, [x21]
	str	q0, [x20]
	ldr	q0, [sp, #16]
	str	q0, [x21]
	ldr	w22, [x26]
	ldr	x24, [x21]
	ldr	w25, [x27]
	add	x8, x24, x25
	add	x0, x8, #16
	ldr	x8, [x19]
	ldp	w10, w9, [x19, #8]
	add	x8, x8, x10
	add	x1, x8, #16
	cmp	w22, w9
	csel	w2, w22, w9, lo
	cset	w20, lo
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w20, w8, eq
	cmp	w8, #1
	b.ne	LBB6_16
; %bb.15:                               ;   in Loop: Header=BB6_11 Depth=1
	ldr	q0, [x21]
	str	q0, [sp, #16]
	ldr	q0, [x19]
	str	q0, [x21]
	ldr	q0, [sp, #16]
	str	q0, [x19]
	ldr	x24, [x21]
	ldp	w25, w22, [x21, #8]
LBB6_16:                                ;   in Loop: Header=BB6_11 Depth=1
	mov	x26, #0                         ; =0x0
	add	x8, x24, x25
	add	x21, x8, #16
	sub	x24, x19, #16
LBB6_17:                                ;   Parent Loop BB6_11 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB6_18 Depth 3
                                        ;       Child Loop BB6_20 Depth 3
	add	x25, x24, x26, lsl #4
LBB6_18:                                ;   Parent Loop BB6_11 Depth=1
                                        ;     Parent Loop BB6_17 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldr	x8, [x25, #16]!
	ldp	w10, w9, [x25, #8]
	add	x8, x8, x10
	add	x0, x8, #16
	cmp	w9, w22
	csel	w2, w9, w22, lo
	cset	w20, lo
	mov	x1, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w20, w8, eq
	add	x26, x26, #1
	tbnz	w8, #0, LBB6_18
; %bb.19:                               ;   in Loop: Header=BB6_17 Depth=2
	sub	x28, x26, #1
	lsl	x27, x23, #4
LBB6_20:                                ;   Parent Loop BB6_11 Depth=1
                                        ;     Parent Loop BB6_17 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	add	x8, x19, x27
	ldr	x9, [x8]
	ldp	w8, w10, [x8, #8]
	add	x8, x9, x8
	add	x1, x8, #16
	cmp	w22, w10
	csel	w2, w22, w10, lo
	cset	w20, lo
	mov	x0, x21
	bl	_memcmp
	cmp	w0, #0
	cset	w8, lt
	csel	w8, w20, w8, eq
	sub	x23, x23, #1
	sub	x27, x27, #16
	tbnz	w8, #0, LBB6_20
; %bb.21:                               ;   in Loop: Header=BB6_17 Depth=2
	add	x8, x23, #1
	cmp	x28, x8
	b.ge	LBB6_23
; %bb.22:                               ;   in Loop: Header=BB6_17 Depth=2
	add	x8, x19, x27
	ldr	q0, [x25]
	str	q0, [sp, #16]
	ldr	q0, [x8, #16]!
	str	q0, [x25]
	ldr	q0, [sp, #16]
	str	q0, [x8]
	b	LBB6_17
LBB6_23:                                ;   in Loop: Header=BB6_11 Depth=1
	add	x21, x23, #2
	ldr	x8, [sp, #8]                    ; 8-byte Folded Reload
	sub	x8, x8, x23
	sub	x28, x8, #2
	cmp	x21, x28
	b.ge	LBB6_9
; %bb.24:                               ;   in Loop: Header=BB6_11 Depth=1
	mov	x0, x19
	mov	x1, x21
	bl	_qsort_s
	add	x8, x19, x27
	add	x19, x8, #32
	b	LBB6_10
LBB6_25:
	ldp	x29, x30, [sp, #112]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #96]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #80]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #64]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #48]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #32]             ; 16-byte Folded Reload
	add	sp, sp, #128
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
	.asciz	"B"

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
