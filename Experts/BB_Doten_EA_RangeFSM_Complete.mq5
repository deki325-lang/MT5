//+------------------------------------------------------------------+
//|                                                   BB_Doten_EA.mq5 |
//| FastBB×Ref(H4/D1) + 多段ガード + ドテン + 反転 + 価格FSMレンジゲート |
//| Clean complete version (Range FSM integrated)                     |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//================= Inputs ===========================================
input ENUM_TIMEFRAMES InpTF = PERIOD_M15;
input int    Fast_Period    = 20;
input double Fast_Dev       = 1.8;

input ENUM_TIMEFRAMES RefTF = PERIOD_H4;
input int    RefShift       = 1;

// 接触/判定
input int    TouchTolPoints      = 15;
input bool   UseWickForTouch     = true;
input bool   RequirePriceTouch   = true;
input bool   AllowPriceOnlyTouch = false;

input bool   TriggerImmediate    = false;
input bool   OnePerBar           = true;
input bool   OnePerRefBar        = false;
input int    MinBarsBetweenSig   = 0;

// 取引
input double Lots                = 0.10;
input int    SlippagePoints      = 10;
input int    RetryCount          = 2;
input int    RetryWaitMillis     = 800;
input long   Magic               = 20250918;

input bool   AllowMultiple       = true;
input bool   AllowOppositeHedge  = true;

// ===== 維持率ガード（ML） ==========================================
input double TargetMarginLevelPct = 300.0;
input double MinAddLot            = 0.05;
input double MaxAddLot            = 0.06;
input int    MaxAddPositionsSide  = 200;
input double MinGridPips          = 150;
input double LotStepFallback      = 0.01;

// ===== 速度/ボラ ガード ============================================
input bool   UseATR_Guard      = true;
input int    ATR_Period        = 14;
input double ATR_Max_Pips      = 50;

input bool   UseBBW_Guard      = true;
input int    BBW_MinPoints     = 100;

input bool   UseSpeedGuard     = true;
input ENUM_TIMEFRAMES SpeedTF  = PERIOD_M1;
input int    SpeedLookback     = 3;
input int    Speed_MaxPoints   = 150;

// Spread / Cooldown
input int    MaxSpreadPoints   = 25;
input int    CooldownBars      = 3;

// ===== Signal strict/loose mode =====
enum SIGNAL_MODE { STRICT_REFxBB=0, LOOSE_BBONLY=1, STRICT_OR_LOOSE=2 };
input SIGNAL_MODE SignalMode   = STRICT_REFxBB;
input bool UseLooseReentry     = true;
input bool RequireBandTouch    = true;
input int  BandTouchTolPts     = 3;

// ===== Range HYBRID gate（価格ベースFSM） ==========================
enum RANGE_GATE_MODE { RANGE_GATE_OFF=0, ALLOW_BREAK_ONLY=1, ALLOW_RANGE_ONLY=2, TAG_ONLY=3 };
input RANGE_GATE_MODE RangeGateMode     = TAG_ONLY;
input ENUM_TIMEFRAMES RangeRefTF_Signal = PERIOD_H4;
input int  RangeEnterTolPts        = 20;
input int  RangeEnterNeedCloses    = 2;
input int  RangeExitBreakPips      = 8;
input int  RangeExitNeedCloses     = 1;
input bool RangeExitUseClose       = true;

// ===== Exit / Trailing =============================================
input bool   UsePerPosSL         = true;
input double PerPosSL_Points     = 1000;

input bool   UseTrailing         = true;
input double TrailStart_Points   = 400;
input double TrailOffset_Points  = 200;
input double TrailStep_Points    = 10;

// ===== Doten / Reverse =============================================
input bool UseCloseThenDoten     = true;
input bool DotenRespectGuards    = true;
input bool DotenAllowWideSpread  = true;
input int  DotenMaxSpreadPoints  = 80;

input bool UseReverseOnClose     = true;
input int  ReverseMinIntervalSec = 2;

