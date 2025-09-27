//+------------------------------------------------------------------+
//| for_test.mq5  (重複整理済み 完全版 - CSVニュース修正)               |
//| FastBB×Ref タッチでドテン/積み増し + 多層ガード                   |
//| CSVニュース + 経済カレンダー併用版                               |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//================= Inputs ===========================================
input ENUM_TIMEFRAMES InpTF = PERIOD_M15;
input int    Fast_Period    = 20;
input double Fast_Dev       = 1.8;

input ENUM_TIMEFRAMES RefTF = PERIOD_H4; // 例: H4 / D1
input int    RefShift       = 1;         // 1=確定バー

// 接触判定
input int    TouchTolPoints      = 15;
input bool   UseWickForTouch     = true;
input bool   RequirePriceTouch   = true;
input bool   AllowPriceOnlyTouch = false;

// 判定タイミング
input bool   TriggerImmediate    = false; // true=ティック即時, false=新バー

// デデュープ
input bool   OnePerBar           = true;
input bool   OnePerRefBar        = false;
input int    MinBarsBetweenSig   = 0;

// 取引系（表示用。実発注はガードで決定）
input double Lots                = 0.10;
input int    SlippagePoints      = 10;
input int    MaxSpreadPoints     = 30;
input int    RetryCount          = 2;
input int    RetryWaitMillis     = 1000;
input long   Magic               = 20250910;

// ヘッジ設定
input bool   AllowMultiple       = true;  // 同方向積み増し
input bool   AllowOppositeHedge  = true; // 逆方向同時保有

// ===== 維持率ガード =================================================
input double TargetMarginLevelPct = 300.0; // 例: 1200%
input double MinAddLot            = 0.05;
input double MaxAddLot            = 0.06;
input int    MaxAddPositionsSide  = 200;     // 同方向の最大本数
input double MinGridPips          = 150;     // 同方向の最小間隔
input double LotStepFallback      = 0.01;

// ===== 速度/ボラ ガード ============================================
// ATR（荒れ/薄さ）
input bool   UseATRGuard       = true;
input int    ATR_Period        = 14;
input double MaxATR_Pips       = 40;
input double MinATR_Pips       = 1;

// 現在バーのレンジ/実体
input bool   UseCandleGuard    = true;
input double MaxCandle_Pips    = 35;
input double MaxBody_Pips      = 25;

// BB帯幅（u-l）
input bool   UseBBWGuard       = true;
input double MaxBBW_Pips       = 30;

// M1急変
input bool   UseSpeedGuard     = true;
input ENUM_TIMEFRAMES SpeedTF  = PERIOD_M1;
input int    SpeedLookback     = 3;
input double MaxSpeedMove_Pips = 20;

// クールダウン
input bool   UseCooldown       = true;
input double BigBar_Pips       = 40;
input int    CooldownBars      = 2;

// 任意: 手動フリーズ窓
input bool      UseNewsFreeze  = false;
input datetime  FreezeFrom     = D'1970.01.01 00:00';
input datetime  FreezeTo       = D'1970.01.01 00:00';

// 通知/表示
input bool   AlertPopup        = true;
input bool   AlertPush         = true;
input bool   ShowPanel         = true;
input ENUM_BASE_CORNER PanelCorner = CORNER_LEFT_LOWER;
input int    PanelX            = 10;
input int    PanelY            = 28;
input int    PanelFontSize     = 10;

// --- バンド接触の厳格化 ---
input bool RequireBandTouch   = true;   // 価格がU/Lにも触れる必要あり
input int  BandTouchTolPts    = 3;      // U/Lとの許容ポイント

// --- Auto flatten by ATR spike ---
enum FLATTEN_CLOSE_MODE { FLAT_CLOSE_ALL=0, FLAT_CLOSE_LOSERS_ONLY=1, FLAT_KEEP_WINNERS_ABOVE=2 };
input bool               UseATR_Flatten    = true;   // ATR急伸で一時フラット
input double             ATR_Spike_Pips    = 120;     // これ以上でフラット化
input int                ATR_FreezeMinutes = 5;     // その後のノーエントリー時間(分)
input FLATTEN_CLOSE_MODE FlattenCloseMode  = FLAT_KEEP_WINNERS_ABOVE;
input double             KeepWinnerMinPips = 8.0;    // これ以上勝っているポジは残す

