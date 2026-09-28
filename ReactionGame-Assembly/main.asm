;===========================================================================
; Two-Player Reaction Time Matching Game - PIC16F877A  
;===========================================================================

    LIST P=16F877A
    #INCLUDE <P16F877A.INC>

    ERRORLEVEL -302          ; suppress "not in bank 0" assembler messages
                             ; (banking is handled explicitly with BANKSEL)

    __CONFIG _XT_OSC & _WDT_OFF & _PWRTE_OFF & _BODEN_OFF & _LVP_OFF

    CBLOCK 0x20
        DELAY1
        DELAY2
        DELAY3
        INDEX           ; general loop counter / scratch
        TEMP            ; byte being sent to the LCD / scratch digit value
        RANDNUM         ; random target time, 0-60 (whole seconds)
        TENS            ; tens digit of RANDNUM (for LCD display)
        ONES            ; ones digit of RANDNUM (for LCD display)

        SCORE1          ; Player 1 score (0-5)
        SCORE2          ; Player 2 score (0-5)

        ; NOTE: the next four MUST stay in this exact order - Refresh_Digit
        ; reaches the HUN byte with "INCF FSR" from the SEC byte.
        P1_SEC          ; Player 1 elapsed whole seconds (0-60)
        P1_HUN          ; Player 1 elapsed hundredths    (0-99)   
        P2_SEC          ; Player 2 elapsed whole seconds (0-60)
        P2_HUN          ; Player 2 elapsed hundredths    (0-99)  

        FLAGS           ; bit0=P1_DONE      bit1=P2_DONE
                        ; bit2=P1_TIMEOUT   bit3=P2_TIMEOUT     
                        ; bit4=P1_ARMED     bit5=P2_ARMED        
                        ; bit7=DP_ON (scratch used by Refresh_Digit)
        DIGIT_SEL       ; which of the 8 multiplexed digits is lit (0-7)
        SCANCOUNT       ; counts refresh passes to time each 0.01s tick

        TARGETL         ; target time in HUNDREDTHS (16-bit, max 6000), low
        TARGETH         ; target time in HUNDREDTHS (16-bit), high
        P1L, P1H        ; Player 1 total time in hundredths (16-bit)
        P2L, P2H        ; Player 2 total time in hundredths (16-bit)
        D1L, D1H        ; |target - P1| in hundredths (16-bit)
        D2L, D2H        ; |target - P2| in hundredths (16-bit)

        AL, AH          ; generic 16-bit subtract operand A
        BL, BH          ; generic 16-bit subtract operand B
        RL, RH          ; generic 16-bit subtract result

        MTEMPL, MTEMPH  ; scratch 16-bit accumulator (Mult100)
        MULTMP          ; scratch byte (Mult100 / SegTable / Div10 / Mod10)
        SEGTEMP         ; final segment pattern about to be sent to PORTC
        WINNER          ; 0 = tie, 1 = Player1, 2 = Player2
        BLINKCNT        ; blink repetition counter (INDEX is used by
                        ; Refresh_Digit, which now runs DURING blinks)
        MUXCNT          ; slot counter for Mux_Delay (DELAY3 is used by
                        ; Delay_ms, which Mux_Delay calls internally)
    ENDC

    ORG 0x00
    GOTO START

;===========================================
; Main program
;===========================================
START:
    BANKSEL TRISD
    CLRF TRISD             ; Port D as output (LCD)

    BANKSEL TRISB
    BSF TRISB, 0           ; RB0 = master button input
    BSF TRISB, 1           ; RB1 = Player 1 button input
    BSF TRISB, 2           ; RB2 = Player 2 button input

    BANKSEL TRISA
    BCF TRISA, 0           ; RA0 = Player 1 LED output
    BCF TRISA, 1           ; RA1 = Player 2 LED output

    BANKSEL TRISC
    CLRF TRISC             ; RC0-RC7 = 7-seg segments + DP, all outputs

    BANKSEL TRISE
    BCF TRISE, 0           ; RE0 = decoder address bit A
    BCF TRISE, 1           ; RE1 = decoder address bit B
    BCF TRISE, 2           ; RE2 = decoder address bit C

    BANKSEL ADCON1
    MOVLW 0x07             ; all AN pins -> digital I/O (no analog needed)
    MOVWF ADCON1

    BANKSEL OPTION_REG
    MOVLW 0x88             ; RBPU'=1 (external 10K pull-ups used instead),
                           ; T0CS=0 (internal clock), PSA=1 (no prescaler)
    MOVWF OPTION_REG

    ; ---- Timer2 = exact 2ms timebase for the display multiplex ----
    ; Fosc/4 = 1MHz -> prescale 1:4 -> 250kHz (4us/count)
    ; PR2 = 249 -> rollover every 250 counts = 1000us
    ; postscale 1:2 -> TMR2IF sets every 2 rollovers = exactly 2000us.
    ; Flag-based pacing ABSORBS the refresh/polling overhead instead of
    ; adding to it, so 5 mux slots = exactly 10ms per hundredth tick and
    ; there is zero cumulative drift against a real stopwatch.
    BANKSEL PR2
    MOVLW .249
    MOVWF PR2
    BANKSEL T2CON
    MOVLW 0x0D             ; postscale 1:2, TMR2ON=1, prescale 1:4
    MOVWF T2CON

    BANKSEL PORTD          ; <-- back to Bank 0 for everything below
    CLRF PORTD
    CLRF PORTA
    MOVLW 0xFF
    MOVWF PORTC            ; segments idle HIGH = all OFF (common anode)
    CLRF PORTE
    CLRF TMR0              ; Timer0 starts free-running from 0
    CLRF SCORE1
    CLRF SCORE2

    CALL LCD_Init
    CALL Print_Ready

