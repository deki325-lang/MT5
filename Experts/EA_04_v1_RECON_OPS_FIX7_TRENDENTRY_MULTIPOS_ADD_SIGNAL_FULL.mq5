//+------------------------------------------------------------------+
//| EA_04_v1_RECON_OPS_FIX7_TRENDENTRY_MULTIPOS_ADD_SIGNAL_FULL.mq5  |
//| Consolidated: keeps prior features, fixes multi-pos add-on logic  |
//| Notes:                                                            |
//| - No PositionSelectByIndex; iterate with PositionGetTicket.       |
//| - Conditional same-direction add-ons on new signals only.         |
//| - Honors EA4_AllowMultiPos / EA4_MaxAddPos / MinGridPips, etc.    |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// ========================= Globals / State ==========================
CTrade trade;
CTrade EA4_Trade;

#define LOG PrintFormat

input ENUM_TIMEFRAMES InpTF = PERIOD_M15;
input int    Fast_Period    = 20;
input double Fast_Dev       = 1.8;
input ENUM_TIMEFRAMES RefTF = PERIOD_H4;
input int    RefShift       = 1;

input int    TouchTolPoints      = 15;
input bool   UseWickForTouch     = true;
input bool   RequirePriceTouch   = true;
input bool   AllowPriceOnlyTouch = false;

input bool   TriggerImmediate    = false;
input bool   OnePerBar           = true;
input bool   OnePerRefBar        = false;
input int    MinBarsBetweenSig   = 0;

input double Lots                = 0.10;
input int    SlippagePoints      = 10;
input int    RetryCount          = 2;
input int    RetryWaitMillis     = 800;
input long   Magic               = 20250910;

input bool   AllowMultiple       = true;
input bool   AllowOppositeHedge  = true;

input bool   UseTrailing          = false;
input double TrailStart_Points    = 400;
input double TrailOffset_Points   = 200;
input double TrailStep_Points     = 10;

input bool   UsePerPosSL      = false;
input double PerPosSL_Points  = 1000;

input int    MaxSpreadPoints   = 80;

input bool   EA4_ReconcileEnable = true;
input bool   EA4_ReconOpenWhenFlat = true;
input double EA4_ReconLots         = 0.10;
input bool   EA4_ReconVerboseLog   = true;
input ENUM_TIMEFRAMES EA4_RefTF           = PERIOD_H4;
input int             EA4_RefShift        = 1;
input bool   EA4_AllowMultiPos = true;
input int    EA4_MaxAddPos     = 200;
input bool   EA4_AddOnSameDir  = true;
input int    EA4_AddMinBars    = 2;
input int    EA4_AddMinPts     = 50;

input bool   UseCloseThenDoten     = true;
input bool   DotenAllowWideSpread  = true;
input int    DotenMaxSpreadPoints  = 80;
input bool   DotenRespectGuards    = true;

input bool   UseReverseOnClose     = true;
input bool   UseReverseOnCloseUQ   = true;
input bool   ReverseRespectGuards  = true;
input int    ReverseDelayMillis    = 0;
input int    ReverseMinIntervalSec = 2;
input bool   ReverseSkipOnBrokerSL = true;
input bool   ReverseOnlyOnPerPosSL = true;
input bool   ReverseAlsoOnBrokerSL = false;
input bool   ReverseUseSameVolume  = true;
input double ReverseFixedLots      = 0.10;

input bool   AlertPopup        = true;
input bool   AlertPush         = false;
input bool   ShowPanel         = true;
input ENUM_BASE_CORNER PanelCorner = CORNER_LEFT_LOWER;
input int    PanelX            = 10;
input int    PanelY            = 28;
input int    PanelFontSize     = 10;

// ===== internal trackers =====
int hBB = INVALID_HANDLE;
int hATR_TF = INVALID_HANDLE;
datetime g_lastBar=0;
datetime g_lastSigBar=0, g_lastSigRef=0;
int      g_lastDir=0;
string   PFX="EA4_MULTI_ADD_";

// --- add-on trackers ---
int      g_addCount   = 0;
double   g_lastAddPrice = 0.0;
datetime g_lastAddTime  = 0;
int      g_lastAddDir   = 0;

