;; BOOTCHER -- Flash bootstrap code for Butcher and EZ-HOST
;; This file is for Rev3 only. It may work on Rev2 but probably
;; will not be released for that.
;;
;; Observations:
;;	We need to boot without 'Andy' (the Jaguar logo) or Tom is left in a bad state
;;	Not sure how to work around this... hopefully there are options
;;
;;  v1.0.0	- original release
;;  v1.1.0	- hardlocks boot sector on start (except when keyword found)
;;			- low voltage flash in BIOS
;;			- check serial number for upgrade mode
;;			- don't allow 'up' shortcut to bypass flash test
;;			- report flash failure and success with screen (red - bad, purple - good)
;;			- remove unused status check from sector erase code
;;			- bootloader now uses skunkconsole for feedback and checks version
;;			- verify and retry phase added
;;	v.1.2.0 - fixed up for Skunkboard v1 JagCD compatibility
;;	v.1.2.1 - some tweaks to make the code line up better with the new JCP for V2 (Release Candidate)
;;  v.1.2.2 - Release final of v1 board
;;  v.1.2.3 - Added return to CD BIOS support, tweaked upgrader
;;  v.1.2.4 - Fixes to startup and restart to better support CD environment
;;	v.2.0.0 - Skunkboard rev 2 firmware first pass
;;	v.2.0.1 - Release final of v2 board
;;  v.2.0.2 - Added return to CD BIOS support, tweaked upgrader
;;  v.2.0.3 - Fixes to startup and restart to better support CD environment
;;  v.2.0.4 - fix BIOS copy size for bank 2 on sbv2
;;  v.2.0.5 - Workaround for bank2 flash verify instability on some boards (to investigate in the future - hangs!)
;;	v.3.0.1 - use high-speed flash mode, remove high voltage options completely
;; -Added autoboot - top 2MB of flash intended. Start with a signature at $bffff0 (bank 2 on rev 2):
;;  BFFFF0 - LION
;;  BFFFF4 - Start address
;;  This boot is still subject to the security scan and is intended for future use like the USB boot
;;  It can be bypassed by holding A, if installed.
;;  v.3.0.2 - fix for 6MB mode - don't copy BIOS to bank 2 until bank 2 is booted
;;          - don't boot bank 2 unless at least first dword looks like a Skunkboard BIOS (so we don't
;;            crash on 6MB images.
;; 
;; Testing: (NOTE: this file does not support SBv1!)
;; Option	SBv1	SBv2	SBv3
;; reset	ok		ok
;; ram		ok		ok
;; flash1/2	ok		ok
;; flash1/4	ok		ok
;; up		ok		ok
;; flash2/2	na		ok
;; flash2/4	na		ok
;; down		na		ok
;; flash6	na		ok
;; a+up		na		ok
;; wflsh1/2 ok		ok		na
;; wflsh1/4 ok		ok		na
;; wflsh2/2	na		ok		na
;; wflsh2/4	na		ok		na
;; wflash6	na		ok		na
;; erase1	ok		ok
;; erase2	na		ok
;; dump1	ok		ok		
;; dump2	na		ok
;; serial#	ok		ok
;; upgrade	ok		na
;; JagCD	ok		ok
;; BS1		ok		ok
;; BS1/RAM	ok		ok
;; BS1/FL2	na		ok
;; BS1/up	ok		ok
;; BS1/down	na		ok
;; Recover1	ok		ok
;; BS2		na		ok
;; BS2/RAM	na		ok
;; BS2/FL1	na		ok
;; BS2/up	na		ok
;; BS2/down	na		ok
;; Recover2	na		ok
;; Autoboot ok		ok
;; SkipAuto ok		ok
;; jcp -n	ok		ok
;; jcp -b	ok		ok
;; jcp -2b	na		ok
;; jcp -6b	na		ok
;; 

		.include	"jaguar.inc"
		
RAMLOAD	.equ $1400		
		
; Search for 'upgrade' to find the block to enable upgrade version checking
; Search for 'v2' to find the differences for the new flash chip	
		
		.text

		move.l	#0, d0

; Get into 16-bit mode
		move.w	#$187b, $f00000		; 16-bit, 6 cycle I/O, 5 cycle ROM
;		move.w	#$0863, $f00000		; 16-bit, 18 cycle I/O
;		move.w  #$1865, $f00000		; 32-bit (stock)

		move.l	#$800000, a3		; a3 = HPI write data
		move.l	#$C00000, a5		; a5 = HPI write address, read data

; Complete EZ-HOST reset procedure, including SIE2 debug enable
; LEAVE THIS HERE!  We need to be out of reset before programming the Flash
; Note that this reset makes it possible to flash sector 0, since it undoes
; the hardlock by also resetting the flash chip.
; Note that we need this always now, because it's the only way to unlock
; the boot sector for the BIOS upgrade.
		move.w	#$7BAC, (a5)		; Force reset
		move.w	#$4006, (a5)		; ...wait 16 cycles... enter HPI boot mode
		move.w	#$4006, (a5)		; ...wait 16 cycles... enter HPI boot mode
		move.w	#$7BAD, (a5)		; Exit reset (boot time)
		
		move.l	#12000, d1			; Wait at least 4ms (full boot)
.waitresetx:	dbra	d1, .waitresetx

		move.w	#$4004, (a5)		; Enter HPI write mode

		move.w	#140, (a5)			; Locate idle task
		move.w	#$ee18, (a3)		; Force sie2_init
		move.l	#3000, d1			; Wait at least 1ms (idle loop)
.waitidlex:	dbra	d1, .waitidlex

		move.w	#140, (a5)
		move.w	#$f468, (a3)		; Restore usb_idle

; check for upgrade code - if we need to, read the serial number from the existing ROM
		move.w	#$4001, (a5)		; enter flash read only mode
		move.w	#$4ba0, (a5)		; make sure we're in bank 0

		move.l	copyblock+8,d0
		cmp.l	#$DEADBEEF,d0		; will be different if called from bjlskunkflash
		bne		.noupgrade

		move.l	$800808,d0			; get old serial number
		move.l	d0,copyblock+8		; store in correct location
.noupgrade:

; Provide some feedback and check if we need to do this
; also wait for the console to come back to life

; this is just a little hacky code to give the PC a chance to reconnect
; after the ezhost reset. The idea is - the skunkRESET succeeds because
; the buffers were clear before the reset (the initial skunkRESET which
; syncs the console causes that). The next two NOPs fill the buffers,
; the third then verifies the PC is answering. If the third one fails
; out (or any of the earlier ones), then the flag is cleared, so we
; go back and try again. This code hangs the Jag without a console so
; should not be used in release code. (Keep just the reset!)
; Well.. actually, we need it now cause we need to force a reset
; and we need to reconnect to the console. This means the upgrader
; will hang if it can't find the console -- be warned!
.resetlp:
		jsr		skunkRESET
		jsr		skunkNOP
		jsr		skunkNOP
; 1 is SB v2, 0 is SB v1
.if 0
		nop
.else
		jsr		skunkNOP
		cmp.l	#0,skunkConsoleUp
		beq		.resetlp
.endif
;; end of hacky loop described above
		
		move.l	#TXTgreet,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP
		
		; Check if the board's got a valid version number,
		; if not, you need to flash the right version yourself
		; One bad assumption here, SBv1 boards originally flashed 0 here,
		; but all BIOS upgrades should have BEEFDEAD, and so should 2.0
		; It's only used to see whether we honor the version number.
		move.l	$80080c,d0
		cmp.l	#$BEEFDEAD,d0		
		bne		.verok			; if no signature, version is not valid (new board?)
		
		; gets the version, prints it, returns it in d1
		jsr		getversion
		and.l	#$00ff0000,d1

