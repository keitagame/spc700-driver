;===============================================================================
; SPC700 スタンドアロン一曲再生サウンドドライバ
;
; 仕様書「SPC700_Standalone_Sound_Driver_Specification.txt」準拠
; 65816側とのIPC無し。APU RAM転送後、自律的にBGM再生を開始する。
;
; アセンブラ: SPC700ニーモニック (WLA-DX / Asar系記法に準拠)
;===============================================================================

;-------------------------------------------------------------------------------
; 2. メモリマップ定義
;-------------------------------------------------------------------------------
.MEMORYMAP
    ; 実機ではAPU RAM 64KBがフラットな1バンク
.ENDME

;--- ゼロページ ($0000-$003F) ---------------------------------------------------
.DEFINE ZP_BASE         $00

; トラック管理構造体 (1トラック8byte, CH0-CH7で計64byte = $00-$3F)
.DEFINE TRACK_SIZE      $08
.DEFINE TRK_PTR_L       $00     ; +0 uint16 ptr (Low)
.DEFINE TRK_PTR_H       $01     ; +1          (High)
.DEFINE TRK_WAIT        $02     ; +2 uint8  wait_ticks
.DEFINE TRK_INST        $03     ; +3 uint8  inst_id
.DEFINE TRK_VOL_L       $04     ; +4 uint8  volume_l
.DEFINE TRK_VOL_R       $05     ; +5 uint8  volume_r
.DEFINE TRK_FLAGS       $06     ; +6 uint8  flags (Bit0: 再生中/停止)
.DEFINE TRK_RESERVED    $07     ; +7 予約

.DEFINE NUM_TRACKS      8

;--- APU ハードウェア I/O レジスタ ($00F0-$00FF) --------------------------------
.DEFINE TEST            $F0
.DEFINE CONTROL         $F1
.DEFINE DSPADDR         $F2
.DEFINE DSPDATA         $F3
.DEFINE CPUIO0          $F4
.DEFINE CPUIO1          $F5
.DEFINE CPUIO2          $F6
.DEFINE CPUIO3          $F7
.DEFINE AUXIO0          $F8
.DEFINE AUXIO1          $F9
.DEFINE T0DIV           $FA     ; Timer0 分周値
.DEFINE T1DIV           $FB
.DEFINE T2DIV           $FC
.DEFINE T0OUT           $FD     ; Timer0 カウンタ (読むとクリアされる)
.DEFINE T1OUT           $FE
.DEFINE T2OUT           $FF

;--- DSPレジスタ (DSPADDR/DSPDATA経由でアクセス) --------------------------------
.DEFINE DSP_MVOL_L      $0C
.DEFINE DSP_MVOL_R      $1C
.DEFINE DSP_DIR         $5D
.DEFINE DSP_FLG         $6C
.DEFINE DSP_KON         $4C
.DEFINE DSP_KOFF        $5C

; チャンネル毎レジスタオフセット (チャンネル番号 << 4 に加算)
.DEFINE DSP_CH_VOLL     $00
.DEFINE DSP_CH_VOLR     $01
.DEFINE DSP_CH_PITCHL   $02
.DEFINE DSP_CH_PITCHH   $03
.DEFINE DSP_CH_SRCN     $04
.DEFINE DSP_CH_ADSR1    $05
.DEFINE DSP_CH_ADSR2    $06
.DEFINE DSP_CH_GAIN     $07

;--- ワークエリア追加変数（未使用予備176byte内に配置してもよいが、
;     ここでは仕様通りゼロページの空きは使わず $40- 以降を使用） ------------
.DEFINE CUR_TRACK       $40     ; メインループでの走査中トラック番号 (一時変数)
.DEFINE TEMP0           $41
.DEFINE TEMP1           $42
.DEFINE TEMP2           $43