// --- reverse/doten trackers ---
bool     g_in_doten_sequence      = false;
datetime g_suppress_reverse_until = 0;
datetime g_last_reverse_at        = 0;
string   g_lastCloseContext       = "-";

// ========================= Utils ===================================
int DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=DigitsSafe(); return (dg==3||dg==5)? 10.0*pt: pt; }
double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask - t.bid)/_Point; }

double HighN (int sh){ double v[]; return (CopyHigh (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double LowN  (int sh){ double v[]; return (CopyLow  (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double CloseN(int sh){ double v[]; return (CopyClose(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double OpenN (int sh){ double v[]; return (CopyOpen (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }

bool CopyBarTime(int sh, datetime &bt){ datetime t[]; if(CopyTime(_Symbol, InpTF, sh, 1, t)!=1) return false; bt=t[0]; return true; }
bool IsNewBar(){ datetime t[2]; if(CopyTime(_Symbol, InpTF, 0, 2, t)!=2) return false; if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; } return false; }

bool EA4_SpreadOK(){ return SpreadPt()<=MaxSpreadPoints; }

void Notify(const string s){ Print("[NOTIFY] ", s); if(AlertPopup) Alert(s); if(AlertPush) SendNotification(s); }

bool GetFastBB(int sh,double &u,double &m,double &l){
  if(hBB==INVALID_HANDLE) return false;
  double bu[],bm[],bl[]; if(CopyBuffer(hBB,0,sh,1,bu)!=1) return false;
  if(CopyBuffer(hBB,1,sh,1,bm)!=1) return false;
  if(CopyBuffer(hBB,2,sh,1,bl)!=1) return false;
  u=bu[0]; m=bm[0]; l=bl[0]; return (u>0 && m>0 && l>0);
}

double RefHigh(){ double v=iHigh(_Symbol,RefTF,RefShift); return (v>0? v:0.0); }
double RefLow (){ double v=iLow (_Symbol,RefTF,RefShift);  return (v>0? v:0.0); }

// ===================== Position helpers (no SelectByIndex) =========
int CountMyPositionsDir(const int dir){
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int d=(t==POSITION_TYPE_BUY ? +1 : -1);
      if(d==dir) cnt++;
   }
   return cnt;
}
int CountMyPositionsAll(){
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      cnt++;
   }
   return cnt;
}
int CurrentDir_Netting(){
   if(!PositionSelect(_Symbol)) return 0;
   if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) return 0;
   long t=(long)PositionGetInteger(POSITION_TYPE);
   if(t==POSITION_TYPE_BUY)  return +1;
   if(t==POSITION_TYPE_SELL) return -1;
   return 0;
}

// ---- spacing check for same-side add ----
input double MinGridPips = 150.0;
bool EnoughSpacingSameSide(int dir){
  if(MinGridPips<=0) return true;
  double p=GetPip();
  double ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
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

// ===================== Close helpers ================================
bool CloseDirPositions(int dir){
  g_lastCloseContext = "DOTEN";
  bool ok_all=true, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int  d=(t==POSITION_TYPE_BUY? +1:-1);
      if(dir==0 || d==dir){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);
        bool r=false; int tries=0;
        while(tries<=RetryCount && !r){ r=trade.PositionClose(ticket); if(!r) Sleep(RetryWaitMillis); tries++; }
        if(!r){ ok_all=false; Print("Close ticket ",ticket," err=",GetLastError()); }
        else { LOG("[EXEC] CloseDir ticket=%I64u dir=%d", ticket, d); }
        more=true; break;
      }
    }
  }
  return ok_all;
}

bool ClosePositionsBeyondLossPoints(double thrPts){
  g_lastCloseContext = "PERPOS_SL";
  bool any=false, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long ptype=(long)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lossPts=(ptype==POSITION_TYPE_BUY)? (open-bid)/_Point : (ask-open)/_Point;
      if(lossPts>=thrPts){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);
        bool r=false; int tries=0;
        while(tries<=RetryCount && !r){ r=trade.PositionClose(tk); if(!r) Sleep(RetryWaitMillis); tries++; }
        if(r){ LOG("[EXEC] Close (PerPosSL) ticket=%I64u lossPts=%.1f thr=%.1f", tk, lossPts, thrPts); any=true; more=true; break; }
      }
    }
  }
  return any;
}


double GetPip(){
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (dg==3 || dg==5) ? 10.0*pt : pt;
}

void EA4_LogLastTradeError(const string where){
   int    ret    = (int)trade.ResultRetcode();
   string desc   = trade.ResultRetcodeDescription();
   int    lastEr = GetLastError();
   double sprPt  = (SymbolInfoDouble(_Symbol, SYMBOL_ASK)-SymbolInfoDouble(_Symbol, SYMBOL_BID))/_Point;
   PrintFormat("[SEND-FAIL] where=%s ret=%d(%s) lastErr=%d spread=%.1fpt", where, ret, desc, lastEr, sprPt);
}

bool IsHedgingAccount(){
   long mm = (long)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

double SymbolMinLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); return (s>0.0? s:0.01); }

double NormalizeVolume(double v){
   double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep();
   v = MathMax(vmin, MathMin(vmax, v));
   v = MathRound(v / vstp) * vstp;
   return NormalizeDouble(v, 2);
}

int CountPositionsSide(const int dir){
   int cnt=0;
   for(int i=PositionsTotal()-1; i>=0; --i){
      ulong tk = PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long typ = (long)PositionGetInteger(POSITION_TYPE);
      int  d   = (typ==POSITION_TYPE_BUY ? +1 : -1);
      if(d==dir) cnt++;
   }
   return cnt;
}

bool EnoughSpacingSameSide(const int dir){
   if(MinGridPips<=0) return true;
   double pip = GetPip();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i=PositionsTotal()-1; i>=0; --i){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long typ = (long)PositionGetInteger(POSITION_TYPE);
      int  d   = (typ==POSITION_TYPE_BUY ? +1 : -1);
      if(d!=dir) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double dist = (dir>0 ? MathAbs(ask-open) : MathAbs(bid-open));
      if(dist < MinGridPips*pip) return false;
   }
   return true;
}