; This upgrade code ensures we only write the boot flash
; if we need to - it checks specifically for known versions.
; Checks that the current BIOS matches the known version
; Use 1 for v2, 0 for v1
;		bra .verok
.if 1
		; Rev 2 board
		cmp.l	#$00020000,d1
		beq		.verok
		; Rev 3 board
		cmp.l	#$00030000,d1
		beq		.verok
.else
		; Rev 1 board
		cmp.l	#$00010000,d1
		beq		.verok
.endif
		
		; don't know this version
		move.l	#TXTnoneed,a0
		jsr skunkCONSOLEWRITE
		jmp		finished

.verok:
startover:
		move.l	#TXTerasing,a0
		jsr	skunkCONSOLEWRITE
		jsr skunkNOP
		move.l	#TXTerasefail,a2	; error string
		move.l	#TXTerasefail+25,a4	; address to print status register
		
		move.w	#$4000, (a5)		; Enter Flash write mode
; Erase boot block
		move.l	#$FFFC0000, d0		; Debug:  Step 1

; 1 is SB v2, 0 is SB v1
.if 1
		; force bank 0
		move.w	#$4BA0, (a5)		; Destined For BAnk 0!

		move.w	#$9098, $80036A		; special command
		move.w	#$C501, $801C94		
		move.w	#$8008, $80036A		; 80
		move.w	#$9098, $80036A		; erase command
		move.w	#$C501, $801C94
		move.w	#$8480, $800000		; 30

; test cycle on page 8 of datasheet
.waiterase:	
		; bit 7 will be 0 during the erase. After, 'true data' is read, which means all bits are 1
		move.w	$800000, d0			; Zero means busy, 8 means ready
		and.w #$1088,d0				; test bits 7,5,3 - map to 3,7,12 (was: and.w #8, d0)
		beq .waiterase

		btst #3, d0					; test if bit 7 is set (maps to 3) (means success)
		beq _abort					; bit 3 or 5 was set, means failure
.else
		move.w	#$8500, $800000		; 50 clear status word
		move.w	#$8180, $800000		; 60 unlock sector
		move.w	#$8508, $800000		; d0 confirm

		move.w	#$8080, $800000		; 20 erase sector
		move.w	#$8508, $800000		; d0 confirm
.waiterase:	move.w	$800000, d0		; Zero means busy, 8 means ready
		btst	#3, d0				; bit 7, maps to 3 (was: and.w #8, d0)
		beq .waiterase
		
		; only check bits 1,3,4,5 - maps to 4,12,10,7
		and.w	#$1490,d0			; (was: cmp.w #8, d0)
		bne _abort
.endif
		
; next phase
		move.w	#$4001, (a5)		; flash read-only mode
		move.l	#TXTwriting,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP

		move.w	#$4000, (a5)		; re-enter Flash write mode

; Set up boot block for our cart (this hacks whatever header we are loading!)
		move.l	#$02020202, bootblock+$400	; 16-bit
		move.l	#$800810, bootblock+$404	; Our boot address
; Defined flags, by bit (0=LSB)
; 0 = skip BIOS animation
; 1 = JSR cart from JagCD (cart can RTS)
; 2 = Do not boot cart (JagCD again)		
		move.l	#$3, bootblock+$408		; Skip jag bios intro, and be a JSR cart for JagCD
;		move.l	#$0, bootblock+$408		; Enable jag bios intro

; Write the boot block - this block is not obfuscated
		move.l	#1023, d1			; 2KB -- up to $800
		move.l	#bootblock, a0		; src
		move.l	#$800000, a1		; dest

_pgmloop:

; 1 is SB v2, 0 is SB v1
.if 1
		move.w	#$9098, $80036A		; program single word
		move.w	#$C501, $801C94		
		move.w	#$8088, $80036A		; A0
		move.w  (a0)+, d2
		move.w  d2, (a1)		; Payload
		add.l	#$40000, d0		; Debug

.waitpgm:	
		move.w  (a1), d0
		cmp.w	d0, d2			; Wait until word matches programmed
		beq .pgmok
		; if not equal, check bits 3 and 5 for failure (map to 7 and 12)
		and.w	#$1080,d0
		beq		.waitpgm
		; recheck as per the datasheet
		move.w	(a1), d0
		cmp.w	d0, d2
		beq		.pgmok
		bra		_progabort
		
.pgmok:		
		add.l	#$2, a1

.else
		move.w	#$8100, (a1)		; 40 program single word
		move.w  (a0)+, (a1)+		; Payload
		add.l	#$40000, d0			; Debug

.waitpgm:	move.w	$800000, d0		; Zero means busy, 8 means ready
		btst	#3, d0				; bit 7, maps to 3 (was: and.w #8, d0)
		beq .waitpgm

		; only check bits 1,3,4,5 - maps to 4,12,10,7
		and.w	#$1490,d0			; (was: cmp.w #8, d0)
		bne _progabort
.endif
		dbra	d1, _pgmloop		; Keep going until we're done

; Write the code block - this block /is/ obfuscated
		move.l	#3071, d1			; 6KB -- up to $2000
		move.l	#copyblock, a0		; src
		move.l	#$800800, a1		; dest

_pgmloopc:

; 1 is SB v2, 0 is SB v1
.if 1
		move.w	#$9098, $80036A		; program single word
		move.w	#$C501, $801C94		
		move.w	#$8088, $80036A		; A0
		move.w  (a0)+, d2

		move.w  d2, (a1)		; Payload
		add.l	#$40000, d0		; Debug

.waitpgmc:	
		move.w  (a1), d0
		cmp.w	d0, d2			; Wait until word matches programmed
		beq		.pgmok
		; if not equal, check bits 3 and 5 for failure (map to 7 and 12)
		and.w	#$1080,d0
		beq		.waitpgmc
		; recheck as per the datasheet
		move.w	(a1), d0
		cmp.w	d0, d2
		beq		.pgmok
		bra		_progabort

.pgmok:		
		add.l	#$2, a1

.else
		move.w	#$8100, (a1)		; 40 program single word

		move.w  (a0)+, (a1)+		; Payload
		add.l	#$40000, d0			; Debug

.waitpgmc:	move.w	$800800, d0		; Zero means busy, 8 means ready
		btst	#3, d0				; bit 7, maps to 3 (was: and.w #8, d0)
		beq .waitpgmc

		; only check bits 1,3,4,5 - maps to 4,12,10,7
		and.w	#$1490,d0			; (was: cmp.w #8, d0)
		bne _progabort
.endif
		dbra	d1, _pgmloopc		; Keep going until we're done

; Back to read mode
		move.w  #$D599, $800000		; FF return to read mode
		move.w	#$4001, (a5)		; Return to flash read/write mode

; now a quick verify
		move.l	#TXTverify,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP
		
; Test the boot block - not obfuscated
		move.l	#1023, d1			; 2KB -- up to $800
		move.l	#bootblock, a0		; src
		move.l	#$800000, a1		; dest

_verloop:
		cmp.w  (a0)+, (a1)+			; Payload
		bne		_verabort
		dbra	d1, _verloop		; Keep going until we're done