;--- 主要アドレス ---------------------------------------------------------------
.DEFINE ADDR_STACK_TOP  $01FF
.DEFINE ADDR_DRIVER     $0200
.DEFINE ADDR_DIR_TABLE  $0400   ; DIRテーブル (32エントリー x 4byte = 128byte)
.DEFINE ADDR_INST_TABLE $0480   ; 音色パラメータテーブル (ADSR/PitchOffset)
.DEFINE ADDR_SEQ_DATA   $0500   ; シーケンスデータ & BRR波形

; 音色パラメータテーブル 1エントリーのフォーマット (4byte固定、最大32音色)
;   +0 uint8  srcn        (DIRインデックス。通常は音色IDそのまま)
;   +1 uint8  adsr1
;   +2 uint8  adsr2
;   +3 sint8  pitch_offset (ノート番号に加算するオフセット。センチュア調整用)
.DEFINE INST_SIZE       $04
.DEFINE INST_SRCN       $00
.DEFINE INST_ADSR1      $01
.DEFINE INST_ADSR2      $02
.DEFINE INST_PITCHOFS   $03


;===============================================================================
; エントリポイント ($0200~)
;===============================================================================
.ORG $0200

;-------------------------------------------------------------------------------
; Reset / Init
;-------------------------------------------------------------------------------
Start:
        SEI                     ; (SPC700にはSEIは無いが割込禁止相当の初期化)
        CLRP                    ; ダイレクトページ = $00 に設定 (DPフラグクリア)

        ; --- 1. スタックポインタ初期化 ---
        MOV     X, #$FF
        MOV     SP, X           ; SP = $01FF

        ; --- ゼロページ ワークエリアのクリア ($00-$3F) ---
        MOV     X, #$00
ClearZP:
        MOV     $00+X, #$00
        INC     X
        CBNE    X, #$40, ClearZP

        ; --- 2. DSPレジスタ初期化 ---

        ; マスターボリューム L/R -> 127 (最大)
        MOV     A, #DSP_MVOL_L
        MOV     DSPADDR, A
        MOV     A, #$7F
        MOV     DSPDATA, A

        MOV     A, #DSP_MVOL_R
        MOV     DSPADDR, A
        MOV     A, #$7F
        MOV     DSPDATA, A

        ; DIRアドレス -> $04 ($0400 = $04 << 8)
        MOV     A, #DSP_DIR
        MOV     DSPADDR, A
        MOV     A, #$04
        MOV     DSPDATA, A

        ; FLGレジスタ -> $00 (ミュート解除・エコー禁止・ソフトリセット解除)
        MOV     A, #DSP_FLG
        MOV     DSPADDR, A
        MOV     A, #$00
        MOV     DSPDATA, A

        ; 念のため、全チャンネルの KOFF を発行して発音状態をクリア
        MOV     A, #DSP_KOFF
        MOV     DSPADDR, A
        MOV     A, #$FF
        MOV     DSPDATA, A

        ; --- 3. 各トラック(CH0-CH7)の読み込みポインタ・変数を初期化 ---
        MOV     Y, #$00                 ; Y = トラックインデックス (0-7)