// 必要証拠金から ML 目標までの余力で上限ロットをざっくり算出
double CalcMaxAddableLotsForTargetML(ENUM_ORDER_TYPE ot){
   // TargetMarginLevelPct が無い環境でもゼロ割を避けるため200%固定相当の安全値に
   double targetML = (TargetMarginLevelPct>0.0? TargetMarginLevelPct : 200.0);
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double used  = 0.0;

   // 現在ポジの必要証拠金合計
   for(int i=PositionsTotal()-1;i>=0;--i){
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long typ=(long)PositionGetInteger(POSITION_TYPE);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double px =(typ==POSITION_TYPE_BUY? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol,SYMBOL_BID));
      double need=0.0;
      ENUM_ORDER_TYPE t=(typ==POSITION_TYPE_BUY? ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      if(OrderCalcMargin(t,_Symbol,vol,px,need)) used+=need;
   }

   double allowed = (targetML>0.0? eq/(targetML/100.0) : eq/2.0);
   double budget  = allowed - used;
   if(budget<=0.0) return 0.0;

   double step = SymbolLotStep();
   double probe= MathMax(step, 0.01);
   double price= (ot==ORDER_TYPE_BUY? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                    : SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double needPer=0.0;
   if(!OrderCalcMargin(ot,_Symbol,probe,price,needPer) || needPer<=0.0) return 0.0;
   double perLot = needPer/probe;

   double raw   = budget/perLot;
   double v     = NormalizeVolume(raw);
   v = MathMax(v, SymbolMinLot());
   v = MathMin(v, SymbolMaxLot());
   return v;
}

bool CloseDirPositions(const int dir){
   bool ok_all=true, more=true;
   while(more){
      more=false;
      for(int i=PositionsTotal()-1;i>=0;--i){
         ulong tk=PositionGetTicket(i); if(tk==0) continue;
         if(!PositionSelectByTicket(tk)) continue;
         if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
         long typ=(long)PositionGetInteger(POSITION_TYPE);
         int  d  =(typ==POSITION_TYPE_BUY? +1 : -1);
         if(dir!=0 && d!=dir) continue;

         trade.SetExpertMagicNumber(Magic);
         trade.SetDeviationInPoints(SlippagePoints);

         bool r=false; int tries=0;
         while(tries<3 && !r){ r=trade.PositionClose(tk); if(!r) Sleep(200); tries++; }
         if(!r){ ok_all=false; Print("Close ticket ",tk," err=",GetLastError()); }
         more=true; break;
      }
   }
   return ok_all;
}


// ===================== Order wrappers ===============================
double SymbolMinLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return (s>0)?s:0.01; }
double NormalizeVolume(double vol){
  double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep();
  vol=MathMax(vmin, MathMin(vmax, vol));
  vol=MathRound(vol / vstp) * vstp;
  return NormalizeDouble(vol,2);
}

