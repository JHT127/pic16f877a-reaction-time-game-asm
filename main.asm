;===========================================================================
; Two-Player Reaction Time Matching Game - PIC16F877A
;===========================================================================
; PIN MAP / HARDWARE CONNECTIONS
;---------------------------------------------------------------------------
; LCD (16x2, 4-bit mode)        : RS=RD0, EN=RD1, D4-D7=RD2-RD5  (unchanged)
;
; Push buttons (each: pin->GND when pressed, +5V through 10K to pin when idle)
;   Master button (Judge)       : RB0
;   Player 1 button              : RB1
;   Player 2 button              : RB2
;
; Indicator LEDs (each: pin -> 220ohm resistor -> LED -> GND)
;   Player 1 LED                : RA0
;   Player 2 LED                : RA1
;
; 7-segment displays (TWO 4-digit common-ANODE modules, multiplexed)
;   Segments a-g                : RC0-RC6  -> 220ohm resistors -> shared
;                                  segment bus on BOTH displays (a-a,b-b,...)
;   Decimal point (DP)          : RC7      -> 220ohm resistor -> shared DP bus
;   Digit select address        : RE0,RE1,RE2 -> inputs A,B,C of a 74LS138
;                                  3-to-8 decoder (G1 tied to +5V, G2A/G2B
;                                  tied to GND so it is always enabled)
;   74LS138 outputs Y0-Y7 (active LOW) -> each through a base resistor
;                                  (~2.2K) to a PNP transistor (2N3906):
;                                    emitter  -> +5V
;                                    collector-> common-anode pin of ONE digit
;                                  Y0-Y3 -> Player 1 display digits 1-4
;                                  Y4-Y7 -> Player 2 display digits 1-4
;                                  (digit 1 = leftmost/leading zero,
;                                   digit 3 = "ones" digit, carries the DP)
;
; Oscillator: 4MHz crystal + 2x15pF caps (already in your schematic)
; MCLR: 10K pull-up to +5V (already in your schematic)
; ADCON1 is set to 0x07 so RA0/RA1/RE0-RE2 are configured as DIGITAL I/O
; (they default to analog inputs on this chip, so this step is required!)
;---------------------------------------------------------------------------
; GAME FLOW
;   1. Press master button  -> random target (0-60s) generated & shown on LCD
;   2. Both LEDs turn ON for 1s ("get set"), then OFF = GO signal
;   3. Both player displays count 00.0 -> up in tenths of a second
;   4. Each player presses their button to stop their own timer
;      (if a player never presses, their timer auto-stops at 60.0s)
;   5. Winner = whichever player's stopped time is closest to the target
;      (ties: nobody scores, LEDs stay off)
;   6. Winner's LED blinks 3x (0.25s on / 0.25s off), score is updated,
;      score shown on LCD line 2
;   7. First to 5 points -> "Wins the Game!" shown, press master to restart
;===========================================================================

    LIST P=16F877A
    #INCLUDE <P16F877A.INC>

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

        P1_SEC          ; Player 1 elapsed whole seconds (0-60)
        P1_TENTH        ; Player 1 elapsed tenths (0-9)
        P2_SEC          ; Player 2 elapsed whole seconds (0-60)
        P2_TENTH        ; Player 2 elapsed tenths (0-9)

        FLAGS           ; bit0=P1_DONE, bit1=P2_DONE, bit7=DP_ON(scratch)
        DIGIT_SEL       ; which of the 8 multiplexed digits is lit (0-7)
        SCANCOUNT       ; counts refresh passes to time each 0.1s tick

        TARGETL         ; target time in tenths of a second (16-bit), low
        TARGETH         ; target time in tenths of a second (16-bit), high
        P1L, P1H        ; Player 1 total time in tenths (16-bit)
        P2L, P2H        ; Player 2 total time in tenths (16-bit)
        D1L, D1H        ; |target - P1| in tenths (16-bit)
        D2L, D2H        ; |target - P2| in tenths (16-bit)

        AL, AH          ; generic 16-bit subtract operand A
        BL, BH          ; generic 16-bit subtract operand B
        RL, RH          ; generic 16-bit subtract result

        MTEMPL, MTEMPH  ; scratch 16-bit accumulator (Mult10)
        MULTMP          ; scratch byte (Mult10 / SegTable / Div10 / Mod10)
        SEGTEMP         ; final segment pattern about to be sent to PORTC
        WINNER          ; 0 = tie, 1 = Player1, 2 = Player2
    ENDC

    ORG 0x00
    GOTO START