//================= Globals ==========================================
CTrade trade;
int   hBB = INVALID_HANDLE;   // FastBB
int   hATR_TF = INVALID_HANDLE;
int   hATR_M1 = INVALID_HANDLE;

datetime g_lastBar=0;
datetime g_lastSigBar=0, g_lastSigRef=0;
int      g_lastDir=0;

string   PFX="BB_DOTEN_EA_FSM_";

datetime g_suppress_reverse_until = 0;
datetime g_last_reverse_at        = 0;
bool     g_in_doten_sequence      = false;

// ===== Range FSM state =====
int      g_rg_state       = 0; // 0=Unknown, 1=IN, -1=OUT
datetime g_rg_refBarStart = 0;
int      g_rg_inStreak    = 0;
int      g_rg_outStreak   = 0;

//================= Utils ============================================
bool CopyBarTime(int sh, datetime &bt){ datetime t[]; if(CopyTime(_Symbol, InpTF, sh, 1, t)!=1) return false; bt=t[0]; return true; }
bool IsNewBar(){ datetime t[2]; if(CopyTime(_Symbol, InpTF, 0, 2, t)!=2) return false; if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; } return false; }

double HighN (int sh){ double v[]; return (CopyHigh (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double LowN  (int sh){ double v[]; return (CopyLow  (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double CloseN(int sh){ double v[]; return (CopyClose(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double OpenN (int sh){ double v[]; return (CopyOpen (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }

int    DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=DigitsSafe(); return (dg==3||dg==5)? 10.0*pt: pt; }

bool GetFastBB(int sh,double &u,double &m,double &l){
  if(hBB==INVALID_HANDLE) return false;
  double bu[],bm[],bl[]; if(CopyBuffer(hBB,0,sh,1,bu)!=1) return false;
  if(CopyBuffer(hBB,1,sh,1,bm)!=1) return false;
  if(CopyBuffer(hBB,2,sh,1,bl)!=1) return false;
  u=bu[0]; m=bm[0]; l=bl[0]; return (u>0 && m>0 && l>0);
}

double RefHigh(){ return iHigh(_Symbol,RefTF,RefShift); }
double RefLow (){ return iLow (_Symbol,RefTF,RefShift);  }

double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask - t.bid)/_Point; }

void Notify(const string s){ Print("[NOTIFY] ", s); Alert(s); }

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
double CalcMaxAddableLotsForTargetML(ENUM_ORDER_TYPE ot){
  double equity=AccountInfoDouble(ACCOUNT_EQUITY);
  double allowed = equity / (TargetMarginLevelPct/100.0);
  double used    = GetCurrentTotalRequiredMargin();
  double budget  = allowed - used;
  if(budget<=0.0) return 0.0;
  double step=SymbolLotStep();
  double probeVol=MathMax(step, 0.01);
  double price=(ot==ORDER_TYPE_BUY)? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double mStep=0.0; if(!OrderCalcMargin(ot,_Symbol,probeVol,price,mStep)||mStep<=0.0) return 0.0;
  double marginPerLot=mStep/probeVol;
  double rawLot=budget/marginPerLot;
  double vMin=SymbolMinLot(), vMax=SymbolMaxLot();
  double lot=MathRound(rawLot/step)*step;
  lot=MathMax(vMin, MathMin(vMax, lot));
  lot=MathMax(lot,MinAddLot); lot=MathMin(lot,MaxAddLot);
  return lot;
}
bool IsHedgingAccount(){ long mm=(long)AccountInfoInteger(ACCOUNT_MARGIN_MODE); return (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING); }
int  CountPositionsSide(int dir){
  int cnt=0; for(int i=PositionsTotal()-1;i>=0;i--){
    ulong tk=PositionGetTicket(i); if(tk==0) continue;
    if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long t=(long)PositionGetInteger(POSITION_TYPE);
    int  d=(t==POSITION_TYPE_BUY? +1:-1);
    if(d==dir) cnt++;
  } return cnt;
}
int  CurrentDir_Netting(){
  if(!PositionSelect(_Symbol)) return 0;
  if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) return 0;
  long t=(long)PositionGetInteger(POSITION_TYPE);
  return (t==POSITION_TYPE_BUY? +1 : -1);
}
bool EnoughSpacingSameSide(int dir){
  if(MinGridPips<=0) return true;
  double p=GetPip(), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
    if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
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

//================= Guards ===========================================
bool GetATRpips(ENUM_TIMEFRAMES tf,int period,int sh,double &outPips){
  int h=(tf==InpTF? hATR_TF:hATR_M1);
  if(h==INVALID_HANDLE) return false;
  double a[]; if(CopyBuffer(h,0,sh,1,a)!=1) return false;
  outPips = a[0]/GetPip();
  return (outPips>0);
}
bool GetBBWp(int sh,double &bbwPts){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  bbwPts=(u-l)/_Point; return true;
}
bool AllGuardsPass(int sh, string &whyNG)
{
  // spread
  double spreadPt = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  if(MaxSpreadPoints > 0 && spreadPt > MaxSpreadPoints){ whyNG="spread"; return false; }

  if(UseATR_Guard){
    double atrNow=0; if(GetATRpips(InpTF, ATR_Period, sh, atrNow) && atrNow > ATR_Max_Pips){ whyNG="atr"; return false; }
  }
  if(UseBBW_Guard){
    double bbw=0; if(GetBBWp(sh,bbw) && bbw < BBW_MinPoints){ whyNG="bbw"; return false; }
  }
  if(UseSpeedGuard){
    double c0=CloseN(sh), c1=CloseN(sh+SpeedLookback);
    if(c1>0){ double spd=MathAbs(c0-c1)/_Point; if(spd > Speed_MaxPoints){ whyNG="speed"; return false; } }
  }
  if(CooldownBars > 0 && g_lastSigBar>0){
    int cur=iBarShift(_Symbol,InpTF,TimeCurrent(),true);
    int last=iBarShift(_Symbol,InpTF,g_lastSigBar,true);
    if(last>=0 && cur>=0 && (last-cur)<CooldownBars){ whyNG="cooldown"; return false; }
  }
  whyNG="";
  return true;
}

//================= Trailing / PerPosSL ===============================
double NormalizePrice(double price){ int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); return NormalizeDouble(price,dg); }
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
    }else{
      refPx     = ask;
      profitPts = (open - ask) / pt;
      if(profitPts < TrailStart_Points) continue;
      wantSL = refPx + TrailOffset_Points*pt;
      if(curSL>0 && wantSL >= curSL - TrailStep_Points*pt) continue;
      if(wantSL >= open) wantSL = open - 1*pt;
      if((wantSL - refPx) < (stopLevel+1)*pt) wantSL = refPx + (stopLevel+1)*pt;
    }
    wantSL = NormalizePrice(wantSL);
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(SlippagePoints);
    bool ok=false; int tries=0;
    while(tries<=RetryCount && !ok){ ok = trade.PositionModify(ticket, wantSL, 0.0); if(!ok) Sleep(RetryWaitMillis); tries++; }
  }
}
bool ClosePositionsBeyondLossPoints(double lossPtsThreshold){
  bool any=false, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1; i>=0; --i){
      ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic)   continue;
      long   ptype = (long)PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lossPts = (ptype==POSITION_TYPE_BUY) ? (open - bid)/_Point : (ask - open)/_Point;
      if(lossPts >= lossPtsThreshold){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);
        bool r=false; int tries=0;
        while(tries<=RetryCount && !r){ r = trade.PositionClose(ticket); if(!r) Sleep(RetryWaitMillis); tries++; }
        any |= r; more=true; break;
      }
    }
  }
  return any;
}

