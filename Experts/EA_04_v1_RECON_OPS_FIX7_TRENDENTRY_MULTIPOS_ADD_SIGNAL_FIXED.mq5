//+------------------------------------------------------------------+
//|                                               MultiPosAddDemo.mq5 |
//|  Minimal, compile-ready helpers for conditional same-direction add |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// ===== Inputs (mirror names used in your EA) ========================
input long   Magic                 = 20250910;
input double Lots                  = 0.10;
input int    SlippagePoints        = 10;

input bool   AllowMultiple         = true;   // hedging: allow multiple tickets
input bool   AllowOppositeHedge    = true;   // keep opposite side too (hedging)

input bool   EA4_AllowMultiPos     = true;   // same-direction add allowed
input int    EA4_MaxAddPos         = 3;      // total tickets on the same side (e.g. 3 = 1 + 2 adds)
input int    EA4_AddMinBars        = 2;      // min bars since last add
input int    EA4_AddMinPts         = 50;     // min price distance (points) since last add

// ===== Globals ======================================================
CTrade trade;
int      g_addCount      = 0;
double   g_lastAddPrice  = 0.0;
datetime g_lastAddTime   = 0;
int      g_lastAddDir    = 0;

// ----- helpers ------------------------------------------------------
int DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double GetPip(){
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int dg = DigitsSafe();
   return (dg==3||dg==5) ? 10.0*pt : pt;
}

// Count positions for this symbol + magic on a direction (+1 buy, -1 sell)
int CountPositionsSide(const int dir){
   int cnt = 0;
   for(int idx = PositionsTotal()-1; idx >= 0; --idx){
      if(!PositionSelectByIndex(idx)) continue;
      if((string)PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic)     continue;
      long typ = (long)PositionGetInteger(POSITION_TYPE);
      int  d   = (typ==POSITION_TYPE_BUY ? +1 : -1);
      if(d == dir) cnt++;
   }
   return cnt;
}

// Ensure spacing between current price and existing same-side entries
bool EnoughSpacingSameSide(const int dir, const int minPts){
   if(minPts <= 0) return true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int idx = PositionsTotal()-1; idx >= 0; --idx){
      if(!PositionSelectByIndex(idx)) continue;
      if((string)PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic)     continue;
      long typ = (long)PositionGetInteger(POSITION_TYPE);
      int  d   = (typ==POSITION_TYPE_BUY ? +1 : -1);
      if(d != dir) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur  = (dir>0 ? ask : bid);
      if(MathAbs(cur - open) < minPts * _Point) return false;
   }
   return true;
}

// Normalize lots to broker settings (safe)
double NormalizeVolume(double vol){
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstp = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstp <= 0.0) vstp = 0.01;
   vol = MathMax(vmin, MathMin(vmax, vol));
   vol = MathRound(vol / vstp) * vstp;
   return NormalizeDouble(vol, 2);
}

// Core: try same-direction add when a new signal matches held direction
bool TryAddSameDirectionIfSignal(const int sigDir){
   if(!EA4_AllowMultiPos || sigDir==0) return false;

   // must already hold at least one position on that side
   int sameCnt = CountPositionsSide(sigDir);
   if(sameCnt <= 0) return false;

   // limit by total tickets
   if(sameCnt >= EA4_MaxAddPos) return false;

   // bar interval check
   bool barsOK = (g_lastAddTime==0) ||
                 ((TimeCurrent() - g_lastAddTime) >= (EA4_AddMinBars * PeriodSeconds(_Period)));
   if(!barsOK) return false;

   // price distance check
   double refPx = (sigDir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
   bool distOK  = (g_lastAddPrice==0.0) ||
                  (MathAbs(refPx - g_lastAddPrice) >= EA4_AddMinPts * _Point);
   if(!distOK) return false;

   // optional spacing vs ALL same-side entries
   if(!EnoughSpacingSameSide(sigDir, EA4_AddMinPts)) return false;

   // place order
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   double lots = NormalizeVolume(Lots);
   bool ok = (sigDir>0) ? trade.Buy(lots, _Symbol) : trade.Sell(lots, _Symbol);
   if(!ok){
      PrintFormat("[ADD] send failed ret=%d lastErr=%d",
                  (int)trade.ResultRetcode(), (int)GetLastError());
      return false;
   }

   // update add trackers
   g_addCount++;
   g_lastAddDir   = sigDir;
   g_lastAddTime  = TimeCurrent();
   g_lastAddPrice = refPx;
   PrintFormat("[ADD] same-dir add #%d dir=%s price=%.5f lots=%.2f",
               g_addCount, (sigDir>0?"BUY":"SELL"), refPx, lots);
   return true;
}

// ===== EA lifecycle =================================================
int OnInit(){
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   Comment("MultiPosAddDemo loaded (helpers only)");
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int){
   Comment("");
}

// NOTE: This demo does NOT generate signals itself.
// Call TryAddSameDirectionIfSignal(+1/-1) from your signal logic.
void OnTick(){
   // no-op
}
