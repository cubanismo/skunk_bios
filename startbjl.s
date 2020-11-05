;; This version can be loaded from BJL and just runs the BIOS without the flash

;; BOOTCHER -- bootstrap code for Butcher and EZ-HOST
;; This file is for Rev3+ only. It may work on Rev2 but probably
;; will not be released for that.
;;	v.3.0.1 - use high-speed flash mode, remove high voltage options completely
;; -Added autoboot - top 2MB of flash intended. Start with a signature at $bffff0 (bank 2 on rev 2):
;;  BFFFF0 - LION
;;  BFFFF4 - Start address
;;  This boot is still subject to the security scan and is intended for future use like the USB boot
;;  It can be bypassed by holding A, if installed.
;;  v.3.0.2 - fix for 6MB mode - don't copy BIOS to bank 2 until bank 2 is booted
;;          - don't boot bank 2 unless at least first dword looks like a Skunkboard BIOS (so we don't
;;            crash on 6MB images.
;;  v.4.0.0 - Disable EZHost UART, configure GPIOs 25 and 28 as outputs, and set GPIO28
;;            high to select Serial EEPROM 1 at boot on dual-EEPROM SBv5 boards.
;;          - User can select Serial EEPROM 1 by pressing left, EEPROM 2 by
;;            pressing right at the boot screen.
;;          - Preserve the EEPROM selection across the EZHost reset after flashing.

		.include	"jaguar.inc"
		
RAMLOAD	.equ $1400		
		
		.text

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

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
		jmp		finalinit	; jump over the reset (embedded subroutine)

