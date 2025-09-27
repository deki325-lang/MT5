//+------------------------------------------------------------------+
//|  EA_04_v1_RECON_OPS_FIX7_TRENDENTRY_MULTIPOS_ADD_SIGNAL.mq5      |
//|  修正版: 同方向ADD対応（条件: AllowMultiple, EA4_AllowMultiPos等）  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//------------------------------------------------------------
// Inputs
//------------------------------------------------------------
input bool   AllowMultiple       = true;
input bool   AllowOppositeHedge  = true;
input bool   EA4_AllowMultiPos   = true;
input int    EA4_MaxAddPos       = 3;       // 合計本数
input bool   EA4_AddOnSameDir    = true;
input int    EA4_AddMinBars      = 2;
input int    EA4_AddMinPts       = 50;
input long   Magic               = 20250910;
input double Lots                = 0.10;

//------------------------------------------------------------
// Globals
//------------------------------------------------------------
CTrade trade;
datetime g_lastAddTime = 0;
double   g_lastAddPrice= 0.0;
int      g_lastAddDir  = 0;

//------------------------------------------------------------
// Helpers
//------------------------------------------------------------
int CountMyPositionsDir(int dir){
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long t=(long)PositionGetInteger(POSITION_TYPE);
      int d=(t==POSITION_TYPE_BUY?+1:-1);
      if(d==dir) cnt++;
   }
   return cnt;
}

bool OpenDirWithGuard(int dir){
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(10);
   return (dir>0)? trade.Buy(Lots,_Symbol) : trade.Sell(Lots,_Symbol);
}

//------------------------------------------------------------
// Main logic (簡略 OnTick テンプレート)
//------------------------------------------------------------
void OnTick(){
   static datetime lastBar=0;
   datetime curBar = iTime(_Symbol,PERIOD_M15,0);
   bool isNewBar = (curBar!=lastBar);
   if(isNewBar) lastBar=curBar;

   // ダミー: シグナルをBUY固定とする（本来はSignalBUY/SELLを呼ぶ）
   int dir = +1;

   int sameCnt = CountMyPositionsDir(dir);
   if(sameCnt==0){
      // 新規エントリー
      if(OpenDirWithGuard(dir)){
         g_lastAddDir=dir; g_lastAddTime=TimeCurrent();
         g_lastAddPrice=(dir>0)? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol,SYMBOL_BID);
      }
   }else if(EA4_AllowMultiPos && AllowMultiple && EA4_AddOnSameDir){
      if(sameCnt < EA4_MaxAddPos){
         bool barsOK = (g_lastAddTime==0) || ((TimeCurrent()-g_lastAddTime)>=EA4_AddMinBars*PeriodSeconds(PERIOD_M15));
         double refPrice=(dir>0)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
         bool distOK=(g_lastAddPrice==0.0)||(MathAbs(refPrice-g_lastAddPrice)>=EA4_AddMinPts*_Point);
         if(barsOK && distOK){
            if(OpenDirWithGuard(dir)){
               g_lastAddDir=dir; g_lastAddTime=TimeCurrent();
               g_lastAddPrice=refPrice;
               PrintFormat("[ADD-ON] same-dir add #%d at %.5f", sameCnt+1, refPrice);
            }
         }
      }
   }
}