// --- Per-position hard stop (loss in points) ---
input bool   UsePerPosSL      = true;   // 個別ストップ有効化
input double PerPosSL_Points  = 400;     // 含み損がこのポイント以上でクローズ（5桁=2.0pips）

// --- Per-position Trailing Stop (points) ---
input bool   UseTrailing          = true;   // トレール有効
input double TrailStart_Points    = 400;     // これ以上の含み益で発動
input double TrailOffset_Points   = 200;      // 価格からの追従距離（ポイント）
input double TrailStep_Points     = 10;      // 有利方向にこの分進んだら更新

input bool UseSoftFirstLots = true;   // 初回〜2本目をmaxLotに合わせて縮小許可

input bool   UseRiskLots     = false;  // リスク％でロット自動
input double RiskPctPerTrade = 20.0;    // 1本目の許容リスク（%）

// --- Doten専用スプレッド緩和（任意） ---
input bool DotenAllowWideSpread   = true; // trueで有効化
input int  DotenMaxSpreadPoints   = 80;    // ドテン時だけの上限（pt）。0以下なら無制限

// --- Reverse on Close (guarded first) ------------------------------
input bool   UseReverseOnClose     = true;   // クローズ検知で反対方向へ（ガード尊重）
input bool   ReverseRespectGuards  = true;   // AllGuardsPass を通す
input int    ReverseDelayMillis    = 0;      // 反転発注までの待ち(ms)
input int    ReverseMinIntervalSec = 2;      // 連続反転の最小間隔(秒)

// --- 個別ストップ時だけ反転 ---------------------------------------
input bool ReverseOnlyOnPerPosSL = true;  // true=PerPosSLで閉じた時だけ反転
input bool ReverseAlsoOnBrokerSL = false; // true=ブローカーSL(DEAL_REASON_SL)でも反転

input bool ReverseSkipOnBrokerSL = true; // ブローカーSL(=トレーリング到達)は反転しない

// --- 段階ロット × 残高スケール（%リスク上限キャップ付き） ---
input bool   UseTieredAdaptiveLots = false;   // 段階ロットを残高で自動スケール
input double FirstTwoLots          = 0.05;   // 1〜2本目の基準ロット
input double ThirdPlusLots         = 0.10;   // 3本目以降の基準ロット

// s = clamp( (Equity / TierBaselineEquity)^TierExponent, TierMinScale, TierMaxScale )
input double TierBaselineEquity    = 80000;  // 基準Equity（例：8万円）
input double TierMinScale          = 2.00;   // 最小倍率
input double TierMaxScale          = 5.00;   // 最大倍率
input double TierExponent          = 1.00;   // 1.0=比例, 0.5=緩やか, 2.0=加速

// 追加：%リスク上限を“キャップ”として併用（UsePerPosSL必須）
input bool   TierRespectRiskCap    = false;   // true=リスク％からの上限も適用

// 反転UQのロット決定用
input bool   ReverseUseSameVolume  = true;   // クローズ量と同じロットを使う
input double ReverseFixedLots      = 0.10;   // 固定ロット（同量を使わない場合）

// --- Unconditional Reverse / Add (fallback) ------------------------
input bool   UseReverseOnCloseUQ   = true;   // 無条件フォールバックON
input bool   ReverseUseMLGuardLots = true;   // ロット=維持率ガードから算出（推奨）
input bool   ReverseAddIfHolding   = true;   // 既存ポジがあれば“積み増し”

// --- Signal時の「解放＋ドテン」専用モード ---------------------------
input bool UseCloseThenDoten     = true;  // シグナルで必ず「解放→ドテン」
input bool DotenRespectGuards    = true;  // ドテン前にガード判定を通す
input bool DotenUseUQFallback    = true;  // ガードNGでも無条件フォールバックで建てる