InitTrackLoop:
        MOV     A, Y
        MOV     TEMP0, A                ; TEMP0 = トラック番号を保存
        ASL     A
        ASL     A
        ASL     A                       ; A = トラック番号 * 8 (構造体オフセット)
        MOV     X, A                    ; X = ゼロページ内オフセット

        ; ptr = トラック先頭シーケンスアドレス (SeqTrackTable[Y]) をロード
        MOV     A, Y
        ASL     A                       ; Y*2 (テーブルは各2byte)
        MOV     TEMP1, A
        MOV     A, SeqTrackTable+TEMP1
        MOV     TRK_PTR_L+X, A
        MOV     A, SeqTrackTable+1+TEMP1
        MOV     TRK_PTR_H+X, A

        MOV     A, #$00
        MOV     TRK_WAIT+X, A           ; wait_ticks = 0 (即座に最初のイベント解釈)
        MOV     A, #$FF
        MOV     TRK_INST+X, A           ; inst_id = 未設定(0xFF)
        MOV     A, #$7F
        MOV     TRK_VOL_L+X, A          ; volume_l = 初期値127
        MOV     TRK_VOL_R+X, A          ; volume_r = 初期値127
        MOV     A, #$01
        MOV     TRK_FLAGS+X, A          ; flags = 再生中(Bit0=1)

        MOV     A, TEMP0
        MOV     Y, A
        INC     Y
        CMP     Y, #NUM_TRACKS
        BNE     InitTrackLoop

        ; --- 4. Timer0 起動 (125 -> 8kHz/125 = 1/64000*125 ≒ 1/64Hz間隔ではなく
        ;     8000Hz / 125 = 64Hz。仕様書コメントに準じ、精密な60Hz同期は
        ;     外部同期(NMI/VBlank)ではなくTimer0の125設定を採用) ---
        MOV     A, #$00
        MOV     CONTROL, A              ; いったんタイマー停止・リセット

        MOV     A, #125
        MOV     T0DIV, A                ; 分周値 125 をセット

        MOV     A, CONTROL
        OR      A, #$01                 ; Timer0 Enable (Bit0)
        MOV     CONTROL, A

        MOV     A, T0OUT                ; T0OUTを一度読んでカウンタをクリア

;-------------------------------------------------------------------------------
; メインループ
;-------------------------------------------------------------------------------
MainLoop:
        MOV     A, T0OUT                ; Timer0カウントを読む(読むとクリアされる)
        BEQ     MainLoop                ; 0ならまだ1tick経過していない → 待機

        ; カウントが1以上 -> UpdateSequencer を実行
        ; (複数tick分溜まっていても、本ドライバは1回のみ処理する簡易実装。
        ;  厳密な追従が必要な場合はAレジスタの値だけループさせる)
CallUpdate:
        CALL    UpdateSequencer
        BRA     MainLoop


;===============================================================================
; UpdateSequencer : 全トラックのシーケンスデータを1tick分進める
;===============================================================================
UpdateSequencer:
        MOV     Y, #$00                 ; Y = トラック番号 0-7
UpdateTrackLoop:
        MOV     A, Y
        MOV     CUR_TRACK, A

        ASL     A
        ASL     A
        ASL     A                       ; A = トラック番号 * 8
        MOV     X, A                    ; X = ゼロページオフセット

        ; flags Bit0 (再生中) チェック。停止トラックはスキップ
        MOV     A, TRK_FLAGS+X
        AND     A, #$01
        BEQ     NextTrack

        ; wait_ticks が 0 より大きければデクリメントして継続待ち
        MOV     A, TRK_WAIT+X
        BEQ     ParseEvents             ; 0ならイベント解釈へ
        DEC     A
        MOV     TRK_WAIT+X, A
        BRA     NextTrack

ParseEvents:
        ; --- シーケンスデータを1イベント以上、wait_ticksがセットされるまで解釈 ---
ParseLoop:
        MOV     A, TRK_PTR_H+X
        MOV     TEMP2, A                ; 現在ポインタHighを退避 (SRCN計算等で使用)

        ; (ptr) から1バイト読み込み。TRK_PTR_L/Hが指すシーケンスデータバイトを
        ; 直接参照するため、一旦YレジスタにトラックIndexを退避しXIndexを使う
        MOV     A, TRK_PTR_L+X
        MOV     TEMP0, A
        MOV     A, TRK_PTR_H+X
        MOV     TEMP1, A

        ; TEMP0/TEMP1 = 現在の読み込みアドレス。
        ; SPC700には(dp)間接的な16bitアドレッシングが無いため、
        ; ゼロページの2byteを「ポインタ」として (X) 間接アドレッシングに使う。
        ; ここでは便宜上ゼロページ $44/$45 を一時ポインタとして利用する。
        MOV     A, TEMP0
        MOV     $44, A
        MOV     A, TEMP1
        MOV     $45, A

        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = シーケンスバイトコード

        ; --- バイトコード分岐 ---
        CMP     A, #$80
        BCS     NotNoteOn               ; 0x80以上ならNote On以外

        ; ===== 0x00-0x7F : Note On =====
        MOV     TEMP2, A                ; TEMP2 = ノート番号
        CALL    AdvanceSeqPtr           ; ptr++ (Byte1消費)

        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = 音長(tick数)
        MOV     TRK_WAIT+X, A           ; wait_ticksに音長をセット
        CALL    AdvanceSeqPtr           ; ptr++ (Byte2消費)

        MOV     A, TEMP2
        CALL    DoNoteOn                ; ノートオン処理 (X=トラックオフセット, A=ノート番号)
        BRA     ParseDone               ; 音長(wait_ticks)がセットされたので今tickの解釈は終了

