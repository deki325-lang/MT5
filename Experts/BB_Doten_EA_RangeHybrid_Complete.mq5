//+------------------------------------------------------------------+
//| BB_Doten_EA_RangeHybrid_Complete.mq5                            |
//| FastBB(20,1.8)×Ref(H4/D1) + 多段ガード + ドテン + 反転 + 指標連動 |
//| 追加: レンジ/ブレイク判定の修正（価格ベース）                      |
//| 追加: レンジ/ブレイク別のTP/トレール切替（任意でON/OFF）           |
//| 追加: 大足/ブレイク時のエグジット抑止（Close系のみ）              |
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

// 取引系
input double Lots                = 0.10;
input int    SlippagePoints      = 10;

input int    RetryCount          = 2;
input int    RetryWaitMillis     = 1000;
input long   Magic               = 20250910;

// ヘッジ設定
input bool   AllowMultiple       = true;   // 同方向積み増し
input bool   AllowOppositeHedge  = true;   // 逆方向同時保有

// ===== 維持率ガード（ML） ==========================================
input double TargetMarginLevelPct = 300.0; // 例: 300%
input double MinAddLot            = 0.05;
input double MaxAddLot            = 0.06;
input int    MaxAddPositionsSide  = 200;
input double MinGridPips          = 150;
input double LotStepFallback      = 0.01;

// ===== 速度/ボラ ガード ============================================
input bool   UseATRGuard       = true;
input int    ATR_Period        = 14;
input double MaxATR_Pips       = 40;
input double MinATR_Pips       = 1;

input bool   UseCandleGuard    = true;
input double MaxCandle_Pips    = 35;
input double MaxBody_Pips      = 25;

input bool   UseBBWGuard       = true;
input double MaxBBW_Pips       = 30;

input ENUM_TIMEFRAMES SpeedTF  = PERIOD_M1;
input int    SpeedLookback     = 3;

// クールダウン
input bool   UseCooldown       = true;
input double BigBar_Pips       = 40;

// 通知/パネル（簡易）
input bool   AlertPopup        = true;
input bool   AlertPush         = true;
input bool   ShowPanel         = true;
input ENUM_BASE_CORNER PanelCorner = CORNER_LEFT_LOWER;
input int    PanelX            = 10;
input int    PanelY            = 28;
input int    PanelFontSize     = 10;

// --- バンド接触の厳格化 ---
input bool RequireBandTouch   = true;
input int  BandTouchTolPts    = 3;

// --- ATRスパイクでフラット（任意） ---
enum FLATTEN_CLOSE_MODE { FLAT_CLOSE_ALL=0, FLAT_CLOSE_LOSERS_ONLY=1, FLAT_KEEP_WINNERS_ABOVE=2 };
input bool               UseATR_Flatten    = true;
input double             ATR_Spike_Pips    = 120;
input int                ATR_FreezeMinutes = 5;
input FLATTEN_CLOSE_MODE FlattenCloseMode  = FLAT_KEEP_WINNERS_ABOVE;
input double             KeepWinnerMinPips = 8.0;

// --- 個別ストップ（含み損ポイント閾値で即クローズ） ---
input bool   UsePerPosSL      = true;
input double PerPosSL_Points  = 1000;

// --- 既存トレーリング（Regime切替OFF時に使用） ---
input bool   UseTrailing          = true;
input double TrailStart_Points    = 400;
input double TrailOffset_Points   = 200;
input double TrailStep_Points     = 10;

// ロット関連
input bool   UseSoftFirstLots = true;
input bool   UseRiskLots      = false;
input double RiskPctPerTrade  = 20.0;

// --- シグナル時の「解放→ドテン」 ---
input bool UseCloseThenDoten     = true;
input bool DotenRespectGuards    = true;
input bool DotenUseUQFallback    = true;
input bool DotenAllowWideSpread  = true; // 早朝対策
input int  DotenMaxSpreadPoints  = 80;

// --- クローズ検知で反転（＋フォールバック） ---
input bool   UseReverseOnClose     = true;
input bool   ReverseRespectGuards  = true;
input int    ReverseDelayMillis    = 0;
input int    ReverseMinIntervalSec = 2;

input bool ReverseOnlyOnPerPosSL = true;
input bool ReverseAlsoOnBrokerSL = false;
input bool ReverseSkipOnBrokerSL = true;

input bool   UseTieredAdaptiveLots = false;
input double FirstTwoLots          = 0.05;
input double ThirdPlusLots         = 0.10;
input double TierBaselineEquity    = 80000;
input double TierMinScale          = 2.00;
input double TierMaxScale          = 5.00;
input double TierExponent          = 1.00;
input bool   TierRespectRiskCap    = false;

input bool   ReverseUseSameVolume  = true;
input double ReverseFixedLots      = 0.10;
input bool   UseReverseOnCloseUQ   = true;
input bool   ReverseUseMLGuardLots = true;
input bool   ReverseAddIfHolding   = true;

//=== Guard settings ==================================================
// Spread
input int    MaxSpreadPoints   = 25;     // 最大スプレッド(pt)

// ATR guard
input bool   UseATR_Guard      = true;   // ATRガードを使う
input double ATR_Max_Pips      = 50;     // 許容ATR上限(pips)

// BBW guard
input bool   UseBBW_Guard      = true;   // BB幅ガードを使う
input int    BBW_MinPoints     = 100;    // 最小BB幅(pt)

// Speed guard
input bool   UseSpeedGuard     = true;   // スピードガードを使う
input int    Speed_MaxPoints   = 150;    // 許容変動幅(pt)

// Cooldown guard
input int    CooldownBars      = 3;      // シグナル間クールダウン（バー数）

// --- BigCandle bias (RefTF側で見る)
input bool   Use_BigBias_Filter    = true;   // 不一致なら見送り（ハード）
input bool   Use_BigBias_Boost     = false;  // 一致ならロットを増やす（ソフト）
input int    BigBias_LookbackBars  = 6;      // 直近N本以内で最新の“大足”を採用
input int    BigBias_ATR_Period    = 14;     // 大足用ATR期間
input double BigBias_Body_ATR_K    = 1.20;   // 大足: 実体 > ATR*k
input double BigBias_Range_ATR_K   = 1.50;   // 大足: 高安幅 > ATR*k
input bool   BigBias_Need_BB_Outside = true; // 終値がBB外で確定も要求
input double BigBias_LotMult       = 1.5;    // 一致時のロット倍率（Boost用）

// ===== Signal strict/loose mode =====
enum SIGNAL_MODE { STRICT_REFxBB=0, LOOSE_BBONLY=1, STRICT_OR_LOOSE=2 };
input SIGNAL_MODE SignalMode = STRICT_REFxBB;
input bool UseLooseReentry = true;

//=== Range HYBRID gate（価格ベース判定に刷新） ========================
enum RANGE_GATE_MODE { RANGE_GATE_OFF=0, ALLOW_BREAK_ONLY=1, ALLOW_RANGE_ONLY=2, TAG_ONLY=3 };
input RANGE_GATE_MODE RangeGateMode     = TAG_ONLY;          // 既定はタグのみ
input ENUM_TIMEFRAMES RangeRefTF_Signal = PERIOD_H4;         // レンジ判定RefTF
input int             RangeTolPoints    = 150;               // Ref H/L 許容差（pt）
input int             Slow_Period_Range = 100;               // SlowBB(period) for assist
input double          Slow_Dev_Range    = 2.3;               // SlowBB(dev)
input bool            FlipOnlyOnBreak   = false;             // true=ブレイク時のみドテン
input bool            RangeUseSlowBBAssist = false;          // SlowBB補助（まずはOFF推奨）

// ====== News / Economic Calendar (integrated) ======================
input bool   UseCalendarNoTrade       = true;
input int    BlockBeforeNewsMin       = 30;
input int    BlockAfterNewsMin        = 0;
input ENUM_CALENDAR_EVENT_IMPORTANCE  MinImportance = CALENDAR_IMPORTANCE_HIGH;
input bool   OnlySymbolCurrencies     = true;

input bool   UseCalendarCloseAll      = true;
input int    CloseBeforeNewsMin       = 30;
input int    RefrainAfterNewsMin      = 15;

