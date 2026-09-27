;===============================================================================
; SPC700 スタンドアロン一曲再生サウンドドライバ
;===============================================================================

arch spc700
norom
org $0200

;-------------------------------------------------------------------------------
; メモリマップ・定数定義
;-------------------------------------------------------------------------------

;--- ゼロページ ($0000-$003F) ---------------------------------------------------
TRK_PTR_L       = $00     ; +0 uint16 ptr (Low)
TRK_PTR_H       = $01     ; +1          (High)
TRK_WAIT        = $02     ; +2 uint8  wait_ticks
TRK_INST        = $03     ; +3 uint8  inst_id
TRK_VOL_L       = $04     ; +4 uint8  volume_l
TRK_VOL_R       = $05     ; +5 uint8  volume_r
TRK_FLAGS       = $06     ; +6 uint8  flags (Bit0: 再生中/停止)
TRK_RESERVED    = $07     ; +7 予約

NUM_TRACKS      = 8

;--- APU ハードウェア I/O レジスタ ($00F0-$00FF) --------------------------------
TEST            = $F0
CONTROL         = $F1
DSPADDR         = $F2
DSPDATA         = $F3
CPUIO0          = $F4
CPUIO1          = $F5
CPUIO2          = $F6
CPUIO3          = $F7
AUXIO0          = $F8
AUXIO1          = $F9
T0DIV           = $FA     ; Timer0 分周値
T1DIV           = $FB
T2DIV           = $FC
T0OUT           = $FD     ; Timer0 カウンタ
T1OUT           = $FE
T2OUT           = $FF

;--- DSPレジスタ (DSPADDR/DSPDATA経由でアクセス) --------------------------------
DSP_MVOL_L      = $0C
DSP_MVOL_R      = $1C
DSP_DIR         = $5D
DSP_FLG         = $6C
DSP_KON         = $4C
DSP_KOFF        = $5C

; チャンネル毎レジスタオフセット
DSP_CH_VOLL     = $00
DSP_CH_VOLR     = $01
DSP_CH_PITCHL   = $02
DSP_CH_PITCHH   = $03
DSP_CH_SRCN     = $04
DSP_CH_ADSR1    = $05
DSP_CH_ADSR2    = $06
DSP_CH_GAIN     = $07

;--- ワークエリア変数 -----------------------------------------------------------
CUR_TRACK       = $40     ; 走査中トラック番号
TEMP0           = $41
TEMP1           = $42
TEMP2           = $43
SEQ_PTR_L       = $44     ; シーケンス間接読み込み用ポインタ (Low)
SEQ_PTR_H       = $45     ; シーケンス間接読み込み用ポインタ (High)
DSP_BASE        = $46     ; DSPチャンネル計算用ベースアドレス

;--- テーブル配置アドレス -------------------------------------------------------
ADDR_DIR_TABLE  = $0400   ; DIRテーブル ($0400-$047F)
ADDR_INST_TABLE = $0480   ; 音色パラメータテーブル ($0480-$04FF)

INST_SRCN       = $00
INST_ADSR1      = $01
INST_ADSR2      = $02
INST_PITCHOFS   = $03


;===============================================================================
; エントリポイント ($0200)
;===============================================================================

Start:
        clrp                    ; Direct Page = $0000-$00FF に設定

        ; --- 1. スタックポインタ初期化 ($01FF) ---
        mov     x, #$FF
        mov     sp, x

        ; --- ゼロページ ワークエリアのクリア ($00-$46) ---
        mov     a, #$00
        mov     x, #$00
ClearZP:
        mov     $00+x, a
        inc     x
        cmp     x, #$47
        bne     ClearZP

        ; --- 2. DSPレジスタ初期化 ---

        ; マスターボリューム L/R -> 127
        mov     a, #DSP_MVOL_L
        mov     DSPADDR, a
        mov     a, #$7F
        mov     DSPDATA, a

        mov     a, #DSP_MVOL_R
        mov     DSPADDR, a
        mov     a, #$7F
        mov     DSPDATA, a

        ; DIRアドレス -> $04 ($0400 = $04 << 8)
        mov     a, #DSP_DIR
        mov     DSPADDR, a
        mov     a, #$04
        mov     DSPDATA, a

        ; FLGレジスタ -> $00 (ミュート解除・エコー禁止)
        mov     a, #DSP_FLG
        mov     DSPADDR, a
        mov     a, #$00
        mov     DSPDATA, a

        ; 全チャンネル KOFF
        mov     a, #DSP_KOFF
        mov     DSPADDR, a
        mov     a, #$FF
        mov     DSPDATA, a

        ; --- 3. トラック構造体の初期化 ---
        mov     y, #$00                 ; Y = トラックインデックス (0-7)