NotNoteOn:
        CMP     A, #$BE
        BCC     IsWaitEvent             ; 0x80-0xBD ならWait/Rest

        BEQ     IsSetInstrument         ; 0xBE

        CMP     A, #$BF
        BEQ     IsSetVolume             ; 0xBF

        CMP     A, #$C0
        BEQ     IsJump                  ; 0xC0

        CMP     A, #$FF
        BEQ     IsEndOfTrack            ; 0xFF

        ; 未定義バイトコードは安全のため読み飛ばす
        CALL    AdvanceSeqPtr
        BRA     ParseLoop

; ----- 0x80-0xBD : Wait / Rest -----
IsWaitEvent:
        ; (値 - 0x80 + 1) tick 分休符
        MOV     TEMP2, A
        CALL    AdvanceSeqPtr           ; ptr++ (このバイト自体を消費)

        MOV     A, TEMP2
        SETC
        SBC     A, #$80                 ; A = 値 - 0x80
        INC     A                       ; A = 値 - 0x80 + 1
        MOV     TRK_WAIT+X, A
        BRA     ParseDone

; ----- 0xBE : Set Instrument -----
IsSetInstrument:
        CALL    AdvanceSeqPtr           ; オペコード消費
        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = 音色ID
        MOV     TRK_INST+X, A
        CALL    AdvanceSeqPtr           ; Byte1消費
        BRA     ParseLoop               ; wait未セットなので同tick内で継続解釈

; ----- 0xBF : Set Volume -----
IsSetVolume:
        CALL    AdvanceSeqPtr           ; オペコード消費
        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = Vol L
        MOV     TRK_VOL_L+X, A
        CALL    AdvanceSeqPtr           ; Byte1消費

        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = Vol R
        MOV     TRK_VOL_R+X, A
        CALL    AdvanceSeqPtr           ; Byte2消費

        ; 発音中であれば即座にDSPへ反映
        CALL    ApplyVolumeToDSP
        BRA     ParseLoop

; ----- 0xC0 : Jump (Loop) -----
IsJump:
        CALL    AdvanceSeqPtr           ; オペコード消費
        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = アドレスLow
        MOV     TEMP0, A
        CALL    AdvanceSeqPtr           ; Byte1消費

        MOV     Y, #$00
        MOV     A, ($44)+Y              ; A = アドレスHigh
        MOV     TEMP1, A

        MOV     A, TEMP0
        MOV     TRK_PTR_L+X, A
        MOV     A, TEMP1
        MOV     TRK_PTR_H+X, A
        BRA     ParseLoop               ; ジャンプ先から継続解釈

; ----- 0xFF : End of Track -----
IsEndOfTrack:
        MOV     A, TRK_FLAGS+X
        AND     A, #$FE                 ; Bit0クリア (再生停止)
        MOV     TRK_FLAGS+X, A
        BRA     ParseDone

ParseDone:
NextTrack:
        MOV     A, CUR_TRACK
        INC     A
        CMP     A, #NUM_TRACKS
        MOV     Y, A
        BNE     UpdateTrackLoop
        RET