;===========================================
; GameLoop - one full round per pass
;  two master presses per round:
;   press #1 -> generate & display target
;   press #2 -> LEDs 1s, then GO
;===========================================
GameLoop:
    CALL WaitMasterPress    ; press #1: judge requests a target

GameLoop_Go:                ; (Restart re-enters here after a game over)
    CALL Generate_Random    ; RANDNUM = 0-60 (whole seconds)
    CALL Display_Target     ; LCD line1: "Target: XX sec"
    CALL Display_Score      ; LCD line2: "P1:x P2:y" (visible every round,
                            ; including "P1:0 P2:0" on the very first one)
    CALL Calc_TargetHun     ; TARGETL/H = RANDNUM * 100 (hundredths)

    BANKSEL PORTA
    BCF PORTA, 0            ; LEDs off while the players get ready
    BCF PORTA, 1

    CALL WaitMasterPress    ; press #2: judge starts the round     

    BANKSEL PORTA
    BSF PORTA, 0            ; LEDs ON for ~1 second ("get set")
    BSF PORTA, 1
    MOVLW .250
    CALL Delay_ms
    MOVLW .250
    CALL Delay_ms
    MOVLW .250
    CALL Delay_ms
    MOVLW .250
    CALL Delay_ms
    BCF PORTA, 0            ; LEDs OFF = GO signal
    BCF PORTA, 1

    ; ---- reset per-round player state ----
    CLRF P1_SEC
    CLRF P1_HUN
    CLRF P2_SEC
    CLRF P2_HUN
    CLRF FLAGS              ; also clears ARMED + TIMEOUT bits
    CLRF DIGIT_SEL
    CLRF SCANCOUNT
    CLRF TMR2               ; sync the 2ms timebase to the GO instant
    BCF PIR1, TMR2IF        ; discard any stale period flag

;===========================================
; CountLoop - runs the multiplexed displays,
; polls both player buttons, and advances
; each player's timer every ~0.01s 
;
; a player's press only counts after
; their button has been seen RELEASED (high)
; at least once after GO ("armed"). Holding
; the button down through the GO signal can
; no longer freeze a timer at 00.00.
;===========================================
CountLoop:
    CALL Refresh_Digit
CL_WaitTick:
    BTFSS PIR1, TMR2IF      ; wait out the remainder of this 2ms slot
    GOTO CL_WaitTick        ; (refresh+polling time is INSIDE the slot,
    BCF PIR1, TMR2IF        ;  so slots are exactly 2ms, drift-free)

    INCF DIGIT_SEL, F
    MOVF DIGIT_SEL, W
    XORLW .8
    BTFSS STATUS, Z
    GOTO SkipWrap
    CLRF DIGIT_SEL
SkipWrap:

    ; ---- Player 1 button (only if not already stopped) ----
    BTFSC FLAGS, 0
    GOTO CheckP2Btn
    BANKSEL PORTB
    BTFSC FLAGS, 4          ; armed yet?
    GOTO P1_Armed
    BTFSS PORTB, 1          ; still held down since before GO?
    GOTO CheckP2Btn         ;   yes -> keep ignoring it
    BSF FLAGS, 4            ;   no  -> seen released, now armed
    GOTO CheckP2Btn
P1_Armed:
    BTFSC PORTB, 1
    GOTO CheckP2Btn
    BSF FLAGS, 0            ; P1 stopped

CheckP2Btn:
    BTFSC FLAGS, 1
    GOTO TickTimers
    BANKSEL PORTB
    BTFSC FLAGS, 5          ; armed yet?
    GOTO P2_Armed
    BTFSS PORTB, 2
    GOTO TickTimers
    BSF FLAGS, 5
    GOTO TickTimers
P2_Armed:
    BTFSC PORTB, 2
    GOTO TickTimers
    BSF FLAGS, 1            ; P2 stopped

TickTimers:
    INCF SCANCOUNT, F
    MOVF SCANCOUNT, W
    XORLW .5                ; 5 slots x 2ms = exactly 0.01s per tick 
    BTFSS STATUS, Z
    GOTO CheckBothDone
    CLRF SCANCOUNT

    BTFSC FLAGS, 0
    GOTO Tick_P2
    CALL Increment_P1
