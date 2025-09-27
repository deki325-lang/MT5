//+------------------------------------------------------------------+
//| EA_BreakTrend_Rev_BE_full.mq5                                   |
//| Breakout fly-in + add-ons + Reverse-on-close                     |
//| + Breakout-End detection (BRK-tag close & reverse suppression)   |
//| Tagging: BRK:UP / BRK:DN                                         |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//--------------------------------------------------------------------
// Inputs
//--------------------------------------------------------------------
input ENUM_TIMEFRAMES InpTF  = PERIOD_M15;   // trade TF
input ENUM_TIMEFRAMES RefTF  = PERIOD_H4;    // reference TF
input int             RefShift = 1;          // reference bar shift (1=last closed)

// --- Entry timing ---
input bool  TriggerImmediate   = true;       // enter on tick (no bar close wait)
input bool  OnePerBar          = true;       // suppress multiple entries per bar

// --- Risk / Lots / Guards ---
input double Lots                 = 0.10;
input int    SlippagePoints       = 10;
input long   Magic                = 20251001;
input int    MaxSpreadPoints      = 80;

input double TargetMarginLevelPct = 300.0;
input double MinAddLot            = 0.01;
input double MaxAddLot            = 1.00;
input double LotStepFallback      = 0.01;

// --- Hedging / Multi-positions ---
input bool   AllowMultiple        = true;    // same-side multiple (hedging only)
input bool   AllowOppositeHedge   = true;    // allow opposite side concurrently
input int    MaxAddPositionsSide  = 200;
input double MinGridPips          = 150.0;
input int    AddMinPts            = 50;
input int    AddMinBars           = 2;

// --- Per-position SL / Trailing ---
input bool   UsePerPosSL          = true;
input double PerPosSL_Points      = 1000;
input bool   UseTrailing          = true;
input double TrailStart_Points    = 400;
input double TrailOffset_Points   = 200;
input double TrailStep_Points     = 10;

// --- Reverse on close (doten) ---
input bool   UseReverseOnClose    = true;
input bool   ReverseRespectGuards = true;
input int    ReverseDelayMillis   = 0;
input int    ReverseMinIntervalSec= 2;
input bool   ReverseUseSameVolume = true;
input double ReverseFixedLots     = 0.10;

// --- Breakout-End detection ---
input bool   BE_Enable                = true;
input int    BE_MinHoldBars           = 2;
input double BE_PullbackPts           = 30;
input double BE_CloseBackInsideBufPts = 10;
input double BE_ATRContractRatio      = 0.65;
input int    BE_ConfirmBars           = 1;
input bool   BE_SkipReverseWhileBreak = true;

//--------------------------------------------------------------------
// Globals
//--------------------------------------------------------------------
CTrade trade;

datetime g_lastBar = 0;
datetime g_lastEntryBar = 0;

// add-on trackers
int      g_addCount      = 0;
double   g_lastAddPrice  = 0.0;
datetime g_lastAddTime   = 0;

// reverse trackers
bool     g_in_doten_sequence      = false;
datetime g_suppress_reverse_until = 0;
datetime g_last_reverse_at        = 0;

// breakout state
bool     g_InBreakout     = false;   // within breakout?
int      g_BreakDir       = 0;       // +1=UP, -1=DOWN
datetime g_BreakStartBar  = 0;
double   g_BreakRefLevel  = 0.0;     // RefHigh/RefLow
double   g_BreakStartATR  = 0.0;
int      g_BreakEndStreak = 0;

// ATR
int hATR = INVALID_HANDLE;

// --- Comment tags ---
#define TAG_BRK_UP "BRK:UP"
#define TAG_BRK_DN "BRK:DN"
#define TAG_NORM   "NORM"

//--------------------------------------------------------------------
// Forward declarations (no duplicates later)
//--------------------------------------------------------------------
double RefHigh();
double RefLow();
bool   SpreadOK();
bool   IsHedgingAccount();
int    CountPositionsSide(const int dir);
bool   EnoughSpacingSameSide(const int dir);
double CalcMaxAddableLotsForTargetML(ENUM_ORDER_TYPE orderType);
double SymbolMinLot();
double SymbolMaxLot();
double SymbolLotStep();
double NormalizeVolume(double v);
bool   CloseDirPositions(const int dir);
void   LogSendFail(const string where);
double GetATR(int sh=0);