input ENUM_CALENDAR_EVENT_IMPORTANCE MinImportance4Close = CALENDAR_IMPORTANCE_HIGH;
input bool   OnlySymbolCurrenciesForClose = true;
enum CLOSE_SCOPE { CLOSE_THIS_SYMBOL=0, CLOSE_THIS_MAGIC_ALL_SYMBOLS=1, CLOSE_ACCOUNT_ALL=2 };
input CLOSE_SCOPE CloseScope = CLOSE_THIS_SYMBOL;
input bool   CancelPendingsToo = true;

input bool DebugNews            = true;
input int  DebugNewsHorizonMin  = 180;

// ===== Range / Break で利確を切替（任意） ===========================
input bool   UseRegimeExitSwitch   = false;   // ONで本機能を有効
input ENUM_TIMEFRAMES RegimeTF     = PERIOD_M15; // 判定TF
input int    RegADX_Period         = 14;     // ADX期間
input double RegADX_Thr_Range      = 18.0;   // 未満=レンジ
input double RegADX_Thr_Break      = 22.0;   // 超=ブレイク
input int    RegBBW_Lookback       = 100;    // FastBB幅のZスコア
input double RegBBW_Z_RangeMax     = -0.30;  // Z<=ここでレンジ
input double RegBBW_Z_BreakMin     =  0.50;  // Z>=ここでブレイク
input double RegBlendWeightADX     = 0.6;    // （将来拡張用）

// レンジ/ブレイク別の利確設定
input double TP_Range_Pips         = 6000;   // レンジ時TP
input double TP_Break_Pips         = 2000;   // ブレイク時TP
input int    Trail_Range_Points    = 3000;   // レンジ時トレール幅
input int    Trail_Break_Points    = 9000;   // ブレイク時トレール幅
input int    TrailStep_Points_RB   = 10;     // 改善ステップ
input bool   RegimeExitOnlyImprove = true;   // 既存より悪化させない

//=== Range 判定（価格ベース・確定足・ヒステリシス）パラメータ ===
input bool   RangeUseCloseBreak   = true;   // true=終値で判定、false=ヒゲで判定
input double RangeBreak_Pips      = 3.0;    // 上下どちらもこのpips超で“BREAK”
input int    RangeHoldBars        = 1;      // 連続この本数、外で確定したらBREAK確定
input double RangeReenter_Pips    = 1.5;    // いったんBREAK後、ここまで戻ればIN

// ATR連動のゆらぎ許容（OPTION）
input bool   RangeUseATRTol       = true;   // ATRから許容“にじみ”を動的付与
input int    RangeATR_Period      = 14;
input double RangeATR_Mult        = 0.15;   // ATR*pips*係数 → 許容幅（pips）

// ---（任意）シンプルな右上ラベル
input bool   ShowSigLabel     = true;
input int    SigLabelFont     = 12;
input int    SigLabelX        = 10;      // 右上からのX
input int    SigLabelY        = 28;      // 右上からのY

// --- Big Candle（ATRベース）判定用（デフォルトは控えめ）
input bool   Use_BigCandle    = true;
input double BigBody_ATR_K    = 1.20;
input double BigRange_ATR_K   = 1.50;
input bool   Need_BB_Outside  = true;   // バンド外確定も必須にする

// === エグジット抑止（トレンド強） ===
input bool SuppressExitOnTrendSignal = true; // 大足/ブレイク合図でEAのクローズ系を抑止
input int  SuppressExitBars          = 1;    // 何本のバーの間 抑止（0=当該バーのみ）
input int  SuppressExitSeconds       = 0;    // もしくは秒数で（>0なら時間優先）

//================= Globals ==========================================
CTrade trade;
int hBB = INVALID_HANDLE;          // FastBB
int hATR_TF = INVALID_HANDLE;      // ATR(InpTF)
int hATR_M1 = INVALID_HANDLE;      // ATR(SpeedTF)
int hBBslow_range = INVALID_HANDLE;// SlowBB for Range assist

datetime g_lastBar=0;
datetime g_lastSigBar=0, g_lastSigRef=0;
int      g_lastDir=0;
datetime g_lastBigBarRef=0;
string   g_lastGuardWhy="-";
datetime g_lastGuardAt=0;

datetime g_atr_freeze_until = 0;

string   PFX="BB_DOTEN_EA_RANGEHYB_";

ulong g_cntOnTick=0, g_cntSigDetected=0, g_cntAfterDedup=0,
      g_cntGuardsPassed=0, g_cntExecCalled=0, g_cntExecSucceeded=0;

datetime g_suppress_reverse_until = 0;
datetime g_last_reverse_at        = 0;
bool     g_in_doten_sequence      = false;
string   g_lastCloseContext       = "-";

// ==== News-close latches ====
ulong    g_last_news_event_id_closed = 0;
datetime g_news_freeze_until        = 0;

// --- Regime 判定用 ---
int   hADX_Regime = INVALID_HANDLE;   // RegimeTFのADX
double g_lastRegimeRB = 0.0;          // -1=Range, +1=Break, 0=Unknown

double g_temp_lot_mult = 1.0;   // 一時的にロットを増減（Boost用）

// --- Exit 抑止ラッチ（重複定義禁止：ここだけ） ---
int      g_exit_suppress_dir   = 0;      // +1/-1/0
datetime g_exit_suppress_until = 0;      // 期限（秒／バー換算）

int g_sigDir = 0;  // 現在のシグナル方向（+1=BUY, -1=SELL, 0=レンジ/無し）

//================= Utils ============================================
bool CopyBarTime(int sh, datetime &bt){ datetime t[]; if(CopyTime(_Symbol, InpTF, sh, 1, t)!=1) return false; bt=t[0]; return true; }
bool IsNewBar(){ datetime t[2]; if(CopyTime(_Symbol, InpTF, 0, 2, t)!=2) return false; if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; } return false; }