Tick_P2:
    BTFSC FLAGS, 1
    GOTO CheckBothDone
    CALL Increment_P2

CheckBothDone:
    MOVF FLAGS, W
    ANDLW 0x03
    XORLW 0x03
    BTFSS STATUS, Z
    GOTO CountLoop
    GOTO RoundResolve

;===========================================
; Increment_P1 / Increment_P2
; advance one player's SEC/HUN by 0.01s;
; auto-stop EXACTLY at 60.00 if the player
; never pressed; mark them TIMED OUT
;===========================================
Increment_P1:
    INCF P1_HUN, F
    MOVF P1_HUN, W
    XORLW .100
    BTFSS STATUS, Z
    RETURN
    CLRF P1_HUN
    INCF P1_SEC, F
    MOVF P1_SEC, W
    XORLW .60               ; just reached 60.00 -> hard cap, stop HERE
    BTFSS STATUS, Z         ; (checking 61 would let the display count
    RETURN                  ;  60.01..60.99 before snapping back)
    BSF FLAGS, 0            ; done (SEC=60, HUN=0 already: shows 60.00)
    BSF FLAGS, 2            ; ...but by TIMEOUT, not by pressing   
    RETURN

Increment_P2:
    INCF P2_HUN, F
    MOVF P2_HUN, W
    XORLW .100
    BTFSS STATUS, Z
    RETURN
    CLRF P2_HUN
    INCF P2_SEC, F
    MOVF P2_SEC, W
    XORLW .60               ; just reached 60.00 -> hard cap, stop HERE
    BTFSS STATUS, Z
    RETURN
    BSF FLAGS, 1            ; done (SEC=60, HUN=0 already: shows 60.00)
    BSF FLAGS, 3            ; ...but by TIMEOUT, not by pressing  
    RETURN

;===========================================
; RoundResolve - both players stopped:
; compute deltas, pick winner, blink LED,
; update score, check for game-over
;===========================================
RoundResolve:
    BANKSEL PORTC
    MOVLW 0xFF
    MOVWF PORTC             ; blank the 7-seg displays (no frozen digit)

    ; ---- P1L/P1H = P1_SEC*100 + P1_HUN ----
    MOVF P1_SEC, W
    CALL Mult100
    MOVF P1_HUN, W
    ADDWF MTEMPL, F
    BTFSC STATUS, C
    INCF MTEMPH, F
    MOVF MTEMPL, W
    MOVWF P1L
    MOVF MTEMPH, W
    MOVWF P1H

    ; ---- P2L/P2H = P2_SEC*100 + P2_HUN ----
    MOVF P2_SEC, W
    CALL Mult100
    MOVF P2_HUN, W
    ADDWF MTEMPL, F
    BTFSC STATUS, C
    INCF MTEMPH, F
    MOVF MTEMPL, W
    MOVWF P2L
    MOVF MTEMPH, W
    MOVWF P2H

    ; ---- D1 = |TARGET - P1| ----
    MOVF TARGETL, W
    MOVWF AL
    MOVF TARGETH, W
    MOVWF AH
    MOVF P1L, W
    MOVWF BL
    MOVF P1H, W
    MOVWF BH
    CALL AbsDiff16
    MOVF RL, W
    MOVWF D1L
    MOVF RH, W
    MOVWF D1H

    ; ---- D2 = |TARGET - P2| ----
    MOVF TARGETL, W
    MOVWF AL
    MOVF TARGETH, W
    MOVWF AH
    MOVF P2L, W
    MOVWF BL
    MOVF P2H, W
    MOVWF BH
    CALL AbsDiff16
    MOVF RL, W
    MOVWF D2L
    MOVF RH, W
    MOVWF D2H

    ; ---- load each player's REAL delta into their display ----
    ; The stopped times are already saved in P1L/P1H and P2L/P2H, so the
    ; SEC/HUN pairs are free: overwrite them with the delta expressed as
    ; seconds + hundredths, and Refresh_Digit shows the deltas unchanged.
    ; (done BEFORE the timeout sentinel so a no-show still sees the real
    ;  |target - 60.00| value on their display)
    MOVF D1L, W
    MOVWF AL
    MOVF D1H, W
    MOVWF AH
    CALL Hun16_To_SecHun
    MOVF MULTMP, W
    MOVWF P1_SEC
    MOVF AL, W
    MOVWF P1_HUN

    MOVF D2L, W
    MOVWF AL
    MOVF D2H, W
    MOVWF AH
    CALL Hun16_To_SecHun
    MOVF MULTMP, W
    MOVWF P2_SEC
    MOVF AL, W
    MOVWF P2_HUN

    ; ---- a timed-out player gets the 0xFFFF sentinel delta ----
    ; (real deltas are at most 6000 = 0x1770, so 0xFFFF can never be beaten;
    ;  if BOTH players timed out, both deltas are 0xFFFF -> tie -> no score)
    BTFSS FLAGS, 2
    GOTO D1_NoTimeout
    MOVLW 0xFF
    MOVWF D1L
    MOVWF D1H
