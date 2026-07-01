        LIST      P=16F877A
        #INCLUDE  <P16F877A.INC>

        __CONFIG  _CP_OFF & _DEBUG_OFF & _WRT_OFF & _CPD_OFF & _LVP_OFF & _BOREN_ON & _PWRTE_ON & _WDT_OFF & _XT_OSC

        ORG     0x0000
        GOTO    START

START

        ; Ã„Ì⁄ «·√—Ã· Digital
        BANKSEL ADCON1
        MOVLW   0x06
        MOVWF   ADCON1

        ; Ã„Ì⁄ «·„‰«›– Output
        BANKSEL TRISA
        CLRF    TRISA
        CLRF    TRISB
        CLRF    TRISE

        ;  ’›Ì— «·„‰«›–
        BANKSEL PORTA
        CLRF    PORTA
        CLRF    PORTB
        CLRF    PORTE

        ;==========================
        ; BCD = 3
        ; RA2 = bit0 = 1
        ; RA3 = bit1 = 1
        ; RA5 = bit2 = 0
        ; RE0 = bit3 = 0
        ;==========================

        BSF     PORTA,2
        BSF     PORTA,3
        BCF     PORTA,5
        BCF     PORTE,0

        ;==========================
        ;  ‘€Ì· Digit1 ›ﬁÿ
        ;==========================

        BSF     PORTB,4

LOOP
        GOTO LOOP

        END