; Test the code block - obfuscated
		move.l	#3071, d1			; 6KB -- up to $2000
		move.l	#copyblock, a0		; src
		move.l	#$800800, a1		; dest

_verloopc:
		cmp.w  (a0)+, (a1)+			; Payload
		bne		_verabort

verbranchc:		
		dbra	d1, _verloopc		; Keep going until we're done

finished:
		jsr getversion

		move.l	#TXTdone,a0
		jsr skunkCONSOLEWRITE

		jsr	skunkCONSOLECLOSE

; all done (used to jmp	$800810 to start the board)
lpevrok:
		move.w	#$1234, BG			; purple
		jmp		lpevrok

; Has failed address in a1 		
_verabort:
		; put the system into a hopefully sane state
		move.w	#$4000, $C00000		; Enter Flash read-write mode
		move.w  #$D599, $800000		; FF return to read mode		
		move.w	#$4001, $C00000		; Enter flash read-only mode
		move.w	#$8588, $80036a		; clear flash error

		move.l	#TXTverifyfail+17,a0
		move.l	a1,d0
		swap	d0
		and.l	#$FFFF,d0
		bsr		writeser
		move.l	a1,d0
		and.l	#$FFFF,d0
		bsr		writeser
		move.l	#TXTverifyfail,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP
		
		jmp		retry
		
; Has failed address in a1 and error code in d0		
_progabort:
		; put the system into a hopefully sane state
		move.w	#$4000, $C00000		; Enter Flash read-write mode
		move.w  #$D599, $800000		; FF return to read mode		
		move.w	#$4001, $C00000		; Enter flash read-only mode
		move.w	#$8588, $80036a		; clear flash error

		move.l	#TXTwritefail+19,a0
		bsr		writehex
		move.l	#TXTwritefail+31,a0
		move.l	a1,d0
		swap	d0
		and.l	#$FFFF,d0
		bsr		writeser
		move.l	a1,d0
		and.l	#$FFFF,d0
		bsr		writeser
		move.l	#TXTwritefail,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP

		jmp		retry

; Enter abort with string to print in a2, error in d0, and address for d0 in a4
_abort:
		; put the system into a hopefully sane state
		move.w	#$4000, $C00000		; Enter Flash read-write mode
		move.w  #$D599, $800000		; FF return to read mode		
		move.w	#$4001, $C00000		; Enter flash read-only mode
		move.w	#$8588, $80036a		; clear flash error
		
		move.l	a4,a0
		jsr		writehex
		move.l	a2,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP

; allow three attempts		
retry:
		move.l	retrycnt,d0
		subq	#1,d0
		beq		outoftries
		move.l	d0,retrycnt
		
		move.l	#TXTretrying,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkNOP
		jmp		startover

outoftries:
		move.l	#TXTgaveup,a0
		jsr		skunkCONSOLEWRITE
		jsr		skunkCONSOLECLOSE
lpevr:
		move.w	#$f0ff, BG			; red
		jmp		lpevr

	; write a 2 character hex value from d0 to a0
writehex:
	move.l	d0,d3
	lsr.l	#4,d3
	and.l	#$F,d3
	cmp.l	#10,d3
	blt		.lt
	addq	#7,d3
.lt:
	add.l	#48,d3
	move.b	d3,(a0)+

	move.l	d0,d3
	and.l	#$F,d3
	cmp.l	#10,d3
	blt		.lt2
	addq	#7,d3
.lt2:
	add.l	#48,d3
	move.b	d3,(a0)+
	rts

	; write a 4-digit hex value from d0 to a0
writeser:
	and.l	#$ffff,d0	; mask for range
	move.l	d0,d4
	lsr.l	#8,d0
	jsr		writehex
	move.l	d4,d0
	jsr		writehex
	rts

getversion:
		; get version and print it, return version in d1
		; destroys d0-d4,a0
		move.l	$800800,d1		; version 00.ma.mi.re
		move.l	$800808,d2		; serial
		
		; now format the string
		move.l	#TXTver,a0		; address of string
		add.l	#13,a0			; address of first digit
		
		move.l	d1,d0
		lsr.l	#8,d0			; major
		lsr.l	#8,d0			; major
		and.l	#$ff,d0
		jsr		writehex

		addq	#1,a0
		move.l	d1,d0
		lsr.l	#8,d0			; minor
		and.l	#$ff,d0
		jsr		writehex
		
		addq	#1,a0
		move.l	d1,d0
		and.l	#$ff,d0			; rev
		jsr		writehex
		
		add.l	#9,a0			; address for serial
		move.l	d2,d0
		jsr		writeser

		; now output the string
		move.l	#TXTver,a0
		jsr skunkCONSOLEWRITE
		jsr skunkNOP
		
		rts		

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	.phrase
bootblock:
	incbin	"fastbt2.bin"

; This is the beginning of the boot ROM -- we get into DRAM as fast as possible
; This is stored at $800800 and copies itself into RAM at $1400 (RAMLOAD)
; Original dest of $800 was conflicting with the JagCD boot!

	.phrase

copyblock:
; A little jump table for some fixed functions - make sure the boot address
; is AFTER these!
		; code version - remember to track this!
		; xx.major.minor.rev
; SB v3
		dc.l	$00030002			; v3 Skunkboard
		
		; flasher start in RAM 
		; - Load $3ff0 with a longword of number of blocks to flash (only 62 or 30 are valid)
		; - Load $3ff4 with the same value, EORd with $0000FFFF
		; - Set the MSB of $3ff0 to use the slow word flash mode
		; - Set the next bit to indicate bank 2
		dc.l	flasher-jcpblock+RAMLOAD
		; serial number goes here - range is 1000-1999 (BCD), DEADBEEF means upgrade, read old serial number
		dc.l	$DEADBEEF
		; helper bytes to let patcher find serial number location (checked by upgrader)
		dc.l	$BEEFDEAD
; $800810

ProgStart:
		; ezhost may still be booting, that complicates the flash access substantially,
		; so get into RAM as quickly as possible.
		; don't modify this block OR ANYTHING ABOVE without checking the addresses!
		; Don't touch video or the stack until after the CD check below
		move.l	#990, d1		; ~4KB (1KW) -- this steals $1400-$2380, unused space
		move.l	#$800830, a0	; Source (32 bytes past this stub...)
		move.l	#RAMLOAD, a1	; Dest
		move.l	(a0)+, (a1)+	; Copy the copy loop
		move.l	(a0)+, (a1)+
		jmp	RAMLOAD				; And continue copying from DRAM

; This is the beginning of DRAM and the rest of bootstrapping

	.phrase
jcpblock:
_copyboot:	move.l	(a0)+, (a1)+		; Finish copying from DRAM
		dbra	d1, _copyboot
		
; before we mess with ANYTHING, check whether we are booting from CD.
; If we are, see if the user is holding down 'C' for "CD". If they are,
; we're all set up to return to the CD BIOS.
		move.l	$2400, d1				; check for magic number
		cmp.l	#$12345678,d1			; I know. But that's what it writes. 
		bne		.noCDmode				; no match means no CD

		; row2 (b): *7412580 xxxxxxxx xxxxxxxx xxxxBxCx
		move.w #$81fb,JOYSTICK	; enable read, audio, nothing on joystick 1, col 1 on joystick 0
		move.l JOYSTICK,d0		; by doing a long read, we get JOYSTICK and JOYBUTS
		btst	#1,d0			; check 'C' button (0 if pressed)
		bne		.noCDmode		; go ahead and boot
		
		; return to the CD bios
		rts