;-------------------------------------------------------------------------------
; AdvanceSeqPtr : 一時ポインタ($44/$45)とトラック構造体のptrを+1し、
;                 トラックのptr($TRK_PTR_L/H+X)にも反映する
;                 (X = 呼び出し元のトラックオフセットを維持したまま呼ぶこと)
;-------------------------------------------------------------------------------
AdvanceSeqPtr:
        MOV     A, $44
        INC     A
        MOV     $44, A
        MOV     A, TRK_PTR_L+X
        INC     A
        MOV     TRK_PTR_L+X, A
        BNE     AdvanceSeqPtrDone
        MOV     A, $45
        INC     A
        MOV     $45, A
        MOV     A, TRK_PTR_H+X
        INC     A
        MOV     TRK_PTR_H+X, A
AdvanceSeqPtrDone:
        RET


;===============================================================================
; 6. DSPレジスタ割り当てと発音制御
;===============================================================================

;-------------------------------------------------------------------------------
; DoNoteOn : Note On イベント処理
;   入力: X = トラック構造体オフセット (Y*8)
;         A = ノート番号 (0-127)
;         CUR_TRACK = トラック番号 (0-7)
;-------------------------------------------------------------------------------
DoNoteOn:
        MOV     TEMP0, A                ; TEMP0 = ノート番号

        ; --- 1. inst_id に応じた音色パラメータをテーブルから参照 ---
        MOV     A, TRK_INST+X
        MOV     TEMP1, A                ; TEMP1 = inst_id
        ASL     A
        ASL     A                       ; A = inst_id * 4 (INST_SIZE)
        MOV     Y, A                    ; Y = 音色テーブル内オフセット

        ; --- 2. 対象チャンネルのDSPレジスタベースアドレスを計算 ---
        ;     チャンネルレジスタベース = CUR_TRACK << 4
        MOV     A, CUR_TRACK
        ASL     A
        ASL     A
        ASL     A
        ASL     A                       ; A = チャンネル番号 * 16
        MOV     TEMP2, A                ; TEMP2 = DSPチャンネルベースアドレス

        ; --- Volume L/R 設定 ---
        MOV     A, TEMP2
        OR      A, #DSP_CH_VOLL
        MOV     DSPADDR, A
        MOV     A, TRK_VOL_L+X
        MOV     DSPDATA, A

        MOV     A, TEMP2
        OR      A, #DSP_CH_VOLR
        MOV     DSPADDR, A
        MOV     A, TRK_VOL_R+X
        MOV     DSPDATA, A

        ; --- Pitch L/H 設定 (ノート番号 + オフセットから計算) ---
        MOV     A, TEMP0                ; ノート番号
        CLRC
        ADC     A, ADDR_INST_TABLE+INST_PITCHOFS+Y  ; + pitch_offset
        CALL    NoteToPitch             ; A(ノート番号相当)→ TEMP0/TEMP1 = Pitch16bit

        MOV     A, TEMP2
        OR      A, #DSP_CH_PITCHL
        MOV     DSPADDR, A
        MOV     A, TEMP0
        MOV     DSPDATA, A

        MOV     A, TEMP2
        OR      A, #DSP_CH_PITCHH
        MOV     DSPADDR, A
        MOV     A, TEMP1
        MOV     DSPDATA, A

        ; --- SRCN (DIRインデックス) 設定 ---
        MOV     A, TEMP2
        OR      A, #DSP_CH_SRCN
        MOV     DSPADDR, A
        MOV     A, ADDR_INST_TABLE+INST_SRCN+Y
        MOV     DSPDATA, A

        ; --- ADSR1 / ADSR2 設定 ---
        MOV     A, TEMP2
        OR      A, #DSP_CH_ADSR1
        MOV     DSPADDR, A
        MOV     A, ADDR_INST_TABLE+INST_ADSR1+Y
        MOV     DSPDATA, A

        MOV     A, TEMP2
        OR      A, #DSP_CH_ADSR2
        MOV     DSPADDR, A
        MOV     A, ADDR_INST_TABLE+INST_ADSR2+Y
        MOV     DSPDATA, A

        ; --- 3. KON (Key On) レジスタの対象チャンネルビットを1にする ---
        MOV     A, #$01
        MOV     Y, CUR_TRACK