;===========================================
; Main program
;===========================================
START:
    BANKSEL TRISD
    CLRF TRISD            ; Port D as output (LCD)

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

    BANKSEL PORTD           ; <-- back to Bank 0 for everything below
    CLRF PORTD
    CLRF PORTA
    CLRF PORTC
    CLRF PORTE
    CLRF TMR0               ; Timer0 starts free-running from 0
    CLRF SCORE1
    CLRF SCORE2

    CALL LCD_Init
    CALL Print_Ready

;===========================================
; GameLoop - one full round per pass
;===========================================
GameLoop:
    CALL WaitMasterPress    ; block here until judge presses & releases RB0

    CALL Generate_Random    ; RANDNUM = 0-60 (whole seconds)
    CALL Display_Target     ; LCD line1: "Target: XX sec"
    CALL Calc_TargetTenths  ; TARGETL/H = RANDNUM * 10

    BANKSEL PORTA
    BCF PORTA, 0            ; LEDs off during "ready" moment
    BCF PORTA, 1
    MOVLW .200
    CALL Delay_ms           ; brief pause so players can get set

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
    CLRF P1_TENTH
    CLRF P2_SEC
    CLRF P2_TENTH
    CLRF FLAGS
    CLRF DIGIT_SEL
    CLRF SCANCOUNT

;===========================================
; CountLoop - runs the multiplexed displays,
; polls both player buttons, and advances
; each player's timer roughly every 0.1s
;===========================================
CountLoop:
    CALL Refresh_Digit
    MOVLW .2
    CALL Delay_ms           ; ~2ms per digit -> ~16ms/8-digit cycle (no flicker)

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
    BTFSC PORTB, 1
    GOTO CheckP2Btn
    BSF FLAGS, 0

CheckP2Btn:
    BTFSC FLAGS, 1
    GOTO TickTimers
    BANKSEL PORTB
    BTFSC PORTB, 2
    GOTO TickTimers
    BSF FLAGS, 1

TickTimers:
    INCF SCANCOUNT, F
    MOVF SCANCOUNT, W
    XORLW .50               ; ~50 passes x ~2ms =~ 0.1s per tick
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
; advance one player's SEC/TENTH by 0.1s;
; auto-stop (mark done) if 60.0s is reached
; (edge case: player never pressed button)
;===========================================
Increment_P1:
    INCF P1_TENTH, F
    MOVF P1_TENTH, W
    XORLW .10
    BTFSS STATUS, Z
    RETURN
    CLRF P1_TENTH
    INCF P1_SEC, F
    MOVF P1_SEC, W
    XORLW .61
    BTFSS STATUS, Z
    RETURN
    MOVLW .60
    MOVWF P1_SEC
    CLRF P1_TENTH
    BSF FLAGS, 0
    RETURN

Increment_P2:
    INCF P2_TENTH, F
    MOVF P2_TENTH, W
    XORLW .10
    BTFSS STATUS, Z
    RETURN
    CLRF P2_TENTH
    INCF P2_SEC, F
    MOVF P2_SEC, W
    XORLW .61
    BTFSS STATUS, Z
    RETURN
    MOVLW .60
    MOVWF P2_SEC
    CLRF P2_TENTH
    BSF FLAGS, 1
    RETURN