double HighN (int sh){ double v[]; return (CopyHigh (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double LowN  (int sh){ double v[]; return (CopyLow  (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double CloseN(int sh){ double v[]; return (CopyClose(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double OpenN (int sh){ double v[]; return (CopyOpen (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }

int DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=DigitsSafe(); return (dg==3||dg==5)? 10.0*pt: pt; }

bool GetFastBB(int sh,double &u,double &m,double &l){
  if(hBB==INVALID_HANDLE) return false;
  double bu[],bm[],bl[]; if(CopyBuffer(hBB,0,sh,1,bu)!=1) return false;
  if(CopyBuffer(hBB,1,sh,1,bm)!=1) return false;
  if(CopyBuffer(hBB,2,sh,1,bl)!=1) return false;
  u=bu[0]; m=bm[0]; l=bl[0]; return (u>0 && m>0 && l>0);
}

double RefHigh(){ double v=iHigh(_Symbol,RefTF,RefShift); return (v>0? v:0.0); }
double RefLow (){ double v=iLow (_Symbol,RefTF,RefShift);  return (v>0? v:0.0); }

double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask - t.bid)/_Point; }
bool SpreadOK(){ return SpreadPt()<=MaxSpreadPoints; }

void Notify(const string s){
  Print("[NOTIFY] ", s);
  if(AlertPopup) Alert(s);
  if(AlertPush)  SendNotification(s);
}

// ---- シンプルラベル（右上） ----
void ShowSigStatus(const string text, const color col)
{
   if(!ShowSigLabel) return;
   string nm = PFX + (string)"SIGLBL";
   if(ObjectFind(0,nm) < 0){
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   }
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,SigLabelX);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,SigLabelY);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,SigLabelFont);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,col);
   ObjectSetString (0,nm,OBJPROP_TEXT,text);
}

// ---- 大足フラグ（InpTFの確定足 i=1 で判定） ----
bool BigCandleFlags_EA(const int i,
                       const double atrv,
                       const double bb_up,
                       const double bb_dn,
                       bool &bigUp,
                       bool &bigDn)
{
   bigUp=false; bigDn=false;
   if(!Use_BigCandle) return false;

   const double hi = HighN(i);
   const double lo = LowN (i);
   const double op = OpenN(i);
   const double cl = CloseN(i);

   const bool bigBody   = (MathAbs(cl-op) > atrv * BigBody_ATR_K);
   const bool bigRange  = ((hi-lo)       > atrv * BigRange_ATR_K);
   const bool outsideUp = (cl > bb_up);
   const bool outsideDn = (cl < bb_dn);

   bigUp = ( (bigBody || bigRange) && cl>op && (!Need_BB_Outside || outsideUp) );
   bigDn = ( (bigBody || bigRange) && cl<op && (!Need_BB_Outside || outsideDn) );
   return (bigUp || bigDn);
}

// ---- Exit suppress helpers (single definition) ----
void SetExitSuppress(const int dirBigBreak){
   if(!SuppressExitOnTrendSignal){
      g_exit_suppress_dir   = 0;
      g_exit_suppress_until = 0;
      return;
   }
   if(dirBigBreak==0){
      g_exit_suppress_dir   = 0;
      g_exit_suppress_until = 0;
      return;
   }
   g_exit_suppress_dir = dirBigBreak;
   int secs = (SuppressExitSeconds>0 ? SuppressExitSeconds
                                     : PeriodSeconds(InpTF)*MathMax(1, SuppressExitBars));
   g_exit_suppress_until = TimeCurrent() + secs;
   PrintFormat("[EXIT SUPPRESS] dir=%s until=%s",
               (dirBigBreak>0? "BUY(+1)":"SELL(-1)"),
               TimeToString(g_exit_suppress_until, TIME_DATE|TIME_MINUTES|TIME_SECONDS));
}

bool ExitSuppressedForDir(const int dirPos){
   if(!SuppressExitOnTrendSignal || dirPos==0) return false;
   if(g_exit_suppress_dir==0) return false;
   if(TimeCurrent() > g_exit_suppress_until){
      g_exit_suppress_dir   = 0;
      g_exit_suppress_until = 0;
      return false;
   }
   return (dirPos == g_exit_suppress_dir);
}

//================= News / Calendar helpers ===========================
bool IsSymbolCurrency(const string ccy){
   string base   = (string)SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profit = (string)SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   return (StringCompare(ccy, base)==0 || StringCompare(ccy, profit)==0);
}

bool FindUpcomingCalendarEvent(int lookaheadMin,
                               ENUM_CALENDAR_EVENT_IMPORTANCE minImp,
                               bool onlySymbolCcy,
                               ulong &out_event_id,
                               datetime &out_event_time)
{
   out_event_id  = 0;
   out_event_time= 0;

   datetime nowST = TimeTradeServer();
   datetime fromT = nowST;
   datetime toT   = nowST + lookaheadMin*60;

   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, fromT, toT, NULL, NULL)){
      Print("CalendarValueHistory failed: ", GetLastError());
      return false;
   }
   datetime nearest = 0x7fffffff;
   ulong    chose_id= 0;

   for(int i=0; i<ArraySize(values); ++i){
      MqlCalendarEvent   ev;
      MqlCalendarCountry co;
      if(!CalendarEventById(values[i].event_id, ev))  continue;
      if(!CalendarCountryById(ev.country_id, co))     continue;

      if(ev.importance < minImp) continue;
      if(onlySymbolCcy && !IsSymbolCurrency(co.currency)) continue;

      if(values[i].time >= nowST && values[i].time < nearest){
         nearest  = values[i].time;
         chose_id = values[i].event_id;
      }
   }
   if(chose_id!=0){
      out_event_id   = chose_id;
      out_event_time = nearest;
      return true;
   }
   return false;
}

bool InPreNewsCloseWindow(int preMin,
                          ENUM_CALENDAR_EVENT_IMPORTANCE minImp,
                          bool onlySymbolCcy,
                          ulong &evt_id, datetime &evt_time)
{
   evt_id=0; evt_time=0;
   if(!UseCalendarCloseAll) return false;

   datetime nowST = TimeTradeServer();
   if(!FindUpcomingCalendarEvent(240, minImp, onlySymbolCcy, evt_id, evt_time))
      return false;

   datetime startWin = evt_time - preMin*60;
   return (nowST >= startWin && nowST < evt_time);
}

bool CloseAllForScope(CLOSE_SCOPE scope, bool pendingsToo)
{
   bool all_ok = true;

   for(int i = PositionsTotal() - 1; i >= 0; --i){
      ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
      string sym   = (string)PositionGetString(POSITION_SYMBOL);
      long   mgc   = (long)PositionGetInteger(POSITION_MAGIC);

      if(scope==CLOSE_THIS_SYMBOL && sym != _Symbol) continue;
      if(scope==CLOSE_THIS_MAGIC_ALL_SYMBOLS && mgc != Magic) continue;

      g_lastCloseContext = "NEWS_CLOSE";

      trade.SetExpertMagicNumber(Magic);
      trade.SetDeviationInPoints(SlippagePoints);

      bool ok=false; int tries=0;
      while(tries<=RetryCount && !ok){
         ok = trade.PositionClose(ticket);
         if(!ok) Sleep(RetryWaitMillis);
         tries++;
      }
      if(!ok){
         Print("NEWS close pos failed ticket=", ticket, " err=", GetLastError());
         all_ok=false;
      }
   }

   if(pendingsToo){
      for(int oi = OrdersTotal() - 1; oi >= 0; --oi){
         ulong tk = OrderGetTicket((uint)oi); if(tk == 0) continue;
         if(!OrderSelect(tk)) continue;

         string sym = (string)OrderGetString(ORDER_SYMBOL);
         long   mgc = (long)OrderGetInteger(ORDER_MAGIC);

         if(scope==CLOSE_THIS_SYMBOL && sym != _Symbol) continue;
         if(scope==CLOSE_THIS_MAGIC_ALL_SYMBOLS && mgc != Magic) continue;

         bool ok=false; int tries=0;
         while(tries<=RetryCount && !ok){
            ok = trade.OrderDelete(tk);
            if(!ok) Sleep(RetryWaitMillis);
            tries++;
         }
         if(!ok){
            Print("NEWS delete order failed ticket=", tk, " err=", GetLastError());
            all_ok=false;
         }
      }
   }
   return all_ok;
}

string ImpStr(int imp){
   if(imp == CALENDAR_IMPORTANCE_HIGH)     return "HIGH";
   if(imp == CALENDAR_IMPORTANCE_MODERATE) return "MEDIUM";
   if(imp == CALENDAR_IMPORTANCE_LOW)      return "LOW";
   return "N/A";
}

void DumpUpcomingNews(int lookaheadMin, ENUM_CALENDAR_EVENT_IMPORTANCE minImp, bool onlySymbolCcy){
   datetime nowST = TimeTradeServer();
   datetime toT   = nowST + lookaheadMin*60;

   MqlCalendarValue v[];
   if(!CalendarValueHistory(v, nowST, toT, NULL, NULL)){
      PrintFormat("[NEWS DBG] CalendarValueHistory failed err=%d", GetLastError());
      return;
   }
   int hits=0;
   for(int i=0;i<ArraySize(v);++i){
      MqlCalendarEvent ev; MqlCalendarCountry co;
      if(!CalendarEventById(v[i].event_id, ev))  continue;
      if(!CalendarCountryById(ev.country_id, co)) continue;

      if(ev.importance < minImp) continue;
      if(onlySymbolCcy && !IsSymbolCurrency(co.currency)) continue;

      PrintFormat("[NEWS DBG] id=%I64u t=%s ccy=%s imp=%s name=%s",
            v[i].event_id,
            TimeToString(v[i].time, TIME_DATE|TIME_MINUTES),
            co.currency,
            ImpStr(ev.importance),
            ev.name);
      hits++;
   }
   PrintFormat("[NEWS DBG] total hits=%d in next %d min (minImp=%s onlySym=%s)",
               hits, lookaheadMin, ImpStr(minImp), (onlySymbolCcy?"true":"false"));
}

//================= Margin / Lots ====================================
double SymbolMinLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return (s>0)?s:LotStepFallback; }

double NormalizeVolume(double vol){
  double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep();
  vol = MathMax(vmin, MathMin(vmax, vol));
  vol = MathRound(vol / vstp) * vstp;
  return vol;
}
double RoundLotToStep(double lot){ double step=SymbolLotStep(); return MathFloor(lot/step)*step; }

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

bool IsHedgingAccount(){ long mm=(long)AccountInfoInteger(ACCOUNT_MARGIN_MODE); return (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING); }
int  CountPositionsSide(int dir){
  int cnt=0;
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long t=(long)PositionGetInteger(POSITION_TYPE);
    int  d=(t==POSITION_TYPE_BUY? +1:-1);
    if(d==dir) cnt++;
  }
  return cnt;
}
int  CountMyPositions(int dir){ return CountPositionsSide(dir); }
int  CurrentDir_Netting(){
  if(!PositionSelect(_Symbol)) return 0;
  if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) return 0;
  long t=(long)PositionGetInteger(POSITION_TYPE);
  if(t==POSITION_TYPE_BUY)  return +1;
  if(t==POSITION_TYPE_SELL) return -1;
  return 0;
}
bool EnoughSpacingSameSide(int dir){
  if(MinGridPips<=0) return true;
  double p=GetPip(), ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
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

//================= Volatility / Guards ==============================
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
  bool atrFreeze  = (g_atr_freeze_until>0 && now<=g_atr_freeze_until);
  return atrFreeze;
}

