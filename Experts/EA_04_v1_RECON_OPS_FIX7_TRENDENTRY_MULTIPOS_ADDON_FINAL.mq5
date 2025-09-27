//+------------------------------------------------------------------+
//|                                                EA_04_v1.mq5     |
//| 修正版: 複数ポジション対応 + RECON/ADDON ロジック                  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// --- ここに既存の全コードが入る（省略）
//==================================================================

//==================================================================
// RECON 部分修正版
//==================================================================
void ReconCheck(int desiredDir)
{
   if(desiredDir==0) return;
   if(PositionSelect(_Symbol)){
      long tcur = PositionGetInteger(POSITION_TYPE);
      if((desiredDir>0 && tcur==POSITION_TYPE_BUY) ||
         (desiredDir<0 && tcur==POSITION_TYPE_SELL)){
         if(EA4_ReconVerboseLog) Print("[RECON] already aligned, checking add-on...");
         CheckAddOn(desiredDir);
         return;
      }
   }
   // 反転 or 新規
   if(desiredDir>0) OpenBuy();
   else if(desiredDir<0) OpenSell();
}

//==================================================================
// ADD-ON チェック部
//==================================================================
void CheckAddOn(int desiredDir)
{
   static datetime lastBarTime=0;
   datetime curBarTime = iTime(_Symbol,PERIOD_M15,0);
   int addonBars=1;
   double addonDistPts=80;
   int addonLimit=5;

   if(lastBarTime==curBarTime) return;
   lastBarTime=curBarTime;

   double dist=0.0;
   if(PositionSelect(_Symbol)){
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      if(desiredDir>0) dist = (NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_BID)-entry,_Digits)/_Point);
      else if(desiredDir<0) dist = (NormalizeDouble(entry-SymbolInfoDouble(_Symbol,SYMBOL_ASK),_Digits)/_Point);
   }

   int count=CountPositionsByDir(desiredDir);
   Print("[ADD-CHECK] bars=0/",addonBars," dist=",dist,"/",addonDistPts," count=",count,"/",addonLimit);

   if(count<addonLimit && dist>=addonDistPts){
      if(desiredDir>0) OpenBuy();
      else OpenSell();
      Print("[ADD-EXEC] additional position opened");
   }
}

//==================================================================
// ポジションカウント
//==================================================================
int CountPositionsByDir(int dir)
{
   int total=0;
   for(int i=0;i<PositionsTotal();i++){
      if(PositionSelectByIndex(i)){
         if(PositionGetString(POSITION_SYMBOL)==_Symbol){
            long t=PositionGetInteger(POSITION_TYPE);
            if((dir>0 && t==POSITION_TYPE_BUY) ||
               (dir<0 && t==POSITION_TYPE_SELL)) total++;
         }
      }
   }
   return total;
}

//==================================================================
// OpenBuy / OpenSell
//==================================================================
void OpenBuy()
{
   double lots=0.10;
   if(trade.Buy(lots,NULL,0,0,0))
      Print("[EXEC] Open BUY lots=",lots);
}
void OpenSell()
{
   double lots=0.10;
   if(trade.Sell(lots,NULL,0,0,0))
      Print("[EXEC] Open SELL lots=",lots);
}