bool OpenDirSimple(int dir, double lots){
  if(lots < SymbolMinLot()) return false;
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  trade.SetAsyncMode(false);
  trade.SetTypeFilling(ORDER_FILLING_IOC);
  bool ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
  if(!ok){
     trade.SetTypeFilling(ORDER_FILLING_FOK);
     ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
  }
  if(ok) LOG("[EXEC] Open %s lots=%.2f", (dir>0?"BUY":"SELL"), lots);
  return ok;
}

// dir: +1=BUY, -1=SELL
bool OpenDirWithGuard(const int dir)
{
   if(dir==0) return false;

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // 逆方向を先に片づけ（両建て一瞬発生を回避）
   const bool hedging = IsHedgingAccount();
   const int  oppoCnt = CountPositionsSide(-dir);
   if(oppoCnt>0 && (!AllowOppositeHedge || !hedging)){
      g_in_doten_sequence      = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
      Sleep(150);
      g_in_doten_sequence=false;
   }

   // 同方向本数と間隔のチェック
   const int sameCnt = CountPositionsSide(dir);
   if(hedging && AllowMultiple){
      if(MaxAddPositionsSide>0 && sameCnt>=MaxAddPositionsSide){
         if(EA4_ReconVerboseLog) PrintFormat("[ADD-BLOCK] reached MaxAddPositionsSide=%d", MaxAddPositionsSide);
         return false;
      }
      if(!EnoughSpacingSameSide(dir)){
         if(EA4_ReconVerboseLog) Print("[ADD-BLOCK] spacing NG (MinGridPips)");
         return false;
      }
   }else{
      if(sameCnt>=1) return false; // ネッティング/単発モードは追加なし
   }

   // ロット決定
   double lots = 0.0;
   if(UseTieredAdaptiveLots){
      lots = ComputeTieredAdaptiveLot(dir, sameCnt);  // ←あなたの既存関数を呼びます
      if(lots<=0.0){ if(EA4_ReconVerboseLog) Print("[LOTS] tiered calc NG"); return false; }
   }else{
      double mlCap = CalcMaxAddableLotsForTargetML(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      if(mlCap<=0.0){ if(EA4_ReconVerboseLog) Print("[LOTS] ML guard budget=0"); return false; }

      double base = NormalizeVolume(Lots);
      if(UseRiskLots && UsePerPosSL && PerPosSL_Points>0){
         double eq=AccountInfoDouble(ACCOUNT_EQUITY);
         double risk=eq*(RiskPctPerTrade/100.0);
         double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
         double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
         double mpp=(ts>0.0? tv/ts:0.0);
         if(mpp>0.0){
            double est=PerPosSL_Points*mpp;
            double lot_by_risk=(est>0.0? risk/est:0.0);
            base=NormalizeVolume(lot_by_risk);
         }
      }

      if(sameCnt<2){
         double cand = NormalizeVolume(MathMin(base, mlCap));
         if(UseSoftFirstLots){
            if(mlCap<MinAddLot) return false;
            if(cand<MinAddLot)  cand = NormalizeVolume(MinAddLot);
         }
         lots=cand;
         if(lots<SymbolMinLot()) return false;
      }else{
         lots = NormalizeVolume(MathMin(mlCap, MaxAddLot));
         if(lots<MinAddLot) return false;
      }
   }

   // ブローカー仕様へ丸め
   double minLot=SymbolMinLot(), maxLot=SymbolMaxLot(), step=SymbolLotStep();
   double lotReq=lots;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(step>0.0) lots = MathRound(lots/step)*step;
   lots = NormalizeDouble(lots,2);

   if(EA4_ReconVerboseLog)
      PrintFormat("[LOTS] req=%.2f -> norm=%.2f (min=%.2f max=%.2f step=%.2f sameCnt=%d)",
                  lotReq, lots, minLot, maxLot, step, sameCnt);

   // 送信（IOC→FOKフォールバック）
   bool ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
   if(!ok){
      EA4_LogLastTradeError("OpenDirWithGuard-IOC");
      trade.SetTypeFilling(ORDER_FILLING_FOK);
      ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
      if(!ok){
         EA4_LogLastTradeError("OpenDirWithGuard-FOK");
         return false;
      }
   }

   if(EA4_ReconVerboseLog)
      PrintFormat("[EXEC] Open %s lots=%.2f (hedge=%s multi=%s)",
                  (dir>0?"BUY":"SELL"), lots, (hedging?"true":"false"), (AllowMultiple?"true":"false"));
   return true;
}



// ===================== Signal detection (ref×BB) ====================
bool SignalSELL(int sh, datetime &sigBar, datetime &sigRef){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  double refH=RefHigh(); if(refH<=0) return false;
  const double tol  = TouchTolPoints*_Point;
  double hi   = HighN(sh);
  double cl   = CloseN(sh);
  double op   = OpenN(sh);
  double probe= (UseWickForTouch ? hi : cl);
  bool touchBB = (u >= refH - tol && u <= refH + tol);
  bool touchPx = (!RequirePriceTouch) || (probe >= refH - tol);
  bool pass    = (touchBB && touchPx) || (AllowPriceOnlyTouch && (probe >= refH - tol));
  if(!pass) return false;
  if(!CopyBarTime(sh,sigBar)) return false;
  sigRef = iTime(_Symbol,RefTF,RefShift); if(sigRef==0) sigRef=sigBar;
  return true;
}
bool SignalBUY(int sh, datetime &sigBar, datetime &sigRef){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  double refL=RefLow(); if(refL<=0) return false;
  const double tol  = TouchTolPoints*_Point;
  double lo   = LowN(sh);
  double cl   = CloseN(sh);
  double op   = OpenN(sh);
  double probe= (UseWickForTouch ? lo : cl);
  bool touchBB = (l >= refL - tol && l <= refL + tol);
  bool touchPx = (!RequirePriceTouch) || (probe <= refL + tol);
  bool pass    = (touchBB && touchPx) || (AllowPriceOnlyTouch && (probe <= refL + tol));
  if(!pass) return false;
  if(!CopyBarTime(sh,sigBar)) return false;
  sigRef = iTime(_Symbol,RefTF,RefShift); if(sigRef==0) sigRef=sigBar;
  return true;
}

// ===================== Add-on logic (signal gated) ==================
void EA4_ResetAdds(){ g_addCount=0; g_lastAddPrice=0.0; g_lastAddTime=0; g_lastAddDir=0; }

bool TryAddSameDirectionIfSignal(const int dir){
  if(!EA4_AllowMultiPos || !EA4_AddOnSameDir) return false;
  if(dir==0) return false;
  if(!PositionSelect(_Symbol)) return false; // 同方向を既に1本以上持っている時にだけ追加
  if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) return false;
  int curDir = ((long)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY? +1:-1);
  if(curDir!=dir) return false;

  // 現在の同方向本数
  int sameNow = CountMyPositionsDir(dir);
  if(sameNow<=0) return false; // 初回建ては別経路で
  if(sameNow >= EA4_MaxAddPos) return false;

  // 最小バー間隔
  if(g_lastAddTime>0){
     if(TimeCurrent() - g_lastAddTime < (EA4_AddMinBars * PeriodSeconds(_Period))) return false;
  }

  // 最小価格距離 / グリッド距離
  double refPrice = (dir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
  if(g_lastAddPrice>0.0 && MathAbs(refPrice - g_lastAddPrice) < EA4_AddMinPts * _Point) return false;
  if(!EnoughSpacingSameSide(dir)) return false;

  // 発注
  bool ok = OpenDirWithGuard(dir);
  if(ok){
     g_addCount++;
     g_lastAddDir   = dir;
     g_lastAddTime  = TimeCurrent();
     g_lastAddPrice = refPrice;
     if(EA4_ReconVerboseLog) PrintFormat("[ADD-ON] same-dir add #%d price=%.5f nowSame=%d", g_addCount, refPrice, sameNow+1);
  }
  return ok;
}

// ===================== Execute by signal ============================
bool ExecuteBySignalDir(int dir){
  if(!EA4_SpreadOK()) { if(EA4_ReconVerboseLog) Print("[GUARD] spread NG"); return false; }
  bool hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

  if(hedging && AllowMultiple){
    // 逆方向制御
    int oppo = CountMyPositionsDir(-dir);
    if(oppo>0 && !AllowOppositeHedge){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(-dir)) { g_in_doten_sequence=false; return false; }
      Notify(((-dir)>0) ? "[CLOSE BUY ALL]" : "[CLOSE SELL ALL]");
    }
    // すでに同方向を持っていれば「追加」は TryAddSameDirectionIfSignal に任せる
    int same = CountMyPositionsDir(dir);
    bool ok=false;
    if(same==0){
       ok = OpenDirWithGuard(dir);
       if(ok){ Notify((dir>0) ? "[OPEN BUY]" : "[OPEN SELL]"); }
    }else{
       ok = TryAddSameDirectionIfSignal(dir);
    }
    g_in_doten_sequence=false;
    if(ok){ g_last_reverse_at   = TimeCurrent(); }
    return ok;
  }else{
    int cur = CurrentDir_Netting();
    if(cur == dir){
      // 追加はできない（ネットティング）
      return true;
    }
    if(cur != 0){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(0)) { g_in_doten_sequence=false; return false; }
      Notify((cur>0) ? "[CLOSE BUY]" : "[CLOSE SELL]");
    }
    bool opened = OpenDirWithGuard(dir);
    if(opened){
      g_in_doten_sequence=false;
      g_last_reverse_at = TimeCurrent();
      Notify((dir>0) ? "[OPEN BUY]" : "[OPEN SELL]");
    }
    return opened;
  }
}