KonShiftLoop:
        CBNE    Y, #$00, KonShiftNext
        BRA     KonShiftDone
KonShiftNext:
        ASL     A
        DEC     Y
        BRA     KonShiftLoop
KonShiftDone:
        MOV     TEMP0, A                ; TEMP0 = KONビットマスク

        MOV     A, #DSP_KON
        MOV     DSPADDR, A
        MOV     A, TEMP0
        MOV     DSPDATA, A

        RET


;-------------------------------------------------------------------------------
; ApplyVolumeToDSP : Set Volume イベント時、発音中チャンネルへ即座に反映
;   入力: X = トラック構造体オフセット, CUR_TRACK = トラック番号
;-------------------------------------------------------------------------------
ApplyVolumeToDSP:
        MOV     A, CUR_TRACK
        ASL     A
        ASL     A
        ASL     A
        ASL     A                       ; A = チャンネル番号 * 16
        MOV     TEMP2, A

        MOV     A, TEMP2
        OR      A, #DSP_CH_VOLL
        MOV     DSPADDR, A
        MOV     A, TRK_VOL_L+X
        MOV     DSPDATA, A

        MOV     A, TEMP2
        OR      A, #DSP_CH_VOLR
        MOV     DSPADDR, A
        MOV     A, TRK_VOL_R+X
        MOV     DSPDATA, A
        RET


;-------------------------------------------------------------------------------
; NoteToPitch : ノート番号(A) から 16bit Pitch値(TEMP0=Low, TEMP1=High) を算出
;   簡易実装: PitchTable(ノート番号 0-127 に対応する16bitピッチ値の
;   ルックアップテーブル)を256エントリー分は用意せず、1オクターブ12音分の
;   基準ピッチテーブルとオクターブシフトで算出する。
;-------------------------------------------------------------------------------
NoteToPitch:
        MOV     TEMP2, A                ; TEMP2 = ノート番号(オフセット加算後)

        ; オクターブ = ノート番号 / 12, 半音 = ノート番号 % 12
        MOV     A, #$00
        MOV     Y, A                    ; Y = オクターブカウンタ
DivLoop:
        MOV     A, TEMP2
        CMP     A, #12
        BCC     DivDone
        SETC
        SBC     A, #12
        MOV     TEMP2, A
        INC     Y
        BRA     DivLoop
DivDone:
        ; TEMP2 = 半音番号(0-11), Y = オクターブ数

        ; 基準テーブルから16bitピッチを取得 (半音番号 * 2)
        MOV     A, TEMP2
        ASL     A
        MOV     TEMP2, A

        MOV     A, PitchTableBase+TEMP2
        MOV     TEMP0, A                ; Low
        MOV     A, PitchTableBase+1+TEMP2
        MOV     TEMP1, A                ; High

        ; オクターブ分だけ左シフト(オクターブ+1ごとに2倍) を基準オクターブから調整
        ; 基準テーブルは第4オクターブ(Y=4)を基準値とする
        MOV     A, Y
        SETC
        SBC     A, #4                   ; A = (相対オクターブ, 符号付きとして扱う)
        BEQ     PitchDone
        BMI     ShiftRightLoop

ShiftLeftLoop:
        ASL     TEMP0
        ROL     TEMP1
        DEC     A
        BNE     ShiftLeftLoop
        BRA     PitchDone

ShiftRightLoop:
        LSR     TEMP1
        ROR     TEMP0
        INC     A
        BNE     ShiftRightLoop

PitchDone:
        RET


;===============================================================================
; データテーブル
;===============================================================================