D1_NoTimeout:
    BTFSS FLAGS, 3
    GOTO D2_NoTimeout
    MOVLW 0xFF
    MOVWF D2L
    MOVWF D2H
D2_NoTimeout:

    CALL CompareWinner      ; WINNER = 0(tie)/1(P1)/2(P2)

    ; ---- show both deltas on the 7-segments for ~1s before the blink ----
    CLRF DIGIT_SEL
    MOVLW .250
    CALL Mux_Delay          ; 250 slots x 2ms = exactly 0.5s
    MOVLW .250
    CALL Mux_Delay          ; total ~1s (deltas also stay visible during
                            ; the blink, since blinks now use Mux_Delay)

    ; ---- a tie blinks BOTH LEDs, still no score ----
    MOVF WINNER, F          ; sets Z if WINNER == 0
    BTFSC STATUS, Z
    CALL Blink_Both

    MOVF WINNER, W
    XORLW .1
    BTFSS STATUS, Z
    GOTO NotP1Win
    CALL Blink_P1
    INCF SCORE1, F
NotP1Win:
    MOVF WINNER, W
    XORLW .2
    BTFSS STATUS, Z
    GOTO NotP2Win
    CALL Blink_P2
    INCF SCORE2, F
NotP2Win:

    BANKSEL PORTC
    MOVLW 0xFF
    MOVWF PORTC             ; delta viewing over: blank the displays
                            ; (multiplex refresh stops past this point)

    CALL Display_Score

    MOVF SCORE1, W
    SUBLW .5
    BTFSC STATUS, Z
    GOTO GameOver_P1
    MOVF SCORE2, W
    SUBLW .5
    BTFSC STATUS, Z
    GOTO GameOver_P2

    GOTO GameLoop

GameOver_P1:
    CALL Print_Winner_P1
    GOTO Restart
GameOver_P2:
    CALL Print_Winner_P2
Restart:
    ; ONE master press acknowledges the winner screen, clears the
    ; scores, and immediately starts the first round of a new game
    CALL WaitMasterPress
    CLRF SCORE1
    CLRF SCORE2
    GOTO GameLoop_Go

;===========================================
; WaitMasterPress - blocks until RB0 is
; pressed (debounced) then released
;===========================================
WaitMasterPress:
WMP_Wait:
    BANKSEL PORTB
    BTFSC PORTB, 0
    GOTO WMP_Wait
    MOVLW .20
    CALL Delay_ms
    BTFSC PORTB, 0
    GOTO WMP_Wait
WMP_Release:
    BTFSS PORTB, 0
    GOTO WMP_Release
    RETURN

;===========================================
; Generate_Random - reads Timer0, reduces to 0-60
; Result left in RANDNUM
;===========================================
Generate_Random:
    MOVF TMR0, W
    MOVWF RANDNUM
ModLoop:
    MOVLW .61
    SUBWF RANDNUM, W      ; W = RANDNUM - 61 ; C=1 if RANDNUM >= 61
    BTFSS STATUS, C
    GOTO ModDone          ; C=0 -> RANDNUM < 61, already in range
    MOVWF RANDNUM         ; C=1 -> RANDNUM >= 61, keep the reduced value
    GOTO ModLoop
ModDone:
    RETURN

;===========================================
; Calc_TargetHun - TARGETL/H = RANDNUM * 100
; (target expressed in hundredths)  
;===========================================
Calc_TargetHun:
    MOVF RANDNUM, W
    CALL Mult100
    MOVF MTEMPL, W
    MOVWF TARGETL
    MOVF MTEMPH, W
    MOVWF TARGETH
    RETURN

;===========================================
; Mult100 - MTEMPL/MTEMPH (16-bit) = W * 100
; (max input 60 -> max result 6000)  
;===========================================
Mult100:
    MOVWF MULTMP
    CLRF MTEMPL
    CLRF MTEMPH
    MOVLW .100
    MOVWF INDEX
Mult100Loop:
    MOVF MULTMP, W
    ADDWF MTEMPL, F
    BTFSC STATUS, C
    INCF MTEMPH, F
    DECFSZ INDEX, F
    GOTO Mult100Loop
    RETURN

