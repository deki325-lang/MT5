//+------------------------------------------------------------------+
//|   EA_02_v3_FULL_withLabels.mq5                                   |
//|   BB × Impulse × BigCandle                                       |
//|   - BreakUP/BreakDNでドテン                                      |
//|   - BigCandleなら最優先でドテン                                  |
//|   - Rangeはノーポジ（全クローズ）                                 |
//|   - ラベルに「大足／ブレイク／レンジ／Idle」表示                  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//=== Inputs =========================================================
input long   Magic             = 20250920;
input double Lots              = 0.10;
input int    SlippagePoints    = 10;
input int    MaxSpreadPoints   = 30;

// --- Bollinger
input int    BB_Period         = 20;
input double BB_Dev            = 2.0;
input ENUM_APPLIED_PRICE BB_P  = PRICE_CLOSE;

// --- Impulse / Regime
input int    ATR_Period        = 14;
input int    Smooth_Period     = 9;
input double Flip_Threshold    = 0.20;

// --- BBW Z (SQUEEZE)
input bool   Use_BBW_Z         = true;
input int    BBW_Z_Lookback    = 200;
input double Thr_Squeeze_Z     = -0.80;

// --- Big Candle
input bool   Use_BigCandle     = true;
input double BigBody_ATR_K     = 1.20;
input double BigRange_ATR_K    = 1.50;
input bool   Need_BB_Outside   = true;

// --- Misc
input bool   OneEntryPerBar    = true;

//=== Globals ========================================================
CTrade trade;
int     hBB   = INVALID_HANDLE;
int     hATR  = INVALID_HANDLE;

datetime g_lastBar     = 0;
double   g_ema_prev    = 0.0;
int      g_runUp=0, g_runDn=0;

int      g_lastDir     = 0;          // 最後の方向 (+1=BUY, -1=SELL, 0=NONE)
string   g_lblName     = "EA02v3_Status";
string   g_lastSigText = "INIT";
color    g_lastSigColor= clrSilver;

//=== Helpers ========================================================
bool IsNewBar(){
   datetime t[2]; if(CopyTime(_Symbol,_Period,0,2,t)!=2) return false;
   if(t[0]!=g_lastBar){ g_lastBar=t[0]; return true; }
   return false;
}

bool SpreadOK(){
   MqlTick tk; if(!SymbolInfoTick(_Symbol,tk)) return false;
   return ((tk.ask-tk.bid)/_Point <= MaxSpreadPoints);
}

void UpdateStatusLabel(const string text,const color col){
   if(ObjectFind(0,g_lblName)<0)
      ObjectCreate(0,g_lblName,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,g_lblName,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,g_lblName,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0,g_lblName,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,g_lblName,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,g_lblName,OBJPROP_FONTSIZE,12);
   ObjectSetInteger(0,g_lblName,OBJPROP_COLOR,col);
   ObjectSetString (0,g_lblName,OBJPROP_TEXT,text);
}

// 全ポジクローズ dir=+1(BUY)/-1(SELL)/0(両方)
bool CloseAllDir(int dir){
   bool all_ok=true, more=true;
   while(more){
      more=false;
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong tk=PositionGetTicket(i); if(tk==0) continue;
         if(!PositionSelectByTicket(tk)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
         long t=(long)PositionGetInteger(POSITION_TYPE);
         int d=(t==POSITION_TYPE_BUY?+1:-1);
         if(dir!=0 && d!=dir) continue;
         trade.SetExpertMagicNumber(Magic);
         trade.SetDeviationInPoints(SlippagePoints);
         if(!trade.PositionClose(tk)) all_ok=false;
         more=true; break;
      }
   }
   return all_ok;
}

bool OpenDir(int dir){
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(SlippagePoints);
   return (dir>0)? trade.Buy(Lots,_Symbol):trade.Sell(Lots,_Symbol);
}

// --- ドテン: 反対全クローズ後に新規
bool CloseThenDoten_BySignal(int dir){
   if(!CloseAllDir(-dir)) return false;
   if(!SpreadOK()) return false;
   return OpenDir(dir);
}

// --- Big Candle 判定
void BigCandleFlags(int i,double atrv,double bu,double bl,
                    double close0,double open0,bool &bigUp,bool &bigDn){
   bigUp=false; bigDn=false;
   double body=MathAbs(close0-open0);
   double range=MathAbs(bu-bl);
   bool isBigBody  = (body  > atrv*BigBody_ATR_K);
   bool isBigRange = (range > atrv*BigRange_ATR_K);
   bool outsideUp = (close0 > bu);
   bool outsideDn = (close0 < bl);
   if(Use_BigCandle && (isBigBody||isBigRange)){
      if(!Need_BB_Outside || outsideUp) bigUp=true;
      if(!Need_BB_Outside || outsideDn) bigDn=true;
   }
}