//================= Range FSM（価格ベース） ===========================
struct RangeInfo { double refH, refL; datetime refStart; double lastProbe; bool priceInside; };
enum RangeState { RANGE_UNKNOWN=0, RANGE_IN=1, RANGE_BREAK=2 };

RangeState GetRangeStateForSignal(const int sh, RangeInfo &ri)
{
   ri.refH=ri.refL=0.0; ri.refStart=0; ri.lastProbe=0.0; ri.priceInside=false;

   datetime bt[]; if(CopyTime(_Symbol, InpTF, sh, 1, bt)!=1) return RANGE_UNKNOWN;
   int refIdx = iBarShift(_Symbol, RangeRefTF_Signal, bt[0], /*exact=*/false);
   if(refIdx < 0) return RANGE_UNKNOWN;

   ri.refH     = iHigh(_Symbol, RangeRefTF_Signal, refIdx);
   ri.refL     = iLow (_Symbol, RangeRefTF_Signal, refIdx);
   ri.refStart = iTime(_Symbol, RangeRefTF_Signal, refIdx);

   if(g_rg_refBarStart != ri.refStart){
     g_rg_refBarStart = ri.refStart;
     g_rg_inStreak  = 0;
     g_rg_outStreak = 0;
   }

   const double tol   = RangeEnterTolPts     * _Point;
   const double brk   = RangeExitBreakPips   * GetPip();
   const double hi    = HighN(sh);
   const double lo    = LowN(sh);
   const double cl    = CloseN(sh);
   const double probeUp   = (RangeExitUseClose ? cl : hi);
   const double probeDown = (RangeExitUseClose ? cl : lo);

   ri.lastProbe = (MathAbs(hi-ri.refH) < MathAbs(lo-ri.refL)) ? hi : lo;

   const bool insideNow = (cl <= ri.refH + tol) && (cl >= ri.refL - tol);
   const bool brokeNow  = (probeUp >= ri.refH + brk) || (probeDown <= ri.refL - brk);

   if(insideNow){ g_rg_inStreak++;  g_rg_outStreak=0; }
   else if(brokeNow){ g_rg_outStreak++; g_rg_inStreak=0; }
   else { g_rg_inStreak=0; g_rg_outStreak=0; }

   if(g_rg_inStreak  >= MathMax(1,RangeEnterNeedCloses)){ g_rg_state = 1; ri.priceInside=true;  return RANGE_IN;    }
   if(g_rg_outStreak >= MathMax(1,RangeExitNeedCloses)) { g_rg_state = -1; ri.priceInside=false; return RANGE_BREAK; }

   if(g_rg_state==1){ ri.priceInside=true;  return RANGE_IN; }
   if(g_rg_state==-1){ri.priceInside=false; return RANGE_BREAK; }
   return RANGE_UNKNOWN;
}

