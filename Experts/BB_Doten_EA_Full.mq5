//+------------------------------------------------------------------+
//| BB_Doten_EA_Full.mq5 (Complete)                                  |
//| FastBB×Ref touch -> doten/add + multi-layer guards                |
//| Calendar + CSV news + Per-position SL + Trailing + Reverse        |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//================= Inputs ===========================================
input ENUM_TIMEFRAMES InpTF = PERIOD_M15;
input int    Fast_Period    = 20;
input double Fast_Dev       = 1.8;

input ENUM_TIMEFRAMES RefTF = PERIOD_H4; // e.g., H4/D1
input int    RefShift       = 1;         // 1 = closed bar

// Touch detection
input int    TouchTolPoints      = 15;
input bool   UseWickForTouch     = true;
input bool   RequirePriceTouch   = true;
input bool   AllowPriceOnlyTouch = false;

// Trigger timing
input bool   TriggerImmediate    = false; // true=tick, false=new bar

// De-dup
input bool   OnePerBar           = true;
input bool   OnePerRefBar        = false;
input int    MinBarsBetweenSig   = 0;

// Trading (nominal; actual lots decided by guards)
input double Lots                = 0.10;
input int    SlippagePoints      = 10;
input int    MaxSpreadPoints     = 30;
input int    RetryCount          = 2;
input int    RetryWaitMillis     = 800;
input long   Magic               = 20250910;

// Hedging
input bool   AllowMultiple       = true;  // add in same direction
input bool   AllowOppositeHedge  = true;  // hold both sides

// ===== Margin-Level Guard ==========================================
input double TargetMarginLevelPct = 300.0;
input double MinAddLot            = 0.05;
input double MaxAddLot            = 0.60;
input int    MaxAddPositionsSide  = 200;
input double MinGridPips          = 150;
input double LotStepFallback      = 0.01;

// ===== Volatility / Speed Guards ===================================
input bool   UseATRGuard       = true;
input int    ATR_Period        = 14;
input double MaxATR_Pips       = 40;
input double MinATR_Pips       = 1;

input bool   UseCandleGuard    = true;
input double MaxCandle_Pips    = 35;
input double MaxBody_Pips      = 25;

input bool   UseBBWGuard       = true;
input double MaxBBW_Pips       = 30;

input bool   UseSpeedGuard     = true;
input ENUM_TIMEFRAMES SpeedTF  = PERIOD_M1;
input int    SpeedLookback     = 3;
input double MaxSpeedMove_Pips = 20;

input bool   UseCooldown       = true;
input double BigBar_Pips       = 40;
input int    CooldownBars      = 2;

// Manual freeze window
input bool      UseNewsFreeze  = false;
input datetime  FreezeFrom     = D'1970.01.01 00:00';
input datetime  FreezeTo       = D'1970.01.01 00:00';

// UI
input bool   AlertPopup        = true;
input bool   AlertPush         = true;
input bool   ShowPanel         = true;
input ENUM_BASE_CORNER PanelCorner = CORNER_LEFT_LOWER;
input int    PanelX            = 10;
input int    PanelY            = 28;
input int    PanelFontSize     = 10;

// Strict band touch
input bool RequireBandTouch   = true;
input int  BandTouchTolPts    = 3;

// --- ATR spike auto-flatten ---
enum FLATTEN_CLOSE_MODE { FLAT_CLOSE_ALL=0, FLAT_CLOSE_LOSERS_ONLY=1, FLAT_KEEP_WINNERS_ABOVE=2 };
input bool               UseATR_Flatten    = true;
input double             ATR_Spike_Pips    = 120;
input int                ATR_FreezeMinutes = 5;
input FLATTEN_CLOSE_MODE FlattenCloseMode  = FLAT_KEEP_WINNERS_ABOVE;
input double             KeepWinnerMinPips = 8.0;

// --- Per-position hard stop (loss in points from open) ---
input bool   UsePerPosSL      = true;
input double PerPosSL_Points  = 400;