InitTrackLoop:
        mov     a, y
        mov     TEMP0, a
        asl     a                       ; A = Y * 2 (テーブル参照用)
        mov     x, a

        mov     a, SeqTrackTable+x
        mov     TEMP1, a
        mov     a, SeqTrackTable+1+x
        mov     TEMP2, a

        mov     a, TEMP0
        asl     a
        asl     a
        asl     a                       ; A = Y * 8 (構造体オフセット)
        mov     x, a

        mov     a, TEMP1
        mov     TRK_PTR_L+x, a
        mov     a, TEMP2
        mov     TRK_PTR_H+x, a

        mov     a, #$00
        mov     TRK_WAIT+x, a           ; wait_ticks = 0
        mov     a, #$FF
        mov     TRK_INST+x, a           ; inst_id = 未設定
        mov     a, #$7F
        mov     TRK_VOL_L+x, a          ; volume_l = 127
        mov     TRK_VOL_R+x, a          ; volume_r = 127
        mov     a, #$01
        mov     TRK_FLAGS+x, a          ; flags = 再生中 (Bit0=1)

        mov     a, TEMP0
        mov     y, a
        inc     y
        cmp     y, #NUM_TRACKS
        bne     InitTrackLoop

        ; --- 4. Timer0 起動 (64Hz周期: 8000Hz / 125) ---
        mov     a, #$00
        mov     CONTROL, a              ; タイマー停止

        mov     a, #125
        mov     T0DIV, a                ; 分周値 125

        mov     a, CONTROL
        or      a, #$01                 ; Timer0 Enable
        mov     CONTROL, a

        mov     a, T0OUT                ; カウンタ初期クリア

;-------------------------------------------------------------------------------
; メインループ
;-------------------------------------------------------------------------------
MainLoop:
        mov     a, T0OUT                ; Timer0カウントチェック
        beq     MainLoop                ; 0なら待機

CallUpdate:
        call    UpdateSequencer
        bra     MainLoop


;===============================================================================
; UpdateSequencer : 全トラックのシーケンス更新
;===============================================================================
UpdateSequencer:
        mov     y, #$00                 ; トラック番号 0-7
UpdateTrackLoop:
        mov     a, y
        mov     CUR_TRACK, a

        asl     a
        asl     a
        asl     a                       ; A = トラック番号 * 8
        mov     x, a                    ; X = ゼロページオフセット

        ; 再生中フラグチェック
        mov     a, TRK_FLAGS+x
        and     a, #$01
        bne     +
        jmp     NextTrack
+
        ; wait_ticks チェック
        mov     a, TRK_WAIT+x
        beq     ParseEvents
        dec     a
        mov     TRK_WAIT+x, a
        jmp     NextTrack

ParseEvents:
ParseLoop:
        ; ポインタを SEQ_PTR に転送
        mov     a, TRK_PTR_L+x
        mov     SEQ_PTR_L, a
        mov     a, TRK_PTR_H+x
        mov     SEQ_PTR_H, a

        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y        ; バイトコード読み込み

        ; --- バイトコード分岐 ---
        cmp     a, #$80
        bcs     NotNoteOn

        ; ===== 0x00-0x7F : Note On =====
        mov     TEMP2, a                ; ノート番号
        call    AdvanceSeqPtr

        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y        ; 音長
        mov     TRK_WAIT+x, a
        call    AdvanceSeqPtr

        mov     a, TEMP2
        call    DoNoteOn
        jmp     ParseDone

NotNoteOn:
        cmp     a, #$BE
        bcc     IsWaitEvent

        beq     IsSetInstrument

        cmp     a, #$BF
        beq     IsSetVolume

        cmp     a, #$C0
        beq     IsJump

        cmp     a, #$FF
        beq     IsEndOfTrack

        ; 未定義コードのスキップ
        call    AdvanceSeqPtr
        jmp     ParseLoop

; ----- 0x80-0xBD : Wait / Rest -----
IsWaitEvent:
        mov     TEMP2, a
        call    AdvanceSeqPtr

        mov     a, TEMP2
        clrc
        sbc     a, #$80
        inc     a
        mov     TRK_WAIT+x, a
        jmp     ParseDone

