	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 15, 0	sdk_version 15, 2
	.globl	_methods_gperf_find             ; -- Begin function methods_gperf_find
	.p2align	2
_methods_gperf_find:                    ; @methods_gperf_find
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
	sub	w8, w1, #3
	cmp	w8, #4
	b.hi	LBB0_5
; %bb.1:
	ldrb	w8, [x0]
Lloh0:
	adrp	x9, _methods_ghash.asso_values@PAGE
Lloh1:
	add	x9, x9, _methods_ghash.asso_values@PAGEOFF
	ldrb	w9, [x9, x8]
	add	x9, x9, w1, uxtw
	cmp	w9, #12
	b.hi	LBB0_5
; %bb.2:
Lloh2:
	adrp	x10, _methods_gperf_find.lengthtable@PAGE
Lloh3:
	add	x10, x10, _methods_gperf_find.lengthtable@PAGEOFF
	ldrb	w10, [x10, x9]
	cmp	w10, w1
	b.ne	LBB0_5
; %bb.3:
Lloh4:
	adrp	x10, _methods_gperf_find.wordlist@PAGE
Lloh5:
	add	x10, x10, _methods_gperf_find.wordlist@PAGEOFF
	add	x19, x10, x9, lsl #4
	ldr	x9, [x19]
	ldrb	w10, [x9]
	cmp	w8, w10
	b.ne	LBB0_5
; %bb.4:
	add	x0, x0, #1
	add	x8, x9, #1
	sub	w2, w1, #1
	mov	x1, x8
	bl	_memcmp
	cbz	w0, LBB0_6
LBB0_5:
	mov	x19, #0                         ; =0x0
LBB0_6:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh0, Lloh1
	.loh AdrpAdd	Lloh2, Lloh3
	.loh AdrpAdd	Lloh4, Lloh5
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0                          ; -- Begin function main
lCPI1_0:
	.byte	0                               ; 0x0
	.byte	1                               ; 0x1
	.byte	2                               ; 0x2
	.byte	3                               ; 0x3
	.byte	4                               ; 0x4
	.byte	5                               ; 0x5
	.byte	6                               ; 0x6
	.byte	7                               ; 0x7
	.byte	8                               ; 0x8
	.byte	9                               ; 0x9
	.byte	10                              ; 0xa
	.byte	11                              ; 0xb
	.byte	12                              ; 0xc
	.byte	13                              ; 0xd
	.byte	14                              ; 0xe
	.byte	15                              ; 0xf
	.section	__TEXT,__text,regular,pure_instructions
	.globl	_main
	.p2align	2
_main:                                  ; @main
	.cfi_startproc