//================= Close helpers (with exit suppression) ============
bool ClosePositionsWithFlattenRule(const int dir){
  g_lastCloseContext = "ATR_FLATTEN";
  bool ok_all=true, more=true;

  while(more){
    more=false;

    for(int i=PositionsTotal()-1; i>=0; --i){
      ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket))                continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic)     continue;

      long ptypeL = (long)PositionGetInteger(POSITION_TYPE);
      int  d      = (ptypeL==POSITION_TYPE_BUY ? +1 : -1);

      // dir フィルタ（0なら両方、±1ならその方向のみ）
      if(dir!=0 && d!=dir) continue;

      // ブレイク/大足で抑止中ならこの方向のクローズはスキップ
      if(ExitSuppressedForDir(d)) continue;

      bool shouldClose = true;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double pip  = GetPip();

      double pp = (ptypeL==POSITION_TYPE_BUY ? (bid-open)/pip : (open-ask)/pip);
      if(FlattenCloseMode==FLAT_CLOSE_LOSERS_ONLY)
         shouldClose = (pp<=0.0);
      else if(FlattenCloseMode==FLAT_KEEP_WINNERS_ABOVE)
         if(pp>=KeepWinnerMinPips) shouldClose=false;

      if(!shouldClose) continue;

      trade.SetExpertMagicNumber(Magic);
      trade.SetDeviationInPoints(SlippagePoints);

      bool r=false; int tries=0;
      while(tries<=RetryCount && !r){
        r = trade.PositionClose(ticket);
        if(!r) Sleep(RetryWaitMillis);
        tries++;
      }
      if(!r){
        ok_all=false;
        Print("Close ticket ",ticket," err=",GetLastError());
      }
      more=true; break; // 1件処理したら再スキャン
    }
  }
  return ok_all;
}

bool ClosePositionsBeyondLossPoints(double lossPtsThreshold){
  g_lastCloseContext = "PERPOS_SL";
  bool anyClosed=false, more=true;

  while(more){
    more=false;

    for(int i=PositionsTotal()-1; i>=0; --i){
      ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket))                continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic)     continue;

      long   ptypeL = (long)PositionGetInteger(POSITION_TYPE);
      int    dirPos = (ptypeL==POSITION_TYPE_BUY ? +1 : -1);

      // 抑止中の方向はスキップ
      if(ExitSuppressedForDir(dirPos)) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double lossPts = (ptypeL==POSITION_TYPE_BUY)
                       ? (open - bid)/_Point
                       : (ask  - open)/_Point;

      if(lossPts >= lossPtsThreshold){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);

        bool r=false; int tries=0;
        while(tries<=RetryCount && !r){
          r = trade.PositionClose(ticket);
          if(!r) Sleep(RetryWaitMillis);
          tries++;
        }
        if(!r){
          Print("PerPosSL close failed ticket=",ticket," err=",GetLastError());
        }
        anyClosed |= r;
        more=true;  // 1件処理したら再スキャン
        break;
      }
    }
  }
  return anyClosed;
}

double NormalizePrice(double price){ int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); return NormalizeDouble(price,dg); }

// 既存トレール（Regime切替OFFのとき使う）
void UpdateTrailingStopsForAll(){
  if(!UseTrailing) return;
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double pt  = _Point;
  long   stopLevel  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

  for(int i=PositionsTotal()-1; i>=0; --i){
    ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
    if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;

    long   ptype = (long)PositionGetInteger(POSITION_TYPE);
    double open  = PositionGetDouble(POSITION_PRICE_OPEN);
    double curSL = PositionGetDouble(POSITION_SL);

    double refPx=0.0, profitPts=0.0, wantSL=0.0;

    if(ptype==POSITION_TYPE_BUY){
      refPx     = bid;
      profitPts = (bid - open) / pt;
      if(profitPts < TrailStart_Points) continue;
      wantSL = refPx - TrailOffset_Points*pt;
      if(curSL>0 && wantSL <= curSL + TrailStep_Points*pt) continue;
      if(wantSL <= open) wantSL = open + 1*pt;
      if((refPx - wantSL) < (stopLevel+1)*pt) wantSL = refPx - (stopLevel+1)*pt;
    }else if(ptype==POSITION_TYPE_SELL){
      refPx     = ask;
      profitPts = (open - ask) / pt;
      if(profitPts < TrailStart_Points) continue;
      wantSL = refPx + TrailOffset_Points*pt;
      if(curSL>0 && wantSL >= curSL - TrailStep_Points*pt) continue;
      if(wantSL >= open) wantSL = open - 1*pt;
      if((wantSL - refPx) < (stopLevel+1)*pt) wantSL = refPx + (stopLevel+1)*pt;
    }else continue;

    wantSL = NormalizePrice(wantSL);
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(SlippagePoints);
    bool ok=false; int tries=0;
    while(tries<=RetryCount && !ok){ ok = trade.PositionModify(ticket, wantSL, 0.0); if(!ok) Sleep(RetryWaitMillis); tries++; }
    if(!ok) Print("Trail modify failed ticket=",ticket," err=",GetLastError());
  }
}

//================= Regime（Range/BreakでTP/SL切替） ==================
bool FastBBW_Z_EA(int look, int sh, double &z){
   if(look < 20) look = 20;
   double ub[], lb[];
   if(CopyBuffer(hBB,0,sh,look,ub)!=look) return false;
   if(CopyBuffer(hBB,2,sh,look,lb)!=look) return false;
   double s=0, s2=0;
   for(int i=0;i<look;i++){
      double w = (ub[i]-lb[i])/_Point;
      s+=w; s2+=w*w;
   }
   double n=look, mean=s/n, var=MathMax(1e-12, s2/n-mean*mean), sd=MathSqrt(var);
   double cur=(ub[0]-lb[0])/_Point;
   z = (sd>0 ? (cur-mean)/sd : 0.0);
   return true;
}

bool GetADX_RegimeTF(int sh, double &adx){
   if(hADX_Regime==INVALID_HANDLE) return false;
   double d[]; if(CopyBuffer(hADX_Regime,0,sh,1,d)!=1) return false;
   adx = d[0]; return true;
}

int DetectRegimeRB(int sh){
   double adx=0, z=0;
   int voteBreak=0, voteRange=0;

   if(GetADX_RegimeTF(sh, adx)){
      if(adx >= RegADX_Thr_Break) voteBreak++;
      else if(adx <= RegADX_Thr_Range) voteRange++;
   }
   if(FastBBW_Z_EA(RegBBW_Lookback, sh, z)){
      if(z >= RegBBW_Z_BreakMin) voteBreak++;
      else if(z <= RegBBW_Z_RangeMax) voteRange++;
   }

   if(voteBreak>voteRange) return +1;
   if(voteRange>voteBreak) return -1;
   return 0;
}

void ApplyExitByRegime(){
   if(!UseRegimeExitSwitch) return;

   int r  = DetectRegimeRB(0);
   if(r==0) r = (int)g_lastRegimeRB;
   if(r==0) r = +1; // 初期はBreak寄り
   g_lastRegimeRB = r;

   bool isRange = (r<0);
   double pt      = _Point;
   int    trailW  = (isRange ? Trail_Range_Points : Trail_Break_Points);
   int    stepW   = MathMax(1, TrailStep_Points_RB);
   double tpPips  = (isRange ? TP_Range_Pips : TP_Break_Pips);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=PositionsTotal()-1; i>=0; --i){
      ulong tk = PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;

      long   typ  = (long)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL= PositionGetDouble(POSITION_SL);
      double curTP= PositionGetDouble(POSITION_TP);

      double wantTP = (typ==POSITION_TYPE_BUY) ? (open + tpPips*pt) : (open - tpPips*pt);
      double ref    = (typ==POSITION_TYPE_BUY ? bid : ask);
      double wantSL = 0.0;

      if(typ==POSITION_TYPE_BUY){
         wantSL = MathMax(open + 1*pt, ref - trailW*pt);
         if(RegimeExitOnlyImprove && curSL>0 && wantSL <= curSL + stepW*pt) wantSL = curSL;
      }else{
         wantSL = MathMin(open - 1*pt, ref + trailW*pt);
         if(RegimeExitOnlyImprove && curSL>0 && wantSL >= curSL - stepW*pt) wantSL = curSL;
      }

      if(RegimeExitOnlyImprove){
         if(typ==POSITION_TYPE_BUY){
            if(curTP>0 && wantTP < curTP) wantTP = curTP;
            if(curSL>0 && wantSL < curSL) wantSL = curSL;
         }else{
            if(curTP>0 && wantTP > curTP) wantTP = curTP;
            if(curSL>0 && wantSL > curSL) wantSL = curSL;
         }
      }

      bool changeTP = (curTP<=0 || MathAbs(wantTP - curTP) > (0.1*pt));
      bool changeSL = (curSL<=0 || MathAbs(wantSL - curSL) > (0.1*pt));
      if(!(changeTP || changeSL)) continue;

      trade.SetExpertMagicNumber(Magic);
      trade.SetDeviationInPoints(SlippagePoints);
      if(!trade.PositionModify(tk, wantSL, wantTP)){
         PrintFormat("[REG_EXIT] modify failed tk=%I64u SL:%.5f->%.5f TP:%.5f->%.5f err=%d",
                     tk, curSL, wantSL, curTP, wantTP, GetLastError());
      }
   }
}