// Tag helpers / BRK close
bool   IsBreakTag(const string s);
bool   IsBreakTagDir(const string s,const int dir);
bool   CloseBreakTaggedPositions(const int dir);

// Order send (with tag)
bool   OpenDirWithGuard(const int dir,const string commentTag);
bool   OpenDirWithGuard(const int dir);

// Break signals & state
struct BreakSignals{bool up;bool down;double refH;double refL;};
BreakSignals DetectBreakSignals();
void   MarkBreakoutStart(const int dir,const double refLevel);
bool   IsBreakoutEndedNow();
void   HandleBreakoutEnd();

//--------------------------------------------------------------------
// Utils
//--------------------------------------------------------------------
int    DigitsSafe(){ return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); }
double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask-t.bid)/_Point; }
bool   SpreadOK(){ return SpreadPt() <= MaxSpreadPoints; }

double SymbolMinLot(){ return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); return (s>0)?s:LotStepFallback; }
double NormalizeVolume(double v){
  double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep();
  v = MathMax(vmin, MathMin(vmax, v));
  if(vstp>0.0) v = MathRound(v / vstp) * vstp;
  return NormalizeDouble(v,2);
}
bool IsNewBar(){
  datetime t[2]; if(CopyTime(_Symbol, InpTF, 0, 2, t)!=2) return false;
  if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; }
  return false;
}
bool IsHedgingAccount(){
  long mm = (long)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
  return (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

//--------------------------------------------------------------------
// Reference H/L
//--------------------------------------------------------------------
double RefHigh(){ return iHigh(_Symbol, RefTF, RefShift); }
double RefLow (){ return iLow (_Symbol, RefTF, RefShift); }

//--------------------------------------------------------------------
// Positions (ticket loop; using PositionGetTicket)
//--------------------------------------------------------------------
int CountPositionsSide(const int dir){
  int cnt=0;
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong tk=PositionGetTicket(i); if(tk==0) continue;
    if(!PositionSelectByTicket(tk)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long t=(long)PositionGetInteger(POSITION_TYPE);
    int  d=0;
    if(t==POSITION_TYPE_BUY)  d=+1;
    else if(t==POSITION_TYPE_SELL) d=-1;
    if(d==dir) cnt++;
  }
  return cnt;
}
bool EnoughSpacingSameSide(const int dir){
  if(MinGridPips<=0) return true;
  double pip = ((DigitsSafe()==3||DigitsSafe()==5)? 10*_Point : _Point);
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong tk=PositionGetTicket(i); if(tk==0) continue;
    if(!PositionSelectByTicket(tk)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long typ=(long)PositionGetInteger(POSITION_TYPE);
    int  d=0;
    if(typ==POSITION_TYPE_BUY) d=+1; else if(typ==POSITION_TYPE_SELL) d=-1; else continue;
    if(d!=dir) continue;
    double open=PositionGetDouble(POSITION_PRICE_OPEN);
    double dist= (dir>0)? MathAbs(ask-open): MathAbs(bid-open);
    if(dist < MinGridPips*pip) return false;
  }
  return true;
}

//--------------------------------------------------------------------
// Close helpers
//--------------------------------------------------------------------
bool CloseDirPositions(const int dir){
  bool any=false;
  for(;;){
    bool found=false;
    ulong tk=0;
    for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long typ=(long)PositionGetInteger(POSITION_TYPE);
      int  d=0; if(typ==POSITION_TYPE_BUY) d=+1; else if(typ==POSITION_TYPE_SELL) d=-1;
      if(dir!=0 && d!=dir) continue;
      tk=t; found=true; break;
    }
    if(!found) break;
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(SlippagePoints);
    bool ok=false; int tries=0;
    while(tries<=2 && !ok){ ok=trade.PositionClose(tk); if(!ok) Sleep(200); tries++; }
    PrintFormat("[EXEC] Close ticket=%I64u ok=%s err=%d", tk, (ok?"true":"false"), (ok?0:GetLastError()));
    any |= ok;
  }
  return any;
}

//--------------------------------------------------------------------
// Margin-level based lot cap (rough)
//--------------------------------------------------------------------
double GetCurrentTotalRequiredMargin(){
  double total=0.0;
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong tk=PositionGetTicket(i); if(tk==0) continue;
    if(!PositionSelectByTicket(tk)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long   typ=(long)PositionGetInteger(POSITION_TYPE);
    double vol=PositionGetDouble(POSITION_VOLUME);
    double price=(typ==POSITION_TYPE_BUY)? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                         : SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double need=0.0;
    ENUM_ORDER_TYPE ot=(typ==POSITION_TYPE_BUY)? ORDER_TYPE_BUY:ORDER_TYPE_SELL;
    if(OrderCalcMargin(ot,_Symbol,vol,price,need)) total+=need;
  }
  return total;
}
double CalcMaxAddableLotsForTargetML(ENUM_ORDER_TYPE orderType){
  if(TargetMarginLevelPct<=0.0) return SymbolMaxLot();
  double eq = AccountInfoDouble(ACCOUNT_EQUITY);
  double allowed = eq / (TargetMarginLevelPct/100.0);
  double used = GetCurrentTotalRequiredMargin();
  double budget = allowed - used;
  if(budget<=0.0) return 0.0;

  double step = SymbolLotStep();
  double probe = MathMax(step,0.01);
  double price = (orderType==ORDER_TYPE_BUY)? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double m=0.0; if(!OrderCalcMargin(orderType,_Symbol,probe,price,m) || m<=0.0) return 0.0;
  double perLot = m/probe;
  double raw = budget/perLot;
  double v = NormalizeVolume(raw);
  v = MathMax(v, MinAddLot);
  v = MathMin(v, MaxAddLot);
  return v;
}

//--------------------------------------------------------------------
// Send with guards + tag
//--------------------------------------------------------------------
void LogSendFail(const string where){
  PrintFormat("[SEND-FAIL] where=%s ret=%d(%s) lastErr=%d spread=%.1fpt",
              where, (int)trade.ResultRetcode(), trade.ResultRetcodeDescription(),
              GetLastError(), SpreadPt());
}
bool OpenDirWithGuard(const int dir,const string commentTag){
  if(dir==0) return false;
  if(!SpreadOK()) return false;

  const bool hedging = IsHedgingAccount();

  // close opposite if not allowed
  int oppo = CountPositionsSide(-dir);
  if(oppo>0 && (!AllowOppositeHedge || !hedging)){
    g_in_doten_sequence = true;
    g_suppress_reverse_until = TimeCurrent()+2;
    if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
    g_in_doten_sequence = false;
  }

  // same-side constraint
  int same = CountPositionsSide(dir);
  if(hedging && AllowMultiple){
    if(MaxAddPositionsSide>0 && same>=MaxAddPositionsSide) return false;
    if(!EnoughSpacingSameSide(dir)) return false;
    // distance/time spacing for add
    double refPx = (dir>0? SymbolInfoDouble(_Symbol,SYMBOL_ASK): SymbolInfoDouble(_Symbol,SYMBOL_BID));
    if(g_lastAddPrice>0.0 && MathAbs(refPx - g_lastAddPrice) < AddMinPts*_Point) return false;
    if(g_lastAddTime>0 && (TimeCurrent()-g_lastAddTime) < AddMinBars*PeriodSeconds(InpTF)) return false;
  }else{
    if(same>=1) return false; // netting / single
  }

  // ML cap
  double mlCap = CalcMaxAddableLotsForTargetML(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
  if(mlCap<=0.0) return false;

  double lots = NormalizeVolume(MathMin(Lots, mlCap));
  if(same>=1 && lots < MinAddLot) lots = NormalizeVolume(MathMin(mlCap, MinAddLot));
  if(lots < SymbolMinLot()) return false;

  // send with comment
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  trade.SetAsyncMode(false);
  trade.SetTypeFilling(ORDER_FILLING_IOC);

  bool ok=false;
  if(dir>0) ok = trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, commentTag);
  else      ok = trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, commentTag);
  if(!ok){
    LogSendFail("OpenDirWithGuard-IOC");
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    if(dir>0) ok = trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, commentTag);
    else      ok = trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, commentTag);
    if(!ok){ LogSendFail("OpenDirWithGuard-FOK"); return false; }
  }

  // trackers
  if(hedging && AllowMultiple){
    g_addCount++;
    g_lastAddPrice = (dir>0? SymbolInfoDouble(_Symbol,SYMBOL_ASK): SymbolInfoDouble(_Symbol,SYMBOL_BID));
    g_lastAddTime  = TimeCurrent();
  }
  PrintFormat("[EXEC] Open %s lots=%.2f tag=%s (same=%d)",
              (dir>0?"BUY":"SELL"), lots, commentTag, same);
  return true;
}
bool OpenDirWithGuard(const int dir){ return OpenDirWithGuard(dir, TAG_NORM); }