;-------------------------------------------------------------------------------
; SeqTrackTable : 各トラック(CH0-CH7)の初期シーケンスデータ開始アドレス
;   (実際の値は曲データのビルド時に決定し、ここでは仕様に基づくプレース
;    ホルダとして $0500 からのオフセットで確保する例を示す)
;-------------------------------------------------------------------------------
SeqTrackTable:
        .DW     Track0Data
        .DW     Track1Data
        .DW     Track2Data
        .DW     Track3Data
        .DW     Track4Data
        .DW     Track5Data
        .DW     Track6Data
        .DW     Track7Data

;-------------------------------------------------------------------------------
; PitchTableBase : 第4オクターブ(基準)における12半音分の16bit Pitch値
;   SPC700のPitchレジスタは 1.0 = $1000 (4096) を基準に、
;   12平均律で半音ごとに 2^(1/12) 倍していく。
;   下記はC(ド)を基準に算出した代表値（一般的なSPCドライバでの近似値）。
;-------------------------------------------------------------------------------
PitchTableBase:
        .DW     $085F           ; C
        .DW     $08E6           ; C#
        .DW     $0977           ; D
        .DW     $0A14           ; D#
        .DW     $0AB8           ; E
        .DW     $0B66           ; F
        .DW     $0C1E           ; F#
        .DW     $0CE1           ; G
        .DW     $0DAF           ; G#
        .DW     $0E89           ; A
        .DW     $0F6F           ; A#
        .DW     $1000           ; B (基準)


;===============================================================================
; DIRテーブル ($0400-$047F) : 音色サンプル定義 (最大32エントリー x 4byte)
;   各エントリー: サンプル開始アドレス(2byte) + ループ開始アドレス(2byte)
;   実データはBRRコンバータの出力に応じてビルド時に配置する。
;===============================================================================
.ORG $0400
DirTable:
        ; エントリー0の例 (Byte0-1:開始アドレス, Byte2-3:ループアドレス)
        .DW     Sample0Start, Sample0Loop
        ; ... 以降、使用する音色数だけエントリーを追加 ...
        .DS     $78, $00        ; 残り31エントリー分を0埋め(プレースホルダ)


;===============================================================================
; 音色パラメータテーブル ($0480-$04FF) : ADSR / Pitch Offset (最大32音色)
;===============================================================================
.ORG $0480
InstTable:
        ; 音色0 の例: SRCN=0, ADSR1, ADSR2, PitchOffset
        .DB     $00, $8F, $E0, $00
        ; ... 以降、使用する音色数だけ追加 ...
        .DS     $7C, $00        ; 残り31音色分を0埋め(プレースホルダ)


;===============================================================================
; シーケンスデータ & BRR波形データ ($0500-$FFFF)
;   以下はフォーマット確認用の最小サンプルデータ。
;   実運用時はMMLコンパイラ等の出力に置き換える。
;===============================================================================
.ORG $0500

Track0Data:
        .DB     $BE, $00                ; Set Instrument = 0
        .DB     $BF, $7F, $7F           ; Set Volume L=127 R=127
        .DB     $3C, $30                ; Note On (note=60=C5) length=48tick
        .DB     $3E, $30                ; Note On (note=62=D5) length=48tick
        .DB     $C0, <Track0Data, >Track0Data  ; Jump (Loop) 先頭へ

Track1Data:
        .DB     $FF                     ; End of Track (未使用チャンネル)
Track2Data:
        .DB     $FF
Track3Data:
        .DB     $FF
Track4Data:
        .DB     $FF
Track5Data:
        .DB     $FF
Track6Data:
        .DB     $FF
Track7Data:
        .DB     $FF

; BRRサンプルデータ配置例 (実データはBRRエンコーダ出力に置換)
Sample0Start:
        .DB     $00                     ; BRRヘッダ (プレースホルダ)
        .DS     $08, $00                ; ダミーBRRブロック
Sample0Loop:
        .DS     $08, $00

;===============================================================================
; EOF
;===============================================================================