; %bb.0:
	stp	d11, d10, [sp, #-128]!          ; 16-byte Folded Spill
	stp	d9, d8, [sp, #16]               ; 16-byte Folded Spill
	stp	x28, x27, [sp, #32]             ; 16-byte Folded Spill
	stp	x26, x25, [sp, #48]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #64]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #80]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #96]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #112]            ; 16-byte Folded Spill
	add	x29, sp, #112
	sub	sp, sp, #672
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
Lloh6:
	adrp	x8, ___stack_chk_guard@GOTPAGE
Lloh7:
	ldr	x8, [x8, ___stack_chk_guard@GOTPAGEOFF]
Lloh8:
	ldr	x8, [x8]
	stur	x8, [x29, #-128]
	ldp	x20, x0, [x1, #8]
	bl	_atoi
	str	x0, [sp, #120]                  ; 8-byte Folded Spill
Lloh9:
	adrp	x8, l_.str.11@PAGE
Lloh10:
	add	x8, x8, l_.str.11@PAGEOFF
	str	x8, [sp]
Lloh11:
	adrp	x2, l_.str.10@PAGE
Lloh12:
	add	x2, x2, l_.str.10@PAGEOFF
	add	x0, sp, #400
	mov	w1, #256                        ; =0x100
	bl	_snprintf
Lloh13:
	adrp	x1, l_.str.12@PAGE
Lloh14:
	add	x1, x1, l_.str.12@PAGEOFF
	add	x0, sp, #400
	bl	_fopen
	cbz	x0, LBB1_104
; %bb.1:
	mov	x21, x0
	add	x19, sp, #144
	add	x0, sp, #144
	mov	w1, #256                        ; =0x100
	mov	x2, x21
	bl	_fgets
	str	x20, [sp, #64]                  ; 8-byte Folded Spill
	cbz	x0, LBB1_8
; %bb.2:
	mov	x20, #0                         ; =0x0
	mov	x25, #0                         ; =0x0
Lloh15:
	adrp	x26, _main.q@PAGE+8
Lloh16:
	add	x26, x26, _main.q@PAGEOFF+8
	mov	w24, #65535                     ; =0xffff
Lloh17:
	adrp	x27, _main.arena@PAGE
Lloh18:
	add	x27, x27, _main.arena@PAGEOFF
LBB1_3:                                 ; =>This Inner Loop Header: Depth=1
	add	x0, sp, #144
	bl	_strlen
	mov	x22, x0
	cbz	x0, LBB1_6
; %bb.4:                                ;   in Loop: Header=BB1_3 Depth=1
	sub	x8, x22, #1
	ldrb	w9, [x19, x8]
	cmp	w9, #10
	b.ne	LBB1_6
; %bb.5:                                ;   in Loop: Header=BB1_3 Depth=1
	strb	wzr, [x19, x8]
	mov	x22, x8
LBB1_6:                                 ;   in Loop: Header=BB1_3 Depth=1
	add	x8, x25, x27
	add	x23, x8, #32
	add	x1, sp, #144
	mov	x0, x23
	mov	x2, x22
	bl	_memcpy
	stp	x23, x22, [x26, #-8]
	add	x23, x20, #1
	add	x0, sp, #144
	mov	w1, #256                        ; =0x100
	mov	x2, x21
	bl	_fgets
	cbz	x0, LBB1_9
; %bb.7:                                ;   in Loop: Header=BB1_3 Depth=1
	add	x8, x25, x22
	add	x8, x8, #39
	and	x25, x8, #0xfffffffffffffff8
	add	x26, x26, #16
	cmp	x20, x24
	mov	x20, x23
	b.lo	LBB1_3
	b	LBB1_9
LBB1_8:
	mov	x23, #0                         ; =0x0
LBB1_9:
	mov	x28, #435                       ; =0x1b3
	movk	x28, #256, lsl #32
	mov	x0, x21
	bl	_fclose
	mov	x19, #0                         ; =0x0
Lloh19:
	adrp	x20, _methods_keys@PAGE
Lloh20:
	add	x20, x20, _methods_keys@PAGEOFF
	mov	w22, #24                        ; =0x18
Lloh21:
	adrp	x26, _hm@PAGE
Lloh22:
	add	x26, x26, _hm@PAGEOFF
LBB1_10:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_12 Depth 2
                                        ;     Child Loop BB1_13 Depth 2
	ldr	x21, [x20, x19, lsl #3]
	mov	x0, x21
	bl	_strlen
	mov	x8, #899                        ; =0x383
	movk	x8, #29597, lsl #16
	movk	x8, #4016, lsl #32
	movk	x8, #5221, lsl #48
	cbz	x0, LBB1_13
; %bb.11:                               ;   in Loop: Header=BB1_10 Depth=1
	mov	x9, x21
	mov	x10, x0
LBB1_12:                                ;   Parent Loop BB1_10 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w11, [x9], #1
	eor	x8, x8, x11
	mul	x8, x8, x28
	subs	x10, x10, #1
	b.ne	LBB1_12
LBB1_13:                                ;   Parent Loop BB1_10 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	and	x8, x8, #0xff
	umaddl	x9, w8, w22, x26
	ldr	x10, [x9]
	add	x8, x8, #1
	cbnz	x10, LBB1_13
; %bb.14:                               ;   in Loop: Header=BB1_10 Depth=1
	stp	x21, x0, [x9]
	str	w19, [x9, #16]
	add	x19, x19, #1
	cmp	x19, #9
	b.ne	LBB1_10
; %bb.15:
	cbz	x23, LBB1_62
; %bb.16:
	mov	x19, #0                         ; =0x0
	mov	w20, #24                        ; =0x18
Lloh23:
	adrp	x8, lCPI1_0@PAGE
Lloh24:
	ldr	q0, [x8, lCPI1_0@PAGEOFF]
	str	q0, [sp, #48]                   ; 16-byte Folded Spill
LBB1_17:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_38 Depth 2
                                        ;     Child Loop BB1_41 Depth 2
Lloh25:
	adrp	x8, _main.q@PAGE
Lloh26:
	add	x8, x8, _main.q@PAGEOFF
	add	x8, x8, x19, lsl #4
	ldp	x21, x22, [x8]
	mov	x0, x21
	mov	x1, x22
	bl	_methods_chain
	mov	x24, x0
	mov	x0, x21
	mov	x1, x22
	bl	_methods_lenswitch
	sub	x8, x22, #8
	cmn	x8, #5
	str	w0, [sp, #96]                   ; 4-byte Folded Spill
	b.hs	LBB1_20
; %bb.18:                               ;   in Loop: Header=BB1_17 Depth=1
	mov	x27, x0
	mov	w8, #-1                         ; =0xffffffff
	str	w8, [sp, #76]                   ; 4-byte Folded Spill
	cbz	x22, LBB1_24
; %bb.19:                               ;   in Loop: Header=BB1_17 Depth=1
	str	w8, [sp, #80]                   ; 4-byte Folded Spill
	mov	w8, #-1                         ; =0xffffffff
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	b	LBB1_37
LBB1_20:                                ;   in Loop: Header=BB1_17 Depth=1
	ldrb	w27, [x21]
Lloh27:
	adrp	x8, _methods_A0@PAGE
Lloh28:
	add	x8, x8, _methods_A0@PAGEOFF
	ldrb	w8, [x8, x27]
                                        ; kill: def $w27 killed $w27 killed $x27 def $x27
	add	w8, w22, w8
	and	x25, x8, #0xf
Lloh29:
	adrp	x8, _methods_len@PAGE
Lloh30:
	add	x8, x8, _methods_len@PAGEOFF
	ldrb	w8, [x8, x25]
	cmp	x22, x8
	b.ne	LBB1_23
; %bb.21:                               ;   in Loop: Header=BB1_17 Depth=1
Lloh31:
	adrp	x8, _methods_key@PAGE
Lloh32:
	add	x8, x8, _methods_key@PAGEOFF
	add	x1, x8, x25, lsl #4
	mov	x0, x21
	str	x1, [sp, #80]                   ; 8-byte Folded Spill
	mov	x2, x22
	bl	_memcmp
	cbz	w0, LBB1_25
; %bb.22:                               ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
	b	LBB1_26
LBB1_23:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	mov	w8, #-1                         ; =0xffffffff
	b	LBB1_31
LBB1_24:                                ;   in Loop: Header=BB1_17 Depth=1
	str	w8, [sp, #80]                   ; 4-byte Folded Spill
	mov	w8, #-1                         ; =0xffffffff
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	mov	w25, #131                       ; =0x83
	b	LBB1_41
LBB1_25:                                ;   in Loop: Header=BB1_17 Depth=1
Lloh33:
	adrp	x8, _methods_val@PAGE
Lloh34:
	add	x8, x8, _methods_val@PAGEOFF
	ldrsb	w8, [x8, x25]
LBB1_26:                                ;   in Loop: Header=BB1_17 Depth=1
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	and	x9, x21, #0xfff
	subs	x8, x9, #4080
	b.hi	LBB1_61
; %bb.27:                               ;   in Loop: Header=BB1_17 Depth=1
	ldr	q0, [x21]
	umov.b	w27, v0[0]
LBB1_28:                                ;   in Loop: Header=BB1_17 Depth=1
Lloh35:
	adrp	x8, _ph_masks@PAGE
Lloh36:
	add	x8, x8, _ph_masks@PAGEOFF
	ldr	q1, [x8, x22, lsl #4]
	tbl.16b	v0, { v0 }, v1
	ldr	x8, [sp, #80]                   ; 8-byte Folded Reload
	ldr	q1, [x8]
	cmeq.16b	v0, v0, v1
	shrn.8b	v0, v0, #4
	fmov	x8, d0
	cmn	x8, #1
	b.eq	LBB1_30
; %bb.29:                               ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
	b	LBB1_31
LBB1_30:                                ;   in Loop: Header=BB1_17 Depth=1
Lloh37:
	adrp	x8, _methods_val@PAGE
Lloh38:
	add	x8, x8, _methods_val@PAGEOFF
	ldrsb	w8, [x8, x25]
LBB1_31:                                ;   in Loop: Header=BB1_17 Depth=1
	str	w8, [sp, #80]                   ; 4-byte Folded Spill
	and	x8, x27, #0xff
Lloh39:
	adrp	x9, _methods_A0@PAGE
Lloh40:
	add	x9, x9, _methods_A0@PAGEOFF
	ldrb	w8, [x9, x8]
	add	w8, w22, w8
	and	x8, x8, #0xf
Lloh41:
	adrp	x9, _methods_len@PAGE
Lloh42:
	add	x9, x9, _methods_len@PAGEOFF
	ldrb	w9, [x9, x8]
	cmp	x22, x9
	b.ne	LBB1_34
; %bb.32:                               ;   in Loop: Header=BB1_17 Depth=1
	ldr	q0, [x21]
Lloh43:
	adrp	x9, _ph_masks@PAGE
Lloh44:
	add	x9, x9, _ph_masks@PAGEOFF
	ldr	q1, [x9, x22, lsl #4]
	tbl.16b	v0, { v0 }, v1
Lloh45:
	adrp	x9, _methods_key@PAGE
Lloh46:
	add	x9, x9, _methods_key@PAGEOFF
	ldr	q1, [x9, x8, lsl #4]
	cmeq.16b	v0, v0, v1
	shrn.8b	v0, v0, #4
	fmov	x9, d0
	cmn	x9, #1
	ldr	w27, [sp, #96]                  ; 4-byte Folded Reload
	b.eq	LBB1_35
; %bb.33:                               ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
	b	LBB1_36
LBB1_34:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
	str	w8, [sp, #76]                   ; 4-byte Folded Spill
	ldr	w27, [sp, #96]                  ; 4-byte Folded Reload
	b	LBB1_37
LBB1_35:                                ;   in Loop: Header=BB1_17 Depth=1
Lloh47:
	adrp	x9, _methods_val@PAGE
Lloh48:
	add	x9, x9, _methods_val@PAGEOFF
	ldrsb	w8, [x9, x8]
LBB1_36:                                ;   in Loop: Header=BB1_17 Depth=1
	str	w8, [sp, #76]                   ; 4-byte Folded Spill
LBB1_37:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	x8, x21
	mov	x9, x22
	mov	x10, #899                       ; =0x383
	movk	x10, #29597, lsl #16
	movk	x10, #4016, lsl #32
	movk	x10, #5221, lsl #48
LBB1_38:                                ;   Parent Loop BB1_17 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w11, [x8], #1
	eor	x10, x10, x11
	mul	x10, x10, x28
	subs	x9, x9, #1
	b.ne	LBB1_38
; %bb.39:                               ;   in Loop: Header=BB1_17 Depth=1
	and	x25, x10, #0xff
	b	LBB1_41
LBB1_40:                                ;   in Loop: Header=BB1_41 Depth=2
	add	w8, w25, #1
	and	x25, x8, #0xff
LBB1_41:                                ;   Parent Loop BB1_17 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	umull	x8, w25, w20
	ldr	x0, [x26, x8]
	cbz	x0, LBB1_45
; %bb.42:                               ;   in Loop: Header=BB1_41 Depth=2
	madd	x8, x25, x20, x26
	ldr	x8, [x8, #8]
	cmp	x8, x22
	b.ne	LBB1_40
; %bb.43:                               ;   in Loop: Header=BB1_41 Depth=2
	mov	x1, x21
	mov	x2, x22
	bl	_memcmp
	cbnz	w0, LBB1_40
; %bb.44:                               ;   in Loop: Header=BB1_17 Depth=1
	madd	x8, x25, x20, x26
	ldr	w25, [x8, #16]
	b	LBB1_46
LBB1_45:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	w25, #-1                        ; =0xffffffff
LBB1_46:                                ;   in Loop: Header=BB1_17 Depth=1
	sub	w8, w22, #3
	cmp	w8, #4
	b.hi	LBB1_53
; %bb.47:                               ;   in Loop: Header=BB1_17 Depth=1
	ldrb	w8, [x21]
Lloh49:
	adrp	x9, _methods_ghash.asso_values@PAGE
Lloh50:
	add	x9, x9, _methods_ghash.asso_values@PAGEOFF
	ldrb	w9, [x9, x8]
	add	x27, x9, w22, uxtw
	cmp	w27, #12
	b.hi	LBB1_51
; %bb.48:                               ;   in Loop: Header=BB1_17 Depth=1
Lloh51:
	adrp	x9, _methods_gperf_find.lengthtable@PAGE
Lloh52:
	add	x9, x9, _methods_gperf_find.lengthtable@PAGEOFF
	ldrb	w9, [x9, x27]
	cmp	w9, w22
	b.ne	LBB1_51
; %bb.49:                               ;   in Loop: Header=BB1_17 Depth=1
	lsl	x9, x27, #4
Lloh53:
	adrp	x10, _methods_gperf_find.wordlist@PAGE
Lloh54:
	add	x10, x10, _methods_gperf_find.wordlist@PAGEOFF
	ldr	x9, [x10, x9]
	ldrb	w10, [x9]
	cmp	w8, w10
	b.ne	LBB1_51
; %bb.50:                               ;   in Loop: Header=BB1_17 Depth=1
	add	x0, x21, #1
	add	x1, x9, #1
	sub	w2, w22, #1
	bl	_memcmp
	cbz	w0, LBB1_60
LBB1_51:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
LBB1_52:                                ;   in Loop: Header=BB1_17 Depth=1
	ldr	w27, [sp, #96]                  ; 4-byte Folded Reload
	cmp	w27, w24
	b.eq	LBB1_54
	b	LBB1_89
LBB1_53:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	w8, #-1                         ; =0xffffffff
	cmp	w27, w24
	b.ne	LBB1_89
LBB1_54:                                ;   in Loop: Header=BB1_17 Depth=1
	ldr	x10, [sp, #88]                  ; 8-byte Folded Reload
	cmp	w10, w24
	b.ne	LBB1_90
; %bb.55:                               ;   in Loop: Header=BB1_17 Depth=1
	ldr	w10, [sp, #80]                  ; 4-byte Folded Reload
	cmp	w10, w24
	b.ne	LBB1_91
; %bb.56:                               ;   in Loop: Header=BB1_17 Depth=1
	ldr	w10, [sp, #76]                  ; 4-byte Folded Reload
	cmp	w10, w24
	b.ne	LBB1_92
; %bb.57:                               ;   in Loop: Header=BB1_17 Depth=1
	cmp	w25, w24
	b.ne	LBB1_93
; %bb.58:                               ;   in Loop: Header=BB1_17 Depth=1
	cmp	w8, w24
	b.ne	LBB1_94
; %bb.59:                               ;   in Loop: Header=BB1_17 Depth=1
	add	x19, x19, #1
	cmp	x19, x23
	b.ne	LBB1_17
	b	LBB1_62
LBB1_60:                                ;   in Loop: Header=BB1_17 Depth=1
Lloh55:
	adrp	x8, _methods_gperf_find.wordlist@PAGE
Lloh56:
	add	x8, x8, _methods_gperf_find.wordlist@PAGEOFF
	add	x8, x8, x27, lsl #4
	ldr	w8, [x8, #8]
	b	LBB1_52
LBB1_61:                                ;   in Loop: Header=BB1_17 Depth=1
	mov	w10, #4096                      ; =0x1000
	sub	x10, x10, x22
	cmp	x9, x10
	csel	x8, xzr, x8, hi
	sub	x9, x21, x8
	ldr	q0, [x9]
	dup.16b	v1, w8
	ldr	q2, [sp, #48]                   ; 16-byte Folded Reload
	add.16b	v1, v1, v2
	tbl.16b	v0, { v0 }, v1
	b	LBB1_28
LBB1_62:
Lloh57:
	adrp	x1, l_.str.14@PAGE
Lloh58:
	add	x1, x1, l_.str.14@PAGEOFF
	ldr	x19, [sp, #64]                  ; 8-byte Folded Reload
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_71
; %bb.63:
Lloh59:
	adrp	x1, l_.str.15@PAGE
Lloh60:
	add	x1, x1, l_.str.15@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_83
; %bb.64:
Lloh61:
	adrp	x1, l_.str.16@PAGE
Lloh62:
	add	x1, x1, l_.str.16@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_98
; %bb.65:
Lloh63:
	adrp	x1, l_.str.17@PAGE
Lloh64:
	add	x1, x1, l_.str.17@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_105
; %bb.66:
Lloh65:
	adrp	x1, l_.str.18@PAGE
Lloh66:
	add	x1, x1, l_.str.18@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_116
; %bb.67:
Lloh67:
	adrp	x1, l_.str.19@PAGE
Lloh68:
	add	x1, x1, l_.str.19@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_130
; %bb.68:
Lloh69:
	adrp	x1, l_.str.20@PAGE
Lloh70:
	add	x1, x1, l_.str.20@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_141
; %bb.69:
Lloh71:
	adrp	x1, l_.str.21@PAGE
Lloh72:
	add	x1, x1, l_.str.21@PAGEOFF
	mov	x0, x19
	bl	_strcmp
	cbz	w0, LBB1_159
; %bb.70:
Lloh73:
	adrp	x8, ___stderrp@GOTPAGE
Lloh74:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh75:
	ldr	x0, [x8]
	str	x19, [sp]
Lloh76:
	adrp	x1, l_.str.22@PAGE
Lloh77:
	add	x1, x1, l_.str.22@PAGEOFF
	b	LBB1_96
LBB1_71:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.72:
	mov	x10, #0                         ; =0x0
	mov	w19, #0                         ; =0x0
	ands	x8, x23, #0x7
	mov	w9, #8                          ; =0x8
	csel	x8, x9, x8, eq
	sub	x20, x23, x8
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
	mov	x21, #225833675390976           ; =0xcd6500000000
	movk	x21, #16845, lsl #48
Lloh78:
	adrp	x22, _main.q@PAGE
Lloh79:
	add	x22, x22, _main.q@PAGEOFF
Lloh80:
	adrp	x25, _main.q@PAGE+72
Lloh81:
	add	x25, x25, _main.q@PAGEOFF+72
	b	LBB1_75
LBB1_73:                                ;   in Loop: Header=BB1_75 Depth=1
	mov	x24, #0                         ; =0x0
LBB1_74:                                ;   in Loop: Header=BB1_75 Depth=1
	scvtf	d0, d0
	scvtf	d1, d1
	fmov	d9, x21
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x26
	add	x10, x24, x26
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_75:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_79 Depth 2
                                        ;     Child Loop BB1_82 Depth 2
	mov	x26, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	cbz	x23, LBB1_73
; %bb.76:                               ;   in Loop: Header=BB1_75 Depth=1
	cmp	x23, #9
	b.hs	LBB1_78
; %bb.77:                               ;   in Loop: Header=BB1_75 Depth=1
	mov	x24, #0                         ; =0x0
	mov	x9, #0                          ; =0x0
	b	LBB1_81
LBB1_78:                                ;   in Loop: Header=BB1_75 Depth=1
	movi.2d	v2, #0000000000000000
	mov	x8, x20
	mov	x9, x25
	movi.2d	v3, #0000000000000000
	movi.2d	v4, #0000000000000000
	movi.2d	v5, #0000000000000000
LBB1_79:                                ;   Parent Loop BB1_75 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	sub	x10, x9, #64
	ld2.2d	{ v6, v7 }, [x10]
	sub	x10, x9, #32
	ld2.2d	{ v16, v17 }, [x10]
	mov	x10, x9
	ld2.2d	{ v18, v19 }, [x10], #32
	ld2.2d	{ v20, v21 }, [x10]
	shl.2d	v6, v6, #32
	shl.2d	v7, v16, #32
	shl.2d	v16, v18, #32
	shl.2d	v17, v20, #32
	ssra.2d	v2, v6, #32
	ssra.2d	v3, v7, #32
	ssra.2d	v4, v16, #32
	ssra.2d	v5, v17, #32
	add	x9, x9, #128
	subs	x8, x8, #8
	b.ne	LBB1_79
; %bb.80:                               ;   in Loop: Header=BB1_75 Depth=1
	add.2d	v2, v3, v2
	add.2d	v2, v4, v2
	add.2d	v2, v5, v2
	addp.2d	d2, v2
	fmov	x24, d2
	mov	x9, x20
LBB1_81:                                ;   in Loop: Header=BB1_75 Depth=1
	sub	x8, x23, x9
	add	x9, x22, x9, lsl #4
	add	x9, x9, #8
LBB1_82:                                ;   Parent Loop BB1_75 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrsw	x10, [x9], #16
	add	x24, x10, x24
	subs	x8, x8, #1
	b.ne	LBB1_82
	b	LBB1_74
LBB1_83:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.84:
	mov	x10, #0                         ; =0x0
	mov	w19, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
	mov	x20, #225833675390976           ; =0xcd6500000000
	movk	x20, #16845, lsl #48
Lloh82:
	adrp	x21, _main.q@PAGE+8
Lloh83:
	add	x21, x21, _main.q@PAGEOFF+8
	b	LBB1_86
LBB1_85:                                ;   in Loop: Header=BB1_86 Depth=1
	scvtf	d0, d9
	scvtf	d1, d10
	fmov	d9, x20
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x26
	add	x10, x22, x26
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_86:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_88 Depth 2
	mov	x26, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d9, d10, [sp, #128]
	mov	x22, #0                         ; =0x0
	cbz	x23, LBB1_85
; %bb.87:                               ;   in Loop: Header=BB1_86 Depth=1
	mov	x24, x21
	mov	x25, x23
LBB1_88:                                ;   Parent Loop BB1_86 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldp	x0, x1, [x24, #-8]
	bl	_methods_chain
	add	x22, x22, w0, sxtw
	add	x24, x24, #16
	subs	x25, x25, #1
	b.ne	LBB1_88
	b	LBB1_85
LBB1_89:
	mov	w9, #0                          ; =0x0
	mov	x10, x27
	b	LBB1_95
LBB1_90:
	mov	w9, #1                          ; =0x1
	b	LBB1_95
LBB1_91:
	mov	w9, #2                          ; =0x2
                                        ; kill: def $w10 killed $w10 def $x10
	b	LBB1_95
LBB1_92:
	mov	w9, #3                          ; =0x3
                                        ; kill: def $w10 killed $w10 def $x10
	b	LBB1_95
LBB1_93:
	mov	w9, #4                          ; =0x4
	mov	x10, x25
	b	LBB1_95
LBB1_94:
	mov	w9, #5                          ; =0x5
	mov	x10, x8
LBB1_95:
Lloh84:
	adrp	x8, ___stderrp@GOTPAGE
Lloh85:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh86:
	ldr	x0, [x8]
	stp	x10, x24, [sp, #24]
                                        ; kill: def $w22 killed $w22 killed $x22 def $x22
	stp	x22, x21, [sp, #8]
	str	x9, [sp]
Lloh87:
	adrp	x1, l_.str.13@PAGE
Lloh88:
	add	x1, x1, l_.str.13@PAGEOFF
LBB1_96:
	bl	_fprintf
LBB1_97:
	mov	w0, #1                          ; =0x1
	b	LBB1_163
LBB1_98:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.99:
	mov	x10, #0                         ; =0x0
	mov	w19, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
	mov	x20, #225833675390976           ; =0xcd6500000000
	movk	x20, #16845, lsl #48
Lloh89:
	adrp	x21, _main.q@PAGE+8
Lloh90:
	add	x21, x21, _main.q@PAGEOFF+8
	b	LBB1_101
LBB1_100:                               ;   in Loop: Header=BB1_101 Depth=1
	scvtf	d0, d9
	scvtf	d1, d10
	fmov	d9, x20
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x26
	add	x10, x22, x26
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_101:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_103 Depth 2
	mov	x26, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d9, d10, [sp, #128]
	mov	x22, #0                         ; =0x0
	cbz	x23, LBB1_100
; %bb.102:                              ;   in Loop: Header=BB1_101 Depth=1
	mov	x24, x21
	mov	x25, x23
LBB1_103:                               ;   Parent Loop BB1_101 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldp	x0, x1, [x24, #-8]
	bl	_methods_lenswitch
	add	x22, x22, w0, sxtw
	add	x24, x24, #16
	subs	x25, x25, #1
	b.ne	LBB1_103
	b	LBB1_100
LBB1_104:
	add	x0, sp, #400
	bl	_perror
	b	LBB1_97
LBB1_105:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.106:
	mov	x10, #0                         ; =0x0
	mov	w19, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
Lloh91:
	adrp	x22, _methods_A0@PAGE
Lloh92:
	add	x22, x22, _methods_A0@PAGEOFF
Lloh93:
	adrp	x27, _methods_len@PAGE
Lloh94:
	add	x27, x27, _methods_len@PAGEOFF
Lloh95:
	adrp	x25, _methods_key@PAGE
Lloh96:
	add	x25, x25, _methods_key@PAGEOFF
	b	LBB1_108
LBB1_107:                               ;   in Loop: Header=BB1_108 Depth=1
	scvtf	d0, d9
	scvtf	d1, d10
	mov	x8, #225833675390976            ; =0xcd6500000000
	movk	x8, #16845, lsl #48
	fmov	d9, x8
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x26
	add	x10, x28, x26
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_108:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_112 Depth 2
	mov	x26, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d9, d10, [sp, #128]
	mov	x28, #0                         ; =0x0
	cbz	x23, LBB1_107
; %bb.109:                              ;   in Loop: Header=BB1_108 Depth=1
Lloh97:
	adrp	x21, _main.q@PAGE+8
Lloh98:
	add	x21, x21, _main.q@PAGEOFF+8
	mov	x24, x23
	b	LBB1_112
LBB1_110:                               ;   in Loop: Header=BB1_112 Depth=2
	mov	x8, #-1                         ; =0xffffffffffffffff
LBB1_111:                               ;   in Loop: Header=BB1_112 Depth=2
	add	x28, x8, x28
	add	x21, x21, #16
	subs	x24, x24, #1
	b.eq	LBB1_107
LBB1_112:                               ;   Parent Loop BB1_108 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x2, [x21]
	sub	x8, x2, #8
	cmn	x8, #5
	b.lo	LBB1_110
; %bb.113:                              ;   in Loop: Header=BB1_112 Depth=2
	ldur	x0, [x21, #-8]
	ldrb	w8, [x0]
	ldrb	w8, [x22, x8]
	add	w8, w2, w8
	and	x20, x8, #0xf
	ldrb	w8, [x27, x20]
	cmp	x2, x8
	b.ne	LBB1_110
; %bb.114:                              ;   in Loop: Header=BB1_112 Depth=2
	add	x1, x25, x20, lsl #4
	bl	_memcmp
	cbnz	w0, LBB1_110
; %bb.115:                              ;   in Loop: Header=BB1_112 Depth=2
Lloh99:
	adrp	x8, _methods_val@PAGE
Lloh100:
	add	x8, x8, _methods_val@PAGEOFF
	ldrsb	x8, [x8, x20]
	b	LBB1_111
LBB1_116:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.117:
	mov	w19, #0                         ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
Lloh101:
	adrp	x21, _methods_A0@PAGE
Lloh102:
	add	x21, x21, _methods_A0@PAGEOFF
Lloh103:
	adrp	x22, _methods_len@PAGE
Lloh104:
	add	x22, x22, _methods_len@PAGEOFF
Lloh105:
	adrp	x27, _methods_key@PAGE
Lloh106:
	add	x27, x27, _methods_key@PAGEOFF
Lloh107:
	adrp	x25, _ph_masks@PAGE
Lloh108:
	add	x25, x25, _ph_masks@PAGEOFF
	mov	x26, #225833675390976           ; =0xcd6500000000
	movk	x26, #16845, lsl #48
Lloh109:
	adrp	x8, lCPI1_0@PAGE
Lloh110:
	ldr	q0, [x8, lCPI1_0@PAGEOFF]
	str	q0, [sp, #96]                   ; 16-byte Folded Spill
Lloh111:
	adrp	x28, _methods_val@PAGE
Lloh112:
	add	x28, x28, _methods_val@PAGEOFF
	b	LBB1_119
LBB1_118:                               ;   in Loop: Header=BB1_119 Depth=1
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmov	d9, x26
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x24
	add	x10, x20, x24
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_119:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_123 Depth 2
	mov	x24, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	mov	x20, #0                         ; =0x0
	cbz	x23, LBB1_118
; %bb.120:                              ;   in Loop: Header=BB1_119 Depth=1
Lloh113:
	adrp	x8, _main.q@PAGE+8
Lloh114:
	add	x8, x8, _main.q@PAGEOFF+8
	mov	x9, x23
	b	LBB1_123
LBB1_121:                               ;   in Loop: Header=BB1_123 Depth=2
	mov	x10, #-1                        ; =0xffffffffffffffff
LBB1_122:                               ;   in Loop: Header=BB1_123 Depth=2
	add	x20, x10, x20
	add	x8, x8, #16
	subs	x9, x9, #1
	b.eq	LBB1_118
LBB1_123:                               ;   Parent Loop BB1_119 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x10, [x8]
	sub	x11, x10, #8
	cmn	x11, #5
	b.lo	LBB1_121
; %bb.124:                              ;   in Loop: Header=BB1_123 Depth=2
	ldur	x12, [x8, #-8]
	ldrb	w11, [x12]
	ldrb	w11, [x21, x11]
	add	w11, w10, w11
	and	x11, x11, #0xf
	ldrb	w13, [x22, x11]
	cmp	x10, x13
	b.ne	LBB1_121
; %bb.125:                              ;   in Loop: Header=BB1_123 Depth=2
	and	x14, x12, #0xfff
	subs	x13, x14, #4080
	b.hi	LBB1_129
; %bb.126:                              ;   in Loop: Header=BB1_123 Depth=2
	ldr	q0, [x12]
LBB1_127:                               ;   in Loop: Header=BB1_123 Depth=2
	ldr	q1, [x25, x10, lsl #4]
	tbl.16b	v0, { v0 }, v1
	ldr	q1, [x27, x11, lsl #4]
	cmeq.16b	v0, v0, v1
	shrn.8b	v0, v0, #4
	fmov	x10, d0
	cmn	x10, #1
	b.ne	LBB1_121
; %bb.128:                              ;   in Loop: Header=BB1_123 Depth=2
	ldrsb	x10, [x28, x11]
	b	LBB1_122
LBB1_129:                               ;   in Loop: Header=BB1_123 Depth=2
	mov	w15, #4096                      ; =0x1000
	sub	x15, x15, x10
	cmp	x14, x15
	csel	x13, xzr, x13, hi
	sub	x12, x12, x13
	ldr	q0, [x12]
	dup.16b	v1, w13
	ldr	q2, [sp, #96]                   ; 16-byte Folded Reload
	add.16b	v1, v1, v2
	tbl.16b	v0, { v0 }, v1
	b	LBB1_127
LBB1_130:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.131:
	mov	w19, #0                         ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
	mov	x20, #225833675390976           ; =0xcd6500000000
	movk	x20, #16845, lsl #48
Lloh115:
	adrp	x22, _methods_A0@PAGE
Lloh116:
	add	x22, x22, _methods_A0@PAGEOFF
Lloh117:
	adrp	x27, _methods_len@PAGE
Lloh118:
	add	x27, x27, _methods_len@PAGEOFF
Lloh119:
	adrp	x25, _methods_key@PAGE
Lloh120:
	add	x25, x25, _methods_key@PAGEOFF
Lloh121:
	adrp	x26, _ph_masks@PAGE
Lloh122:
	add	x26, x26, _ph_masks@PAGEOFF
Lloh123:
	adrp	x28, _methods_val@PAGE
Lloh124:
	add	x28, x28, _methods_val@PAGEOFF
	b	LBB1_133
LBB1_132:                               ;   in Loop: Header=BB1_133 Depth=1
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmov	d9, x20
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x24
	add	x10, x21, x24
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_133:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_137 Depth 2
	mov	x24, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	mov	x21, #0                         ; =0x0
	cbz	x23, LBB1_132
; %bb.134:                              ;   in Loop: Header=BB1_133 Depth=1
Lloh125:
	adrp	x8, _main.q@PAGE+8
Lloh126:
	add	x8, x8, _main.q@PAGEOFF+8
	mov	x9, x23
	b	LBB1_137
LBB1_135:                               ;   in Loop: Header=BB1_137 Depth=2
	mov	x10, #-1                        ; =0xffffffffffffffff
LBB1_136:                               ;   in Loop: Header=BB1_137 Depth=2
	add	x21, x10, x21
	add	x8, x8, #16
	subs	x9, x9, #1
	b.eq	LBB1_132
LBB1_137:                               ;   Parent Loop BB1_133 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x10, [x8]
	sub	x11, x10, #8
	cmn	x11, #5
	b.lo	LBB1_135
; %bb.138:                              ;   in Loop: Header=BB1_137 Depth=2
	ldur	x12, [x8, #-8]
	ldrb	w11, [x12]
	ldrb	w11, [x22, x11]
	add	w11, w10, w11
	and	x11, x11, #0xf
	ldrb	w13, [x27, x11]
	cmp	x10, x13
	b.ne	LBB1_135
; %bb.139:                              ;   in Loop: Header=BB1_137 Depth=2
	ldr	q0, [x12]
	ldr	q1, [x26, x10, lsl #4]
	tbl.16b	v0, { v0 }, v1
	ldr	q1, [x25, x11, lsl #4]
	cmeq.16b	v0, v0, v1
	shrn.8b	v0, v0, #4
	fmov	x10, d0
	cmn	x10, #1
	b.ne	LBB1_135
; %bb.140:                              ;   in Loop: Header=BB1_137 Depth=2
	ldrsb	x10, [x28, x11]
	b	LBB1_136
LBB1_141:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.142:
	mov	w9, #0                          ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
Lloh127:
	adrp	x27, _main.q@PAGE
Lloh128:
	add	x27, x27, _main.q@PAGEOFF
	mov	w25, #24                        ; =0x18
	b	LBB1_145
LBB1_143:                               ;   in Loop: Header=BB1_145 Depth=1
	mov	x20, #0                         ; =0x0
LBB1_144:                               ;   in Loop: Header=BB1_145 Depth=1
	scvtf	d0, d9
	scvtf	d1, d10
	mov	x8, #225833675390976            ; =0xcd6500000000
	movk	x8, #16845, lsl #48
	fmov	d9, x8
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	ldr	x10, [sp, #96]                  ; 8-byte Folded Reload
	add	x10, x20, x10
	ldr	w9, [sp, #88]                   ; 4-byte Folded Reload
	add	w9, w9, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w9, w8
	b.eq	LBB1_162
LBB1_145:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_149 Depth 2
                                        ;       Child Loop BB1_151 Depth 3
                                        ;       Child Loop BB1_155 Depth 3
	str	w9, [sp, #88]                   ; 4-byte Folded Spill
	str	x10, [sp, #96]                  ; 8-byte Folded Spill
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d9, d10, [sp, #128]
	cbz	x23, LBB1_143
; %bb.146:                              ;   in Loop: Header=BB1_145 Depth=1
	mov	x19, #0                         ; =0x0
	mov	x20, #0                         ; =0x0
	b	LBB1_149
LBB1_147:                               ;   in Loop: Header=BB1_149 Depth=2
	mov	w8, #-1                         ; =0xffffffff
LBB1_148:                               ;   in Loop: Header=BB1_149 Depth=2
	add	x20, x20, w8, sxtw
	add	x19, x19, #1
	cmp	x19, x23
	b.eq	LBB1_144
LBB1_149:                               ;   Parent Loop BB1_145 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB1_151 Depth 3
                                        ;       Child Loop BB1_155 Depth 3
	add	x8, x27, x19, lsl #4
	ldp	x21, x22, [x8]
	cbz	x22, LBB1_153
; %bb.150:                              ;   in Loop: Header=BB1_149 Depth=2
	mov	x8, x21
	mov	x9, x22
	mov	x10, #899                       ; =0x383
	movk	x10, #29597, lsl #16
	movk	x10, #4016, lsl #32
	movk	x10, #5221, lsl #48
LBB1_151:                               ;   Parent Loop BB1_145 Depth=1
                                        ;     Parent Loop BB1_149 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w11, [x8], #1
	eor	x10, x10, x11
	mul	x10, x10, x28
	subs	x9, x9, #1
	b.ne	LBB1_151
; %bb.152:                              ;   in Loop: Header=BB1_149 Depth=2
	and	x24, x10, #0xff
	b	LBB1_155
LBB1_153:                               ;   in Loop: Header=BB1_149 Depth=2
	mov	w24, #131                       ; =0x83
	b	LBB1_155
LBB1_154:                               ;   in Loop: Header=BB1_155 Depth=3
	add	w8, w24, #1
	and	x24, x8, #0xff
LBB1_155:                               ;   Parent Loop BB1_145 Depth=1
                                        ;     Parent Loop BB1_149 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	umull	x8, w24, w25
	ldr	x0, [x26, x8]
	cbz	x0, LBB1_147
; %bb.156:                              ;   in Loop: Header=BB1_155 Depth=3
	madd	x8, x24, x25, x26
	ldr	x8, [x8, #8]
	cmp	x8, x22
	b.ne	LBB1_154
; %bb.157:                              ;   in Loop: Header=BB1_155 Depth=3
	mov	x1, x21
	mov	x2, x22
	bl	_memcmp
	cbnz	w0, LBB1_154
; %bb.158:                              ;   in Loop: Header=BB1_149 Depth=2
	madd	x8, x24, x25, x26
	ldr	w8, [x8, #16]
	b	LBB1_148
LBB1_159:
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w8, #1
	b.lt	LBB1_161
; %bb.160:
	mov	w19, #0                         ; =0x0
	mov	x10, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
Lloh129:
	adrp	x22, _methods_ghash.asso_values@PAGE
Lloh130:
	add	x22, x22, _methods_ghash.asso_values@PAGEOFF
Lloh131:
	adrp	x21, _methods_gperf_find.lengthtable@PAGE
Lloh132:
	add	x21, x21, _methods_gperf_find.lengthtable@PAGEOFF
Lloh133:
	adrp	x25, _methods_gperf_find.wordlist@PAGE
Lloh134:
	add	x25, x25, _methods_gperf_find.wordlist@PAGEOFF
	b	LBB1_166
LBB1_161:
	mov	x10, #0                         ; =0x0
	mov	x8, #36074                      ; =0x8cea
	movk	x8, #14752, lsl #16
	movk	x8, #15961, lsl #32
	movk	x8, #17961, lsl #48
	fmov	d8, x8
LBB1_162:
	str	x10, [sp]
Lloh135:
	adrp	x0, l_.str.23@PAGE
Lloh136:
	add	x0, x0, l_.str.23@PAGEOFF
	bl	_printf
Lloh137:
	adrp	x8, ___stderrp@GOTPAGE
Lloh138:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh139:
	ldr	x0, [x8]
	ucvtf	d0, x23
	fdiv	d0, d8, d0
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	str	x8, [sp, #24]
	str	d0, [sp, #16]
	ldr	x9, [sp, #64]                   ; 8-byte Folded Reload
Lloh140:
	adrp	x8, l_.str.11@PAGE
Lloh141:
	add	x8, x8, l_.str.11@PAGEOFF
	stp	x8, x9, [sp]
Lloh142:
	adrp	x1, l_.str.24@PAGE
Lloh143:
	add	x1, x1, l_.str.24@PAGEOFF
	bl	_fprintf
	mov	w0, #0                          ; =0x0
LBB1_163:
	ldur	x8, [x29, #-128]
Lloh144:
	adrp	x9, ___stack_chk_guard@GOTPAGE
Lloh145:
	ldr	x9, [x9, ___stack_chk_guard@GOTPAGEOFF]
Lloh146:
	ldr	x9, [x9]
	cmp	x9, x8
	b.ne	LBB1_176
; %bb.164:
	add	sp, sp, #672
	ldp	x29, x30, [sp, #112]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #96]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #80]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #64]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #48]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #32]             ; 16-byte Folded Reload
	ldp	d9, d8, [sp, #16]               ; 16-byte Folded Reload
	ldp	d11, d10, [sp], #128            ; 16-byte Folded Reload
	ret
LBB1_165:                               ;   in Loop: Header=BB1_166 Depth=1
	scvtf	d0, d9
	scvtf	d1, d10
	mov	x8, #225833675390976            ; =0xcd6500000000
	movk	x8, #16845, lsl #48
	fmov	d9, x8
	fmadd	d10, d0, d9, d1
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp, #128]
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d0, d9, d1
	fsub	d0, d0, d10
	fcmp	d0, d8
	fcsel	d8, d0, d8, mi
	mov	x10, x20
	add	x10, x26, x20
	add	w19, w19, #1
	ldr	x8, [sp, #120]                  ; 8-byte Folded Reload
	cmp	w19, w8
	b.eq	LBB1_162
LBB1_166:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_168 Depth 2
	mov	x20, x10
	add	x1, sp, #128
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d9, d10, [sp, #128]
	mov	x26, #0                         ; =0x0
	cbz	x23, LBB1_165
; %bb.167:                              ;   in Loop: Header=BB1_166 Depth=1
Lloh147:
	adrp	x28, _main.q@PAGE+8
Lloh148:
	add	x28, x28, _main.q@PAGEOFF+8
	mov	x27, x23
LBB1_168:                               ;   Parent Loop BB1_166 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x8, [x28]
	sub	w9, w8, #3
	cmp	w9, #4
	b.hi	LBB1_173
; %bb.169:                              ;   in Loop: Header=BB1_168 Depth=2
	ldur	x9, [x28, #-8]
	ldrb	w10, [x9]
	ldrb	w11, [x22, x10]
	add	x24, x11, w8, uxtw
	cmp	w24, #12
	b.hi	LBB1_173
; %bb.170:                              ;   in Loop: Header=BB1_168 Depth=2
	ldrb	w11, [x21, x24]
	cmp	w11, w8
	b.ne	LBB1_173
; %bb.171:                              ;   in Loop: Header=BB1_168 Depth=2
	lsl	x11, x24, #4
	ldr	x11, [x25, x11]
	ldrb	w12, [x11]
	cmp	w10, w12
	b.ne	LBB1_173
; %bb.172:                              ;   in Loop: Header=BB1_168 Depth=2
	add	x0, x9, #1
	add	x1, x11, #1
	sub	w2, w8, #1
	bl	_memcmp
	cbz	w0, LBB1_175
LBB1_173:                               ;   in Loop: Header=BB1_168 Depth=2
	mov	w8, #-1                         ; =0xffffffff
LBB1_174:                               ;   in Loop: Header=BB1_168 Depth=2
	add	x26, x26, w8, sxtw
	add	x28, x28, #16
	subs	x27, x27, #1
	b.ne	LBB1_168
	b	LBB1_165
LBB1_175:                               ;   in Loop: Header=BB1_168 Depth=2
	add	x8, x25, x24, lsl #4
	ldr	w8, [x8, #8]
	b	LBB1_174
LBB1_176:
	bl	___stack_chk_fail
	.loh AdrpAdd	Lloh13, Lloh14
	.loh AdrpAdd	Lloh11, Lloh12
	.loh AdrpAdd	Lloh9, Lloh10
	.loh AdrpLdrGotLdr	Lloh6, Lloh7, Lloh8
	.loh AdrpAdd	Lloh17, Lloh18
	.loh AdrpAdd	Lloh15, Lloh16
	.loh AdrpAdd	Lloh21, Lloh22
	.loh AdrpAdd	Lloh19, Lloh20
	.loh AdrpLdr	Lloh23, Lloh24
	.loh AdrpAdd	Lloh25, Lloh26
	.loh AdrpAdd	Lloh29, Lloh30
	.loh AdrpAdd	Lloh27, Lloh28
	.loh AdrpAdd	Lloh31, Lloh32
	.loh AdrpAdd	Lloh33, Lloh34
	.loh AdrpAdd	Lloh35, Lloh36
	.loh AdrpAdd	Lloh37, Lloh38
	.loh AdrpAdd	Lloh41, Lloh42
	.loh AdrpAdd	Lloh39, Lloh40
	.loh AdrpAdd	Lloh45, Lloh46
	.loh AdrpAdd	Lloh43, Lloh44
	.loh AdrpAdd	Lloh47, Lloh48
	.loh AdrpAdd	Lloh49, Lloh50
	.loh AdrpAdd	Lloh51, Lloh52
	.loh AdrpAdd	Lloh53, Lloh54
	.loh AdrpAdd	Lloh55, Lloh56
	.loh AdrpAdd	Lloh57, Lloh58
	.loh AdrpAdd	Lloh59, Lloh60
	.loh AdrpAdd	Lloh61, Lloh62
	.loh AdrpAdd	Lloh63, Lloh64
	.loh AdrpAdd	Lloh65, Lloh66
	.loh AdrpAdd	Lloh67, Lloh68
	.loh AdrpAdd	Lloh69, Lloh70
	.loh AdrpAdd	Lloh71, Lloh72
	.loh AdrpAdd	Lloh76, Lloh77
	.loh AdrpLdrGotLdr	Lloh73, Lloh74, Lloh75
	.loh AdrpAdd	Lloh80, Lloh81
	.loh AdrpAdd	Lloh78, Lloh79
	.loh AdrpAdd	Lloh82, Lloh83
	.loh AdrpAdd	Lloh87, Lloh88
	.loh AdrpLdrGotLdr	Lloh84, Lloh85, Lloh86
	.loh AdrpAdd	Lloh89, Lloh90
	.loh AdrpAdd	Lloh95, Lloh96
	.loh AdrpAdd	Lloh93, Lloh94
	.loh AdrpAdd	Lloh91, Lloh92
	.loh AdrpAdd	Lloh97, Lloh98
	.loh AdrpAdd	Lloh99, Lloh100
	.loh AdrpAdd	Lloh111, Lloh112
	.loh AdrpLdr	Lloh109, Lloh110
	.loh AdrpAdd	Lloh107, Lloh108
	.loh AdrpAdd	Lloh105, Lloh106
	.loh AdrpAdd	Lloh103, Lloh104
	.loh AdrpAdd	Lloh101, Lloh102
	.loh AdrpAdd	Lloh113, Lloh114
	.loh AdrpAdd	Lloh123, Lloh124
	.loh AdrpAdd	Lloh121, Lloh122
	.loh AdrpAdd	Lloh119, Lloh120
	.loh AdrpAdd	Lloh117, Lloh118
	.loh AdrpAdd	Lloh115, Lloh116
	.loh AdrpAdd	Lloh125, Lloh126
	.loh AdrpAdd	Lloh127, Lloh128
	.loh AdrpAdd	Lloh133, Lloh134
	.loh AdrpAdd	Lloh131, Lloh132
	.loh AdrpAdd	Lloh129, Lloh130
	.loh AdrpAdd	Lloh142, Lloh143
	.loh AdrpAdd	Lloh140, Lloh141
	.loh AdrpLdrGotLdr	Lloh137, Lloh138, Lloh139
	.loh AdrpAdd	Lloh135, Lloh136
	.loh AdrpLdrGotLdr	Lloh144, Lloh145, Lloh146
	.loh AdrpAdd	Lloh147, Lloh148
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function methods_chain
_methods_chain:                         ; @methods_chain
	.cfi_startproc
; %bb.0:
	sub	x8, x1, #3
	cmp	x8, #4
	b.hi	LBB2_15
; %bb.1:
Lloh149:
	adrp	x9, lJTI2_0@PAGE
Lloh150:
	add	x9, x9, lJTI2_0@PAGEOFF
	adr	x10, LBB2_2
	ldrb	w11, [x9, x8]
	add	x10, x10, x11, lsl #2
	br	x10
LBB2_2:
	ldrh	w8, [x0]
	ldrb	w9, [x0, #2]
	mov	w10, #17735                     ; =0x4547
	cmp	w8, w10
	mov	w8, #84                         ; =0x54
	ccmp	w9, w8, #0, eq
	b.eq	LBB2_16
; %bb.3:
	ldrh	w9, [x0]
	ldrb	w10, [x0, #2]
	mov	w11, #21840                     ; =0x5550
	cmp	w9, w11
	ccmp	w10, w8, #0, eq
	b.ne	LBB2_15
; %bb.4:
	mov	w0, #3                          ; =0x3
	ret
LBB2_5:
	ldr	w8, [x0]
	mov	w9, #17736                      ; =0x4548
	movk	w9, #17473, lsl #16
	cmp	w8, w9
	b.eq	LBB2_17
; %bb.6:
	ldr	w8, [x0]
	mov	w9, #20304                      ; =0x4f50
	movk	w9, #21587, lsl #16
	cmp	w8, w9
	b.ne	LBB2_15
; %bb.7:
	mov	w0, #2                          ; =0x2
	ret
LBB2_8:
	ldr	w8, [x0]
	ldrb	w9, [x0, #4]
	mov	w10, #21076                     ; =0x5254
	movk	w10, #17217, lsl #16
	cmp	w8, w10
	mov	w8, #69                         ; =0x45
	ccmp	w9, w8, #0, eq
	b.eq	LBB2_18
; %bb.9:
	ldr	w8, [x0]
	ldrb	w9, [x0, #4]
	mov	w10, #16720                     ; =0x4150
	movk	w10, #17236, lsl #16
	cmp	w8, w10
	mov	w8, #72                         ; =0x48
	ccmp	w9, w8, #0, eq
	b.ne	LBB2_15
; %bb.10:
	mov	w0, #8                          ; =0x8
	ret
LBB2_11:
	ldr	w8, [x0]
	ldrh	w9, [x0, #4]
	mov	w10, #17732                     ; =0x4544
	movk	w10, #17740, lsl #16
	cmp	w8, w10
	mov	w8, #17748                      ; =0x4554
	ccmp	w9, w8, #0, eq
	b.ne	LBB2_15
; %bb.12:
	mov	w0, #4                          ; =0x4
	ret
LBB2_13:
	ldr	w8, [x0]
	ldur	w9, [x0, #3]
	mov	w10, #20291                     ; =0x4f43
	movk	w10, #20046, lsl #16
	cmp	w8, w10
	mov	w8, #17742                      ; =0x454e
	movk	w8, #21571, lsl #16
	ccmp	w9, w8, #0, eq
	b.eq	LBB2_19
; %bb.14:
	ldr	w8, [x0]
	ldur	w9, [x0, #3]
	mov	w10, #20559                     ; =0x504f
	movk	w10, #18772, lsl #16
	cmp	w8, w10
	mov	w8, #20297                      ; =0x4f49
	movk	w8, #21326, lsl #16
	ccmp	w9, w8, #0, eq
	b.eq	LBB2_20
LBB2_15:
	mov	w0, #-1                         ; =0xffffffff
	ret
LBB2_16:
	mov	w0, #0                          ; =0x0
	ret
LBB2_17:
	mov	w0, #1                          ; =0x1
	ret
LBB2_18:
	mov	w0, #7                          ; =0x7
	ret
LBB2_19:
	mov	w0, #5                          ; =0x5
	ret
LBB2_20:
	mov	w0, #6                          ; =0x6
	ret
	.loh AdrpAdd	Lloh149, Lloh150
	.cfi_endproc
	.section	__TEXT,__const
lJTI2_0:
	.byte	(LBB2_2-LBB2_2)>>2
	.byte	(LBB2_5-LBB2_2)>>2
	.byte	(LBB2_8-LBB2_2)>>2
	.byte	(LBB2_11-LBB2_2)>>2
	.byte	(LBB2_13-LBB2_2)>>2
                                        ; -- End function
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2                               ; -- Begin function methods_lenswitch
_methods_lenswitch:                     ; @methods_lenswitch
	.cfi_startproc
; %bb.0:
	sub	x8, x1, #3
	cmp	x8, #4
	b.hi	LBB3_4
; %bb.1:
Lloh151:
	adrp	x9, lJTI3_0@PAGE
Lloh152:
	add	x9, x9, lJTI3_0@PAGEOFF
	adr	x10, LBB3_2
	ldrb	w11, [x9, x8]
	add	x10, x10, x11, lsl #2
	br	x10
LBB3_2:
	ldrh	w8, [x0]
	ldrb	w9, [x0, #2]
	mov	w10, #17735                     ; =0x4547
	cmp	w8, w10
	mov	w8, #84                         ; =0x54
	ccmp	w9, w8, #0, eq
	b.eq	LBB3_12
; %bb.3:
	ldrh	w9, [x0]
	mov	w10, #21840                     ; =0x5550
	eor	w9, w9, w10
	ldrb	w10, [x0, #2]
	eor	w8, w10, w8
	orr	w8, w9, w8
	cmp	w8, #0
	mov	w8, #3                          ; =0x3
	csinv	w0, w8, wzr, eq
	ret
LBB3_4:
	mov	w0, #-1                         ; =0xffffffff
	ret
LBB3_5:
	ldr	w8, [x0]
	mov	w9, #17736                      ; =0x4548
	movk	w9, #17473, lsl #16
	cmp	w8, w9
	b.eq	LBB3_13
; %bb.6:
	ldr	w8, [x0]
	mov	w9, #20304                      ; =0x4f50
	movk	w9, #21587, lsl #16
	cmp	w8, w9
	mov	w8, #2                          ; =0x2
	csinv	w0, w8, wzr, eq
	ret
LBB3_7:
	ldr	w8, [x0]
	ldrb	w9, [x0, #4]
	mov	w10, #21076                     ; =0x5254
	movk	w10, #17217, lsl #16
	cmp	w8, w10
	mov	w8, #69                         ; =0x45
	ccmp	w9, w8, #0, eq
	b.eq	LBB3_14
; %bb.8:
	ldr	w8, [x0]
	mov	w9, #16720                      ; =0x4150
	movk	w9, #17236, lsl #16
	eor	w8, w8, w9
	ldrb	w9, [x0, #4]
	mov	w10, #72                        ; =0x48
	eor	w9, w9, w10
	orr	w8, w8, w9
	cmp	w8, #0
	mov	w8, #8                          ; =0x8
	csinv	w0, w8, wzr, eq
	ret
LBB3_9:
	ldr	w8, [x0]
	mov	w9, #17732                      ; =0x4544
	movk	w9, #17740, lsl #16
	eor	w8, w8, w9
	ldrh	w9, [x0, #4]
	mov	w10, #17748                     ; =0x4554
	eor	w9, w9, w10
	orr	w8, w8, w9
	cmp	w8, #0
	mov	w8, #4                          ; =0x4
	csinv	w0, w8, wzr, eq
	ret
LBB3_10:
	ldr	w8, [x0]
	ldur	w9, [x0, #3]
	mov	w10, #20291                     ; =0x4f43
	movk	w10, #20046, lsl #16
	cmp	w8, w10
	mov	w8, #17742                      ; =0x454e
	movk	w8, #21571, lsl #16
	ccmp	w9, w8, #0, eq
	b.eq	LBB3_15
; %bb.11:
	ldr	w8, [x0]
	mov	w9, #20559                      ; =0x504f
	movk	w9, #18772, lsl #16
	eor	w8, w8, w9
	ldur	w9, [x0, #3]
	mov	w10, #20297                     ; =0x4f49
	movk	w10, #21326, lsl #16
	eor	w9, w9, w10
	orr	w8, w8, w9
	cmp	w8, #0
	mov	w8, #6                          ; =0x6
	csinv	w0, w8, wzr, eq
	ret
LBB3_12:
	mov	w0, #0                          ; =0x0
	ret
LBB3_13:
	mov	w0, #1                          ; =0x1
	ret
LBB3_14:
	mov	w0, #7                          ; =0x7
	ret
LBB3_15:
	mov	w0, #5                          ; =0x5
	ret
	.loh AdrpAdd	Lloh151, Lloh152
	.cfi_endproc
	.section	__TEXT,__const
lJTI3_0:
	.byte	(LBB3_2-LBB3_2)>>2
	.byte	(LBB3_5-LBB3_2)>>2
	.byte	(LBB3_7-LBB3_2)>>2
	.byte	(LBB3_9-LBB3_2)>>2
	.byte	(LBB3_10-LBB3_2)>>2
                                        ; -- End function
_methods_gperf_find.lengthtable:        ; @methods_gperf_find.lengthtable
	.ascii	"\000\000\000\003\004\005\006\007\003\004\005\000\007"

	.section	__DATA,__data
	.p2align	3, 0x0                          ; @methods_gperf_find.wordlist
_methods_gperf_find.wordlist:
	.quad	l_.str
	.long	0                               ; 0x0
	.space	4
	.quad	l_.str
	.long	0                               ; 0x0
	.space	4
	.quad	l_.str
	.long	0                               ; 0x0
	.space	4
	.quad	l_.str.1
	.long	0                               ; 0x0
	.space	4
	.quad	l_.str.2
	.long	1                               ; 0x1
	.space	4
	.quad	l_.str.3
	.long	7                               ; 0x7
	.space	4
	.quad	l_.str.4
	.long	4                               ; 0x4
	.space	4
	.quad	l_.str.5
	.long	6                               ; 0x6
	.space	4
	.quad	l_.str.6
	.long	3                               ; 0x3
	.space	4
	.quad	l_.str.7
	.long	2                               ; 0x2
	.space	4
	.quad	l_.str.8
	.long	8                               ; 0x8
	.space	4
	.quad	l_.str
	.long	0                               ; 0x0
	.space	4
	.quad	l_.str.9
	.long	5                               ; 0x5
	.space	4

	.section	__TEXT,__cstring,cstring_literals
l_.str:                                 ; @.str
	.space	1

l_.str.1:                               ; @.str.1
	.asciz	"GET"

l_.str.2:                               ; @.str.2
	.asciz	"HEAD"

l_.str.3:                               ; @.str.3
	.asciz	"TRACE"

l_.str.4:                               ; @.str.4
	.asciz	"DELETE"

l_.str.5:                               ; @.str.5
	.asciz	"OPTIONS"

l_.str.6:                               ; @.str.6
	.asciz	"PUT"

l_.str.7:                               ; @.str.7
	.asciz	"POST"

l_.str.8:                               ; @.str.8
	.asciz	"PATCH"

l_.str.9:                               ; @.str.9
	.asciz	"CONNECT"

l_.str.10:                              ; @.str.10
	.asciz	"gen/%s.q"

l_.str.11:                              ; @.str.11
	.asciz	"methods"

l_.str.12:                              ; @.str.12
	.asciz	"r"

.zerofill __DATA,__bss,_main.arena,4194304,0 ; @main.arena
.zerofill __DATA,__bss,_main.q,1048576,3 ; @main.q
l_.str.13:                              ; @.str.13
	.asciz	"mismatch form %d on %.*s: %d vs %d\n"

l_.str.14:                              ; @.str.14
	.asciz	"null"

l_.str.15:                              ; @.str.15
	.asciz	"chain"

l_.str.16:                              ; @.str.16
	.asciz	"lenswitch"

l_.str.17:                              ; @.str.17
	.asciz	"ph_memcmp"

l_.str.18:                              ; @.str.18
	.asciz	"ph_neon"

l_.str.19:                              ; @.str.19
	.asciz	"ph_pad"

l_.str.20:                              ; @.str.20
	.asciz	"hmap"

l_.str.21:                              ; @.str.21
	.asciz	"gperf"

l_.str.22:                              ; @.str.22
	.asciz	"unknown form %s\n"

l_.str.23:                              ; @.str.23
	.asciz	"%lld\n"

l_.str.24:                              ; @.str.24
	.asciz	"%s %s %.3f ns/lookup (min of %d passes)\n"

	.section	__TEXT,__const
_methods_ghash.asso_values:             ; @methods_ghash.asso_values
	.ascii	"\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\005\000\r\r\000\000\r\r\r\r\r\r\000\005\r\r\r\000\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r\r"

	.section	__DATA,__const
	.p2align	3, 0x0                          ; @methods_keys
_methods_keys:
	.quad	l_.str.1
	.quad	l_.str.2
	.quad	l_.str.7
	.quad	l_.str.6
	.quad	l_.str.4
	.quad	l_.str.9
	.quad	l_.str.5
	.quad	l_.str.3
	.quad	l_.str.8

.zerofill __DATA,__bss,_hm,6144,3       ; @hm
	.section	__TEXT,__const
_methods_len:                           ; @methods_len
	.ascii	"\377\377\377\003\004\005\006\007\003\004\007\005\377\377\377\377"

_methods_val:                           ; @methods_val
	.ascii	"\377\377\377\003\002\b\004\005\000\001\006\007\377\377\377\377"

_methods_A0:                            ; @methods_A0
	.ascii	"\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\005\005\000\000\000\000\000\000\003\000\000\000\000\006"
	.space	171

	.p2align	4, 0x0                          ; @methods_key
_methods_key:
	.space	16
	.space	16
	.space	16
	.byte	80                              ; 0x50
	.byte	85                              ; 0x55
	.byte	84                              ; 0x54
	.space	13
	.byte	80                              ; 0x50
	.byte	79                              ; 0x4f
	.byte	83                              ; 0x53
	.byte	84                              ; 0x54
	.space	12
	.byte	80                              ; 0x50
	.byte	65                              ; 0x41
	.byte	84                              ; 0x54
	.byte	67                              ; 0x43
	.byte	72                              ; 0x48
	.space	11
	.byte	68                              ; 0x44
	.byte	69                              ; 0x45
	.byte	76                              ; 0x4c
	.byte	69                              ; 0x45
	.byte	84                              ; 0x54
	.byte	69                              ; 0x45
	.space	10
	.byte	67                              ; 0x43
	.byte	79                              ; 0x4f
	.byte	78                              ; 0x4e
	.byte	78                              ; 0x4e
	.byte	69                              ; 0x45
	.byte	67                              ; 0x43
	.byte	84                              ; 0x54
	.space	9
	.byte	71                              ; 0x47
	.byte	69                              ; 0x45
	.byte	84                              ; 0x54
	.space	13
	.byte	72                              ; 0x48
	.byte	69                              ; 0x45
	.byte	65                              ; 0x41
	.byte	68                              ; 0x44
	.space	12
	.byte	79                              ; 0x4f
	.byte	80                              ; 0x50
	.byte	84                              ; 0x54
	.byte	73                              ; 0x49
	.byte	79                              ; 0x4f
	.byte	78                              ; 0x4e
	.byte	83                              ; 0x53
	.space	9
	.byte	84                              ; 0x54
	.byte	82                              ; 0x52
	.byte	65                              ; 0x41
	.byte	67                              ; 0x43
	.byte	69                              ; 0x45
	.space	11
	.space	16
	.space	16
	.space	16
	.space	16

	.p2align	4, 0x0                          ; @ph_masks
_ph_masks:
	.space	16,128
	.ascii	"\000\200\200\200\200\200\200\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\200\200\200\200\200\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\200\200\200\200\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\200\200\200\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\200\200\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\200\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\200\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\200\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\200\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\200\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\n\200\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\n\013\200\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\n\013\f\200\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\n\013\f\r\200\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\n\013\f\r\016\200"
	.ascii	"\000\001\002\003\004\005\006\007\b\t\n\013\f\r\016\017"

.subsections_via_symbols