//================= Range 判定（価格ベース + BB補助） ==================
struct RangeInfo {
   double   refH, refL;
   datetime refStart;
   double   lastProbe;     // 直近の判定に使った価格（close or wick）
   bool     priceInside;   // 内側判定
   bool     bbAssistUsed;
};
enum RangeState { RANGE_UNKNOWN=0, RANGE_IN=1, RANGE_BREAK=2 };

double _PipsToPrice(double p){ return p * GetPip(); }

RangeState GetRangeStateForSignal(const int sh, RangeInfo &ri)
{
   ri.refH=0; ri.refL=0; ri.refStart=0; ri.lastProbe=0; ri.priceInside=false; ri.bbAssistUsed=false;

   datetime bt[];
   if(CopyTime(_Symbol, InpTF, sh, 1, bt)!=1) return RANGE_UNKNOWN;
   int refIdx = iBarShift(_Symbol, RangeRefTF_Signal, bt[0], true);
   if(refIdx < 0) return RANGE_UNKNOWN;

   ri.refH     = iHigh (_Symbol, RangeRefTF_Signal, refIdx);
   ri.refL     = iLow  (_Symbol, RangeRefTF_Signal, refIdx);
   ri.refStart = iTime (_Symbol, RangeRefTF_Signal, refIdx);

   double tolPx_fixed = RangeTolPoints * _Point;
   double tolPx_atr   = 0.0;
   if(RangeUseATRTol && hATR_TF!=INVALID_HANDLE){
      double a[]; if(CopyBuffer(hATR_TF,0,sh,1,a)==1){
         double atrPips = a[0]/GetPip();
         tolPx_atr = _PipsToPrice(atrPips * RangeATR_Mult);
      }
   }
   double tolPx = MathMax(tolPx_fixed, tolPx_atr);

   double hi=HighN(sh), lo=LowN(sh), cl=CloseN(sh);
   double probeUp   = RangeUseCloseBreak ? cl : hi;
   double probeDown = RangeUseCloseBreak ? cl : lo;
   ri.lastProbe = (MathAbs(probeUp - ri.refH) < MathAbs(probeDown - ri.refL)) ? probeUp : probeDown;

   double brkPx = _PipsToPrice(RangeBreak_Pips);
   bool outUp   = (probeUp   >= ri.refH + brkPx);
   bool outDn   = (probeDown <= ri.refL - brkPx);
   bool outNow  = outUp || outDn;

   int outsideCount = 0;
   if(outNow){
      int need = MathMax(1, RangeHoldBars);
      for(int i=0;i<need;i++){
         double hi_i=HighN(sh+i), lo_i=LowN(sh+i), cl_i=CloseN(sh+i);
         double up_i   = RangeUseCloseBreak ? cl_i : hi_i;
         double down_i = RangeUseCloseBreak ? cl_i : lo_i;
         bool up  = (up_i   >= ri.refH + brkPx);
         bool dn  = (down_i <= ri.refL - brkPx);
         if(!(up||dn)) break;
         outsideCount++;
      }
   }

   double reenterPx = _PipsToPrice(RangeReenter_Pips);
   bool backInside  = (cl <= ri.refH + MathMax(tolPx, reenterPx)) &&
                      (cl >= ri.refL - MathMax(tolPx, reenterPx));

   if(outsideCount >= MathMax(1, RangeHoldBars)){
      ri.priceInside=false;
      return backInside ? RANGE_IN : RANGE_BREAK;
   }else{
      bool inside = (ri.lastProbe <= ri.refH + tolPx) && (ri.lastProbe >= ri.refL - tolPx);
      ri.priceInside = inside;
      return inside ? RANGE_IN : RANGE_BREAK;
   }
}

//================= Panel（簡易） ====================================
void UpdatePanel(){
  if(!ShowPanel) return;
  string nm=PFX+"PANEL";
  if(ObjectFind(0,nm)<0){
    ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,nm,OBJPROP_CORNER,(long)PanelCorner);
    ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,PanelX);
    ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,PanelY);
    ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,PanelFontSize);
    ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
  }
  int buyCnt=CountMyPositions(+1), sellCnt=CountMyPositions(-1);
  double equity=AccountInfoDouble(ACCOUNT_EQUITY);
  double used=GetCurrentTotalRequiredMargin();
  double ml=(used>0.0)? (equity/used*100.0) : 99999.0;

  string txt=StringFormat("BB Doten RangeHybrid | %s %s | BUY:%d SELL:%d | ML:%.1f%% Spread:%.1fpt",
              _Symbol, EnumToString(InpTF), buyCnt, sellCnt, ml, SpreadPt());
  ObjectSetString(0,nm,OBJPROP_TEXT,txt);
}

//================= Open/Close/Execute ===============================
bool CloseDirPositions(int dir){
  g_lastCloseContext = "DOTEN";
  bool ok_all=true, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int  d=(t==POSITION_TYPE_BUY? +1:-1);
      if(dir==0 || d==dir){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);
        bool r=false; int tries=0;
        while(tries<=RetryCount && !r){ r=trade.PositionClose(ticket); if(!r) Sleep(RetryWaitMillis); tries++; }
        if(!r){ ok_all=false; Print("Close ticket ",ticket," err=",GetLastError()); }
        more=true; break;
      }
    }
  }
  return ok_all;
}

double ComputeTieredAdaptiveLot(int dir, int sameCnt){
  double base = (sameCnt < 2 ? FirstTwoLots : ThirdPlusLots);
  double s = 1.0;
  if(UseTieredAdaptiveLots && TierBaselineEquity > 0.0){
    double eqs = AccountInfoDouble(ACCOUNT_EQUITY);
    s = MathPow(eqs / TierBaselineEquity, TierExponent);
    s = MathMax(TierMinScale, MathMin(TierMaxScale, s));
  }
  double req = base * s;
  if(sameCnt >= 2) req = MathMin(req, MaxAddLot);
  if(TierRespectRiskCap && UsePerPosSL && PerPosSL_Points > 0){
    double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
    double risk = eq * (RiskPctPerTrade/100.0);
    double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double mpp  = (ts>0.0 ? tv/ts : 0.0);
    if(mpp>0.0){ double est = PerPosSL_Points*mpp; double lot_by_risk=risk/est; req=MathMin(req,lot_by_risk); }
  }
  ENUM_ORDER_TYPE ot=(dir>0? ORDER_TYPE_BUY:ORDER_TYPE_SELL);
  double maxML = CalcMaxAddableLotsForTargetML(ot);
  if(maxML<=0.0) return 0.0;
  double lots = NormalizeVolume(MathMin(req, maxML));
  if(sameCnt<2){ if(lots<SymbolMinLot()) return 0.0; } else { if(lots<MinAddLot) return 0.0; }
  return lots;
}