// --- 経済カレンダーでの事前クローズ＆トレード禁止（統合版） ---
// トレード禁止（指標の前後で新規エントリー停止）
input bool   UseCalendarNoTrade       = true;   // 経済カレンダーでトレード禁止
input int    BlockBeforeNewsMin       = 30;     // 何分前から禁止
input int    BlockAfterNewsMin        = 0;      // 何分後まで禁止（不要なら0）
input ENUM_CALENDAR_EVENT_IMPORTANCE  MinImportance = CALENDAR_IMPORTANCE_HIGH; // 重要度しきい値
input bool   OnlySymbolCurrencies     = true;   // シンボル通貨のイベントだけ対象

// 事前クローズ（保有ポジ/保留注文の整理）
input bool   UseCalendarCloseAll      = true;   // 指標前に全決済する
input int    CloseBeforeNewsMin       = 30;     // 何分前に決済するか
input int    RefrainAfterNewsMin      = 15;     // 何分後までエントリー停止

// クローズ対象の重要度/通貨/範囲
input ENUM_CALENDAR_EVENT_IMPORTANCE MinImportance4Close = CALENDAR_IMPORTANCE_HIGH;
input bool   OnlySymbolCurrenciesForClose = true;  // シンボル通貨(CCY)だけ対象
enum CLOSE_SCOPE { CLOSE_THIS_SYMBOL=0, CLOSE_THIS_MAGIC_ALL_SYMBOLS=1, CLOSE_ACCOUNT_ALL=2 };
input CLOSE_SCOPE CloseScope = CLOSE_THIS_SYMBOL;   // どこまで閉じるか
input bool   CancelPendingsToo = true;              // 保留注文も消す？

// CSVニュース（toyolab方式）
#define NEWS_MAX 2000
datetime g_NewsTime[NEWS_MAX];
int      g_NTsize=0;

int LoadNewsTimeCSV()
{
   g_NTsize=0;
   int fh = FileOpen("newstime.csv", FILE_READ|FILE_CSV|FILE_COMMON);
   if(fh==INVALID_HANDLE){
      Print("[NEWS CSV] open fail err=",GetLastError());
      return 0;
   }
   while(!FileIsEnding(fh) && g_NTsize<NEWS_MAX){
      datetime dt = FileReadDatetime(fh);
      if(dt==0) break;
      g_NewsTime[g_NTsize++] = dt;
      string name = FileReadString(fh); // 使わないが読み捨て
   }
   FileClose(fh);
   PrintFormat("[NEWS CSV] loaded %d rows", g_NTsize);
   return g_NTsize;
}

// 現在時刻が「指標の前後ウィンドウ」に入っているか？
bool NewsFilter_CSV(int before_min, int after_min)
{
   datetime now = TimeCurrent();
   for(int i=0;i<g_NTsize;i++){
      if(now >= g_NewsTime[i]-before_min*60 && now <= g_NewsTime[i]+after_min*60)
         return true;
   }
   return false;
}

//================= Globals ==========================================
CTrade trade;
int hBB = INVALID_HANDLE;
int hATR_TF = INVALID_HANDLE; // InpTFのATR
int hATR_M1 = INVALID_HANDLE; // SpeedTFのATR（任意）

datetime g_lastBar=0;
datetime g_lastSigBar=0, g_lastSigRef=0;
int      g_lastDir=0;         // +1=BUY, -1=SELL, 0=flat
datetime g_lastBigBarRef=0;   // クールダウン参照
string   g_lastGuardWhy="-";
datetime g_lastGuardAt=0;

datetime g_atr_freeze_until = 0; // ATRフラット後の凍結解除時刻

string   PFX="BB_DOTEN_EA_NOLOOP_MULTI_FIX_GUARD_FIRST010_";

// 計測カウンタ
ulong g_cntOnTick=0, g_cntSigDetected=0, g_cntAfterDedup=0,
      g_cntGuardsPassed=0, g_cntExecCalled=0, g_cntExecSucceeded=0;

// Reverse control
datetime g_suppress_reverse_until = 0;   // 反転抑止（短時間サプレッション）
datetime g_last_reverse_at        = 0;   // ガード尊重リバースの直近発注時刻
datetime g_last_reverse_at_uq     = 0;   // 無条件フォールバックの直近発注時刻
bool     g_in_doten_sequence      = false; // ExecuteBySignalDir 内のドテン処理中
string   g_lastCloseContext       = "-";    // 直近クローズの文脈タグ