//================= Signals ==========================================
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

  bool pass_loose=false;
  if(UseLooseReentry){
    double u1,m1,l1; bool ok_prev = GetFastBB(sh+1,u1,m1,l1);
    double c1 = CloseN(sh+1);
    bool prevOutside = ok_prev && (c1 >= u1 + tolB);
    bool nowInside   =             (cl <= u  - tolB);
    bool reenter     = prevOutside && nowInside;
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

  bool pass_loose=false;
  if(UseLooseReentry){
    double u1,m1,l1; bool ok_prev = GetFastBB(sh+1,u1,m1,l1);
    double c1 = CloseN(sh+1);
    bool prevOutside = ok_prev && (c1 <= l1 - tolB);
    bool nowInside   =             (cl >= l  + tolB);
    bool reenter     = prevOutside && nowInside;
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

//================= Open/Close =======================================
bool CloseDirPositions(int dir){
  bool ok_all=true, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int  d=(t==POSITION_TYPE_BUY? +1:-1);
      if(dir==0 || d==dir){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);
        bool r=false; int tries=0;
        while(tries<=RetryCount && !r){ r=trade.PositionClose(ticket); if(!r) Sleep(RetryWaitMillis); tries++; }
        if(!r){ ok_all=false; }
        more=true; break;
      }
    }
  }
  return ok_all;
}
bool OpenDirWithGuard(int dir){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);

  int sameCnt=CountPositionsSide(dir);
  if(IsHedgingAccount() && AllowMultiple){
    if(sameCnt>=MaxAddPositionsSide) return false;
    if(!EnoughSpacingSameSide(dir))  return false;
  }
  double maxLot = CalcMaxAddableLotsForTargetML((dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
  if(maxLot<=0.0) return false;
  double lots = NormalizeVolume(MathMin(Lots, maxLot));
  if(sameCnt >= 2) lots = NormalizeVolume(MathMin(maxLot, MaxAddLot));
  if(lots < SymbolMinLot()) return false;

  bool ok=false; int tries=0;
  while(tries<=RetryCount && !ok){
    ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
    if(!ok) Sleep(RetryWaitMillis);
    tries++;
  }
  return ok;
}
bool ExecuteBySignalDir(int dir){
  // Hedging/netting両対応
  bool hedging = IsHedgingAccount();
  if(hedging && AllowMultiple){
    int oppo = CountPositionsSide(-dir);
    if(oppo > 0 && !AllowOppositeHedge){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(-dir)) { g_in_doten_sequence=false; return false; }
    }
    bool opened = OpenDirWithGuard(dir);
    g_in_doten_sequence=false;
    if(opened) g_last_reverse_at = TimeCurrent();
    return opened;
  }else{
    int cur = CurrentDir_Netting();
    if(cur == dir) return true;
    if(cur != 0){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(0)) { g_in_doten_sequence=false; return false; }
    }
    bool opened = OpenDirWithGuard(dir);
    g_in_doten_sequence=false;
    if(opened) g_last_reverse_at = TimeCurrent();
    return opened;
  }
}
bool CloseThenDoten_BySignal(int dir){
  int oppoCnt = CountPositionsSide(-dir);
  if(oppoCnt > 0){
    g_in_doten_sequence = true;
    g_suppress_reverse_until = TimeCurrent() + 2;
    if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
  }
  // spread 例外枠
  if(DotenAllowWideSpread){
    double sp = SpreadPt();
    bool overNormal = (sp > MaxSpreadPoints);
    bool withinDoten = (DotenMaxSpreadPoints<=0) ? true : (sp <= DotenMaxSpreadPoints);
    if(overNormal && withinDoten){
      CTrade t2; t2.SetExpertMagicNumber(Magic); t2.SetDeviationInPoints(SlippagePoints);
      double lots = NormalizeVolume(Lots);
      bool okForce = (dir>0)? t2.Buy(lots,_Symbol) : t2.Sell(lots,_Symbol);
      g_last_reverse_at = TimeCurrent();
      g_in_doten_sequence=false;
      return okForce;
    }
  }
  // 通常
  if(DotenRespectGuards){
    string why=""; if(!AllGuardsPass(0, why)){ g_in_doten_sequence=false; return false; }
  }
  bool ok = OpenDirWithGuard(dir);
  g_in_doten_sequence=false;
  if(ok) g_last_reverse_at = TimeCurrent();
  return ok;
}