; ----- 0xBE : Set Instrument -----
IsSetInstrument:
        call    AdvanceSeqPtr
        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y
        mov     TRK_INST+x, a
        call    AdvanceSeqPtr
        jmp     ParseLoop

; ----- 0xBF : Set Volume -----
IsSetVolume:
        call    AdvanceSeqPtr
        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y
        mov     TRK_VOL_L+x, a
        call    AdvanceSeqPtr

        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y
        mov     TRK_VOL_R+x, a
        call    AdvanceSeqPtr

        call    ApplyVolumeToDSP
        jmp     ParseLoop

; ----- 0xC0 : Jump -----
IsJump:
        call    AdvanceSeqPtr
        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y
        mov     TEMP0, a
        call    AdvanceSeqPtr

        mov     y, #$00
        mov     a, (SEQ_PTR_L)+y
        mov     TEMP1, a

        mov     a, TEMP0
        mov     TRK_PTR_L+x, a
        mov     a, TEMP1
        mov     TRK_PTR_H+x, a
        jmp     ParseLoop

; ----- 0xFF : End of Track -----
IsEndOfTrack:
        mov     a, TRK_FLAGS+x
        and     a, #$FE                 ; Bit0クリア
        mov     TRK_FLAGS+x, a
        jmp     ParseDone

ParseDone:
NextTrack:
        mov     a, CUR_TRACK
        inc     a
        cmp     a, #NUM_TRACKS
        mov     y, a
        beq     +
        jmp     UpdateTrackLoop
+
        ret


;-------------------------------------------------------------------------------
; AdvanceSeqPtr : シーケンスポインタ更新 (+1)
;-------------------------------------------------------------------------------
AdvanceSeqPtr:
        mov     a, SEQ_PTR_L
        inc     a
        mov     SEQ_PTR_L, a
        mov     a, TRK_PTR_L+x
        inc     a
        mov     TRK_PTR_L+x, a
        bne     AdvanceSeqPtrDone
        mov     a, SEQ_PTR_H
        inc     a
        mov     SEQ_PTR_H, a
        mov     a, TRK_PTR_H+x
        inc     a
        mov     TRK_PTR_H+x, a
AdvanceSeqPtrDone:
        ret


;===============================================================================
; 発音制御サブルーチン
;===============================================================================

;-------------------------------------------------------------------------------
; DoNoteOn : ノートオン処理
;-------------------------------------------------------------------------------
DoNoteOn:
        mov     TEMP0, a                ; TEMP0 = ノート番号

        ; DSP チャンネルベース計算
        mov     a, CUR_TRACK
        asl     a
        asl     a
        asl     a
        asl     a
        mov     DSP_BASE, a             ; DSP_BASE = CH * 16

        ; Volume L/R
        mov     a, DSP_BASE
        or      a, #DSP_CH_VOLL
        mov     DSPADDR, a
        mov     a, TRK_VOL_L+x
        mov     DSPDATA, a

        mov     a, DSP_BASE
        or      a, #DSP_CH_VOLR
        mov     DSPADDR, a
        mov     a, TRK_VOL_R+x
        mov     DSPDATA, a

        ; 音色インデックス計算 (inst_id * 4 -> X)
        mov     a, TRK_INST+x
        asl     a
        asl     a
        mov     x, a

        ; SRCN / ADSR1 / ADSR2 設定
        mov     a, DSP_BASE
        or      a, #DSP_CH_SRCN
        mov     DSPADDR, a
        mov     a, ADDR_INST_TABLE+INST_SRCN+x
        mov     DSPDATA, a

        mov     a, DSP_BASE
        or      a, #DSP_CH_ADSR1
        mov     DSPADDR, a
        mov     a, ADDR_INST_TABLE+INST_ADSR1+x
        mov     DSPDATA, a

        mov     a, DSP_BASE
        or      a, #DSP_CH_ADSR2
        mov     DSPADDR, a
        mov     a, ADDR_INST_TABLE+INST_ADSR2+x
        mov     DSPDATA, a

        ; ピッチ計算 (ノート番号 + オフセット)
        mov     a, TEMP0
        clrc
        adc     a, ADDR_INST_TABLE+INST_PITCHOFS+x

        call    NoteToPitch             ; A -> TEMP0(PitchL), TEMP1(PitchH)

        mov     a, DSP_BASE
        or      a, #DSP_CH_PITCHL
        mov     DSPADDR, a
        mov     a, TEMP0
        mov     DSPDATA, a

        mov     a, DSP_BASE
        or      a, #DSP_CH_PITCHH
        mov     DSPADDR, a
        mov     a, TEMP1
        mov     DSPDATA, a

        ; Key On 発行
        mov     a, #$01
        mov     y, CUR_TRACK
        beq     KonShiftDone