// ==== News-close latches ====
ulong    g_last_news_event_id_closed = 0; // 直近でクローズ対応したイベントID
datetime g_news_freeze_until        = 0; // 指標後の“休む”終了時刻

//================= Utils (プロトタイプだけ簡略) =====================
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=(int)(long)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); return (dg==3||dg==5)?10.0*pt:pt; }
double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask-t.bid)/_Point; }
bool SpreadOK(){ return SpreadPt()<=MaxSpreadPoints; }
bool IsHedgingAccount(){ long mm=(long)AccountInfoInteger(ACCOUNT_MARGIN_MODE); return (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING); }
double SymbolMinLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return (s>0)?s:LotStepFallback; }
double NormalizeVolume(double vol){ double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep(); vol=MathMax(vmin,MathMin(vmax,vol)); vol=MathRound(vol/vstp)*vstp; return vol; }
int DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
bool GetFastBB(int sh,double &u,double &m,double &l){ static int hBB_=INVALID_HANDLE; if(hBB==INVALID_HANDLE){ hBB=iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE); } double bu[],bm[],bl[]; if(CopyBuffer(hBB,0,sh,1,bu)!=1) return false; if(CopyBuffer(hBB,1,sh,1,bm)!=1) return false; if(CopyBuffer(hBB,2,sh,1,bl)!=1) return false; u=bu[0]; m=bm[0]; l=bl[0]; return (u>0 && m>0 && l>0); }
double RefHigh(){ double v=iHigh(_Symbol,RefTF,RefShift); return (v>0? v:0.0); }
double RefLow (){ double v=iLow (_Symbol,RefTF,RefShift);  return (v>0? v:0.0); }
datetime RefBarTimeOf(datetime tInp){ int idx=iBarShift(_Symbol,RefTF,tInp,true); if(idx<0) return 0; return iTime(_Symbol,RefTF,idx); }
bool CopyBarTime(int sh, datetime &bt){ datetime t[]; if(CopyTime(_Symbol, InpTF, sh, 1, t)!=1) return false; bt=t[0]; return true; }
double OpenN(int sh){ double v[]; return (CopyOpen(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double HighN (int sh){ double v[]; return (CopyHigh (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double LowN  (int sh){ double v[]; return (CopyLow  (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double CloseN(int sh){ double v[]; return (CopyClose(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }

// --- 主要関数プロトタイプ（本体は簡略 or 既存流用想定） ---
bool AllGuardsPass(int sh, string &whyNG);
bool CloseAllForScope(CLOSE_SCOPE scope, bool pendingsToo);
bool InPreNewsCloseWindow(int preMin, ENUM_CALENDAR_EVENT_IMPORTANCE minImp, bool onlySymbolCcy, ulong &evt_id, datetime &evt_time);
bool FindUpcomingCalendarEvent(int lookaheadMin, ENUM_CALENDAR_EVENT_IMPORTANCE minImp, bool onlySymbolCcy, ulong &out_event_id, datetime &out_event_time);
bool ExecuteBySignalDir(int dir);
bool SignalSELL(int sh, datetime &sigBar, datetime &sigRef);
bool SignalBUY (int sh, datetime &sigBar, datetime &sigRef);

//================= Guards（CSVニュースの括弧修正済み） ================
bool GetATRpips(ENUM_TIMEFRAMES tf,int period,int sh,double &outPips){
   int h=(tf==InpTF? hATR_TF:hATR_M1);
   if(h==INVALID_HANDLE) return false;
   double a[]; if(CopyBuffer(h,0,sh,1,a)!=1) return false;
   outPips = a[0]/GetPip();
   return (outPips>0);
}
bool GetCandlePips(int sh,double &rangePips,double &bodyPips){
   double hi=HighN(sh), lo=LowN(sh), cl=CloseN(sh);
   double op[]; if(CopyOpen(_Symbol, InpTF, sh, 1, op)!=1) return false;
   rangePips=(hi-lo)/GetPip();
   bodyPips =MathAbs(cl-op[0])/GetPip();
   return true;
}
bool GetBBWpips(int sh,double &bbwPips){
   double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
   bbwPips=(u-l)/GetPip();
   return (bbwPips>0);
}
bool GetM1SpeedPips(double &sumPips){
   if(SpeedLookback<=0){ sumPips=0; return true; }
   MqlRates rates[]; int n=CopyRates(_Symbol, SpeedTF, 0, SpeedLookback, rates);
   if(n<=0) return false;
   double s=0; for(int i=0;i<n;i++) s+=(rates[i].high-rates[i].low)/GetPip();
   sumPips=s; return true;
}
bool InFreezeWindow(){
   datetime now=TimeCurrent();
   bool newsFreeze = (UseNewsFreeze && now>=FreezeFrom && now<=FreezeTo);
   bool atrFreeze  = (g_atr_freeze_until>0 && now<=g_atr_freeze_until);
   return (newsFreeze || atrFreeze);
}

bool AllGuardsPass(int sh, string &whyNG){
   if(!SpreadOK()){ whyNG="spread_ng"; return false; }
   if(InFreezeWindow()){ whyNG="freeze_window"; return false; }

   // CSVニュースによる停止（テスターで強い）
   if(UseCalendarNoTrade){
      if(NewsFilter_CSV(BlockBeforeNewsMin, BlockAfterNewsMin)){
         whyNG="news_csv_window";
         return false;
      }
   }

   if(UseATRGuard){
      double atrP=0; 
      if(GetATRpips(InpTF,ATR_Period,sh,atrP)){
         if(atrP>MaxATR_Pips){ whyNG=StringFormat("atr_high(%.1f)",atrP); return false; }
         if(atrP<MinATR_Pips){ whyNG=StringFormat("atr_low(%.1f)",atrP);  return false; }
      }
   }
   if(UseCandleGuard){
      double rng,body; if(GetCandlePips(sh,rng,body)){
         if(rng>MaxCandle_Pips){ whyNG=StringFormat("range_big(%.1f)",rng); return false; }
         if(body>MaxBody_Pips){  whyNG=StringFormat("body_big(%.1f)",body);  return false; }
      }
   }
   if(UseBBWGuard){
      double bbw; if(GetBBWpips(sh,bbw)){
         if(bbw>MaxBBW_Pips){ whyNG=StringFormat("bbw_big(%.1f)",bbw); return false; }
      }
   }
   if(UseSpeedGuard){
      double sp; if(GetM1SpeedPips(sp)){
         if(sp>MaxSpeedMove_Pips){ whyNG=StringFormat("speed_big(%.1f)",sp); return false; }
      }
   }
   if(UseCooldown){
      if(sh==1){
         double rng1,body1;
         if(GetCandlePips(1,rng1,body1) && rng1>=BigBar_Pips){
            datetime bt[]; if(CopyTime(_Symbol, InpTF, 1, 1, bt)==1) g_lastBigBarRef=bt[0];
         }
      }
      if(g_lastBigBarRef>0){
         int nowIdx=iBarShift(_Symbol,InpTF,TimeCurrent(),true);
         int bigIdx=iBarShift(_Symbol,InpTF,g_lastBigBarRef,true);
         if(nowIdx>=0 && bigIdx>=0 && (bigIdx-nowIdx)<CooldownBars){
            whyNG="cooldown"; return false;
         }
      }
   }

   // ATR spikeフラット（簡略：詳細ロジックは省略）
   if(UseATR_Flatten){
      double atrNow=0;
      if(GetATRpips(InpTF, ATR_Period, 0, atrNow)){
         if(atrNow >= ATR_Spike_Pips){
            g_atr_freeze_until = TimeCurrent() + ATR_FreezeMinutes*60;
            whyNG = StringFormat("atr_flat(%.1f)", atrNow);
            return false;
         }
      }
   }
   return true;
}

//================= Signals（簡略版） ================================
bool SignalSELL(int sh, datetime &sigBar, datetime &sigRef){
   double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
   double refH=RefHigh(); if(refH<=0) return false;
   const double tol  = TouchTolPoints*_Point;
   const double tolB = BandTouchTolPts*_Point;
   double hi=HighN(sh), cl=CloseN(sh), op=OpenN(sh);
   double probe=(UseWickForTouch?hi:cl);
   bool touchBB=(u >= refH - tol && u <= refH + tol);
   bool touchPx=(!RequirePriceTouch) || (probe >= refH - tol);
   bool bandOK =(!RequireBandTouch)  || (probe >= u - tolB);
   bool pass   =(touchBB && touchPx && bandOK) || (AllowPriceOnlyTouch && !RequireBandTouch && (probe >= refH - tol));
   if(!pass) return false;
   if(!CopyBarTime(sh,sigBar)) return false;
   sigRef = RefBarTimeOf(sigBar); if(sigRef==0) sigRef=sigBar;
   return true;
}
bool SignalBUY(int sh, datetime &sigBar, datetime &sigRef){
   double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
   double refL=RefLow(); if(refL<=0) return false;
   const double tol  = TouchTolPoints*_Point;
   const double tolB = BandTouchTolPts*_Point;
   double lo=LowN(sh), cl=CloseN(sh), op=OpenN(sh);
   double probe=(UseWickForTouch?lo:cl);
   bool touchBB=(l >= refL - tol && l <= refL + tol);
   bool touchPx=(!RequirePriceTouch) || (probe <= refL + tol);
   bool bandOK =(!RequireBandTouch)  || (probe <= l + tolB);
   bool pass   =(touchBB && touchPx && bandOK) || (AllowPriceOnlyTouch && !RequireBandTouch && (probe <= refL + tol));
   if(!pass) return false;
   if(!CopyBarTime(sh,sigBar)) return false;
   sigRef = RefBarTimeOf(sigBar); if(sigRef==0) sigRef=sigBar;
   return true;
}

//================= Execution（簡略） ================================
int CountPositionsSide(int dir){
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int  d=(t==POSITION_TYPE_BUY? +1:-1);
      if(d==dir) cnt++;
   }
   return cnt;
}
bool EnoughSpacingSameSide(int dir){
   if(MinGridPips<=0) return true;
   double p=GetPip(), ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int  d=(t==POSITION_TYPE_BUY? +1:-1);
      if(d!=dir) continue;
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double dist=(dir>0)? MathAbs(ask-open):MathAbs(bid-open);
      if(dist < MinGridPips*p) return false;
   }
   return true;
}
double GetCurrentTotalRequiredMargin(){
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
      string sym=(string)PositionGetString(POSITION_SYMBOL);
      long   type=(long)PositionGetInteger(POSITION_TYPE);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double price=(type==POSITION_TYPE_BUY)? SymbolInfoDouble(sym, SYMBOL_ASK)
                                            : SymbolInfoDouble(sym, SYMBOL_BID);
      double need=0.0;
      ENUM_ORDER_TYPE ot=(type==POSITION_TYPE_BUY)? ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      if(OrderCalcMargin(ot, sym, vol, price, need)) total+=need;
   }
   return total;
}
double RoundLotToStep(double lot){ double step=SymbolLotStep(); return MathFloor(lot/step)*step; }
double CalcMaxAddableLotsForTargetML(ENUM_ORDER_TYPE orderType){
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double allowed = equity / (TargetMarginLevelPct/100.0);
   double used    = GetCurrentTotalRequiredMargin();
   double budget  = allowed - used;
   if(budget<=0.0) return 0.0;
   double step=SymbolLotStep();
   double probeVol=MathMax(step, 0.01);
   double price=(orderType==ORDER_TYPE_BUY)? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mStep=0.0;
   if(!OrderCalcMargin(orderType,_Symbol,probeVol,price,mStep) || mStep<=0.0) return 0.0;
   double marginPerLot=mStep/probeVol;
   double rawLot=budget/marginPerLot;
   double vMin=SymbolMinLot(), vMax=SymbolMaxLot();
   double lot=RoundLotToStep(rawLot);
   lot=MathMax(lot,0.0); lot=MathMin(lot,vMax); lot=MathMax(lot,vMin);
   lot=MathMax(lot,MinAddLot); lot=MathMin(lot,MaxAddLot);
   return lot;
}
bool OpenDirWithGuard(int dir){
   if(!SpreadOK()) return false;
   int sameCnt=CountPositionsSide(dir);
   if(IsHedgingAccount() && AllowMultiple){
      if(sameCnt>=MaxAddPositionsSide) return false;
      if(!EnoughSpacingSameSide(dir))  return false;
   }
   string why="";
   if(!AllGuardsPass(0,why)) return false;
   double maxLot = CalcMaxAddableLotsForTargetML((dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(maxLot<=0.0) return false;
   double lots = NormalizeVolume(MathMin(maxLot, (sameCnt<2?Lots:MaxAddLot)));
   if(sameCnt>=2 && lots<MinAddLot) lots=NormalizeVolume(MinAddLot);
   if(lots<SymbolMinLot()) return false;
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
   return ok;
}
bool ExecuteBySignalDir(int dir){
   bool hedging = IsHedgingAccount();
   if(hedging && AllowMultiple){
      int oppo = CountPositionsSide(-dir);
      if(oppo>0 && !AllowOppositeHedge){
         // 反対側をクローズ（簡略版）
         for(int i=PositionsTotal()-1;i>=0;i--){
            ulong tk=PositionGetTicket(i); if(tk==0) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
            long t=(long)PositionGetInteger(POSITION_TYPE);
            int  d=(t==POSITION_TYPE_BUY? +1:-1);
            if(d==-dir){
               trade.SetExpertMagicNumber(Magic);
               trade.SetDeviationInPoints(SlippagePoints);
               trade.PositionClose(tk);
            }
         }
      }
      return OpenDirWithGuard(dir);
   }else{
      // NETTING：反転
      if(PositionSelect(_Symbol) && (long)PositionGetInteger(POSITION_MAGIC)==Magic){
         trade.SetExpertMagicNumber(Magic);
         trade.SetDeviationInPoints(SlippagePoints);
         // Fix: close by selected position's ticket, not index 0
         ulong tk = (ulong)PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(tk);
      }
      return OpenDirWithGuard(dir);
   }
}

//================= News Utils（簡略） ===============================
string ImpStr(int imp){
   if(imp == CALENDAR_IMPORTANCE_HIGH)   return "HIGH";
   if(imp == CALENDAR_IMPORTANCE_MODERATE) return "MEDIUM";
   if(imp == CALENDAR_IMPORTANCE_LOW)    return "LOW";
   return "N/A";
}
bool IsSymbolCurrency(const string ccy){
   string base = (string)SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profit = (string)SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   return (StringCompare(ccy, base)==0 || StringCompare(ccy, profit)==0);
}
bool FindUpcomingCalendarEvent(int lookaheadMin, ENUM_CALENDAR_EVENT_IMPORTANCE minImp, bool onlySymbolCcy, ulong &out_event_id, datetime &out_event_time){
   out_event_id  = 0; out_event_time=0;
   datetime nowST = TimeTradeServer();
   datetime fromT = nowST;
   datetime toT   = nowST + lookaheadMin*60;
   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, fromT, toT, NULL, NULL)) return false;
   datetime nearest = 0x7fffffff;
   ulong    chose_id= 0;
   for(int i=0; i<ArraySize(values); ++i){
      MqlCalendarEvent ev; MqlCalendarCountry co;
      if(!CalendarEventById(values[i].event_id, ev))  continue;
      if(!CalendarCountryById(ev.country_id, co))     continue;
      if(ev.importance < minImp) continue;
      if(onlySymbolCcy && !IsSymbolCurrency(co.currency)) continue;
      if(values[i].time >= nowST && values[i].time < nearest){
         nearest = values[i].time; chose_id = values[i].event_id;
      }
   }
   if(chose_id!=0){ out_event_id=chose_id; out_event_time=nearest; return true; }
   return false;
}
bool InPreNewsCloseWindow(int preMin, ENUM_CALENDAR_EVENT_IMPORTANCE minImp, bool onlySymbolCcy, ulong &evt_id, datetime &evt_time){
   evt_id=0; evt_time=0;
   if(!UseCalendarCloseAll) return false;
   datetime nowST = TimeTradeServer();
   if(!FindUpcomingCalendarEvent(240, minImp, onlySymbolCcy, evt_id, evt_time)) return false;
   datetime startWin = evt_time - preMin*60;
   return (nowST >= startWin && nowST < evt_time);
}
bool CloseAllForScope(CLOSE_SCOPE scope, bool pendingsToo){
   bool all_ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; --i){
      ulong tk = PositionGetTicket(i); if(tk==0) continue;
      string sym = (string)PositionGetString(POSITION_SYMBOL);
      long   mgc = (long)PositionGetInteger(POSITION_MAGIC);
      if(scope==CLOSE_THIS_SYMBOL && sym != _Symbol) continue;
      if(scope==CLOSE_THIS_MAGIC_ALL_SYMBOLS && mgc != Magic) continue;
      trade.SetExpertMagicNumber(Magic);
      trade.SetDeviationInPoints(SlippagePoints);
      if(!trade.PositionClose(tk)) all_ok=false;
   }
   if(pendingsToo){
      for(int oi = OrdersTotal() - 1; oi >= 0; --oi){
         ulong tk = OrderGetTicket((uint)oi); if(tk==0) continue;
         if(!OrderSelect(tk)) continue;
         string sym = (string)OrderGetString(ORDER_SYMBOL);
         long   mgc = (long)OrderGetInteger(ORDER_MAGIC);
         if(scope==CLOSE_THIS_SYMBOL && sym != _Symbol) continue;
         if(scope==CLOSE_THIS_MAGIC_ALL_SYMBOLS && mgc != Magic) continue;
         if(!trade.OrderDelete(tk)) all_ok=false;
      }
   }
   return all_ok;
}

//================= Panel（省略版） ==================================
void UpdatePanel(){
   if(!ShowPanel) return;
   string nm=PFX+"PANEL";
   if(ObjectFind(0,nm)<0){
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,(long)PanelCorner);
      ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,PanelX);
      ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,PanelY);
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,PanelFontSize);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,(long)false);
   }
   int buyCnt=CountPositionsSide(+1), sellCnt=CountPositionsSide(-1);
   string txt=StringFormat("Sym:%s TF:%s BUY:%d SELL:%d Spread:%.1fpt", _Symbol, EnumToString(InpTF), buyCnt, sellCnt, SpreadPt());
   ObjectSetString(0,nm,OBJPROP_TEXT,txt);
}

//================= Lifecycle =======================================
int OnInit(){
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   LoadNewsTimeCSV();
   hBB     = iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE);
   hATR_TF = iATR(_Symbol, InpTF, ATR_Period);
   hATR_M1 = iATR(_Symbol, SpeedTF, ATR_Period);
   UpdatePanel();
   return (hBB==INVALID_HANDLE || hATR_TF==INVALID_HANDLE) ? INIT_FAILED : INIT_SUCCEEDED;
}
void OnDeinit(const int){ string nm=PFX+"PANEL"; if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm); }
bool IsNewBar(){ datetime t[2]; if(CopyTime(_Symbol, InpTF, 0, 2, t)!=2) return false; if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; } return false; }