//--------------------------------------------------------------------
// ATR helper
//--------------------------------------------------------------------
double GetATR(int sh=0){
  if(hATR==INVALID_HANDLE) return 0.0;
  double a[]; if(CopyBuffer(hATR,0,sh,1,a)!=1) return 0.0;
  return a[0];
}

//--------------------------------------------------------------------
// Break signals (fly-in): Ask>RefHigh => BUY, Bid<RefLow => SELL
//--------------------------------------------------------------------
BreakSignals DetectBreakSignals(){
  BreakSignals s; s.up=false; s.down=false; s.refH=RefHigh(); s.refL=RefLow();
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  if(s.refH>0 && ask > s.refH) s.up=true;
  if(s.refL>0 && bid < s.refL) s.down=true;
  return s;
}

//--------------------------------------------------------------------
// Breakout state: start/end
//--------------------------------------------------------------------
void MarkBreakoutStart(const int dir, const double refLevel){
  g_InBreakout     = true;
  g_BreakDir       = dir;
  g_BreakStartBar  = iTime(_Symbol, InpTF, 0);
  g_BreakRefLevel  = refLevel;
  g_BreakStartATR  = GetATR(0);
  g_BreakEndStreak = 0;
  PrintFormat("[BEG] breakout dir=%s ref=%.5f ATR0=%.2f",
              (dir>0?"UP":"DOWN"), refLevel, g_BreakStartATR);
}