bool OpenDirWithGuard(int dir){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);

  int sameCnt=CountPositionsSide(dir);
  if(IsHedgingAccount() && AllowMultiple){
    if(sameCnt>=MaxAddPositionsSide) return false;
    if(!EnoughSpacingSameSide(dir))  return false;
  }

  double lots = 0.0;
  if(UseTieredAdaptiveLots){
    lots = ComputeTieredAdaptiveLot(dir, sameCnt);
    if(lots<=0.0) return false;
  }else{
    double maxLot = CalcMaxAddableLotsForTargetML((dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
    if(maxLot<=0.0) return false;
    double fixedLot = NormalizeVolume(Lots);
    if(UseRiskLots && UsePerPosSL && PerPosSL_Points>0){
      double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
      double risk = eq * (RiskPctPerTrade/100.0);
      double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double mpp  = (ts>0.0 ? tv/ts : 0.0);
      if(mpp>0.0){ double est = PerPosSL_Points*mpp; double lot_by_risk=risk/est; fixedLot=NormalizeVolume(lot_by_risk); }
    }
    if(sameCnt < 2){
      double candidate = NormalizeVolume(MathMin(fixedLot, maxLot));
      if(UseSoftFirstLots){
        if(maxLot < MinAddLot) return false;
        if(candidate < MinAddLot) candidate = NormalizeVolume(MinAddLot);
      }
      lots = candidate;
      if(lots < SymbolMinLot()) return false;
    }else{
      lots = NormalizeVolume(MathMin(maxLot, MaxAddLot));
      if(lots < MinAddLot) return false;
    }
  }

  bool ok=false; int tries=0;
  while(tries<=RetryCount && !ok){
    ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
    if(!ok) Sleep(RetryWaitMillis);
    tries++;
  }
  return ok;
}

// dir: +1=BUY, -1=SELL
bool CloseThenDoten_BySignal(int dir){
  int oppoCnt = CountMyPositions(-dir);
  if(oppoCnt > 0){
    g_in_doten_sequence = true;
    g_suppress_reverse_until = TimeCurrent() + 2;
    if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
    Notify((dir>0) ? "[FORCE CLOSE SELL]" : "[FORCE CLOSE BUY]");
  }

  if(DotenAllowWideSpread){
    double sp = SpreadPt();
    bool overNormal = (sp > MaxSpreadPoints);
    bool withinDoten = (DotenMaxSpreadPoints<=0) ? true : (sp <= DotenMaxSpreadPoints);
    if(overNormal && withinDoten){
      double volUQ = 0.0;
      int sameCntDir = CountPositionsSide(dir);
      if(UseTieredAdaptiveLots) volUQ = ComputeTieredAdaptiveLot(dir, sameCntDir);
      if(volUQ <= 0.0){ volUQ = NormalizeVolume(Lots); if(sameCntDir >= 2 && volUQ < MinAddLot) volUQ = NormalizeVolume(MinAddLot); }
      if(volUQ < SymbolMinLot()){ g_in_doten_sequence=false; return false; }

      CTrade t2; t2.SetExpertMagicNumber(Magic); t2.SetDeviationInPoints(SlippagePoints);
      bool okForce = (dir>0)? t2.Buy(volUQ,_Symbol) : t2.Sell(volUQ,_Symbol);
      g_last_reverse_at = TimeCurrent();
      g_in_doten_sequence=false;
      if(okForce) Notify((dir>0) ? "[OPEN BUY DOTEN (WIDE)]" : "[OPEN SELL DOTEN (WIDE)]");
      return okForce;
    }
  }

  if(DotenRespectGuards){
    string why=""; if(!AllGuardsPass(0, why)){
      if(!DotenUseUQFallback){ g_in_doten_sequence=false; return false; }
    }else{
      bool ok = OpenDirWithGuard(dir);
      g_in_doten_sequence=false;
      if(ok){ g_last_reverse_at = TimeCurrent(); Notify((dir>0) ? "[OPEN BUY DOTEN]" : "[OPEN SELL DOTEN]"); return true; }
      if(!DotenUseUQFallback) return false;
    }
  }

  double volUQ = 0.0;
  int sameCntDir = CountPositionsSide(dir);
  if(UseTieredAdaptiveLots) volUQ = ComputeTieredAdaptiveLot(dir, sameCntDir);
  if(volUQ <= 0.0){ volUQ = NormalizeVolume(Lots); if(sameCntDir >= 2 && volUQ < MinAddLot) volUQ = NormalizeVolume(MinAddLot); }
  if(volUQ < SymbolMinLot()){ g_in_doten_sequence=false; return false; }

  CTrade t; t.SetExpertMagicNumber(Magic); t.SetDeviationInPoints(SlippagePoints);
  bool ok2 = (dir>0) ? t.Buy (volUQ, _Symbol) : t.Sell(volUQ, _Symbol);
  g_last_reverse_at = TimeCurrent();
  g_in_doten_sequence=false;
  return ok2;
}

bool ExecuteBySignalDir(int dir){
  if(!SpreadOK()) return false;
  bool hedging = IsHedgingAccount();

  if(hedging && AllowMultiple){
    int oppo = CountMyPositions(-dir);
    if(oppo > 0 && !AllowOppositeHedge){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(-dir)) { g_in_doten_sequence=false; return false; }
      Notify(((-dir)>0) ? "[CLOSE BUY ALL]" : "[CLOSE SELL ALL]");
    }
    bool opened = OpenDirWithGuard(dir);
    if(!opened){ g_in_doten_sequence=false; return false; }
    g_in_doten_sequence=false;
    g_last_reverse_at   = TimeCurrent();
    Notify((dir>0) ? "[OPEN BUY ADD]" : "[OPEN SELL ADD]");
    return true;
  }else{
    int cur = CurrentDir_Netting();
    if(cur == dir) return true;
    if(cur != 0){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(0)) { g_in_doten_sequence=false; return false; }
      Notify((cur>0) ? "[CLOSE BUY]" : "[CLOSE SELL]");
    }
    bool opened = OpenDirWithGuard(dir);
    if(!opened){ g_in_doten_sequence=false; return false; }
    g_in_doten_sequence=false;
    g_last_reverse_at = TimeCurrent();
    Notify((dir>0) ? "[OPEN BUY]" : "[OPEN SELL]");
    return true;
  }
}

//================= Signals ==========================================
void LogSignalWrap(int dir,int sh,double refPx,double u,double m,double l,double probe,datetime sigBar,datetime sigRef){
  PrintFormat("[SIG] %s Bar=%s Ref=%s RefPx=%.5f BB=%.5f/%.5f/%.5f probe=%.5f tol=%d",
    (dir>0?"BUY":"SELL"),
    TimeToString(sigBar, TIME_DATE|TIME_MINUTES),
    TimeToString(sigRef, TIME_DATE|TIME_MINUTES),
    refPx,u,m,l,probe,TouchTolPoints);
}
bool SignalSELL(int sh, datetime &sigBar, datetime &sigRef){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  double refH=RefHigh(); if(refH<=0) return false;

  const double tol  = TouchTolPoints*_Point;
  const double tolB = BandTouchTolPts*_Point;

  double hi   = HighN(sh);
  double cl   = CloseN(sh);
  double op   = OpenN(sh);
  double probe= (UseWickForTouch ? hi : cl);

  bool touchBB     = (u >= refH - tol && u <= refH + tol);
  bool touchPx     = (!RequirePriceTouch) || (probe >= refH - tol);
  bool bandTouchOK = (!RequireBandTouch)  || (probe >= u - tolB);
  bool pass_refbb  = (touchBB && touchPx && bandTouchOK)
                  || (AllowPriceOnlyTouch && !RequireBandTouch && (probe >= refH - tol));

  bool pass_loose = false;
  if(UseLooseReentry){
    double u1,m1,l1; bool ok_prev = GetFastBB(sh+1,u1,m1,l1);
    double c1 = CloseN(sh+1);
    bool prevOutside = ok_prev && (c1 >= u1 + tolB);
    bool nowInside   =             (cl <= u  - tolB);
    bool reenter     = (prevOutside && nowInside);
    bool bearishFail = (hi >= u - tolB) && (cl < op);
    pass_loose = reenter || bearishFail;
  }

  bool pass = (SignalMode==STRICT_REFxBB)? pass_refbb
              : (SignalMode==LOOSE_BBONLY)? pass_loose
              : (pass_refbb || pass_loose);
  if(!pass) return false;

  if(!CopyBarTime(sh,sigBar)) return false;
  sigRef = iTime(_Symbol,RefTF,RefShift); if(sigRef==0) sigRef=sigBar;
  return true;
}
bool SignalBUY(int sh, datetime &sigBar, datetime &sigRef){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  double refL=RefLow(); if(refL<=0) return false;

  const double tol  = TouchTolPoints*_Point;
  const double tolB = BandTouchTolPts*_Point;

  double lo   = LowN(sh);
  double cl   = CloseN(sh);
  double op   = OpenN(sh);
  double probe= (UseWickForTouch ? lo : cl);

  bool touchBB     = (l >= refL - tol && l <= refL + tol);
  bool touchPx     = (!RequirePriceTouch) || (probe <= refL + tol);
  bool bandTouchOK = (!RequireBandTouch)  || (probe <= l + tolB);
  bool pass_refbb  = (touchBB && touchPx && bandTouchOK)
                  || (AllowPriceOnlyTouch && !RequireBandTouch && (probe <= refL + tol));

  bool pass_loose = false;
  if(UseLooseReentry){
    double u1,m1,l1; bool ok_prev = GetFastBB(sh+1,u1,m1,l1);
    double c1 = CloseN(sh+1);
    bool prevOutside = ok_prev && (c1 <= l1 - tolB);
    bool nowInside   =             (cl >= l  + tolB);
    bool reenter     = (prevOutside && nowInside);
    bool bullishWick = (lo <= l + tolB) && (cl > op);
    pass_loose = reenter || bullishWick;
  }

  bool pass = (SignalMode==STRICT_REFxBB)? pass_refbb
              : (SignalMode==LOOSE_BBONLY)? pass_loose
              : (pass_refbb || pass_loose);
  if(!pass) return false;

  if(!CopyBarTime(sh,sigBar)) return false;
  sigRef = iTime(_Symbol,RefTF,RefShift); if(sigRef==0) sigRef=sigBar;
  return true;
}