void OnTick(){
   g_cntOnTick++;
   // 事前クローズ窓
   ulong evt_id; datetime evt_time;
   if(UseCalendarCloseAll && InPreNewsCloseWindow(CloseBeforeNewsMin, MinImportance4Close, OnlySymbolCurrenciesForClose, evt_id, evt_time)){
      static ulong last_evt=0; 
      if(last_evt!=evt_id){
         CloseAllForScope(CloseScope, CancelPendingsToo);
         last_evt=evt_id;
         if(RefrainAfterNewsMin > 0) g_news_freeze_until = evt_time + RefrainAfterNewsMin*60;
      }
      return;
   }
   if(g_news_freeze_until>0 && TimeTradeServer()<=g_news_freeze_until) return;

   UpdatePanel();
   int sh=(TriggerImmediate?0:1);
   if(!TriggerImmediate && !IsNewBar()) return;

   datetime bS=0,rS=0,bB=0,rB=0;
   bool sigS=SignalSELL(sh,bS,rS);
   bool sigB=SignalBUY (sh,bB,rB);
   if(sigS==sigB) return;
   datetime sigBar=(sigS? bS:bB);
   datetime sigRef=(sigS? rS:rB);
   int      sigDir=(sigS? -1:+1);

   string why="";
   if(!AllGuardsPass(sh,why)) return;
   ExecuteBySignalDir(sigDir);
}