KonShiftLoop:
        asl     a
        dec     y
        bne     KonShiftLoop
KonShiftDone:
        mov     TEMP0, a

        mov     a, #DSP_KON
        mov     DSPADDR, a
        mov     a, TEMP0
        mov     DSPDATA, a

        ret


;-------------------------------------------------------------------------------
; ApplyVolumeToDSP : ボリューム即時反映
;-------------------------------------------------------------------------------
ApplyVolumeToDSP:
        mov     a, CUR_TRACK
        asl     a
        asl     a
        asl     a
        asl     a
        mov     DSP_BASE, a

        mov     a, DSP_BASE
        or      a, #DSP_CH_VOLL
        mov     DSPADDR, a
        mov     a, TRK_VOL_L+x
        mov     DSPDATA, a

        mov     a, DSP_BASE
        or      a, #DSP_CH_VOLR
        mov     DSPADDR, a
        mov     a, TRK_VOL_R+x
        mov     DSPDATA, a
        ret


;-------------------------------------------------------------------------------
; NoteToPitch : ピッチ変換
;-------------------------------------------------------------------------------
NoteToPitch:
        mov     TEMP2, a

        mov     y, #$00                 ; オクターブ
DivLoop:
        mov     a, TEMP2
        cmp     a, #12
        bcc     DivDone
        clrc
        sbc     a, #12
        mov     TEMP2, a
        inc     y
        bra     DivLoop
DivDone:
        mov     a, TEMP2
        asl     a
        mov     x, a                    ; X = 半音オフセット

        mov     a, PitchTableBase+x
        mov     TEMP0, a
        mov     a, PitchTableBase+1+x
        mov     TEMP1, a

        mov     a, y
        clrc
        sbc     a, #4                   ; 基準オクターブ = 4
        beq     PitchDone
        bmi     ShiftRightLoop

ShiftLeftLoop:
        asl     TEMP0
        rol     TEMP1
        dec     a
        bne     ShiftLeftLoop
        bra     PitchDone

ShiftRightLoop:
        lsr     TEMP1
        ror     TEMP0
        inc     a
        bne     ShiftRightLoop

PitchDone:
        ret


;===============================================================================
; テーブルデータ
;===============================================================================

SeqTrackTable:
        dw      Track0Data
        dw      Track1Data
        dw      Track2Data
        dw      Track3Data
        dw      Track4Data
        dw      Track5Data
        dw      Track6Data
        dw      Track7Data

PitchTableBase:
        dw      $085F           ; C
        dw      $08E6           ; C#
        dw      $0977           ; D
        dw      $0A14           ; D#
        dw      $0AB8           ; E
        dw      $0B66           ; F
        dw      $0C1E           ; F#
        dw      $0CE1           ; G
        dw      $0DAF           ; G#
        dw      $0E89           ; A
        dw      $0F6F           ; A#
        dw      $1000           ; B


;===============================================================================
; DIR テーブル ($0400-$047F)
;===============================================================================
org $0400
DirTable:
        dw      Sample0Start, Sample0Loop
        fillbyte $00 : fill $78


;===============================================================================
; 音色パラメータテーブル ($0480-$04FF)
;===============================================================================
org $0480
InstTable:
        db      $00, $8F, $E0, $00     ; 音色0: SRCN=0, ADSR1, ADSR2, PitchOffset
        fillbyte $00 : fill $7C


;===============================================================================
; シーケンス & 波形データ ($0500~)
;===============================================================================
org $0500

Track0Data:
        db      $BE, $00                ; Set Inst 0
        db      $BF, $7F, $7F           ; Set Vol L127 R127
        db      $3C, $30                ; Note On (C5, len=48)
        db      $3E, $30                ; Note On (D5, len=48)
        db      $C0 : dw Track0Data     ; Jump Loop

Track1Data:
        db      $FF
Track2Data:
        db      $FF
Track3Data:
        db      $FF
Track4Data:
        db      $FF
Track5Data:
        db      $FF
Track6Data:
        db      $FF
Track7Data:
        db      $FF

Sample0Start:
        db      $00
        fillbyte $00 : fill $08
Sample0Loop:
        fillbyte $00 : fill $08