//================= Events ===========================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&      request,
                        const MqlTradeResult&       result)
{
  if(!UseReverseOnClose) return;
  if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

  ulong deal_id = trans.deal; if(deal_id==0) return;
  datetime now = TimeCurrent();
  HistorySelect(now - 24*60*60, now + 60);

  string  deal_sym   = (string)HistoryDealGetString (deal_id, DEAL_SYMBOL);
  long    deal_magic = (long)  HistoryDealGetInteger(deal_id, DEAL_MAGIC);
  long    deal_entry = (long)  HistoryDealGetInteger(deal_id, DEAL_ENTRY);
  long    deal_type  = (long)  HistoryDealGetInteger(deal_id, DEAL_TYPE);
  double  deal_vol   =         HistoryDealGetDouble (deal_id, DEAL_VOLUME);

  if(deal_sym  != _Symbol) return;
  if(deal_magic != Magic)  return;
  if(deal_entry != DEAL_ENTRY_OUT) return;
  if(deal_vol  <= 0.0)     return;

  if(g_in_doten_sequence) return;
  if(now <= g_suppress_reverse_until) return;
  if((g_last_reverse_at > 0) && (now - g_last_reverse_at < ReverseMinIntervalSec)) return;

  int newDir = (deal_type == DEAL_TYPE_SELL) ? +1 : -1; // 反対方向へ
  bool ok=false;
  string why="";
  if(!DotenRespectGuards || AllGuardsPass(0, why)){
    ok = OpenDirWithGuard(newDir);
    if(ok){
      g_last_reverse_at        = TimeCurrent();
      g_suppress_reverse_until = TimeCurrent() + ReverseMinIntervalSec;
      Notify(StringFormat("[REVERSE ENTER] dir=%s",(newDir>0? "BUY":"SELL")));
    }
  }
}