// ===================== Reconcile (light) ============================
void EA4_ReconcileHoldings(const int desiredDir)
{
   if(desiredDir==0) return;
   if(PositionSelect(_Symbol)){
      long tcur = PositionGetInteger(POSITION_TYPE);
      if((desiredDir>0 && tcur==POSITION_TYPE_BUY) ||
         (desiredDir<0 && tcur==POSITION_TYPE_SELL)){
         if(EA4_ReconVerboseLog) Print("[RECON] already aligned, no close");
         // ここで同方向「追加」の検討（シグナル側で呼ぶのが原則）
         return;
      }
      if(desiredDir>0 && tcur==POSITION_TYPE_SELL) EA4_Trade.PositionClose(_Symbol);
      if(desiredDir<0 && tcur==POSITION_TYPE_BUY ) EA4_Trade.PositionClose(_Symbol);
   }else{
      if(desiredDir!=0 && EA4_ReconOpenWhenFlat){
         double lots = (EA4_ReconLots>0.0 ? EA4_ReconLots : Lots);
         if(lots<=0.0) lots = Lots;
         bool sent=false;
         if(EA4_SpreadOK()){
            sent = (desiredDir>0) ? EA4_Trade.Buy(lots,_Symbol) : EA4_Trade.Sell(lots,_Symbol);
         }
         if(EA4_ReconVerboseLog)
            PrintFormat("[RECON] open when flat: %s lots=%.2f sent=%s",
                        (desiredDir>0?"BUY":"SELL"), lots, (sent?"true":"false"));
      }
   }
}