//================= Trade Transaction（反転） =========================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&      request,
                        const MqlTradeResult&       result)
{
  if(!(UseReverseOnClose || UseReverseOnCloseUQ)) return;
  if(trans.type != TRADE_TRANSACTION_DEAL_ADD)    return;

  ulong deal_id = trans.deal; if(deal_id==0) return;

  datetime now = TimeCurrent();
  HistorySelect(now - 7*24*60*60, now + 60);

  string  deal_sym   = (string)HistoryDealGetString (deal_id, DEAL_SYMBOL);
  long    deal_magic = (long)  HistoryDealGetInteger(deal_id, DEAL_MAGIC);
  long    deal_entry = (long)  HistoryDealGetInteger(deal_id, DEAL_ENTRY);
  long    deal_type  = (long)  HistoryDealGetInteger(deal_id, DEAL_TYPE);
  double  deal_vol   =         HistoryDealGetDouble (deal_id, DEAL_VOLUME);

  if(deal_sym  != _Symbol) return;
  if(deal_magic != Magic)  return;
  if(deal_entry != DEAL_ENTRY_OUT) return;
  if(deal_vol  <= 0.0)     return;

  long deal_reason = (long)HistoryDealGetInteger(deal_id, DEAL_REASON);
  bool isBrokerSL  = (deal_reason == DEAL_REASON_SL);
  bool isExpert    = (deal_reason == DEAL_REASON_EXPERT);
  bool isPerPos    = (isExpert && g_lastCloseContext == "PERPOS_SL");

  if(ReverseSkipOnBrokerSL && isBrokerSL) return;
  if(ReverseOnlyOnPerPosSL){
    if(!( isPerPos || (ReverseAlsoOnBrokerSL && isBrokerSL) )) return;
  }

  if(g_in_doten_sequence) return;
  if(now <= g_suppress_reverse_until) return;

  int newDir = (deal_type == DEAL_TYPE_SELL) ? -1 : +1;
  bool reverseAlready=false;

  if(UseReverseOnClose){
    if((g_last_reverse_at > 0) && (now - g_last_reverse_at < ReverseMinIntervalSec)){
      // skip → UQへ
    }else{
      bool guardedOK = true;
      if(ReverseRespectGuards){ string why=""; if(!AllGuardsPass(0, why)){ guardedOK=false; } }
      if(guardedOK){
        if(ReverseDelayMillis > 0) Sleep(ReverseDelayMillis);
        bool ok = OpenDirWithGuard(newDir);
        if(ok){
          g_last_reverse_at        = TimeCurrent();
          g_suppress_reverse_until = TimeCurrent() + ReverseMinIntervalSec;
          reverseAlready = true;
          Notify(StringFormat("[REVERSE ENTER] dir=%s ctx=%s",(newDir>0? "BUY":"SELL"), g_lastCloseContext));
        }
      }
    }
  }

  if(UseReverseOnCloseUQ && !reverseAlready){
    int sameCntDir = CountPositionsSide(newDir);
    double volUQ = 0.0;
    if(UseTieredAdaptiveLots) volUQ = ComputeTieredAdaptiveLot(newDir, sameCntDir);
    if(volUQ <= 0.0 && ReverseUseMLGuardLots){
      volUQ = CalcMaxAddableLotsForTargetML(newDir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      volUQ = NormalizeVolume(volUQ);
    }
    if(volUQ <= 0.0){ double baseVol = (ReverseUseSameVolume ? deal_vol : ReverseFixedLots); volUQ = NormalizeVolume(baseVol); }
    if(volUQ < SymbolMinLot()){ g_lastCloseContext = "-"; return; }
    if(ReverseDelayMillis > 0) Sleep(ReverseDelayMillis);
    CTrade t; t.SetExpertMagicNumber(Magic); t.SetDeviationInPoints(SlippagePoints);
    bool ok2 = (newDir > 0) ? t.Buy (volUQ, _Symbol) : t.Sell(volUQ, _Symbol);
    PrintFormat("[UQ-REVERSE] dir=%s vol=%.2f ok=%s", (newDir>0?"BUY":"SELL"), volUQ, (ok2?"true":"false"));
  }
  g_lastCloseContext = "-";
}

//================= Lifecycle =======================================
int OnInit(){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);

  hBB = iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE);
  if(hBB==INVALID_HANDLE){ Print("ERR iBands(Fast)"); return INIT_FAILED; }

  hATR_TF = iATR(_Symbol, InpTF, ATR_Period);
  if(hATR_TF==INVALID_HANDLE){ Print("ERR iATR(InpTF)"); return INIT_FAILED; }

  hATR_M1 = iATR(_Symbol, SpeedTF, ATR_Period);
  if(hATR_M1==INVALID_HANDLE){ Print("WARN iATR(SpeedTF) failed"); }

  hBBslow_range = iBands(_Symbol, InpTF, Slow_Period_Range, 0, Slow_Dev_Range, PRICE_CLOSE);
  if(hBBslow_range==INVALID_HANDLE){ Print("ERR iBands(SlowRange)"); /* 補助のみなので続行可 */ }

  if(UseRegimeExitSwitch){
    hADX_Regime = iADX(_Symbol, RegimeTF, RegADX_Period);
    if(hADX_Regime==INVALID_HANDLE) Print("WARN: iADX(RegimeTF) init failed");
  }

  datetime t0[]; if(CopyTime(_Symbol,InpTF,0,1,t0)==1) g_lastBar=t0[0];

  long stopLevel  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  long freezeLvl  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
  PrintFormat("[TRAIL] StopLevel=%ld FreezeLevel=%ld Start=%d Offset=%d Step=%d",
              stopLevel, freezeLvl, TrailStart_Points, TrailOffset_Points, TrailStep_Points);

  long mm = (long)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
  PrintFormat("[ACCOUNT] margin_mode=%d (%s)", (int)mm, (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING? "HEDGING":"NETTING"));
  if(DebugNews) DumpUpcomingNews(DebugNewsHorizonMin, MinImportance, OnlySymbolCurrencies);

  return INIT_SUCCEEDED;
}
void OnDeinit(const int){ string nm=PFX+"PANEL"; if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm); }

