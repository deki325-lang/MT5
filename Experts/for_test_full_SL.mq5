//+------------------------------------------------------------------+
//| for_test_full_SL.mq5                                            |
//| 差し替え用の完全版 (発注時ブローカーSL + ソフトSL保険付き)          |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

input double Lots = 0.10;
input int SlippagePoints = 10;
input long Magic = 20250910;
input bool UsePerPosSL = true;
input double PerPosSL_Points = 400;

CTrade trade;

// --- StopLevel順守してSLを丸める ---
double ClampToStopLevelForSL(bool isBuy, double wantSL){
   long stopLevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt = _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(isBuy){
      double minSL = ask - (stopLevel+1)*pt;
      if(wantSL > minSL) wantSL = minSL;
   }else{
      double minSL = bid + (stopLevel+1)*pt;
      if(wantSL < minSL) wantSL = minSL;
   }
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(wantSL,dg);
}

// --- ソフトSLチェック ---
bool ClosePositionsBeyondLossPoints(double lossPtsThreshold){
   bool any=false;
   for(int i=PositionsTotal()-1; i>=0; --i){
      ulong tk = PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      long tp = (long)PositionGetInteger(POSITION_TYPE);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid= SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask= SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lossPts = (tp==POSITION_TYPE_BUY)? (op-bid)/_Point : (ask-op)/_Point;
      if(lossPts >= lossPtsThreshold){
         trade.SetExpertMagicNumber(Magic);
         trade.SetDeviationInPoints(SlippagePoints);
         trade.PositionClose(tk);
         any=true;
      }
   }
   return any;
}

// --- 発注 ---
bool OpenDirWithGuard(int dir){
   double lots = Lots;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl=0.0;
   if(UsePerPosSL && PerPosSL_Points>0){
      if(dir>0) sl=ClampToStopLevelForSL(true, ask - PerPosSL_Points*_Point);
      else      sl=ClampToStopLevelForSL(false,bid + PerPosSL_Points*_Point);
   }
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = (dir>0)? trade.Buy(lots,_Symbol,0.0,sl,0.0) : trade.Sell(lots,_Symbol,0.0,sl,0.0);
   return ok;
}

// --- テスト用 ---
int OnInit(){ return(INIT_SUCCEEDED); }
void OnTick(){
   if(UsePerPosSL && PerPosSL_Points>0) ClosePositionsBeyondLossPoints(PerPosSL_Points);
   // ダミー: 強制的にBUYして動作確認
   if(PositionsTotal()==0) OpenDirWithGuard(+1);
}