bool IsBreakoutEndedNow(){
  if(!BE_Enable || !g_InBreakout || g_BreakDir==0) return false;

  // min hold bars (bar-based)
  if(BE_MinHoldBars>0){
    datetime curBar = iTime(_Symbol, InpTF, 0);
    int bars = (int)((curBar - g_BreakStartBar)/PeriodSeconds(InpTF));
    if(bars < BE_MinHoldBars) return false;
  }

  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  double px  = (g_BreakDir>0? bid: ask); // evaluation side

  bool endNow=false;

  // 1) pullback from ref
  if(BE_PullbackPts>0){
    double pb = MathAbs(px - g_BreakRefLevel)/_Point;
    if(pb >= BE_PullbackPts) g_BreakEndStreak++; else g_BreakEndStreak=0;
    if(g_BreakEndStreak >= BE_ConfirmBars){ Print("[BE-END] pullback"); endNow=true; }
  }

  // 2) close back inside reference with buffer
  if(!endNow && BE_CloseBackInsideBufPts>0){
    double c1 = iClose(_Symbol, InpTF, 1);
    if(g_BreakDir>0){
      if(c1 <= (g_BreakRefLevel - BE_CloseBackInsideBufPts*_Point)) g_BreakEndStreak++; else g_BreakEndStreak=0;
    }else{
      if(c1 >= (g_BreakRefLevel + BE_CloseBackInsideBufPts*_Point)) g_BreakEndStreak++; else g_BreakEndStreak=0;
    }
    if(g_BreakEndStreak >= BE_ConfirmBars){ Print("[BE-END] close back inside"); endNow=true; }
  }

  // 3) ATR contraction
  if(!endNow && BE_ATRContractRatio>0.0 && g_BreakStartATR>0.0){
    double now = GetATR(0);
    if(now>0.0 && now <= g_BreakStartATR*BE_ATRContractRatio) g_BreakEndStreak++; else g_BreakEndStreak=0;
    if(g_BreakEndStreak >= BE_ConfirmBars){
      PrintFormat("[BE-END] ATR contraction %.2f -> %.2f", g_BreakStartATR, now);
      endNow=true;
    }
  }

  return endNow;
}