.noCDmode:
; Get the ROM up to our full supported speed.
		move.w	#$187b, $f00000		; 16-bit, 6 cycle I/O, 5 cycle ROM
		
; stop the GPU and the DSP
		move.l	#0,G_CTRL
		move.l	#0,D_CTRL

; Initialize Jaguar to get video started
		move.l  #$70007,G_END		; big-endian mode
		move.l  #$70007,D_END

		move.w  #$FFFF,VI       	; disable video interrupts
;		move.w	#519,VI				; Atari's default line for vertical interrupts (we don't use them though)
									; don't set this - reduces compatibility for some reason

		move.l  #$23FC,a7   		; Setup a stack
		move.w 	#$2700,sr			; no interrupts

		move.w  CONFIG,d0      		; Also is joystick register
		andi.w  #VIDTYPE,d0    		; 0 = PAL, 1 = NTSC
		beq 	palvals

		move.w  #NTSC_HMID,d2
		move.w  #NTSC_WIDTH,d0

		move.w  #NTSC_VMID,d6
		move.w  #NTSC_HEIGHT,d4

		bra 	calc_vals
palvals:
		move.w  #PAL_HMID,d2
		move.w  #PAL_WIDTH,d0

		move.w  #PAL_VMID,d6
		move.w  #PAL_HEIGHT,d4

calc_vals:
		move.w  d0,320
		move.w  d4,200

		move.w  d0,d1
		asr 	#1,d1         	 	; Width/2

		sub.w   d1,d2         	  	; Mid - Width/2
		add.w   #4,d2         	  	; (Mid - Width/2)+4

		sub.w   #1,d1         	  	; Width/2 - 1
		ori.w   #$400,d1      	  	; (Width/2 - 1)|$400
		
		move.w  d1,HDE

		move.w  d2,HDB1
		move.w  d2,HDB2

		move.w  d6,d5
		sub.w   d4,d5

		add.w   d4,d6

		move.w  d5, VDB
		move.w  #$FFFF, VDE

		move.w  #$AC1,VMODE		; RGB mode at 320x (ish)
;		0000 1010 1100 0001
;       xxxx |  | |||| || |
;     unused |  | |||| || Enable
;            |  | |||| |16-bit CRY
;            |  | |||| No genlock
;            |  | |||No ext video 'encrustation'
;            |  | ||No encrustation border color
;            |  | |CSync enabled
;            |  | BG Enabled
;            |  Color mode fixed (VARMOD)
;            Width = 5+1=6 clocks/pixel


; Write our display list (just one stop object)
; We need a display list under <$4000 or we can't load BJL stuff in there
		move.l	#$FF0, a0
		clr.l   (a0)+
		move.l  #STOPOBJ,(a0)
		move.l	#$FF0, d0
		swap	d0			; Why do we swap?  Everybody does...
		move.l	d0, OLP		; not really safe, but works well enough for this
		move.w	#0, OBF		; in case the OP halted on a GPU interrupt, this should wake it
		jmp		finalinit-jcpblock+RAMLOAD	; jump over the reset (embedded subroutine)
		
; Complete EZ-HOST reset procedure, including SIE2 debug enable
; Sets a3 and a5, destroys d1
ezreset:
		move.l	#$800000, a3		; a3 = HPI write data
		move.l	#$C00000, a5		; a5 = HPI write address, read data

		move.w	#$7BAC, (a5)		; Force reset
		move.w	#$4006, (a5)		; ...wait 16 cycles... enter HPI boot mode
		move.w	#$4006, (a5)		; ...wait 16 cycles... enter HPI boot mode
		move.w	#$7BAD, (a5)		; Exit reset (boot time)
		
		move.l	#12000, d1			; Wait at least 4ms (full boot)
.waitreset:	dbra	d1, .waitreset

		move.w	#$4004, (a5)		; Enter HPI write mode

		move.w	#140, (a5)			; Locate idle task
		move.w	#$ee18, (a3)		; Force sie2_init
		move.l	#3000, d1			; Wait at least 1ms (idle loop)
.waitidle:	dbra	d1, .waitidle

		move.w	#140, (a5)
		move.w	#$f468, (a3)		; Restore usb_idle

;		move.w	#$142, (a5)			; DOESN'T WORK -- BREAKS ADDRESS REG
;		move.w	#$0101, (a3)		; Flip endian mode (for byte reads)

.dolock:
		; here we hardlock sector 0. Because !WP is tied low, it is not possible
		; to erase or modify sector 0 without a power cycle or reset after this
		; reset of the EZHost is enough to clear this (or boot with BJL)
		move.w	#$4000, (a5)		; Enter Flash read/write mode
		
		; switch to bank 0 then hardlock sector 0 
		move.w	#$4BA0, (a5)		; Destined For BAnk 0!

		; 36A=9098 / 1C94=C501 / 36A=8008 / 36A=9098 / 1C94=C501 / Addr=8180
		move.w	#$9098, $80036a		; 555=aa
		move.w	#$c501, $801c94		; aaa=55
		move.w	#$8008, $80036a		; 555=80
		move.w	#$9098, $80036a		; 555=aa
		move.w	#$c501, $801c94		; aaa=55
		move.w	#$8180, $800000		; 0 = 60	; sector lockdown
		
		move.w	#$4004, (a5)		; return to HPI write mode
		rts

finalinit:
		jsr		ezreset-jcpblock+RAMLOAD	; now actually DO that reset
.donelock:

; Check for autoboot (extended BIOS, intended for USB boot)
; that code may RTS to come back here if it finds nothing
		move.w #$81fe,JOYSTICK	; enable read, audio, nothing on joystick 1, col 0 on joystick 0
		move.l JOYSTICK,d0		; by doing a long read, we get JOYSTICK and JOYBUTS
		btst	#01,d0			; test A
		beq		EnterLoop		; skip if pressed

		; check on second bank for v2 board
		move.w  #$4BA1, (a5)	; Destined For BAnk 1!

		move.w	#$4001, (a5)	; Enter Flash read-only mode (helps us reboot!)

		move.l	$BFFFF0,d0		; get token
		cmp.l	#'LION',d0		; test against keystring
		bne		EnterLoop
		
		move.l	$BFFFF4,a2		; get start address
		cmp.l	#0,a2			; sanity check
		beq		EnterLoop
		cmp.l	#$ffffffff,a2
		beq		EnterLoop
		
		; okay, then!
		jmp		startcode-jcpblock+RAMLOAD

EnterLoop:
		; we do this again even though it was done above, because code
		; that returns loops back to this point.
		move.l	#$800000, a3		; a3 = HPI write data
		move.l	#$C00000, a5		; a5 = HPI write address, read data

; copy the board's revision and serial number into the
; bottom of the first buffer. Tag is $FA57F00D
; This way JCP can get the data.
		move.w	#$4BA0, (a5)		; Destined For BAnk 0!
		move.w	#$4001, (a5)		; Flash read-only mode
		move.l	$800800, d0			; get board version
		move.l	$800808, d1			; get serial number
		
		move.w	#$4004, (a5)	 	; HPI write mode
		move.w	#$2800,	(a5)		; $2800 buffer
		move.w	#$fa57, (a3)
		move.w	#$f00d, (a3)
		move.w	d0, (a3)			; half of version
		swap	d0
		move.w	d0, (a3)			; other half
		move.w	d1, (a3)			; half of serial
		swap	d1
		move.w	d1, (a3)			; other half
		