;===========================================
; RoundResolve - both players stopped:
; compute deltas, pick winner, blink LED,
; update score, check for game-over
;===========================================
RoundResolve:
    ; ---- P1L/P1H = P1_SEC*10 + P1_TENTH ----
    MOVF P1_SEC, W
    CALL Mult10
    MOVF P1_TENTH, W
    ADDWF MTEMPL, F
    BTFSC STATUS, C
    INCF MTEMPH, F
    MOVF MTEMPL, W
    MOVWF P1L
    MOVF MTEMPH, W
    MOVWF P1H

    ; ---- P2L/P2H = P2_SEC*10 + P2_TENTH ----
    MOVF P2_SEC, W
    CALL Mult10
    MOVF P2_TENTH, W
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

    CALL CompareWinner     ; WINNER = 0(tie)/1(P1)/2(P2)

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
    CALL WaitMasterPress
    CLRF SCORE1
    CLRF SCORE2
    CALL Print_Ready
    GOTO GameLoop

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
; Calc_TargetTenths - TARGETL/H = RANDNUM * 10
;===========================================
Calc_TargetTenths:
    MOVF RANDNUM, W
    CALL Mult10
    MOVF MTEMPL, W
    MOVWF TARGETL
    MOVF MTEMPH, W
    MOVWF TARGETH
    RETURN

;===========================================
; Mult10 - MTEMPL/MTEMPH (16-bit) = W * 10
;===========================================
Mult10:
    MOVWF MULTMP
    CLRF MTEMPL
    CLRF MTEMPH
    MOVLW .10
    MOVWF INDEX
Mult10Loop:
    MOVF MULTMP, W
    ADDWF MTEMPL, F
    BTFSC STATUS, C
    INCF MTEMPH, F
    DECFSZ INDEX, F
    GOTO Mult10Loop
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
; Blink_P1 / Blink_P2 - 3x (0.25s on/0.25s off)
;===========================================
Blink_P1:
    BANKSEL PORTA
    MOVLW .3
    MOVWF INDEX
BlinkP1Loop:
    BSF PORTA, 0
    MOVLW .250
    CALL Delay_ms
    BCF PORTA, 0
    MOVLW .250
    CALL Delay_ms
    DECFSZ INDEX, F
    GOTO BlinkP1Loop
    RETURN

Blink_P2:
    BANKSEL PORTA
    MOVLW .3
    MOVWF INDEX
BlinkP2Loop:
    BSF PORTA, 1
    MOVLW .250
    CALL Delay_ms
    BCF PORTA, 1
    MOVLW .250
    CALL Delay_ms
    DECFSZ INDEX, F
    GOTO BlinkP2Loop
    RETURN

;===========================================
; Refresh_Digit - lights ONE of the 8 mux'd
; digits according to DIGIT_SEL (0-7):
;   0,4 = leading digit (always '0')
;   1,5 = tens of seconds
;   2,6 = ones of seconds (carries the DP)
;   3,7 = tenths of a second
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
    CLRF TEMP
    GOTO RD_GotValue
RD_Pos1:
    MOVF INDF, W
    CALL Div10
    MOVWF TEMP
    GOTO RD_GotValue
RD_Pos2:
    MOVF INDF, W
    CALL Mod10
    MOVWF TEMP
    BSF FLAGS, 7
    GOTO RD_GotValue
RD_Pos3:
    INCF FSR, F              ; SEC -> TENTH (contiguous in CBLOCK)
    MOVF INDF, W
    MOVWF TEMP
RD_GotValue:

    MOVF TEMP, W
    CALL SegTable            ; W = active-HIGH 7-seg pattern for digit
    BTFSC FLAGS, 7
    IORLW 0x80               ; set DP bit if this is the "ones" digit
    XORLW 0xFF                ; invert -> active-LOW (common-anode hardware)
    MOVWF SEGTEMP

    BANKSEL PORTE
    MOVF DIGIT_SEL, W
    ANDLW 0x07
    MOVWF PORTE               ; drive 74LS138 address (selects the digit)

    BANKSEL PORTC
    MOVF SEGTEMP, W
    MOVWF PORTC               ; drive segments a-g + DP

    RETURN

;===========================================
; Div10 / Mod10 - input W (0-60), output W
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
; Print_Ready - shown at startup / after a game
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