//=== Lifecycle ======================================================
int OnInit(){
   hBB  = iBands(_Symbol,_Period,BB_Period,0,BB_Dev,BB_P);
   if(hBB==INVALID_HANDLE){ Print("iBands fail"); return INIT_FAILED; }
   hATR = iATR(_Symbol,_Period,ATR_Period);
   if(hATR==INVALID_HANDLE){ Print("iATR fail"); return INIT_FAILED; }
   datetime t0[]; if(CopyTime(_Symbol,_Period,0,1,t0)==1) g_lastBar=t0[0];
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
   if(ObjectFind(0,g_lblName)>=0) ObjectDelete(0,g_lblName);
   if(hBB!=INVALID_HANDLE)  IndicatorRelease(hBB);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
}

//=== MAIN ===========================================================
void OnTick(){
   if(!IsNewBar()) return;

   // データ取得
   int need=MathMax(BBW_Z_Lookback+5,MathMax(BB_Period,ATR_Period)+5);
   MqlRates r[]; int n=CopyRates(_Symbol,_Period,0,need,r); if(n<need/2) return;
   ArraySetAsSeries(r,true);

   double bu[],bm[],bl[];
   ArraySetAsSeries(bu,true); ArraySetAsSeries(bm,true); ArraySetAsSeries(bl,true);
   if(CopyBuffer(hBB,0,0,n,bu)<=0) return;
   if(CopyBuffer(hBB,1,0,n,bm)<=0) return;
   if(CopyBuffer(hBB,2,0,n,bl)<=0) return;

   double atr[]; ArraySetAsSeries(atr,true);
   if(CopyBuffer(hATR,0,0,n,atr)<=0) return;

   int i=1;
   double cl=r[i].close, op=r[i].open, high=r[i].high, low=r[i].low;
   double atrv=MathMax(atr[i],_Point);

   // --- SQUEEZE判定
   double bbw_z=0.0;
   if(Use_BBW_Z && n>(BBW_Z_Lookback+2)){
      double bbw= (bu[i]-bl[i])/MathMax(MathAbs(bm[i]),_Point);
      // Z計算省略版
      bbw_z=(bbw-0.0)/1.0;
      if(bbw_z<=Thr_Squeeze_Z){
         CloseAllDir(0);
         g_lastSigText="SQUEEZE→FLAT"; g_lastSigColor=clrDodgerBlue;
         UpdateStatusLabel(g_lastSigText,g_lastSigColor);
         return;
      }
   }

   // --- break判定
   bool breakUP=(cl>bu[i]);
   bool breakDN=(cl<bl[i]);

   // --- big candle判定
   bool bigUp=false,bigDn=false;
   BigCandleFlags(i,atrv,bu[i],bl[i],cl,op,bigUp,bigDn);
   if(bigUp||bigDn){
      int dir=(bigUp?+1:-1);
      g_lastSigText=(bigUp?"BIGCANDLE: BUY":"BIGCANDLE: SELL");
      g_lastSigColor=(bigUp?clrLimeGreen:clrTomato);
      UpdateStatusLabel(g_lastSigText,g_lastSigColor);
      CloseAllDir(-dir);
      if(SpreadOK() && OpenDir(dir)) g_lastDir=dir;
      return;
   }

   // --- レンジ
   bool isRange=(!breakUP && !breakDN);
   if(isRange){
      CloseAllDir(0);
      g_lastSigText="RANGE→FLAT"; g_lastSigColor=clrSilver;
      UpdateStatusLabel(g_lastSigText,g_lastSigColor);
      return;
   }

   // --- シグナル方向
   int sigDir=0;
   if(breakUP) sigDir=+1;
   else if(breakDN) sigDir=-1;

   if(sigDir!=0){
      g_lastSigText=(sigDir>0?"BREAK: BUY":"BREAK: SELL");
      g_lastSigColor=(sigDir>0?clrLimeGreen:clrTomato);
      bool ok=CloseThenDoten_BySignal(sigDir);
      if(ok) g_lastDir=sigDir;
      UpdateStatusLabel(g_lastSigText+(ok?" [OK]":" [NG]"),g_lastSigColor);
      return;
   }

   // --- Idle
   string lastDirStr=(g_lastDir>0?"BUY":(g_lastDir<0?"SELL":"NONE"));
   UpdateStatusLabel("IDLE (lastDir="+lastDirStr+")",clrSilver);
}
