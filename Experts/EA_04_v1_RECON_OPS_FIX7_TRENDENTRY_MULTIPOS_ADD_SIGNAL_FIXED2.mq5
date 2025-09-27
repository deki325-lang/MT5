//+------------------------------------------------------------------+
//|  EA_04_v1_RECON_OPS_FIX7_TRENDENTRY_MULTIPOS_ADD_SIGNAL_FIXED2.mq5
//|  Minimal helper demonstrating safe "same-direction add-on" logic
//|  without using PositionSelectByIndex (uses PositionGetTicket loop).
//|  Drop the functions into your EA, then call TryAddSameDirectionIfSignal(+1/-1)
//|  right after a NEW signal is confirmed. Requires hedging accounts for true multi-pos.
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// ---- Inputs you likely already have in your EA (duplicate/rename as needed) ----
input long   Magic                 = 20250910;
input double Lots                  = 0.10;
input int    SlippagePoints        = 10;

input bool   EA4_AllowMultiPos     = true;  // allow same-direction add
input int    EA4_MaxAddPos         = 3;     // total positions same dir (e.g., 3 => first 1 + adds 2)
input int    EA4_AddMinBars        = 2;     // min bars since last add
input int    EA4_AddMinPts         = 50;    // min distance in points since last add

// Optional spacing vs every existing same-side position
input double MinGridPips           = 15;    // 0=disable (distance from each position's open)
input double MinAddLot             = 0.05;  // lower bound for add
input double MaxAddLot             = 50.0;  // upper bound for add

// ---- Globals to track add-ons ----
int      g_addCount      = 0;
double   g_lastAddPrice  = 0.0;
datetime g_lastAddTime   = 0;
int      g_lastAddDir    = 0;

CTrade trade;

// ---- Utils ----
int  DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=DigitsSafe(); return (dg==3||dg==5)? 10.0*pt: pt; }
double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask - t.bid)/_Point; }

double SymbolMinLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double SymbolMaxLot(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double SymbolLotStep(){ double s=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return (s>0?s:0.01); }

double NormalizeVolume(double vol){
  double vmin=SymbolMinLot(), vmax=SymbolMaxLot(), vstp=SymbolLotStep();
  vol = MathMax(vmin, MathMin(vmax, vol));
  vol = MathRound(vol / vstp) * vstp;
  return NormalizeDouble(vol, 2);
}

// Count positions for this symbol+magic and direction (+1/-1)
int CountPositionsSide(const int dir){
  int cnt=0;
  for(int i=PositionsTotal()-1; i>=0; --i){
    ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long typ=(long)PositionGetInteger(POSITION_TYPE);
    int  d=(typ==POSITION_TYPE_BUY? +1:-1);
    if(d==dir) cnt++;
  }
  return cnt;
}

// Enough spacing from EVERY same-side open price (in pips). Returns true if OK.
bool EnoughSpacingSameSide(const int dir, const double minPips){
  if(minPips<=0) return true;
  double ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double pip=GetPip();
  for(int i=PositionsTotal()-1; i>=0; --i){
    ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long typ=(long)PositionGetInteger(POSITION_TYPE);
    int  d=(typ==POSITION_TYPE_BUY? +1:-1);
    if(d!=dir) continue;
    double open=PositionGetDouble(POSITION_PRICE_OPEN);
    double ref = (dir>0? ask: bid);
    double distPips = MathAbs(ref - open)/pip;
    if(distPips < minPips) return false;
  }
  return true;
}

// Open wrapper (simple). In your EA replace with your guarded version if needed.
bool OpenDirSimple(const int dir, double lots){
  lots = NormalizeVolume(lots);
  if(lots < SymbolMinLot()) return false;
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  return (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
}

// ---- Main add-on entry ----
// Call this when a NEW signal in direction `dir` (+1=BUY/-1=SELL) is detected.
bool TryAddSameDirectionIfSignal(const int dir){
  if(!EA4_AllowMultiPos) return false;
  if(dir==0) return false;

  // 必ず「すでに同方向を1本以上保有」している時のみ追加
  int curSame = CountPositionsSide(dir);
  if(curSame<=0) return false;

  // 本数上限（合計本数）
  if(curSame >= EA4_MaxAddPos) return false;

  // 直前が別方向ならカウンタ初期化
  if(g_lastAddDir != dir){ g_addCount=0; g_lastAddPrice=0.0; g_lastAddTime=0; }

  // バー間隔
  if(EA4_AddMinBars>0 && g_lastAddTime>0){
    datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(curBar == 0) curBar = TimeCurrent(); // fallback (shouldn't happen)
    if( (curBar - g_lastAddTime) < EA4_AddMinBars * PeriodSeconds(_Period) )
      return false;
  }

  // 価格距離（前回追加基準）
  double ask=SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid=SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double nowPx = (dir>0? ask: bid);
  if(g_lastAddPrice>0.0){
    if( MathAbs(nowPx - g_lastAddPrice) < EA4_AddMinPts * _Point )
      return false;
  }

  // 既存同方向の建値との距離チェック
  if(!EnoughSpacingSameSide(dir, MinGridPips)) return false;

  // ロット（ここでは固定 Lots を使用。必要ならあなたのロット計算関数に置換）
  double addLots = Lots;
  if(curSame >= 1){ // 2本目以降の下限
    addLots = MathMax(addLots, MinAddLot);
  }
  if(addLots > MaxAddLot) addLots = MaxAddLot;

  bool ok = OpenDirSimple(dir, addLots);
  if(ok){
    g_addCount++;
    g_lastAddDir   = dir;
    g_lastAddTime  = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(g_lastAddTime==0) g_lastAddTime=TimeCurrent();
    g_lastAddPrice = nowPx;
    PrintFormat("[ADD-ON] dir=%s add#=%d lots=%.2f px=%.5f curSame(before)=%d / max=%d",
                (dir>0?"BUY":"SELL"), g_addCount, addLots, nowPx, curSame, EA4_MaxAddPos);
  }else{
    PrintFormat("[ADD-ON FAIL] dir=%s lots=%.2f err=%d",
                (dir>0?"BUY":"SELL"), addLots, GetLastError());
  }
  return ok;
}

// ---- Demo scaffolding (optional) ----
int OnInit(){ trade.SetExpertMagicNumber(Magic); trade.SetDeviationInPoints(SlippagePoints); return(INIT_SUCCEEDED); }
void OnDeinit(const int reason){}
void OnTick(){
  // This EA does nothing by itself. Integrate TryAddSameDirectionIfSignal()
  // into your main EA after a *new* same-direction signal is confirmed.
}