//==================================================================
// 全ガード通過チェック
//==================================================================
bool AllGuardsPass(int sh, string &whyNG)
{
   int spreadPt = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(MaxSpreadPoints > 0 && spreadPt > MaxSpreadPoints){
      whyNG = "spread_ng"; return false;
   }

   if(UseATR_Guard){
      double atrNow=0;
      if(GetATRpips(InpTF, ATR_Period, sh, atrNow)){
         if(atrNow > ATR_Max_Pips){
            whyNG = "atr_high"; return false;
         }
      }
   }

   if(UseBBW_Guard && hBB != INVALID_HANDLE){
      double ub[], lb[];
      if(CopyBuffer(hBB,0,sh,1,ub)==1 && CopyBuffer(hBB,2,sh,1,lb)==1){
         double bbw = (ub[0]-lb[0])/_Point;
         if(bbw < BBW_MinPoints){
            whyNG = "bbw_narrow"; return false;
         }
      }
   }

   if(UseSpeedGuard){
      double c0 = CloseN(sh);
      double c1 = CloseN(sh+SpeedLookback);
      if(c1 > 0){
         double spd = MathAbs(c0-c1)/_Point;
         if(spd > Speed_MaxPoints){
            whyNG = "speed_high"; return false;
         }
      }
   }

   if(CooldownBars > 0){
      int curBar = iBarShift(_Symbol, InpTF, TimeCurrent(), true);
      if(g_lastSigBar != 0){
         int lastBar = iBarShift(_Symbol, InpTF, g_lastSigBar, true);
         if(lastBar >= 0 && curBar >= 0 && (lastBar-curBar) < CooldownBars){
            whyNG = "cooldown"; return false;
         }
      }
   }

   whyNG = "";
   return true;
}

void OnTick(){
  g_cntOnTick++;

  // --- ニュース“事前クローズ” ---
  if(UseCalendarCloseAll){
     ulong evt_id; datetime evt_time;
     if(InPreNewsCloseWindow(CloseBeforeNewsMin,
                             MinImportance4Close,
                             OnlySymbolCurrenciesForClose,
                             evt_id, evt_time))
     {
        if(g_last_news_event_id_closed != evt_id){
           PrintFormat("[NEWS] Pre-close all. evt_id=%I64u t=%s",
                       evt_id, TimeToString(evt_time, TIME_DATE|TIME_MINUTES));

           bool ok = CloseAllForScope(CloseScope, CancelPendingsToo);
           if(ok){
              g_last_news_event_id_closed = evt_id;
              if(RefrainAfterNewsMin > 0)
                 g_news_freeze_until = evt_time + RefrainAfterNewsMin*60;
           }
        }
        return; // 直前は新規停止
     }
  }

  // --- ニュース前後“トレード禁止” ---
  if(UseCalendarNoTrade){
     ulong idNT; datetime tNT;
     bool hit = FindUpcomingCalendarEvent(BlockBeforeNewsMin + BlockAfterNewsMin,
                                          MinImportance, OnlySymbolCurrencies,
                                          idNT, tNT);
     if(hit){
        datetime nowST = TimeTradeServer();
        datetime fromT = tNT - BlockBeforeNewsMin*60;
        datetime toT   = tNT + BlockAfterNewsMin*60;
        if(nowST >= fromT && nowST <= toT){
           return; // 完全停止（保全系はここより前で処理）
        }
     }
  }

  // --- ニュース後“休む” ---
  if(g_news_freeze_until > 0 && TimeTradeServer() <= g_news_freeze_until){
     return;
  }

  g_sigDir = 0;

  // 保全：個別SL/トレール/Regime利確/パネル
  if(UsePerPosSL) ClosePositionsBeyondLossPoints(PerPosSL_Points);
  if(UseRegimeExitSwitch) ApplyExitByRegime();
  else if(UseTrailing)    UpdateTrailingStopsForAll();
  UpdatePanel();

  int sh=(TriggerImmediate?0:1);
  if(!TriggerImmediate && !IsNewBar()) return;

  // --- シグナル検出 ---
  datetime bS=0,rS=0,bB=0,rB=0;
  bool sigS=SignalSELL(sh,bS,rS);
  bool sigB=SignalBUY (sh,bB,rB);
  if(sigS==sigB) return; // 同時 or 無し

  g_cntSigDetected++;
  datetime sigBar=(sigS? bS:bB);
  datetime sigRef=(sigS? rS:rB);
  int      sigDir=(sigS? -1:+1);

  // --- デデュープ ---
  if(OnePerBar && sigBar==g_lastSigBar) return;
  if(OnePerRefBar && sigRef==g_lastSigRef) return;
  if(MinBarsBetweenSig>0 && g_lastSigBar>0){
    int cur=iBarShift(_Symbol,InpTF,sigBar,true);
    int last=iBarShift(_Symbol,InpTF,g_lastSigBar,true);
    if(last>=0 && cur>=0 && (last-cur)<MinBarsBetweenSig) return;
  }
  g_cntAfterDedup++;

  // --- ガード ---
  string why="";
  if(!AllGuardsPass(sh,why)){
    bool allow_doten_override=false;
    if(UseCloseThenDoten && DotenAllowWideSpread && why=="spread_ng"){
      double sp=SpreadPt(); bool within=(DotenMaxSpreadPoints<=0)?true:(sp<=DotenMaxSpreadPoints);
      if(within){ allow_doten_override=true; PrintFormat("[GUARD OVERRIDE] spread=%.1fpt <= %dpt", sp, DotenMaxSpreadPoints); }
    }
    if(!allow_doten_override){ g_lastGuardWhy=why; g_lastGuardAt=TimeCurrent(); return; }
  }
  g_cntGuardsPassed++;

  // --- Range gate ---
  RangeInfo  rng;
  RangeState rstate = GetRangeStateForSignal(sh, rng);
  PrintFormat("[RANGE TAG] %s | RefTF=%s H=%.5f L=%.5f probe=%.5f tol=%dpt %s",
              (rstate==RANGE_IN?"IN":"BREAK"),
              EnumToString(RangeRefTF_Signal), rng.refH, rng.refL, rng.lastProbe,
              RangeTolPoints, (rng.bbAssistUsed? "BBassist":""));

  if(RangeGateMode == ALLOW_BREAK_ONLY && rstate != RANGE_BREAK) return;
  if(RangeGateMode == ALLOW_RANGE_ONLY && rstate != RANGE_IN)    return;

  // === 「Ref シグナル」×「大足 or ブレイク」で最終方向を決定 ===

  // 1) Ref×BB の既存シグナル方向（sigDir）
  g_cntGuardsPassed++;

  // シグナル確定直後：エグジット抑止（方向=シグナル方向で暫定セット）
  if(SuppressExitOnTrendSignal && (sigDir==+1 || sigDir==-1)){
     SetExitSuppress(sigDir);
  }

  // 2) InpTF 確定足 i=1 の BB と ATR を取得
  int   iConfirm = 1;
  double ub,mb,lb; if(!GetFastBB(iConfirm, ub,mb,lb)) return;
  double atrNow[]; if(CopyBuffer(hATR_TF,0,iConfirm,1,atrNow)!=1) return;
  double atrv = atrNow[0];

  // 3) 「大足 or ブレイク」の“方向”を判定
  bool bigUp=false, bigDn=false;
  BigCandleFlags_EA(iConfirm, atrv, ub, lb, bigUp, bigDn);

  double cl_now = CloseN(iConfirm);
  bool breakUP  = (cl_now > ub);
  bool breakDN  = (cl_now < lb);

  int dirBigBreak = 0;
  if(bigUp || bigDn)        dirBigBreak = (bigUp ? +1 : -1);
  else if(breakUP||breakDN) dirBigBreak = (breakUP ? +1 : -1);

  // 大足/ブレイク方向で抑止を上書き（方向が出たら優先）
  if(dirBigBreak != 0){
     SetExitSuppress(dirBigBreak);
  }else{
     // 方向が消えたら解除したい場合は下を有効化
     // SetExitSuppress(0);
  }

  g_sigDir = dirBigBreak;

  // 4) 最終アクション条件
  if(dirBigBreak == 0){
     ShowSigStatus("RANGE", clrSilver);
     return;
  }

  // 5) 最終方向 = 大足/ブレイク方向
  int finalDir = dirBigBreak;

  // 6) ラベル表示
  if(bigUp || bigDn)
     ShowSigStatus(bigUp ? "BIG BUY" : "BIG SELL", bigUp ? clrLime : clrRed);
  else
     ShowSigStatus(finalDir>0 ? "BREAK BUY" : "BREAK SELL", finalDir>0 ? clrLime : clrRed);

  // 7) 保有の扱い：反対側クローズ → 同方向なければ新規1本
  int keepCnt  = CountMyPositions(finalDir);
  int closeCnt = CountMyPositions(-finalDir);

  if(closeCnt > 0){
     CloseDirPositions(-finalDir);
  }
  if(keepCnt == 0){
     bool ok = ExecuteBySignalDir(finalDir);
     if(ok){
        g_cntExecSucceeded++;
        g_lastSigBar=sigBar; g_lastSigRef=sigRef; g_lastDir=finalDir;
     }
  }

  return;
}