void HandleBreakoutEnd(){
  // Close only BRK-tagged positions in the breakout direction
  CloseBreakTaggedPositions(g_BreakDir);
  Print("[BE-END] close BRK-tag positions only");

  // reset state
  g_InBreakout     = false;
  g_BreakDir       = 0;
  g_BreakStartBar  = 0;
  g_BreakRefLevel  = 0.0;
  g_BreakStartATR  = 0.0;
  g_BreakEndStreak = 0;
}

//--------------------------------------------------------------------
// Tag helpers & tagged close (single definition)
//--------------------------------------------------------------------
bool IsBreakTag(const string s){
  return (StringFind(s,TAG_BRK_UP,0)>=0 || StringFind(s,TAG_BRK_DN,0)>=0);
}
bool IsBreakTagDir(const string s,const int dir){
  if(dir>0) return (StringFind(s,TAG_BRK_UP,0)>=0);
  if(dir<0) return (StringFind(s,TAG_BRK_DN,0)>=0);
  return false;
}
bool CloseBreakTaggedPositions(const int dir){
  bool any=false, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(dir==0){
        if(!IsBreakTag(cmt)) continue;
      }else{
        long t=(long)PositionGetInteger(POSITION_TYPE);
        int  d=0; if(t==POSITION_TYPE_BUY) d=+1; else if(t==POSITION_TYPE_SELL) d=-1;
        if(d!=dir) continue;
        if(!IsBreakTagDir(cmt, dir)) continue;
      }

      trade.SetExpertMagicNumber(Magic);
      trade.SetDeviationInPoints(SlippagePoints);
      bool r=false; int tries=0;
      while(tries<3 && !r){ r=trade.PositionClose(tk); if(!r) Sleep(200); tries++; }
      PrintFormat("[EXEC] Close BRK-tag ticket=%I64u ok=%s", tk, (r?"true":"false"));
      any |= r; more=true; break;
    }
  }
  return any;
}

//--------------------------------------------------------------------
// Execute by signal (hedging aware) - TAGGED entry
//--------------------------------------------------------------------
bool ExecuteBySignalDir(const int dir, const double refLevel){
  if(dir==0) return false;

  // OnePerBar for fly-in
  if(OnePerBar){
    datetime cur = iTime(_Symbol, InpTF, 0);
    if(cur == g_lastEntryBar) return false;
  }

  const bool hedging = IsHedgingAccount();

  // close opposite if hedging not allowed
  int oppo = CountPositionsSide(-dir);
  if(oppo>0 && !AllowOppositeHedge){
    g_in_doten_sequence = true;
    g_suppress_reverse_until = TimeCurrent()+2;
    if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
    g_in_doten_sequence=false;
  }

  // tag selection
  string tag = (dir>0)? TAG_BRK_UP : TAG_BRK_DN;

  // open (or add) with tag
  bool ok = OpenDirWithGuard(dir, tag);
  if(ok){
    MarkBreakoutStart(dir, refLevel);
    g_lastEntryBar = iTime(_Symbol, InpTF, 0);
  }
  return ok;
}

//--------------------------------------------------------------------
// Trailing
//--------------------------------------------------------------------
void UpdateTrailingStopsForAll(){
  if(!UseTrailing) return;
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double pt  = _Point;
  long   stopLevel  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
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

    wantSL = NormalizeDouble(wantSL, DigitsSafe());
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(SlippagePoints);
    bool ok=false; int tries=0;
    while(tries<=2 && !ok){ ok = trade.PositionModify(ticket, wantSL, 0.0); if(!ok) Sleep(200); tries++; }
    if(!ok) Print("Trail modify failed ticket=",ticket," err=",GetLastError());
  }
}