;===========================================
; Sub16 : (AH:AL) - (BH:BL) -> (RH:RL)
; (two's-complement result if A < B)
;===========================================
Sub16:
    MOVF BL, W
    SUBWF AL, W
    MOVWF RL
    BTFSS STATUS, C
    GOTO Sub16Borrow
    MOVF BH, W
    SUBWF AH, W
    MOVWF RH
    RETURN
Sub16Borrow:
    MOVF BH, W
    SUBWF AH, W
    MOVWF RH
    DECF RH, F
    RETURN

;===========================================
; AbsDiff16 : (RH:RL) = | (AH:AL) - (BH:BL) |
;===========================================
AbsDiff16:
    CALL Sub16
    BTFSS RH, 7
    RETURN
    COMF RL, F
    COMF RH, F
    INCF RL, F
    BTFSC STATUS, Z
    INCF RH, F
    RETURN

;===========================================
; CompareWinner - compares D1(H:L) vs D2(H:L)
; WINNER = 0 (tie), 1 (P1 smaller delta wins),
; 2 (P2 smaller delta wins)
;===========================================
CompareWinner:
    MOVF D2H, W
    SUBWF D1H, W
    BTFSS STATUS, Z
    GOTO CW_HighDiff
    MOVF D2L, W
    SUBWF D1L, W
    BTFSC STATUS, Z
    GOTO CW_Tie
    BTFSS STATUS, C
    GOTO CW_P1
    GOTO CW_P2
CW_HighDiff:
    BTFSS STATUS, C
    GOTO CW_P1
    GOTO CW_P2
CW_Tie:
    CLRF WINNER
    RETURN
CW_P1:
    MOVLW .1
    MOVWF WINNER
    RETURN
CW_P2:
    MOVLW .2
    MOVWF WINNER
    RETURN

;===========================================
; Blink_P1 / Blink_P2 / Blink_Both
; 3x (0.25s on / 0.25s off)
;===========================================
; NOTE: blinks use Mux_Delay so the 7-segment displays keep showing the
; deltas during the whole announcement. BLINKCNT (not INDEX) counts the
; repetitions because Refresh_Digit uses INDEX internally.
; 125 mux slots x exactly 2ms = exactly 0.25s per half-period (Timer2-paced).
Blink_P1:
    BANKSEL PORTA
    MOVLW .3
    MOVWF BLINKCNT
BlinkP1Loop:
    BSF PORTA, 0
    MOVLW .125
    CALL Mux_Delay
    BCF PORTA, 0
    MOVLW .125
    CALL Mux_Delay
    DECFSZ BLINKCNT, F
    GOTO BlinkP1Loop
    RETURN

Blink_P2:
    BANKSEL PORTA
    MOVLW .3
    MOVWF BLINKCNT
BlinkP2Loop:
    BSF PORTA, 1
    MOVLW .125
    CALL Mux_Delay
    BCF PORTA, 1
    MOVLW .125
    CALL Mux_Delay
    DECFSZ BLINKCNT, F
    GOTO BlinkP2Loop
    RETURN

Blink_Both:                 ;  tie feedback: both LEDs, no score
    BANKSEL PORTA
    MOVLW .3
    MOVWF BLINKCNT
BlinkBLoop:
    BSF PORTA, 0
    BSF PORTA, 1
    MOVLW .125
    CALL Mux_Delay
    BCF PORTA, 0
    BCF PORTA, 1
    MOVLW .125
    CALL Mux_Delay
    DECFSZ BLINKCNT, F
    GOTO BlinkBLoop
    RETURN

;===========================================
; Mux_Delay - delays for W slots of EXACTLY
; 2ms each (Timer2-paced) WHILE keeping the
; 8-digit multiplex running, so the displays
; stay lit and flicker-free. Total = W x 2ms.
;===========================================
Mux_Delay:
    MOVWF MUXCNT
    BANKSEL TMR2
    CLRF TMR2               ; sync so the first slot is a full 2ms
    BCF PIR1, TMR2IF
MuxLoop:
    CALL Refresh_Digit
MD_WaitTick:
    BTFSS PIR1, TMR2IF
    GOTO MD_WaitTick
    BCF PIR1, TMR2IF
    INCF DIGIT_SEL, F
    MOVF DIGIT_SEL, W
    XORLW .8
    BTFSS STATUS, Z
    GOTO MuxNoWrap
    CLRF DIGIT_SEL
MuxNoWrap:
    DECFSZ MUXCNT, F
    GOTO MuxLoop
    RETURN

;===========================================
; Hun16_To_SecHun - converts a 16-bit value in
; hundredths (AH:AL, max 6000) into:
;   MULTMP = whole seconds (0-60)
;   AL     = remaining hundredths (0-99)
; Used to put the deltas into display format.
;===========================================
Hun16_To_SecHun:
    CLRF MULTMP
H2S_Loop:
    MOVF AH, F              ; AH != 0 -> value certainly >= 100
    BTFSS STATUS, Z
    GOTO H2S_Sub
    MOVLW .100
    SUBWF AL, W             ; C=1 if AL >= 100
    BTFSS STATUS, C
    RETURN                  ; remainder (<100) left in AL
H2S_Sub:
    MOVLW .100
    SUBWF AL, F             ; AL -= 100
    BTFSS STATUS, C
    DECF AH, F              ; borrow into high byte
    INCF MULTMP, F          ; seconds++
    GOTO H2S_Loop

;===========================================
; Refresh_Digit - lights ONE of the 8 mux'd
; digits according to DIGIT_SEL (0-7):
;   0,4 = tens of seconds
;   1,5 = ones of seconds (carries the DP)
;   2,6 = tenths
;   3,7 = hundredths
; 0-3 = Player 1, 4-7 = Player 2  
;===========================================
Refresh_Digit:
    MOVLW P1_SEC
    BTFSC DIGIT_SEL, 2
    MOVLW P2_SEC
    MOVWF FSR

    MOVF DIGIT_SEL, W
    ANDLW 0x03
    MOVWF INDEX

    BCF FLAGS, 7            ; DP off by default

    MOVF INDEX, W
    XORLW 0x00
    BTFSC STATUS, Z
    GOTO RD_Pos0
    MOVF INDEX, W
    XORLW 0x01
    BTFSC STATUS, Z
    GOTO RD_Pos1
    MOVF INDEX, W
    XORLW 0x02
    BTFSC STATUS, Z
    GOTO RD_Pos2
    GOTO RD_Pos3

RD_Pos0:
    MOVF INDF, W            ; SEC
    CALL Div10              ; tens of seconds
    MOVWF TEMP
    GOTO RD_GotValue
RD_Pos1:
    MOVF INDF, W            ; SEC
    CALL Mod10              ; ones of seconds
    MOVWF TEMP
    BSF FLAGS, 7            ; DP lives on this digit: "SS."
    GOTO RD_GotValue
RD_Pos2:
    INCF FSR, F             ; SEC -> HUN (contiguous in CBLOCK)
    MOVF INDF, W
    CALL Div10              ; tenths
    MOVWF TEMP
    GOTO RD_GotValue
RD_Pos3:
    INCF FSR, F             ; SEC -> HUN
    MOVF INDF, W
    CALL Mod10              ; hundredths
    MOVWF TEMP
RD_GotValue:

    MOVF TEMP, W
    CALL SegTable            ; W = active-HIGH 7-seg pattern for digit
    BTFSC FLAGS, 7
    IORLW 0x80               ; set DP bit if this is the "ones" digit
    XORLW 0xFF               ; invert -> active-LOW (common-anode hardware)
    MOVWF SEGTEMP

    BANKSEL PORTC
    MOVLW 0xFF
    MOVWF PORTC

    BANKSEL PORTE
    MOVF DIGIT_SEL, W
    ANDLW 0x07
    MOVWF PORTE               ; drive 74LS138 address (selects the digit)

    BANKSEL PORTC
    MOVF SEGTEMP, W
    MOVWF PORTC               ; drive segments a-g + DP

    RETURN

;===========================================
; Div10 / Mod10 - input W (0-99), output W
;===========================================
Div10:
    MOVWF MTEMPL
    CLRF MULTMP
Div10Loop:
    MOVLW .10
    SUBWF MTEMPL, W
    BTFSS STATUS, C
    GOTO Div10Done
    MOVWF MTEMPL
    INCF MULTMP, F
    GOTO Div10Loop
Div10Done:
    MOVF MULTMP, W
    RETURN

Mod10:
    MOVWF MTEMPL
Mod10Loop:
    MOVLW .10
    SUBWF MTEMPL, W
    BTFSS STATUS, C
    GOTO Mod10Done
    MOVWF MTEMPL
    GOTO Mod10Loop
Mod10Done:
    MOVF MTEMPL, W
    RETURN

;===========================================
; SegTable - input W = digit 0-9,
; output W = active-HIGH 7-seg pattern
; (bit0=a,bit1=b,...bit6=g ; bit7 reserved for DP)
;===========================================
SegTable:
    MOVWF MULTMP
    MOVF MULTMP, W
    XORLW .0
    BTFSC STATUS, Z
    RETLW 0x3F
    MOVF MULTMP, W
    XORLW .1
    BTFSC STATUS, Z
    RETLW 0x06
    MOVF MULTMP, W
    XORLW .2
    BTFSC STATUS, Z
    RETLW 0x5B
    MOVF MULTMP, W
    XORLW .3
    BTFSC STATUS, Z
    RETLW 0x4F
    MOVF MULTMP, W
    XORLW .4
    BTFSC STATUS, Z
    RETLW 0x66
    MOVF MULTMP, W
    XORLW .5
    BTFSC STATUS, Z
    RETLW 0x6D
    MOVF MULTMP, W
    XORLW .6
    BTFSC STATUS, Z
    RETLW 0x7D
    MOVF MULTMP, W
    XORLW .7
    BTFSC STATUS, Z
    RETLW 0x07
    MOVF MULTMP, W
    XORLW .8
    BTFSC STATUS, Z
    RETLW 0x7F
    RETLW 0x6F              ; 9 (default)

;===========================================
; Display_Target - splits RANDNUM into tens/ones
; digits and prints "Target: XX sec" on line 1
;===========================================
Display_Target:
    MOVF RANDNUM, W
    MOVWF ONES
    CLRF TENS
DivLoop:
    MOVLW .10
    SUBWF ONES, W
    BTFSS STATUS, C
    GOTO DivDone
    MOVWF ONES
    INCF TENS, F
    GOTO DivLoop
DivDone:

    MOVLW 0x80
    CALL Send_Command
    CALL Print_TargetLabel   ; "Target: "

    MOVF TENS, W
    ADDLW 0x30
    CALL Send_Data
    MOVF ONES, W
    ADDLW 0x30
    CALL Send_Data

    CALL Print_Sec           ; " sec    "
    RETURN

;===========================================
; Display_Score - LCD line 2: "P1:x P2:y"
;===========================================
Display_Score:
    MOVLW 0xC0
    CALL Send_Command
    MOVLW 0x50          ; 'P'
    CALL Send_Data
    MOVLW 0x31          ; '1'
    CALL Send_Data
    MOVLW 0x3A          ; ':'
    CALL Send_Data
    MOVF SCORE1, W
    ADDLW 0x30
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x50          ; 'P'
    CALL Send_Data
    MOVLW 0x32          ; '2'
    CALL Send_Data
    MOVLW 0x3A          ; ':'
    CALL Send_Data
    MOVF SCORE2, W
    ADDLW 0x30
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    RETURN

;===========================================
; Print_Ready - shown at startup
;===========================================
Print_Ready:
    MOVLW 0x80
    CALL Send_Command
    MOVLW 0x50          ; 'P'
    CALL Send_Data
    MOVLW 0x72          ; 'r'
    CALL Send_Data
    MOVLW 0x65          ; 'e'
    CALL Send_Data
    MOVLW 0x73          ; 's'
    CALL Send_Data
    MOVLW 0x73          ; 's'
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x4D          ; 'M'
    CALL Send_Data
    MOVLW 0x61          ; 'a'
    CALL Send_Data
    MOVLW 0x73          ; 's'
    CALL Send_Data
    MOVLW 0x74          ; 't'
    CALL Send_Data
    MOVLW 0x65          ; 'e'
    CALL Send_Data
    MOVLW 0x72          ; 'r'
    CALL Send_Data

    MOVLW 0xC0
    CALL Send_Command
    MOVLW 0x74          ; 't'
    CALL Send_Data
    MOVLW 0x6F          ; 'o'
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x53          ; 'S'
    CALL Send_Data
    MOVLW 0x74          ; 't'
    CALL Send_Data
    MOVLW 0x61          ; 'a'
    CALL Send_Data
    MOVLW 0x72          ; 'r'
    CALL Send_Data
    MOVLW 0x74          ; 't'
    CALL Send_Data
    RETURN

;===========================================
; Print_Winner_P1 / Print_Winner_P2
;===========================================
Print_Winner_P1:
    MOVLW 0x01          ; clear display
    CALL Send_Command
    MOVLW .2
    CALL Delay_ms
    MOVLW 0x80
    CALL Send_Command
    MOVLW 0x50          ; 'P'
    CALL Send_Data
    MOVLW 0x6C          ; 'l'
    CALL Send_Data
    MOVLW 0x61          ; 'a'
    CALL Send_Data
    MOVLW 0x79          ; 'y'
    CALL Send_Data
    MOVLW 0x65          ; 'e'
    CALL Send_Data
    MOVLW 0x72          ; 'r'
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x31          ; '1'
    CALL Send_Data
    MOVLW 0xC0
    CALL Send_Command
    MOVLW 0x57          ; 'W'
    CALL Send_Data
    MOVLW 0x69          ; 'i'
    CALL Send_Data
    MOVLW 0x6E          ; 'n'
    CALL Send_Data
    MOVLW 0x73          ; 's'
    CALL Send_Data
    MOVLW 0x21          ; '!'
    CALL Send_Data
    RETURN

Print_Winner_P2:
    MOVLW 0x01          ; clear display
    CALL Send_Command
    MOVLW .2
    CALL Delay_ms
    MOVLW 0x80
    CALL Send_Command
    MOVLW 0x50          ; 'P'
    CALL Send_Data
    MOVLW 0x6C          ; 'l'
    CALL Send_Data
    MOVLW 0x61          ; 'a'
    CALL Send_Data
    MOVLW 0x79          ; 'y'
    CALL Send_Data
    MOVLW 0x65          ; 'e'
    CALL Send_Data
    MOVLW 0x72          ; 'r'
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x32          ; '2'
    CALL Send_Data
    MOVLW 0xC0
    CALL Send_Command
    MOVLW 0x57          ; 'W'
    CALL Send_Data
    MOVLW 0x69          ; 'i'
    CALL Send_Data
    MOVLW 0x6E          ; 'n'
    CALL Send_Data
    MOVLW 0x73          ; 's'
    CALL Send_Data
    MOVLW 0x21          ; '!'
    CALL Send_Data
    RETURN

;===========================================
; Print_TargetLabel - prints "Target: "
;===========================================
Print_TargetLabel:
    MOVLW 0x54          ; 'T'
    CALL Send_Data
    MOVLW 0x61          ; 'a'
    CALL Send_Data
    MOVLW 0x72          ; 'r'
    CALL Send_Data
    MOVLW 0x67          ; 'g'
    CALL Send_Data
    MOVLW 0x65          ; 'e'
    CALL Send_Data
    MOVLW 0x74          ; 't'
    CALL Send_Data
    MOVLW 0x3A          ; ':'
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    RETURN

;===========================================
; Print_Sec - prints " sec   "
;===========================================
Print_Sec:
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x73          ; 's'
    CALL Send_Data
    MOVLW 0x65          ; 'e'
    CALL Send_Data
    MOVLW 0x63          ; 'c'
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    MOVLW 0x20          ; ' '
    CALL Send_Data
    RETURN

;===========================================
; LCD_Init - Initialize LCD in 4-bit mode
;===========================================
LCD_Init:
    MOVLW .15
    CALL Delay_ms

    MOVLW 0x30
    CALL Send_Nibble
    MOVLW .5
    CALL Delay_ms

    MOVLW 0x30
    CALL Send_Nibble
    MOVLW .1
    CALL Delay_100us

    MOVLW 0x30
    CALL Send_Nibble
    MOVLW .1
    CALL Delay_100us

    MOVLW 0x20
    CALL Send_Nibble
    MOVLW .1
    CALL Delay_100us

    MOVLW 0x28        ; 4-bit, 2 lines
    CALL Send_Command

    MOVLW 0x0C        ; Display on, cursor off
    CALL Send_Command

    MOVLW 0x01        ; Clear display
    CALL Send_Command
    MOVLW .2
    CALL Delay_ms

    MOVLW 0x06        ; Entry mode
    CALL Send_Command

    RETURN

;===========================================
; Send_Nibble - Sends ONLY the upper nibble of W
;===========================================
Send_Nibble:
    BANKSEL PORTD
    MOVWF TEMP
    BCF PORTD, 0

    BCF PORTD, 2
    BTFSC TEMP, 4
    BSF PORTD, 2
    BCF PORTD, 3
    BTFSC TEMP, 5
    BSF PORTD, 3
    BCF PORTD, 4
    BTFSC TEMP, 6
    BSF PORTD, 4
    BCF PORTD, 5
    BTFSC TEMP, 7
    BSF PORTD, 5

    BSF PORTD, 1
    NOP
    NOP
    BCF PORTD, 1
    RETURN

;===========================================
; Send_Command - Send command to LCD (RS = 0)
;===========================================
Send_Command:
    BANKSEL PORTD
    MOVWF TEMP
    BCF PORTD, 0

    BCF PORTD, 2
    BTFSC TEMP, 4
    BSF PORTD, 2
    BCF PORTD, 3
    BTFSC TEMP, 5
    BSF PORTD, 3
    BCF PORTD, 4
    BTFSC TEMP, 6
    BSF PORTD, 4
    BCF PORTD, 5
    BTFSC TEMP, 7
    BSF PORTD, 5

    BSF PORTD, 1
    NOP
    NOP
    BCF PORTD, 1

    BCF PORTD, 2
    BTFSC TEMP, 0
    BSF PORTD, 2
    BCF PORTD, 3
    BTFSC TEMP, 1
    BSF PORTD, 3
    BCF PORTD, 4
    BTFSC TEMP, 2
    BSF PORTD, 4
    BCF PORTD, 5
    BTFSC TEMP, 3
    BSF PORTD, 5

    BSF PORTD, 1
    NOP
    NOP
    BCF PORTD, 1

    MOVLW .2
    CALL Delay_100us
    RETURN

;===========================================
; Send_Data - Send data to LCD (RS = 1)
;===========================================
Send_Data:
    BANKSEL PORTD
    MOVWF TEMP
    BSF PORTD, 0

    BCF PORTD, 2
    BTFSC TEMP, 4
    BSF PORTD, 2
    BCF PORTD, 3
    BTFSC TEMP, 5
    BSF PORTD, 3
    BCF PORTD, 4
    BTFSC TEMP, 6
    BSF PORTD, 4
    BCF PORTD, 5
    BTFSC TEMP, 7
    BSF PORTD, 5

    BSF PORTD, 1
    NOP
    NOP
    BCF PORTD, 1

    BCF PORTD, 2
    BTFSC TEMP, 0
    BSF PORTD, 2
    BCF PORTD, 3
    BTFSC TEMP, 1
    BSF PORTD, 3
    BCF PORTD, 4
    BTFSC TEMP, 2
    BSF PORTD, 4
    BCF PORTD, 5
    BTFSC TEMP, 3
    BSF PORTD, 5

    BSF PORTD, 1
    NOP
    NOP
    BCF PORTD, 1

    MOVLW .2
    CALL Delay_100us
    RETURN

;===========================================
; Delay_100us - 100us delay (4MHz)
;===========================================
Delay_100us:
    MOVLW .50
    MOVWF DELAY1
D100:
    NOP
    DECFSZ DELAY1, F
    GOTO D100
    RETURN

;===========================================
; Delay_ms - Millisecond delay
;===========================================
Delay_ms:
    MOVWF DELAY3
DMS1:
    MOVLW .250
    MOVWF DELAY2
DMS2:
    NOP
    DECFSZ DELAY2, F
    GOTO DMS2
    DECFSZ DELAY3, F
    GOTO DMS1
    RETURN

    END