//================= Init/Deinit/OnTick ================================
int OnInit(){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);

  hBB = iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE);
  if(hBB==INVALID_HANDLE){ Print("ERR iBands(Fast)"); return INIT_FAILED; }

  hATR_TF = iATR(_Symbol, InpTF, ATR_Period);
  if(hATR_TF==INVALID_HANDLE){ Print("ERR iATR(InpTF)"); return INIT_FAILED; }

  hATR_M1 = iATR(_Symbol, SpeedTF, ATR_Period);
  if(hATR_M1==INVALID_HANDLE){ Print("WARN iATR(SpeedTF) failed"); }

  datetime t0[]; if(CopyTime(_Symbol,InpTF,0,1,t0)==1) g_lastBar=t0[0];

  return INIT_SUCCEEDED;
}
void OnDeinit(const int){}

void OnTick(){
  // 保全
  if(UsePerPosSL) ClosePositionsBeyondLossPoints(PerPosSL_Points);
  if(UseTrailing) UpdateTrailingStopsForAll();

  int sh=(TriggerImmediate?0:1);
  if(!TriggerImmediate && !IsNewBar()) return;

  // signals
  datetime bS=0,rS=0,bB=0,rB=0;
  bool sigS=SignalSELL(sh,bS,rS);
  bool sigB=SignalBUY (sh,bB,rB);
  if(sigS==sigB) return; // 同時 or 無し

  datetime sigBar=(sigS? bS:bB);
  datetime sigRef=(sigS? rS:rB);
  int      sigDir=(sigS? -1:+1);

  // デデュープ
  if(OnePerBar && sigBar==g_lastSigBar) return;
  if(OnePerRefBar && sigRef==g_lastSigRef) return;
  if(MinBarsBetweenSig>0 && g_lastSigBar>0){
    int cur=iBarShift(_Symbol,InpTF,sigBar,true);
    int last=iBarShift(_Symbol,InpTF,g_lastSigBar,true);
    if(last>=0 && cur>=0 && (last-cur)<MinBarsBetweenSig) return;
  }

  // ガード
  string why="";
  if(!AllGuardsPass(sh,why)){
    if(!(UseCloseThenDoten && DotenAllowWideSpread && why=="spread")){
      return;
    }
  }

  // Range gate
  RangeInfo  rng; 
  RangeState rstate = GetRangeStateForSignal(sh, rng);
  if(RangeGateMode == ALLOW_BREAK_ONLY && rstate != RANGE_BREAK) return;
  if(RangeGateMode == ALLOW_RANGE_ONLY && rstate != RANGE_IN)    return;

  // 発注
  bool ok=false;
  if(UseCloseThenDoten) ok = CloseThenDoten_BySignal(sigDir);
  else                  ok = ExecuteBySignalDir(sigDir);
  if(ok){ g_lastSigBar=sigBar; g_lastSigRef=sigRef; g_lastDir=sigDir; }
}
//+------------------------------------------------------------------+