// --- Per-position Trailing Stop (points) ---
input bool   UseTrailing          = true;
input double TrailStart_Points    = 400;
input double TrailOffset_Points   = 200;
input double TrailStep_Points     = 10;

input bool   UseSoftFirstLots     = true;
input bool   UseRiskLots          = false;
input double RiskPctPerTrade      = 2.0;

// Doten spread relaxation
input bool DotenAllowWideSpread   = true;
input int  DotenMaxSpreadPoints   = 80;

// Reverse on close
input bool   UseReverseOnClose     = true;
input bool   ReverseRespectGuards  = true;
input int    ReverseDelayMillis    = 0;
input int    ReverseMinIntervalSec = 2;

// Reverse filter for SL
input bool ReverseOnlyOnPerPosSL = true;
input bool ReverseAlsoOnBrokerSL = false;
input bool ReverseSkipOnBrokerSL = true;

// Tiered adaptive lots (optional)
input bool   UseTieredAdaptiveLots = false;
input double FirstTwoLots          = 0.05;
input double ThirdPlusLots         = 0.10;
input double TierBaselineEquity    = 80000;
input double TierMinScale          = 1.00;
input double TierMaxScale          = 5.00;
input double TierExponent          = 1.00;
input bool   TierRespectRiskCap    = false;

// Reverse UQ (fallback)
input bool   UseReverseOnCloseUQ   = true;
input bool   ReverseUseMLGuardLots = true;
input bool   ReverseUseSameVolume  = true;
input double ReverseFixedLots      = 0.10;
input bool   ReverseAddIfHolding   = true;

// Signal flow
input bool UseCloseThenDoten     = true;
input bool DotenRespectGuards    = true;
input bool DotenUseUQFallback    = true;

// Calendar / News
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

input bool DebugNews            = false;
input int  DebugNewsHorizonMin  = 180;

//===== Signal mode (kept simple here) ================================
input bool UseLooseReentry = true;

//================= CSV News (toyolab) ================================
#define NEWS_MAX 2000
datetime g_NewsTime[NEWS_MAX];
int      g_NTsize=0;

int LoadNewsTimeCSV(){
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
      string name = FileReadString(fh);
   }
   FileClose(fh);
   PrintFormat("[NEWS CSV] loaded %d rows", g_NTsize);
   return g_NTsize;
}
bool NewsFilter_CSV(int before_min, int after_min){
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
int hATR_TF = INVALID_HANDLE;
int hATR_M1 = INVALID_HANDLE;

datetime g_lastBar=0;
datetime g_lastSigBar=0, g_lastSigRef=0;
int      g_lastDir=0;
datetime g_lastBigBarRef=0;
string   g_lastGuardWhy="-";
datetime g_lastGuardAt=0;
datetime g_atr_freeze_until = 0;

string   PFX="BB_DOTEN_EA_FULL_";

ulong g_cntOnTick=0, g_cntSigDetected=0, g_cntAfterDedup=0,
      g_cntGuardsPassed=0, g_cntExecCalled=0, g_cntExecSucceeded=0;

datetime g_suppress_reverse_until = 0;
datetime g_last_reverse_at        = 0;
bool     g_in_doten_sequence      = false;
string   g_lastCloseContext       = "-";

ulong    g_last_news_event_id_closed = 0;
datetime g_news_freeze_until        = 0;

//================= Utils ============================================
void Notify(string s){ if(AlertPopup) Alert(s); if(AlertPush) SendNotification(s); }
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=(int)(long)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); return (dg==3||dg==5)?10.0*pt:pt; }
double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask-t.bid)/_Point; }
bool SpreadOK(){ return SpreadPt()<=MaxSpreadPoints; }
bool IsHedgingAccount(){ long mm=(long)AccountInfoInteger(ACCOUNT_MARGIN_MODE); return (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING); }
double SymbolMinLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return (s>0)?s:LotStepFallback; }
double NormalizeVolume(double vol){ double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep(); vol=MathMax(vmin,MathMin(vmax,vol)); vol=MathRound(vol/vstp)*vstp; return vol; }
int DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