// ===================== Panel / Trailing =============================
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
  int buyCnt=CountMyPositionsDir(+1), sellCnt=CountMyPositionsDir(-1);
  double equity=AccountInfoDouble(ACCOUNT_EQUITY);
  string txt=StringFormat("EA4 MultiAdd | %s %s | BUY:%d SELL:%d | Spread:%.1fpt Eq:%.0f",
              _Symbol, EnumToString(InpTF), buyCnt, sellCnt, SpreadPt(), equity);
  ObjectSetString(0,nm,OBJPROP_TEXT,txt);
}

void UpdateTrailingStopsForAll(){
  if(!UseTrailing) return;
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double pt  = _Point;
  long   stopLevel  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
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

    wantSL = NormalizeDouble(wantSL, DigitsSafe());
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(SlippagePoints);
    bool ok=false; int tries=0;
    while(tries<=RetryCount && !ok){ ok = trade.PositionModify(ticket, wantSL, 0.0); if(!ok) Sleep(RetryWaitMillis); tries++; }
    if(!ok) Print("Trail modify failed ticket=",ticket," err=",GetLastError());
  }
}

// ===================== Lifecycle ===================================
int OnInit(){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);

  hBB = iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE);
  if(hBB==INVALID_HANDLE){ Print("ERR iBands(Fast)"); return INIT_FAILED; }
  hATR_TF = iATR(_Symbol, InpTF, 14);
  if(hATR_TF==INVALID_HANDLE){ Print("ERR iATR(InpTF)"); return INIT_FAILED; }

  datetime t0[]; if(CopyTime(_Symbol,InpTF,0,1,t0)==1) g_lastBar=t0[0];
  return INIT_SUCCEEDED;
}
void OnDeinit(const int){ string nm=PFX+"PANEL"; if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm); }