; 68k mode
		move.w	#$01c0,d6			; d6 for bg color
		
; done, set the screen to notify such	
		move.w  #$C000,BORD1       	; Green border 
		move.w	#0,BORD2
		move.w  #$8FC0,BG          	; Init line buffer to green
;		move.w  #$1234,BG          	; Init line buffer to purple
		
; Now fully booted!  Start polling EZ-HOST for data to download
; d4 = current 'base address' (2800/37EA or 1800/27EA)
		move.w	#$27EA, (a5)		; Put -1s in both blocks before poll
		move.w	#$ffff, (a3)		
		move.w	#$37EA, (a5)
		move.w	#$ffff, (a3)

; 2800 block sends first
		move.w	#$37EA, d4
		
; In this early wait phase, we also watch the joystick.
; If the user presses 'UP' on joystick 0, we launch the cartridge
; There's no checking whether the flash contains valid data
		move.w	#$4001, (a5)		; Enter Flash read-only mode (helps us reboot!)
		
.waitjoy:	
; check block
		move.w	d4, (a5)
		move.w	(a5),d0
		andi.w	#$ff00,d0		; low byte may be set first, $FFxx is never valid
		cmp.w	#$ff00,d0
		bne 	.waitblockok	; valid read, jump out of this loop

; check joystick (enable audio here - BIOS apparently does!)
		; bits end up a bit screwy. It looks like these. The first set is joystick 1 if enabled,
		; notice how it's selects are the opposite to joystick 0. Value to write is $81YZ, where Y
		; is the row for JOY1 and Z is the row for JOY0. The 8 enables read, and the 1 enables
		; audio (why that's in the joystick register... oi.). I can't test the Numpad or option
		; because my Genesis pad doesn't have those. ;)
		;           JOY1JOY0                       J1J0
		; row0 (e): 369#RLDU xxxxxxxx xxxxxxxx xxxxOxAP
		; row1 (d): 2580*741 xxxxxxxx xxxxxxxx xxxxCxBx		; note: numpad may be backwards here
		; row2 (b): *7412580 xxxxxxxx xxxxxxxx xxxxBxCx
		; row3 (7): RLDU369# xxxxxxxx xxxxxxxx xxxxAPOx		; also, option may be bitshifted by one :)

		move.w #$81fe,JOYSTICK	; enable read, audio, nothing on joystick 1, col 0 on joystick 0
		move.l JOYSTICK,d0		; by doing a long read, we get JOYSTICK and JOYBUTS

; V2 - check down for bank 2
		btst	#25,d0			; test down
		beq		.gobank1		; branch if pressed

		btst	#24,d0			; test up
		bne		.waitjoy		; wait if not pressed
		
		move.l	#$802000,a2		; launch address in bank 0
		
		btst	#01,d0			; test A
		bne		.use4mb			; skip if not pressed
		
		move.l	#$70802000,a2	; start in 6MB mode

.use4mb:
		move.l  #$00,BORD1      ; Black the screen
		move.w  #$00,BG         ; black
		jmp		startcode-jcpblock+RAMLOAD	; launch the cartridge securely	

.gobank1:
; not used on v1, but that's okay
		move.l  #$00,BORD1      ; Black the screen
		move.w  #$00,BG         ; black

		move.l	#$10802000,a2				; launch address in bank 1
		jmp		startcode-jcpblock+RAMLOAD	; launch the cartridge securely	

; Wait for the current block to go 'ready' 

.waitblock:	move.w	#$4001, (a5)		; Enter Flash read-only mode (helps us reboot!)

.waitblock2:	move.w	d4, (a5)
		move.w	(a5),d0
		andi.w	#$ff00,d0			; low byte may be set first, $FFxx is never valid
		cmp.w	#$ff00,d0
		beq 	.waitblock2
		
.waitblockok:		
		move.w	d6, BG
		move.w	VC,d6
		asl.w	#7,d6
		ori.w	#$c0,d6
		move.w  #-1,BG

; Now copy the block contents into DRAM
		sub.w	#$A, d4			; Point to block footer and read it in
		move.w	d4, (a5)
		move.l	(a5), a0		; a0 = Destination address
		move.l	(a5), a2		; a2 = Jump target
		move.w	(a5), d3		; d3 = Base address of next block
		move.w	(a5), d1		; d1 = Number of bytes to copy
		
		addq	#3,d1			; round up to dwords
		lsr.w	#2,d1			; divide by 4
		subq	#1,d1			; and subtract one for dbra loop
		andi	#$3ff,d1		; technically $3f8 is the maximum count, this is a quick safety

		sub.w	#$FE0, d4		; Point to start of block
		move.w	d4, (a5)

; Although the later screen color change is better for debugging,
; this shorter color change flashes less for TV/epilepsy worries
		move.w  #$8FC0,BG        ; Reset line buffer to green
		
		; NOTE: Tried unrolling this loop, it made no difference in speed. This
		; likely means that the USB transfer of the next block takes longer than
		; the memory copy does, so optimizing this has no effect. I get a max of
		; about 337k/s here, and it does not change at all when unrolled
.blockcopy:	
		move.l	(a5), (a0)+			; Copy it!
		dbra	d1, .blockcopy

		move.w	#$4004, (a5)		; Enter HPI write mode

		add.w	#$FEA, d4			; Mark the block done
		move.w	d4, (a5)
		move.w	#$ffff, (a3)

		move.l	d3, d4				; Point to next block ready flag
		add.w	#$FEA, d4

		cmp.l	#-1, a2				; Keep looping until jump target != -1
		beq 	.waitblock		

		move.w	#$4001, (a5)		; Enter Flash read-only mode (helps us reboot!)

		jmp startcode-jcpblock+RAMLOAD	; secure entry point
		
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;		
		
; I've gone ahead and embedded the flash program here as part
; of securing the cart against unauthorized programs. Well,
; only Battlesphere.
		
		.phrase

flasher:
		move.l	#$01c0,	d6			; color index used during erase

		move.l	#$C00000, a5		; a5 = HPI address write/data read
		move.l	#$800000, a3		; a3 = HPI data write
		
; Mark both blocks used as a flag to block JCP
		move.w	#$4004, (a5)		; Enter HPI write mode
		move.w	#$27EA, (a5)		; Put 0s in both blocks before poll
		move.w	#$0000, (a3)		
		move.w	#$37EA, (a5)
		move.w	#$0000, (a3)
		move.w	#$4001, (a5)		; Return to flash read-only mode

; work out how many blocks we need to erase with the
; passed in count. If that's not valid, erase them all.
		move.l	$3ff0,d1
		move.l	d1,d2
		eor		#$ffff,d2
		cmp.l	$3ff4,d2
		beq		.d1valid
		; not valid - erase all blocks (and clear flag for later tests)
		move.l	#62,d1
		move.l	d1,$3ff0
.d1valid:

; Bank set for SB v2
		; Check and set correct bank
		btst	#30,d1
		beq.s	.setbank0
		
		; set bank 1
		move.w  #$4BA1, (a5)		; Destined For BAnk 1!
		; we need to erase just block 0 anyway (it's not locked, and it's 64kbyte)
		move.l	#$800000, a0
		jsr		EraseBlockInA0-jcpblock+RAMLOAD
		; carry on (NOTE! no bios yet! We'll add it if we boot bank 2)
		bra.s	.bankset
		
.setbank0:
		move.w	#$4BA0, (a5)		; Destined For BAnk 0!

; Start by erasing all the boot blocks save the bottom one... (8kbytes blocks, 64kbytes sectors beyond)
; destroys d6,d0
		move.l	#$802000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		move.l	#$880000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		move.l	#$882000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		move.l	#$900000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		move.l	#$902000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		move.l	#$980000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		move.l	#$982000, a0
		jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		
.bankset:

		; double check max range (comes after above so rev2 can test the high bits of d1)
		and.l	#$3f,d1
		; now only 63 is invalid
		cmp.l	#63,d1
		bne		.d1valid2
		; invalid - erase all blocks
		move.l	#62,d1
.d1valid2:

; erase the rest of the blocks, by count in d1
		move.l	#$984000, a0
_eraseloop:	jsr 	EraseBlockInA0-jcpblock+RAMLOAD
		add.l	#16384, a0
		dbra	d1, _eraseloop

; Now to program...
		move.w	#$4004, (a5)		; Enter HPI write mode

		move.w	#$27EA, (a5)		; Put -1s in both blocks before poll
		move.w	#$ffff, (a3)		
		move.w	#$37EA, (a5)
		move.w	#$ffff, (a3)

		move.w	#$37EA, d4
		
; put the flash chip into single-pulse Word program mode
; code:		555/aa,		aaa/55,		555/80,		555/aa,		aaa/55,		555/a0
; hash:		80036a/9098,801c94/c501,80036a/8008,80036a/9098,801c94/c501,80036a/8088
		move.w	#$4000, (a5)	; Enter Flash read/write mode

		move.w #$9098,$80036a
		move.w #$c501,$801c94
		move.w #$8008,$80036a
		move.w #$9098,$80036a
		move.w #$c501,$801c94
		move.w #$8088,$80036a
; Note that a chip reset is needed to exit this mode now! So we can't compare the data?

; Wait for the current block to go 'ready'

.waitblock:	
		move.w	d4, (a5)
		move.w	(a5),d1
		andi.w	#$ff00,d1
		cmp.w	#$ff00,d1		; watch for high byte only - low byte changes first in rare conditions
		beq 	.waitblock
		
; Now copy the block contents into ROM
		move.w	#$0,BG			; clear background
		move.w	#$4000, (a5)	; Enter Flash read/write mode

		sub.w	#$A, d4			; Point to block footer and read it in
		move.w	d4, (a5)
		move.l	(a5), a0		; a0 = Destination address
		move.l	(a5), a2		; a2 = Jump target
		move.w	(a5), d3		; d3 = Base address of next block
		move.w	(a5), d1		; d1 = Number of bytes to copy
		move.l	d3,-(sp)		; save d3 for later to free the register
				
		; Note: v3 ignores the 'slow word flash' mode bit - it has just one mode
		
		move.l	a0, a3			; a3 = Spare copy of a0 (destination address)

		sub.w	#$FE0, d4		; Point to start of block
		move.w	d4, (a5)

		addq	#3,d1			; round up to dwords
		lsr.w	#2,d1			; divide by 4
		subq	#1,d1			; and subtract one for dbra loop
		andi	#$3ff,d1		; technically $3f8 is the maximum count, this is a quick safety

; Previously, best case (0xff's) gets 289k/s, worst case (0x00's) gets 198k/s
; We're about 30% slower now.
		move.l	(a5), d7
		swap	d7					; prepare for the write

.blockcopy:	
		move.w  d7, (a0)			; Payload

; we know we have to wait a few cycles, set up the next block
; before we start to wait
		move.l	a0, a1				; save a0
		addq	#2, a0				; next address
		move.l	d7,d6				; save d7
		swap	d7					; get next value
		move.w	#80, d3				; Wait at most 100uS after program

.blkcpylp2:
		cmp.w	(a1), d6			; Check for correctly written data or...
		dbeq	d3, .blkcpylp2		; ...time out when d3 expires

; other word
		move.w  d7, (a0)			; Payload

; we know we have to wait a few cycles, set up the next loop
; before we start to wait
		move.l	a0, a1				; save a0
		addq	#2, a0				; next address
		move	d7,d6				; save d7
		move.l	(a5), d7			; get next value
		swap	d7					; prepare for the write
		move.w	#80, d3				; Wait at most 100uS after program

.blkcpylp:
		cmp.w	(a1),d6				; Check for correctly written data or...
		dbeq	d3, .blkcpylp		; ...time out when d3 expires

; We can not write to the flash during the program or it will fail
; we can execute the loop before waiting for the flash to finish
		dbra	d1,  .blockcopy		; Keep going until we're done

; one final wait
.waitpgm2:
		cmp.w   (a1), d7			; Check for correctly written data or...
		dbeq	d3, .waitpgm2		; ...time out when d3 expires

.blockdone:
		move.w	#$ffff,BG		; set background color
		add.w	#$FEA, d4		; Mark the block done
		move.w	#$4004, (a5)	; Enter HPI write mode
		move.w	d4, (a5)
		move.w	#$ffff, (a3)

		move.l	(sp)+,d4		; get the old d3 (next block address) into d4
		add.w	#$FEA, d4

		cmp.l	#-1, a2			; Keep looping until jump target != -1
		beq 	.waitblock		

		move.w	#$5512, BG		; Indicate completion

		move.w	#$4001, (a5)	; Enter Flash read-only mode

		; reset the flash chip to get out of program mode (preserve A2!)
		jsr		ezreset-jcpblock+RAMLOAD	; now actually DO that reset

		; check a2 for return without start flag
		cmp.l	#$fffffffe,a2
		bne		.longjmp
		rts						; this takes us back into the BIOS
		
.longjmp:
		jmp startcode-jcpblock+RAMLOAD	; secure entry point

; This will leave the status in D0...  (Scratching it!)
EraseBlockInA0:
		move.w	#$4000, (a5)		; Enter Flash read/write mode

		move.w	#$9098, $80036A		; special command
		move.w	#$C501, $801C94		
		move.w	#$8008, $80036A		; 80
		move.w	#$9098, $80036A		; erase command
		move.w	#$C501, $801C94
		move.w	#$8480, (a0)		; 30

; XXX - Doesn't handle erase errors (but what can we do?)
.waiterase:	
		move.w	d6, BG
		move.w	VC,d6
		asl.w	#7,d6
		ori.w	#$c0,d6
		move.w	(a0), d0		; Zero means busy, 8 means ready
		move.w	#0, BG		
		and.w	#8, d0
		beq .waiterase

		move.w	#$0, BG			; Indicate we succeeded.

		move.w	#$4001, (a5)		; Enter Flash read-only mode
		rts

; Go home!
_gameover:
		move.w	#$4001, (a5)		; Enter Flash read-only mode
		jmp forevr-jcpblock+RAMLOAD

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;		

; and this little block is our security against starting 
; unauthorized programs
; Boot address is in a2
; DON'T CHANGE A2!
;
; The top nibble allows a bank select on v2 boards: 0 = bank 0, 1 = bank 1, 7 = 6MB mode
; Not using the high bit because of the way JCP uses it.
;

startcode:
; Basically, the confirmed checksums are in bank 0 and may not be in bank 1, either bank may be active
		; before anything else, we need to check if we are launching the
		; flash stub - that must be allowed! We'll check every word that matters.
		; Note: *MUST* load at $4100 and *MUST* follow this exact format
		move.l	a2,d0			; get address of exe
		and.l	#$00FFFFFF,d0	; mask off the control byte
		cmp		#$4100,d0		; test address of stub
		bne		.notstub
		move.l	a2,a0			; make a copy
		cmp.w	#$223c,(a0)		; move.l #xxxxxxxx,d1
		bne		.notstub
		addq	#6,a0			; skip 32-bit argument
		cmp.w	#$21c1,(a0)+	; move.l d1,$3ff0
		bne		.notstub
		cmp.l	#$3ff00a81,(a0)+ ; rest of move, eor.l #$xxxxxxxx,d1
		bne		.notstub
		cmp.l	#$0000ffff,(a0)+ ; eor data #$ffff
		bne		.notstub
		cmp.l	#$21c13ff4,(a0)+ ; move.l d1,$3ff4
		bne		.notstub
		cmp.l	#$22790080,(a0)+ ; move.l $800804,a1
		bne		.notstub
		cmp.l	#$08044ed1,(a0)+ ; rest of move, jmp (a1)
		bne		.notstub
		; it IS the flash stub, so skip over the check
		
		; But, we know it's the flash stub, and we know if bank 2 is
		; up that it's going to read the wrong vector address
		; so we will cheat and patch it in RAM (we know exactly
		; what we have). We can't change the stub without breaking
		; compatibility with the older Skunkboard BIOS.
		; Just drop the vector read and branch directly
		; JMP $xxxxxxxx = 4EF9xxxxxxxx
		move.w	#$4ef9, $4114
		move.l	#flasher-jcpblock+RAMLOAD, $4116
		
		bra		oktolaunch

		; what we want to do here is just check the flash for any of the signatures
		; If they exist, we fail out and return not-authorized to JCP, which is supposed
		; to be waiting (if it's not, then too bad). We do this regardless of what
		; address we are going to launch, to prevent simple tricks from working
		; around it. 
		
		; don't touch A2!! Safe to touch ROM here though.
		; Of course this is still easily broken by putting a jmp (a2) right up front

.notstub:		
		; before we mess around here, make sure we're on bank 0
		move.w	#$4001, (a5)		; set flash read-only mode
		move.w  #$4BA0, (a5)

		; first check if the sigs have been messed with
		moveq	#0,d0
		move.l	#sigs-copyblock+$800800,a0
		move.l	#72,d1			; 8*8 dwords of sig, 8 dwords of address, 1 dword of count, -1 for dbra
		
.checklp:
		add.l	(a0)+,d0
		dbra	d1,.checklp
		
		; now pointing at the checksum
		cmp.l	(a0),d0
		bne		unauth
		
		; okay, checksum is okay, walk through the list and check the flash, both banks if v2
		move.l	#sigs-copyblock+$800800,a0
		move.l	(a0)+,d0		; countdown
		subq	#1,d0			; minus 1
		
.testlp:
		move.l	(a0)+,a1		; target address in A1
		moveq	#31,d1			; byte count
		
.cmplp:
		cmp.b	(a1)+,(a0)+
		bne		.isok
		dbra	d1,.cmplp
		
		; if we get here, it was a perfect match
		bra		unauth
		
.isok:	
		subq	#1,d1
.fixup:		
		; fix up the address
		addq	#1,a0
		dbra	d1,.fixup
				
		; check next signature, if there is one
		dbra	d0, .testlp	

		; checking bank 1 is a bit more painful - in many cases, the
		; signatures will only be in bank 0. Luckily, bank changes are
		; fast and easy.
		move.l	#sigs-copyblock+$800800,a0
		move.l	(a0)+,d0		; countdown
		subq	#1,d0			; minus 1
		
.testlp2:
		move.l	(a0)+,a1		; target address in A1
		moveq	#31,d1			; byte count
		
.cmplp2:
		; (a0) in bank 0, (a1) in bank 1
		; switch to bank 0
		move.w	#$4BA0, (a5)
		move.b	(a0)+,d2
		; switch to bank 1
		move.w	#$4BA1, (a5)
		cmp.b	(a1)+,d2
		bne		.isok2
		dbra	d1,.cmplp2
		
		; if we get here, it was a perfect match
		bra		unauth
		
.isok2:	
		subq	#1,d1
.fixup2:		
		; fix up the address
		addq	#1,a0
		dbra	d1,.fixup2
				
		; check next signature, if there is one
		dbra	d0, .testlp2

oktolaunch:
		; all seems well, go ahead and launch
		; we write the magic value 0000 into both buffer flags to say so
		move.l	#$800000, a3		; a3 = HPI write data
		move.l	#$C00000, a5		; a5 = HPI write address, read data

		move.w	#$4004, (a5)		; Enter HPI write mode

		move.w	#$27EA, (a5)
		move.w	#$0000, (a3)		
		move.w	#$37EA, (a5)
		move.w	#$0000, (a3)

		move.w	#$4001, (a5)		; Enter Flash read-only mode (helps us reboot!)

		; test for the appropriate bank
		move.l	a2,d0
		move.l	a2,d1
		and.l	#$00FFFFFF,d1		; mask off control nibbles
		move.l	d1,a2

; Banking select for v2
		and.l	#$F0000000,d0		; get the one we care about
		cmp.l	#$70000000,d0		; is it 6MB mode?
		beq		.set6MB
		cmp.l	#$10000000,d0		; is it bank 1?
		beq		.setBank1
		
		; else just set bank 0
		move.w	#$4001, (a5)		; set flash read-only mode
		move.w	#$4BA0, (a5)		; Select bank 0
		bra		.jmpout
		
.set6MB:
		; set bank 0, 6MB mode
		move.w	#$4003, (a5)		; set 6MB mode
		move.w	#$4BA0, (a5)		; Select bank 0
		bra		.jmpout
		
.setBank1:
		; set bank 1						
		move.w	#$4001, (a5)		; set flash read-only mode
		move.w	#$4BA1, (a5)		; Select bank 1
		; a little extra check here to make sure there is a BIOS present!
		move.l $800000,d0				; check the first dword contains data
		cmp.l #$ffffffff,d0			; erased
		bne .verifybios					; there is SOMETHING there
		; copy the BIOS over. Note this overwrites 8k at the 1MB RAM point.
		jsr		CopyBIOS-jcpblock+RAMLOAD

.verifybios:
		; check whether the first word at bank 2 looks like a skunkboard BIOS
		move.w	#$4001, (a5)		; set flash read-only mode
		move.w	#$4BA0, (a5)		; Select bank 0
		move.l $800000,d0				; get the word
		move.w  #$4BA1, (a5)		; Select bank 1
		cmp.l  $800000,d0				; do they match?
		beq.s .jmpout						; looks good!
		
		; no, it's something weird, probably part of a 6MB ROM
		; switch back to bank 1 (for reset) and back to wait mode.
		move.w	#$4BA0, (a5)		; Select bank 0
		; give the user some feedback - we'll go black for a delay and then restart
		move.w	#$0000, BG			; black background as feedback

		moveq		#30,d2					; Wait roughly 1s
.userfbA:		
		move.l	#25000, d1
.userfeedback:	dbra	d1, .userfeedback
		dbra d2, .userfbA

;		move.w	#$ffff, BG			; white background as feedback of delay ending
		bra skipboot

.jmpout:				

		; now finally do the jump - we JSR to allow the code to return to us
		; (for JCP utilities mainly), on return we reset the stack (to avoid
		; leaks) and anything else needed, and jump back up to the wait loop
		move.l	#INITSTACK,a7	; Set Atari's default stack
		jsr (a2)

skipboot:
		; Assume that the code didn't screw with the system (this is meant for
		; JCP utilities), reset the stack to avoid stack leaks, then go back
		; to the green screen and wait
		move.l  #$23FC,a7   	; Setup a stack
		jmp	EnterLoop-jcpblock+RAMLOAD
		
unauth:
		; Flash contains unauthorized data, or checksums corrupt, fail it
		; we write the magic value 8888 into both buffer flags to say so
		move.l	#$800000, a3		; a3 = HPI write data
		move.l	#$C00000, a5		; a5 = HPI write address, read data

		move.w	#$4004, (a5)		; Enter HPI write mode

		move.w	#$27EA, (a5)
		move.w	#$8888, (a3)		
		move.w	#$37EA, (a5)
		move.w	#$8888, (a3)

		move.w	#$4001, (a5)		; Enter Flash read-only mode (helps us reboot!)		
		move.w	#$4ba0, (a5)		; and bank 0 to make reboot work
		
		; Then we fail it out by changing the screen color and spinning
		; user will have to jcp -r/power cycle
forevr:
		move.w	#$f0ff, BG			; red
		jmp		forevr-jcpblock+RAMLOAD

; Signature format: Num sigs, address, 32 bytes, (repeats), overall checksum (32bit)
; Battlesphere signatures
        .phrase
sigs:        
        dc.l 8
        dc.l $00836FFE
        dc.b $4C,$DF,$00,$20,$4E,$75,$48,$E7
        dc.b $40,$80,$41,$F9,$00,$16,$AB,$D4
        dc.b $20,$50,$22,$10,$B2,$BC,$00,$98
        dc.b $D5,$78,$67,$00,$00,$4A,$B2,$BC
        dc.l $008446C0
        dc.b $58,$01,$2C,$42,$98,$03,$10,$00
        dc.b $00,$00,$78,$23,$D4,$74,$0C,$22
        dc.b $D7,$80,$64,$21,$1C,$22,$98,$03
        dc.b $90,$04,$00,$91,$98,$04,$50,$00
        dc.l $0089DA48
        dc.b $A4,$26,$98,$04,$32,$5C,$00,$F0
        dc.b $D0,$00,$E4,$00,$98,$00,$05,$00
        dc.b $00,$00,$40,$07,$00,$E8,$98,$06
        dc.b $00,$25,$00,$00,$98,$00,$32,$F8
        dc.l $009190EC
        dc.b $98,$06,$A1,$14,$00,$F1,$BC,$C2
        dc.b $BC,$02,$98,$04,$50,$58,$00,$00
        dc.b $98,$00,$C1,$5C,$00,$F1,$BC,$04
        dc.b $98,$01,$54,$5C,$00,$00,$8C,$00
        dc.l $00878D86
        dc.b $4C,$DF,$00,$20,$4E,$75,$48,$E7
        dc.b $40,$80,$41,$F9,$00,$16,$AB,$D4
        dc.b $20,$50,$22,$10,$B2,$BC,$00,$9B
        dc.b $26,$78,$67,$00,$00,$4A,$B2,$BC
        dc.l $00885E18
        dc.b $58,$01,$2C,$42,$98,$03,$10,$00
        dc.b $00,$00,$78,$23,$D4,$74,$0C,$22
        dc.b $D7,$80,$64,$21,$1C,$22,$98,$03
        dc.b $67,$54,$00,$94,$98,$04,$27,$50
        dc.l $008D61C8
        dc.b $A4,$26,$98,$04,$32,$5C,$00,$F0
        dc.b $D0,$00,$E4,$00,$98,$00,$05,$00
        dc.b $00,$00,$40,$07,$00,$E8,$98,$06
        dc.b $00,$25,$00,$00,$98,$00,$32,$F8
        dc.l $0094683C
        dc.b $98,$06,$A1,$14,$00,$F1,$BC,$C2
        dc.b $BC,$02,$98,$04,$50,$58,$00,$00
        dc.b $98,$00,$C1,$5C,$00,$F1,$BC,$04
        dc.b $98,$01,$54,$5C,$00,$00,$8C,$00
endsigs:
        dc.l $521370F8
        
        .phrase
		; copy the BIOS over. We know the flasher is at $4100 (it must be as noted below),
		; so we can safely overwrite higher memory. We also know bank 2 is supposed to be active
		; We only need 8k anyway, so we'll stick our buffer at the 1MB RAM point.
		; a5 must be set up, exits with bank 2 active
CopyBIOS:
		movem.l	d0-d1/a0-a1,-(sp)

		move.w	#$1234, BG			; purple background, in case it hangs

		move.w	#$4000, (a5)		; Enter Flash read/write mode
		move.w	#$4BA0, (a5)		; now from bank 0
		
		move.l	#$800000, a0		; source BIOS data
		move.l	#$100000, a1		; destination in RAM
		move.l	#$7ff, d0			; 8k / 4 - 1
.cplp2:
		move.l	(a0)+,(a1)+
		dbra	d0,.cplp2			; copy the block
		
		; Now write the data to bank 2
		move.w  #$4BA1, (a5)		; Access BAnk 1!
		
		; do the write - to guarantee it will work, we should use the
		; slow flash write from $100000 to $800000, 8k
		move.l	#$100000, a0	; source
		move.l	#$800000, a1	; dest
		move.l	#$fff, d0		; 8k/2-1

.wrword:		
		;36A=9098 / 1C94=C501 / 36A=8088 / Adr0=Data
		move.w	#$9098, $80036a
		move.w	#$c501, $801c94
		move.w	#$8088, $80036a	; program word
		move.w	(a0)+, d1
		move.w  d1,(a1)			; Payload

.waitpgm21:	
		cmp.w	(a1), d1		; wait for it to be equal
		bne 	.waitpgm21
		addq	#2,	a1

		dbra	d0, .wrword

		movem.l (sp)+,d0-d1/a0-a1	; Restore regs
		rts
 
eof:
		; useful to know the last used BIOS address - this is not used in the code!
		dc.l	eof-copyblock+$800800
		
		; fill 6k of FF bytes since that all gets written to the boot
		.incbin	"6Kof0xFF.bin"

; strings for upgrader, not part of BIOS
		.long
TXTgreet:
		.dc.b	'Skunkboard BIOS Update 1.02.04',13,10,0
		
		.long
TXTver:
		.dc.b	'Current ver: xx.xx.xx, Serial xxxx',13,10,0		

		.long
TXTnoneed:
		.dc.b	'This upgrader can not upgrade this version.',13,10,0
		
		.long
TXTdone:
		.dc.b	'Operation complete.',13,10,0
		
		.long
TXTerasing:
		.dc.b	'Preparing...',13,10,0

		.long
TXTerasefail:
		.dc.b	'Preparation failed. Code xx',13,10,0
		
		.long
TXTwriting:
		.dc.b	'Writing...',13,10,0
		
		.long
TXTwritefail:
		.dc.b	'Write failed. Code xx, address xxxxxxxx',13,10,0
		
		.long
TXTverify:
		.dc.b	'Verifying...',13,10,0
		
		.long
TXTverifyfail:
		.dc.b	'Verify failed at xxxxxxxx!',13,10,0	
		
		.long
TXTretrying:
		.dc.b	'Operation failed - will retry.',13,10,0
		
		.long
TXTgaveup:
		.dc.b	'Failed to upgrade board. Please copy the above log and request assistance.',13,10,0
		
		.long
retrycnt:
		.dc.l	3

		.phrase
		.include	"../jcp2/jcp/skunk.s"

		.end