.if BIOS_MAJOR_VERSION >= 4
; Write an EZHost control register (address 0xc000 - 0xcfff)
;
; !!! Must be called in HPI write mode with a5/a3 = HPI write addr/data
;
; Parameters:
;   d0 - low word:  ezhost control register address
;   d0 - high word: control register value
;   a3 - 0x800000 - HPI write data
;   a5 - 0xC00000 - HPI write address/read data
;
; Return:
;   d0 - low word:  zero on success, non-zero on failure
;   d0 - high word: preserved (new control register value)
;
ezwrctrlreg:
		; Can't use HPI DMA access to EZHost registers. Need to send LCP (Link
		; Control Protocol) requests instead, and that means using HPI mailbox
		; messages, which use two not-very-well documented skunk addressing
		; "modes". Here's the full list, taken from comments in the Butcher/CPLD
		; VHDL source:
		;
		;   0x4000 = flash read/write, HPI DMA read-only.
		;   0x4001 = flash read-only, HPI DMA read-only.
		;   0x4002 = reserved.
		;   0x4003 = flash 6MB mode. HPI DMA not supported.
		;   0x4004 = HPI DMA read/write supported (No flash access?).
		;   0x4005 = HPI Mailbox Register read/write.
		;   0x4006 = HPI Boot. Pull ezhost boot pins (GPIO30 & GPIO31) low.
		;   0x4007 = HPI Status Port read (bit 0 = HPI mailbox intr status).
		;
		; LCP commands are set up by writing a payload via DMA to some BIOS-
		; reserved memory locations on the ezhost processor, then the command
		; is kicked off by writing it to the HPI mailbox register:
		;
		; 0x01ba [COMM_PORT_CMD] = command (Write via mailbox reg, not DMA):
		;  0xfa50 = reset
		;  0xce00 = jump2code
		;  0xce04 = call code
		;  0xce01 = exec int
		;  0xce02 = read control reg
		;  0xce03 = write control reg
		;  0xce08 = read mem (not used on HPI, use DMA)
		;  0xce09 = write mem (not used on HPI, use DMA)
		;  0xce05 = read xmem (external mem, not present on skunk)
		;  0xce06 = write xmem (external mem, not present on skunk)
		;  0xce07 = config (not used on HPI, configure HSS baud rate)
		; 0x01bc [COMM_MEM_ADDR] = address (for rd/wr mem, rd/wr ctrl reg, also
		;                          COMM_BAUD_RATE for cfg cmd.
		; 0x01be [COMM_MEM_LEN] = length of memory to read/write for rd/wr mem,
		;                         reg data for rd/wr ctrl reg.
		; 0x01c0 [COMM_CTRL_REG_LOGIC] = logic op for write ctrl reg, Also
		;  0x0 = write                   COMM_LAST_DATA, and memory pointer for
		;  0x1 = AND                     rd/wr xmem.
		;  0x2 = OR
		; 0x01c2 [COMM_INTR_NUM] = interrupt number for exec int
		; 0x01c4 [COMM_R0] = ezhost r0 reg value for exec int
		; 0x01c6 [COMM_R1] = ezhost r1 reg value for exec int
		; 0x01c8 [COMM_R2] = ezhost r2 reg value for exec int
		; 0x01ca [COMM_R3] = ezhost r3 reg value for exec int
		; 0x01cc [COMM_R4] = ezhost r4 reg value for exec int
		; 0x01ce [COMM_R5] = ezhost r5 reg value for exec int
		; 0x01d0 [COMM_R6] = ezhost r6 reg value for exec int
		; 0x01d2 [COMM_R7] = ezhost r7 reg value for exec int
		; 0x01d4 [COMM_R8] = ezhost r8 reg value for exec int
		; 0x01d6 [COMM_R9] = ezhost r9 reg value for exec int
		; 0x01d8 [COMM_R10] = ezhost r10 reg value for exec int
		; 0x01da [COMM_R11] = ezhost r11 reg value for exec int
		; 0x01dc [COMM_R12] = ezhost r12 reg value for exec int
		; 0x01de [COMM_R13] = ezhost r13 reg value for exec int

		move.l	d1,-(sp)			; Preserve d1

		move.w	#$4005, (a5)		; Enter HPI mailbox mode
		move.w	(a3), d1			; Read mailbox to clear HPI interrupt
		move.w	#$ce03, d1			; d1.w = CMD_WRITE_CTRL_REG
ezcmdcmn:
		move.w	#$4004, (a5)		; Enter HPI write mode
		move.w	#$01bc, (a5)		; CTRL_REG_ADDR =
		move.w	d0, (a3)			; d0 low word.
		swap	d0
		move.w	d0, (a3)			; CTRL_REG_DATA = d0 high word
		move.w	#0, (a3)			; CTRL_REG_LOGIC = WRITE
		move.w	#$4005, (a5)		; Enter HPI mailbox mode
		move.w	d1, (a3)			; mailbox = CMD_[READ/WRITE]_CTRL_REG
		move.w	#$4007, (a5)		; Enter HPI status register mode
		move.l  #1000, d1			; Poll status register for ~4ms...
.wrmbox:
		move.w	(a3), d0
		btst	#0, d0				; ...or until Mailbox out flag is set.
		bnz		.rdmbox
		dbra	d1, .wrmbox

		move.l	#1, d0				; ezhost never responded to mbox write.
		bra		.mbdone
.rdmbox:
		move.w	#$4005, (a5)		; Enter HPI mailbox mode
		cmp.w	#$0fed, (a3)		; Reading mailbox clears the interrupt.
		beq		.mboxok				; 0xdead = NAK, 0x0fed = ACK.

		move.l	#2, d0				; ezhost NAKed the register write command
		bra		.mbdone
.mboxok:
		move.w	#$4004, (a5)		; Return to HPI write mode
		move.w	#$01be, (a5)		; Read from CTRL_REG_DATA into d0.w and swap
		move.w	(a5), d0			; it to the high word. This handles the return
		swap	d0					; value for reads, and is a no-op for writes.
		clr.w	d0					; Return success
.mbdone:
		move.w	#$4004, (a5)		; Be sure to return in HPI write mode
		move.l	(sp)+, d1			; Restore d1
		rts

; Read an EZHost control register (address 0xc000 - 0xcfff)
;
; !!! Must be called in HPI write mode with a5/a3 = HPI write addr/data
;
; Parameters:
;   d0 - low word:  ezhost control register address
;   a3 - 0x800000 - HPI write data
;   a5 - 0xC00000 - HPI write address/read data
;
; Return:
;   d0 - low word:  zero on success, non-zero on failure
;   d0 - high word: the register value on success. Undefined on failure.
;
ezrdctrlreg:
		; Reuse much of ezwrctrlreg. The only difference is the value written to
		; the mailbox to submit the command, which is stored in d1.w.
		move.l	d1,-(sp)			; Preserve d1

		move.w	#$4005, (a5)		; Enter HPI mailbox mode
		move.w	(a3), d1			; Read mailbox to clear HPI interrupt
		move.w	#$ce02, d1			; d1.w = CMD_READ_CTRL_REG
		bra		ezcmdcmn

; Error check an EZHost control register read or write
;
; Validates the return value of ezwrctrlreg or ezrdctrlreg and gives the user about
; 4 seconds of feedback if they fail:
;   Brown  - Unresponsive EZHost
;   Purple - NAKed LPC command
;   Red    - Unknown return code.
; Otherwise, it returns immediately.
;
; Parameters:
;   d0.w - ez[wr,rd]ctrlreg return value
;
; All registers are preserved
ezchkctrl:
		cmp.w	#0, d0			; If zero, return immediately
		beq		.donechk
		cmp.w	#2, d0			; Compare against 2
		blo		.noresp			; less than, not 0, must be 1
		beq		.nak			; Exactly 2. Else, it's greater than 2.
		move.w	#$f0ff, BG		; Unknown error. Red background as feedback.
		bra		.feedback
.noresp:
		move.w	#$b743, BG		; No response to cmd. Brown background as feedback.
		bra		.feedback
.nak:
		move.w	#$6050, BG		; Cmd NAKed. Purple background as feedback.
.feedback:
		movem.l	d1-d2, -(sp)
		moveq	#120,d2			; Wait roughly 4s
.userfbA:
		move.l	#25000, d1
.userfeedback:	dbra	d1, .userfeedback
		dbra	d2, .userfbA

		move.w  #$8fc0, BG		; Restore green background,
		movem.l	(sp)+, d1-d2
.donechk:
		rts
.endif ; .if BIOS_MAJOR_VERSION >= 4
		
; Complete EZ-HOST reset procedure, including SIE2 debug enable
;
; Parameters:
;   d2 - low word:  Serial EEPROM selection: 0x1000 for 93C46, 0x0200 for 93C86
;
; Sets a3 and a5, destroys d1 and d0
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

.if BIOS_MAJOR_VERSION >= 4
		; Select serial EEPROM using GPIO25 & GPIO28 on SBv5.
		; GPIO28 is shared with the ezhost UART TX line, so the UART must be
		; disabled first.

		; Disable ezhost UART
		move.w	#0, d0				; Write 0 to...
		swap	d0
		move.w	#$c0e0, d0			; ...UART CTRL Register
		jsr		ezwrctrlreg
		jsr		ezchkctrl

		; Select desired EEPROM
		move.w	d2, d0				; Write EERPOM selection to...
		swap	d0
		move.w	#$c024, d0			; ...GPIO data register 1
		jsr		ezwrctrlreg
		jsr		ezchkctrl

		; Configure GPIO25 and GPIO28 as outputs
		move.w	#$1200, d0			; Write 0x1200 to...
		swap	d0
		move.w	#$c028, d0			; ...GPIO direction register 1
		jsr		ezwrctrlreg
		jsr		ezchkctrl
.endif
		rts

finalinit:
		move.w	#$1000, d2			; Default to the 93C46/128-byte EEPROM on boot
		jsr		ezreset				; now actually DO that reset
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
		jmp		startcode

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

.if BIOS_MAJOR_VERSION >= 4
; V4 - check left for EEPROM 1, right for EEPROM 2
		btst	#26,d0			; test left
		bne		.noe2p0			; branch if not pressed
		move.w	#$1000, d0		; Set GPIO28 high, GPIO25 low
		move.w	#$ffff, BG		; yellow background as feedback
		bra		.sete2p

.noe2p0:
		btst	#27,d0			; test right
		bne		.noe2p1			; branch if not pressed
		move.w	#$0200, d0		; Set GPIO28 low, GPIO25 high
		move.w	#$1234, BG		; purple background as feedback

.sete2p:
		swap	d0
		move.w	#$c024, d0		; ...GPIO data register 1
		move.w	#$4004, (a5)	; Enter HPI write mode
		jsr		ezwrctrlreg
		jsr		ezchkctrl

		moveq	#30,d2			; Wait roughly 1s
.userfbA:
		move.l	#25000, d1
.userfeedback:	dbra	d1, .userfeedback
		dbra	d2, .userfbA

		move.w  #$8FC0, BG		; Restore green background,
		move.w	#$4001, (a5)	; return to Flash read-only mode,
		bra		.waitjoy		; and keep waiting.
.noe2p1:
.endif ; .if BIOS_MAJOR_VERSION >= 4

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
		jmp		startcode	; launch the cartridge securely	

.gobank1:
; not used on v1, but that's okay
		move.l  #$00,BORD1      ; Black the screen
		move.w  #$00,BG         ; black

		move.l	#$10802000,a2				; launch address in bank 1
		jmp		startcode	; launch the cartridge securely	

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

		jmp startcode	; secure entry point
		
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
		jsr		EraseBlockInA0
		; carry on (NOTE! no bios yet! We'll add it if we boot bank 2)
		bra.s	.bankset
		
.setbank0:
		move.w	#$4BA0, (a5)		; Destined For BAnk 0!

; Start by erasing all the boot blocks save the bottom one... (8kbytes blocks, 64kbytes sectors beyond)
; destroys d6,d0
		move.l	#$802000, a0
		jsr 	EraseBlockInA0
		move.l	#$880000, a0
		jsr 	EraseBlockInA0
		move.l	#$882000, a0
		jsr 	EraseBlockInA0
		move.l	#$900000, a0
		jsr 	EraseBlockInA0
		move.l	#$902000, a0
		jsr 	EraseBlockInA0
		move.l	#$980000, a0
		jsr 	EraseBlockInA0
		move.l	#$982000, a0
		jsr 	EraseBlockInA0
		
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
_eraseloop:	jsr 	EraseBlockInA0
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

		; reset the flash chip to get out of program mode (preserve A2!), but first
		; read back the current serial EEPROM selection and pass it to the reset
		; routine in d2.w to preserve it.
		move.w	#$c024, d0		; Read GPIO data register 1 to d0 high word
		jsr		ezrdctrlreg
		jsr		ezchkctrl
		swap	d0
		move.w	d0, d2
		jsr		ezreset			; now actually DO that reset

		; check a2 for return without start flag
		cmp.l	#$fffffffe,a2
		bne		.longjmp
		rts						; this takes us back into the BIOS
		
.longjmp:
		jmp startcode	; secure entry point

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
		jmp forevr

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
		move.l	#flasher, $4116

		bra		oktolaunch

		; what we want to do here is just check the flash for any of the signatures
		; If they exist, we fail out and return not-authorized to JCP, which is supposed
		; to be waiting (if it's not, then too bad). We do this regardless of what
		; address we are going to launch, to prevent simple tricks from working
		; around it. 
		
		; don't touch A2!! Safe to touch ROM here though.
		; Of course this is still easily broken by putting a jmp (a2) right up front

.notstub:		
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
		move.l	$800000,d0			; check the first dword contains data
		cmp.l	#$ffffffff,d0		; erased
		bne		.verifybios			; there is SOMETHING there
		; copy the BIOS over. Note this overwrites 8k at the 1MB RAM point.
		jsr		CopyBIOS

.verifybios:
		; check whether the first word at bank 2 looks like a skunkboard BIOS
		move.w	#$4001, (a5)		; set flash read-only mode
		move.w	#$4BA0, (a5)		; Select bank 0
		move.l	$800000,d0			; get the word
		move.w	#$4BA1, (a5)		; Select bank 1
		cmp.l	$800000,d0			; do they match?
		beq.s	.jmpout				; looks good!

		; no, it's something weird, probably part of a 6MB ROM
		; switch back to bank 1 (for reset) and back to wait mode.
		move.w	#$4BA0, (a5)		; Select bank 0
		; give the user some feedback - we'll go black for a delay and then restart
		move.w	#$0000, BG			; black background as feedback

		moveq	#30,d2				; Wait roughly 1s
.userfbA:
		move.l	#25000, d1
.userfeedback:	dbra	d1, .userfeedback
		dbra	d2, .userfbA

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
		jmp	EnterLoop
		
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
		jmp		forevr

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
		.end