// ===================== OnTick ======================================
void OnTick(){
  if(UsePerPosSL) ClosePositionsBeyondLossPoints(PerPosSL_Points);
  if(UseTrailing) UpdateTrailingStopsForAll();
  UpdatePanel();

  int sh=(TriggerImmediate?0:1);
  if(!TriggerImmediate && !IsNewBar()) return;

  datetime bS=0,rS=0,bB=0,rB=0;
  bool sigS=SignalSELL(sh,bS,rS);
  bool sigB=SignalBUY (sh,bB,rB);
  if(sigS==sigB) return; // 同時 or 無し

  int sigDir=(sigS? -1:+1);
  g_lastSigBar=(sigS? bS:bB);
  g_lastSigRef=(sigS? rS:rB);
  g_lastDir=sigDir;

  // 反対側をクローズ（ヘッジOFF時など）
  int oppo=CountMyPositionsDir(-sigDir);
  if(oppo>0 && (!AllowOppositeHedge)){
     CloseDirPositions(-sigDir);
  }

  // 初回 or 追加
  ExecuteBySignalDir(sigDir);
}

// ===================== Trade Transaction (reverse) ==================
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
  bool reversed=false;

  if(UseReverseOnClose){
    if((g_last_reverse_at > 0) && (now - g_last_reverse_at < ReverseMinIntervalSec)){
      // skip -> UQ
    }else{
      bool guardOK = (!ReverseRespectGuards) || EA4_SpreadOK();
      if(guardOK){
        if(ReverseDelayMillis>0) Sleep(ReverseDelayMillis);
        if(OpenDirWithGuard(newDir)){
          g_last_reverse_at        = TimeCurrent();
          g_suppress_reverse_until = TimeCurrent() + ReverseMinIntervalSec;
          reversed=true;
          Notify(StringFormat("[REVERSE ENTER] dir=%s ctx=%s",(newDir>0? "BUY":"SELL"), g_lastCloseContext));
        }
      }
    }
  }

  if(UseReverseOnCloseUQ && !reversed){
    double volUQ = NormalizeVolume(ReverseUseSameVolume ? deal_vol : ReverseFixedLots);
    if(volUQ < SymbolMinLot()) return;
    if(ReverseDelayMillis>0) Sleep(ReverseDelayMillis);
    CTrade t; t.SetExpertMagicNumber(Magic); t.SetDeviationInPoints(SlippagePoints);
    bool ok2 = (newDir > 0) ? t.Buy (volUQ, _Symbol) : t.Sell(volUQ, _Symbol);
    PrintFormat("[UQ-REVERSE] dir=%s vol=%.2f ok=%s", (newDir>0?"BUY":"SELL"), volUQ, (ok2?"true":"false"));
  }
  g_lastCloseContext = "-";
}