bool CopyBarTime(int sh, datetime &bt){ datetime t[]; if(CopyTime(_Symbol, InpTF, sh, 1, t)!=1) return false; bt=t[0]; return true; }
bool IsNewBar(){ datetime t[2]; if(CopyTime(_Symbol, InpTF, 0, 2, t)!=2) return false; if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; } return false; }
double HighN (int sh){ double v[]; return (CopyHigh (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double LowN  (int sh){ double v[]; return (CopyLow  (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double CloseN(int sh){ double v[]; return (CopyClose(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double OpenN (int sh){ double v[]; return (CopyOpen (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }

bool GetFastBB(int sh,double &u,double &m,double &l){
   if(hBB==INVALID_HANDLE) return false;
   double bu[],bm[],bl[];
   if(CopyBuffer(hBB,0,sh,1,bu)!=1) return false;
   if(CopyBuffer(hBB,1,sh,1,bm)!=1) return false;
   if(CopyBuffer(hBB,2,sh,1,bl)!=1) return false;
   u=bu[0]; m=bm[0]; l=bl[0];
   return (u>0 && m>0 && l>0);
}
double RefHigh(){ double v=iHigh(_Symbol,RefTF,RefShift); return (v>0? v:0.0); }
double RefLow (){ double v=iLow (_Symbol,RefTF,RefShift);  return (v>0? v:0.0); }
datetime RefBarTimeOf(datetime tInp){ int idx=iBarShift(_Symbol,RefTF,tInp,true); if(idx<0) return 0; return iTime(_Symbol,RefTF,idx); }

//================= ATR/Candle/BBW/Speed =============================
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
   bool newsCalm   = (g_news_freeze_until>0 && TimeTradeServer()<=g_news_freeze_until);
   return (newsFreeze || atrFreeze || newsCalm);
}

//================= Guards ===========================================
bool AllGuardsPass(int sh, string &whyNG){
   if(!SpreadOK()){ whyNG="spread_ng"; return false; }
   if(InFreezeWindow()){ whyNG="freeze_window"; return false; }

   // CSV news window
   if(UseCalendarNoTrade){
      if(NewsFilter_CSV(BlockBeforeNewsMin, BlockAfterNewsMin)){
         whyNG="news_csv_window"; return false;
      }
   }

   if(UseATRGuard){
      double atrP=0; if(GetATRpips(InpTF,ATR_Period,sh,atrP)){
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

   // ATR spike flatten
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

//================= Lots / Margin ====================================
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

//================= Per-Position SL & Trailing =======================
double NormalizePrice(double price){
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, dg);
}
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
      trade.PositionModify(ticket, wantSL, 0.0);
   }
}
bool ClosePositionsBeyondLossPoints(double lossPtsThreshold){
   bool anyClosed=false, more=true;
   g_lastCloseContext = "PERPOS_SL";
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

         double lossPts = 0.0;
         if(ptype == POSITION_TYPE_BUY)  lossPts = (open - bid)/_Point;
         if(ptype == POSITION_TYPE_SELL) lossPts = (ask  - open)/_Point;

         if(lossPts >= lossPtsThreshold){
            trade.SetExpertMagicNumber(Magic);
            trade.SetDeviationInPoints(SlippagePoints);
            bool r=false; int tries=0;
            while(tries<=RetryCount && !r){
               r = trade.PositionClose(ticket);
               if(!r) Sleep(RetryWaitMillis);
               tries++;
            }
            anyClosed |= r;
            more=true; break;
         }
      }
   }
   return anyClosed;
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
   bool pass = pass_refbb || pass_loose;
   if(!pass) return false;

   if(!CopyBarTime(sh,sigBar)) return false;
   sigRef = RefBarTimeOf(sigBar); if(sigRef==0) sigRef = sigBar;
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
   bool pass = pass_refbb || pass_loose;
   if(!pass) return false;

   if(!CopyBarTime(sh,sigBar)) return false;
   sigRef = RefBarTimeOf(sigBar); if(sigRef==0) sigRef = sigBar;
   return true;
}

//================= Open/Close & Execution ===========================
int CurrentDir_Netting(){
   if(!PositionSelect(_Symbol)) return 0;
   if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) return 0;
   long t=(long)PositionGetInteger(POSITION_TYPE);
   if(t==POSITION_TYPE_BUY) return +1;
   if(t==POSITION_TYPE_SELL) return -1;
   return 0;
}
bool CloseDirPositions(int dir){
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
            while(tries<=RetryCount && !r){
               r=trade.PositionClose(ticket);
               if(!r) Sleep(RetryWaitMillis);
               tries++;
            }
            ok_all &= r;
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
      double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double mpp = (tick_sz>0.0 ? tick_val / tick_sz : 0.0);
      if(mpp > 0.0){
         double est_loss_money = PerPosSL_Points * mpp;
         if(est_loss_money > 0.0){
            double lot_by_risk = risk / est_loss_money;
            req = MathMin(req, lot_by_risk);
         }
      }
   }
   double maxML = CalcMaxAddableLotsForTargetML(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(maxML <= 0.0) return 0.0;
   double lots = NormalizeVolume(MathMin(req, maxML));

   if(sameCnt < 2){
      if(lots < SymbolMinLot()) return 0.0;
   }else{
      if(lots < MinAddLot) return 0.0;
   }
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

   string why="";
   if(!AllGuardsPass(0, why)) return false;

   double lots = 0.0;
   if(UseTieredAdaptiveLots){
      lots = ComputeTieredAdaptiveLot(dir, sameCnt);
      if(lots <= 0.0) return false;
   }else{
      double maxLot = CalcMaxAddableLotsForTargetML((dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      if(maxLot <= 0.0) return false;
      double fixedLot = NormalizeVolume(Lots);
      if(UseRiskLots && UsePerPosSL && PerPosSL_Points>0){
         double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
         double risk = eq * (RiskPctPerTrade/100.0);
         double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         double mpp = (tick_sz>0.0 ? tick_val / tick_sz : 0.0);
         if(mpp>0.0){
            double est_loss = PerPosSL_Points * mpp;
            double lot_by_risk = risk / est_loss;
            fixedLot = NormalizeVolume(lot_by_risk);
         }
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
bool CloseThenDoten_BySignal(int dir){
   int oppoCnt = CountPositionsSide(-dir);
   if(oppoCnt > 0){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
      Notify((dir>0) ? "[FORCE CLOSE SELL]" : "[FORCE CLOSE BUY]");
   }
   if(DotenRespectGuards){
      string why="";
      if(!AllGuardsPass(0, why)){
         if(!DotenUseUQFallback){ g_in_doten_sequence=false; return false; }
      }else{
         bool ok = OpenDirWithGuard(dir);
         g_in_doten_sequence=false;
         if(ok){ g_last_reverse_at = TimeCurrent(); Notify((dir>0) ? "[OPEN BUY DOTEN]" : "[OPEN SELL DOTEN]"); return true; }
         if(!DotenUseUQFallback) return false;
      }
   }
   // UQ fallback lots
   double volUQ = 0.0;
   int sameCntDir = CountPositionsSide(dir);
   if(UseTieredAdaptiveLots) volUQ = ComputeTieredAdaptiveLot(dir, sameCntDir);
   if(volUQ <= 0.0 && ReverseUseMLGuardLots){
      volUQ = CalcMaxAddableLotsForTargetML(dir>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      volUQ = NormalizeVolume(volUQ);
   }
   if(volUQ <= 0.0){
      volUQ = NormalizeVolume(Lots);
      if(sameCntDir >= 2 && volUQ < MinAddLot) volUQ = NormalizeVolume(MinAddLot);
   }
   if(volUQ < SymbolMinLot()){ g_in_doten_sequence=false; return false; }
   CTrade t; t.SetExpertMagicNumber(Magic); t.SetDeviationInPoints(SlippagePoints);
   bool ok2 = (dir>0)? t.Buy(volUQ,_Symbol) : t.Sell(volUQ,_Symbol);
   g_last_reverse_at = TimeCurrent(); g_in_doten_sequence=false;
   if(ok2) Notify((dir>0) ? "[OPEN BUY DOTEN (UQ)]" : "[OPEN SELL DOTEN (UQ)]");
   return ok2;
}
bool ExecuteBySignalDir(int dir){
   if(!SpreadOK()) return false;
   bool hedging = IsHedgingAccount();
   if(hedging && AllowMultiple){
      int oppo = CountPositionsSide(-dir);
      if(oppo > 0 && !AllowOppositeHedge){
         g_in_doten_sequence = true;
         g_suppress_reverse_until = TimeCurrent() + 2;
         if(!CloseDirPositions(-dir)) { g_in_doten_sequence=false; return false; }
         Notify(((-dir)>0) ? "[CLOSE BUY ALL]" : "[CLOSE SELL ALL]");
      }
      bool opened = OpenDirWithGuard(dir);
      g_in_doten_sequence=false;
      if(opened){ g_last_reverse_at   = TimeCurrent(); Notify((dir>0) ? "[OPEN BUY ADD]" : "[OPEN SELL ADD]"); }
      return opened;
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
      g_in_doten_sequence=false;
      if(opened){ g_last_reverse_at = TimeCurrent(); Notify((dir>0) ? "[OPEN BUY]" : "[OPEN SELL]"); }
      return opened;
   }
}

//================= News (Calendar) ==================================
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

//================= Panel ============================================
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
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double used=GetCurrentTotalRequiredMargin();
   double ml=(used>0.0)? (equity/used*100.0) : 99999.0;
   string txt=StringFormat("Sym:%s TF:%s BUY:%d SELL:%d Spread:%.1fpt ML:%.0f%%",
                           _Symbol, EnumToString(InpTF), buyCnt, sellCnt, SpreadPt(), ml);
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

   if(hBB==INVALID_HANDLE || hATR_TF==INVALID_HANDLE){
      Print("Init failed: indicators"); return INIT_FAILED;
   }
   long stopLevel  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLvl  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   PrintFormat("[TRAIL CHECK] StopLevel=%ldpt FreezeLevel=%ldpt Start=%d Offset=%d Step=%d",
               stopLevel, freezeLvl, TrailStart_Points, TrailOffset_Points, TrailStep_Points);

   UpdatePanel();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int){ string nm=PFX+"PANEL"; if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm); }

void OnTick(){
   g_cntOnTick++;

   // Calendar pre-close
   ulong evt_id; datetime evt_time;
   if(UseCalendarCloseAll && InPreNewsCloseWindow(CloseBeforeNewsMin, MinImportance4Close, OnlySymbolCurrenciesForClose, evt_id, evt_time)){
      if(g_last_news_event_id_closed != evt_id){
         CloseAllForScope(CloseScope, CancelPendingsToo);
         g_last_news_event_id_closed = evt_id;
         if(RefrainAfterNewsMin > 0) g_news_freeze_until = evt_time + RefrainAfterNewsMin*60;
      }
      return;
   }
   if(g_news_freeze_until>0 && TimeTradeServer()<=g_news_freeze_until) return;

   // Per-position SL (software safety)
   if(UsePerPosSL && PerPosSL_Points>0) ClosePositionsBeyondLossPoints(PerPosSL_Points);

   // Trailing
   UpdateTrailingStopsForAll();

   UpdatePanel();

   int sh=(TriggerImmediate?0:1);
   if(!TriggerImmediate && !IsNewBar()) return;

   datetime bS=0,rS=0,bB=0,rB=0;
   bool sigS=SignalSELL(sh,bS,rS);
   bool sigB=SignalBUY (sh,bB,rB);
   if(sigS==sigB) return;

   g_cntSigDetected++;

   datetime sigBar=(sigS? bS:bB);
   datetime sigRef=(sigS? rS:rB);
   int      sigDir=(sigS? -1:+1);

   // De-dup
   if(OnePerBar && sigBar==g_lastSigBar) return;
   if(OnePerRefBar && sigRef==g_lastSigRef) return;
   if(MinBarsBetweenSig>0 && g_lastSigBar>0){
      int cur=iBarShift(_Symbol,InpTF,sigBar,true);
      int last=iBarShift(_Symbol,InpTF,g_lastSigBar,true);
      if(last>=0 && cur>=0 && (last-cur)<MinBarsBetweenSig) return;
   }
   g_cntAfterDedup++;

   // Guards
   string why="";
   bool guardOK = AllGuardsPass(sh,why);
   if(!guardOK){
      // allow doten override for spread if permitted
      if(!(UseCloseThenDoten && DotenAllowWideSpread && why=="spread_ng")){
         g_lastGuardWhy=why; g_lastGuardAt=TimeCurrent();
         return;
      }
   }
   g_cntGuardsPassed++;

   // Exec
   g_cntExecCalled++;
   bool ok=false;
   if(UseCloseThenDoten) ok = CloseThenDoten_BySignal(sigDir);
   else                  ok = ExecuteBySignalDir(sigDir);

   if(ok){
      g_cntExecSucceeded++;
      g_lastSigBar=sigBar;
      g_lastSigRef=sigRef;
      g_lastDir=sigDir;
   }
}

//================= Trade Transaction (Reverse on Close) =============
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&      request,
                        const MqlTradeResult&       result)
{
   if(!(UseReverseOnClose || UseReverseOnCloseUQ)) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)    return;

   ulong deal_id = trans.deal;
   if(deal_id == 0) return;

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
      if(!( isPerPos || (ReverseAlsoOnBrokerSL && isBrokerSL) ))
         return;
   }

   if(g_in_doten_sequence) return;
   if(now <= g_suppress_reverse_until) return;

   int newDir = (deal_type == DEAL_TYPE_SELL) ? -1 : +1;
   bool reverseAlreadyHandled = false;

   if(UseReverseOnClose){
      if((g_last_reverse_at > 0) && (now - g_last_reverse_at < ReverseMinIntervalSec)){
         // fallthrough to UQ
      }else{
         bool guardedOK = true;
         if(ReverseRespectGuards){
            string why="";
            if(!AllGuardsPass(0, why)){
               guardedOK = false;
               PrintFormat("[REVERSE] blocked by guard: %s", why);
            }
         }
         if(guardedOK){
            if(ReverseDelayMillis > 0) Sleep(ReverseDelayMillis);
            bool ok = OpenDirWithGuard(newDir);
            if(ok){
               g_last_reverse_at        = TimeCurrent();
               g_suppress_reverse_until = TimeCurrent() + ReverseMinIntervalSec;
               reverseAlreadyHandled    = true;
               Notify(StringFormat("[REVERSE ENTER] dir=%s ctx=%s",
                     (newDir>0? "BUY":"SELL"), g_lastCloseContext));
            }
         }
      }
   }

   if(UseReverseOnCloseUQ && !reverseAlreadyHandled){
      int sameCntDir = CountPositionsSide(newDir);
      double volUQ = 0.0;
      if(UseTieredAdaptiveLots) volUQ = ComputeTieredAdaptiveLot(newDir, sameCntDir);
      if(volUQ <= 0.0 && ReverseUseMLGuardLots){
         volUQ = CalcMaxAddableLotsForTargetML(newDir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
         volUQ = NormalizeVolume(volUQ);
      }
      if(volUQ <= 0.0){
         double baseVol = (ReverseUseSameVolume ? deal_vol : ReverseFixedLots);
         volUQ = NormalizeVolume(baseVol);
      }
      if(volUQ < SymbolMinLot()){ g_lastCloseContext = "-"; return; }
      if(ReverseDelayMillis > 0) Sleep(ReverseDelayMillis);
      CTrade t; t.SetExpertMagicNumber(Magic); t.SetDeviationInPoints(SlippagePoints);
      bool ok2 = (newDir > 0) ? t.Buy (volUQ, _Symbol) : t.Sell(volUQ, _Symbol);
      PrintFormat("[UQ-REVERSE] dir=%s vol=%.2f ok=%s", (newDir>0?"BUY":"SELL"), volUQ, (ok2?"true":"false"));
   }
   g_lastCloseContext = "-";
}