//--------------------------------------------------------------------
// Life cycle
//--------------------------------------------------------------------
int OnInit(){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  hATR = iATR(_Symbol, InpTF, 14);
  datetime t0[]; if(CopyTime(_Symbol, InpTF, 0, 1, t0)==1) g_lastBar=t0[0];
  return INIT_SUCCEEDED;
}
void OnDeinit(const int){}

//--------------------------------------------------------------------
// OnTick
//--------------------------------------------------------------------
void OnTick(){
  // per-position SL & trailing first (optional external logic for SL)
  if(UseTrailing) UpdateTrailingStopsForAll();

  if(!TriggerImmediate){
    if(!IsNewBar()) return;
  }

  // detect breakout signals (fly-in)
  BreakSignals sig = DetectBreakSignals();
  if(sig.up != sig.down){
    int dir = (sig.up? +1 : -1);
    double rLevel = (sig.up? sig.refH : sig.refL);
    ExecuteBySignalDir(dir, rLevel);
  }

  // breakout end check -> close only BRK-tagged
  if(BE_Enable && g_InBreakout){
    if(IsBreakoutEndedNow()){
      HandleBreakoutEnd();
    }
  }
}

//--------------------------------------------------------------------
// OnTradeTransaction: Reverse-on-close with breakout suppression
//--------------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&      request,
                        const MqlTradeResult&       result)
{
  if(!UseReverseOnClose) return;
  if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

  ulong deal_id = trans.deal; if(deal_id==0) return;
  datetime now = TimeCurrent();
  HistorySelect(now - 7*24*60*60, now+60);

  string  sym   = (string)HistoryDealGetString (deal_id, DEAL_SYMBOL);
  long    magic = (long)  HistoryDealGetInteger(deal_id, DEAL_MAGIC);
  long    entry = (long)  HistoryDealGetInteger(deal_id, DEAL_ENTRY);
  long    dtype = (long)  HistoryDealGetInteger(deal_id, DEAL_TYPE);
  double  dvol  =         HistoryDealGetDouble (deal_id, DEAL_VOLUME);

  if(sym!=_Symbol || magic!=Magic) return;
  if(entry != DEAL_ENTRY_OUT) return; // only exit

  // new direction = opposite to the just-closed side
  int newDir = 0;
  if(dtype==DEAL_TYPE_SELL) newDir = -1;
  else if(dtype==DEAL_TYPE_BUY) newDir = +1;
  if(newDir==0) return;

  // spacing for reverses
  if((g_last_reverse_at>0) && (now - g_last_reverse_at < ReverseMinIntervalSec)) return;

  // suppress reverse against ongoing breakout
  if(BE_SkipReverseWhileBreak && g_InBreakout && newDir != g_BreakDir){
    Print("[REV] Suppressed due to breakout state");
    return;
  }

  if(ReverseRespectGuards && !SpreadOK()) return;
  if(ReverseDelayMillis>0) Sleep(ReverseDelayMillis);

  double vol = NormalizeVolume(ReverseUseSameVolume ? dvol : ReverseFixedLots);
  if(vol < SymbolMinLot()) vol = SymbolMinLot();

  // send (tag as breakout side)
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  bool ok=false;
  if(newDir>0) ok = trade.Buy(vol,_Symbol,0,0,0,TAG_BRK_UP);
  else         ok = trade.Sell(vol,_Symbol,0,0,0,TAG_BRK_DN);
  if(!ok) LogSendFail("Reverse-On-Close");
  else{
    g_last_reverse_at        = TimeCurrent();
    g_suppress_reverse_until = TimeCurrent() + ReverseMinIntervalSec;
    PrintFormat("[REV] enter %s vol=%.2f", (newDir>0?"BUY":"SELL"), vol);
    // treat as breakout start
    MarkBreakoutStart(newDir, (newDir>0? RefHigh(): RefLow()));
  }
}
