//+------------------------------------------------------------------+
//| EA_04_v1_RECON_OPS_FIX7_TRENDENTRY_MULTIPOS_ADDON_FINAL_FIX2.mq5 |
//| One-file drop-in with reconciler + add-on control                 |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// ---- GLOBAL TRADE OBJECT (declare first!) ----
CTrade trade;

// convenient macro
#define LOG PrintFormat

//================= [ADD-EA4] エラーログ =================================
void EA4_LogLastTradeError(const string where)
{
   int    ret     = (int)trade.ResultRetcode();
   string desc    = trade.ResultRetcodeDescription();
   int    lastErr = GetLastError();
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long   freeze  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   stoplevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID))/_Point;
   PrintFormat("[SEND-FAIL] where=%s ret=%d(%s) lastErr=%d minLot=%.2f maxLot=%.2f stepLot=%.2f digits=%d freeze=%d stopLevel=%d spread=%.1fpt",
               where, ret, desc, lastErr, minLot, maxLot, stepLot, digits, freeze, stoplevel, spreadPts);
}

//================= Inputs (必要最小限) ================================
input long   Magic               = 20250910;
input double Lots                = 0.10;
input int    SlippagePoints      = 10;
input int    MaxSpreadPoints     = 80;     // スプレッド通常ガード
input int    DotenMaxSpreadPoints= 80;     // ドテン許容スプレッド
input bool   DotenAllowWideSpread= true;   // スプレッド越えでもドテンUQを許可
input bool   AllowMultiple       = true;   // 同方向の追加を許可（ヘッジ口座用）
input bool   AllowOppositeHedge  = true;   // 逆方向同時保有を許可（ヘッジ口座）
input bool   EA4_AllowMultiPos   = false;  // ネッティング相当の同一方向本数制御
input int    EA4_MaxAddPos       = 3;
input int    EA4_AddMinBars      = 2;
input int    EA4_AddMinPts       = 50;

// 参照系（最低限）
input ENUM_TIMEFRAMES InpTF      = PERIOD_M15;
input int    Fast_Period         = 20;
input double Fast_Dev            = 1.8;
input ENUM_TIMEFRAMES RefTF      = PERIOD_H4;
input int    RefShift            = 1;

// バンド接触用（不足していた場合に備え定義）
input bool RequireBandTouch   = true;
input int  BandTouchTolPts    = 3;

// Per-Pos SL
input bool   UsePerPosSL      = true;
input double PerPosSL_Points  = 1000;

// 逆張り・反転系の抑止
input bool UseCloseThenDoten     = true;
input bool DotenRespectGuards    = true;
input bool DotenUseUQFallback    = true;

//================= グローバル・状態 ===================================
datetime g_lastAddTime = 0;
double   g_lastAddPrice= 0.0;
int      g_lastAddDir  = 0;
int      g_addCount    = 0;

datetime g_last_reverse_at        = 0;
datetime g_suppress_reverse_until = 0;
bool     g_in_doten_sequence      = false;
string   g_lastCloseContext       = "-";

//================= Utils =============================================
int DigitsSafe(){ return (int)(long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double GetPip(){ double pt=SymbolInfoDouble(_Symbol, SYMBOL_POINT); int dg=DigitsSafe(); return (dg==3||dg==5)? 10.0*pt: pt; }
double SpreadPt(){ MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return 1e9; return (t.ask - t.bid)/_Point; }
bool   EA4_SpreadOK(){ return SpreadPt()<=MaxSpreadPoints; }

bool CopyBarTime(int sh, datetime &bt){ datetime t[]; if(CopyTime(_Symbol, InpTF, sh, 1, t)!=1) return false; bt=t[0]; return true; }
double HighN (int sh){ double v[]; return (CopyHigh (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double LowN  (int sh){ double v[]; return (CopyLow  (_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }
double CloseN(int sh){ double v[]; return (CopyClose(_Symbol,InpTF,sh,1,v)==1? v[0]:0.0); }

bool GetFastBB(int sh,double &u,double &m,double &l){
  static int hBB = INVALID_HANDLE;
  if(hBB==INVALID_HANDLE) hBB = iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE);
  if(hBB==INVALID_HANDLE) return false;
  double bu[],bm[],bl[]; if(CopyBuffer(hBB,0,sh,1,bu)!=1) return false;
  if(CopyBuffer(hBB,1,sh,1,bm)!=1) return false;
  if(CopyBuffer(hBB,2,sh,1,bl)!=1) return false;
  u=bu[0]; m=bm[0]; l=bl[0]; return (u>0 && m>0 && l>0);
}

int CountPositionsSide(int dir){
  int cnt=0;
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong tk=PositionGetTicket(i); if(tk==0) continue;
    if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
    long t=(long)PositionGetInteger(POSITION_TYPE);
    int  d=(t==POSITION_TYPE_BUY? +1:-1);
    if(d==dir) cnt++;
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
        while(tries<=2 && !r){ r=trade.PositionClose(ticket); if(!r) Sleep(250); tries++; }
        if(!r){ ok_all=false; Print("Close ticket ",ticket," err=",GetLastError()); }
        else  { LOG("[EXEC] CloseDir ticket=%I64u dir=%d", ticket, d); }
        more=true; break;
      }
    }
  }
  return ok_all;
}

//================= Guarded Open =====================================
bool OpenDirWithGuard(int dir){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  trade.SetAsyncMode(false);
  trade.SetTypeFilling(ORDER_FILLING_IOC);

  double lots = Lots;
  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double stepLot= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  lots = MathMax(minLot, MathMin(maxLot, lots));
  if(stepLot>0) lots = MathFloor((lots/stepLot)+0.5)*stepLot;

  if(!EA4_SpreadOK()){
     // Fallback: ドテンなどの特例は上位で処理
     Print("[GUARD] spread NG");
     return false;
  }

  bool ok = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
  if(!ok){
     EA4_LogLastTradeError("OpenDirWithGuard-IOC");
     trade.SetTypeFilling(ORDER_FILLING_FOK);
     bool ok2 = (dir>0)? trade.Buy(lots,_Symbol) : trade.Sell(lots,_Symbol);
     if(!ok2){
        EA4_LogLastTradeError("OpenDirWithGuard-FOK");
        return false;
     }
     ok = ok2;
  }
  LOG("[EXEC] Open %s lots=%.2f", (dir>0?"BUY":"SELL"), lots);
  return ok;
}

//================= Close→Doten ======================================
bool CloseThenDoten_BySignal(int dir){
  // 反対側を先にクローズ
  int oppoCnt = CountPositionsSide(-dir);
  if(oppoCnt>0){
    g_in_doten_sequence = true;
    g_suppress_reverse_until = TimeCurrent() + 2;
    if(!CloseDirPositions(-dir)){ g_in_doten_sequence=false; return false; }
    Print((dir>0) ? "[FORCE CLOSE SELL]" : "[FORCE CLOSE BUY]");
  }

  // スプレッド超過でもUQで強制エントリー可
  if(DotenAllowWideSpread){
    double sp = SpreadPt();
    bool overNormal  = (sp > MaxSpreadPoints);
    bool withinDoten = (DotenMaxSpreadPoints<=0) ? true : (sp <= DotenMaxSpreadPoints);
    if(overNormal && withinDoten){
      CTrade t2; t2.SetExpertMagicNumber(Magic); t2.SetDeviationInPoints(SlippagePoints);
      double lots = Lots;
      bool okForce = (dir>0)? t2.Buy(lots,_Symbol) : t2.Sell(lots,_Symbol);
      g_last_reverse_at = TimeCurrent();
      g_in_doten_sequence=false;
      if(okForce) Print((dir>0) ? "[OPEN BUY DOTEN (WIDE)]" : "[OPEN SELL DOTEN (WIDE)]");
      return okForce;
    }
  }

  // 通常のガードを尊重
  if(DotenRespectGuards){
    if(EA4_SpreadOK()){
      bool ok = OpenDirWithGuard(dir);
      g_in_doten_sequence=false;
      if(ok){ g_last_reverse_at = TimeCurrent(); Print((dir>0) ? "[OPEN BUY DOTEN]" : "[OPEN SELL DOTEN]"); return true; }
      if(!DotenUseUQFallback) return false;
    }else if(!DotenUseUQFallback){
      g_in_doten_sequence=false; return false;
    }
  }

  // UQフォールバック
  CTrade t; t.SetExpertMagicNumber(Magic); t.SetDeviationInPoints(SlippagePoints);
  double lots = Lots;
  bool ok2 = (dir>0) ? t.Buy (lots, _Symbol) : t.Sell(lots, _Symbol);
  g_last_reverse_at = TimeCurrent();
  g_in_doten_sequence=false;
  return ok2;
}

//================= ExecuteBySignalDir ================================
bool ExecuteBySignalDir(int dir){
  // ヘッジ/ネッティング両対応（同一シンボル×マジック）
  if(AllowMultiple){
    // 反対方向のヘッジを許可しない場合はクローズしてから建てる
    int oppo = CountPositionsSide(-dir);
    if(oppo>0 && !AllowOppositeHedge){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(-dir)) { g_in_doten_sequence=false; return false; }
      Print(((-dir)>0) ? "[CLOSE BUY ALL]" : "[CLOSE SELL ALL]");
    }
    bool opened = OpenDirWithGuard(dir);
    if(!opened){ g_in_doten_sequence=false; return false; }
    g_in_doten_sequence=false;
    g_last_reverse_at = TimeCurrent();
    Print((dir>0) ? "[OPEN BUY ADD]" : "[OPEN SELL ADD]");
    return true;
  }else{
    // ネッティング風：同方向なら何もしない。反対ならクローズ→エントリー
    int cur = CurrentDir_Netting();
    if(cur == dir) return true;
    if(cur != 0){
      g_in_doten_sequence = true;
      g_suppress_reverse_until = TimeCurrent() + 2;
      if(!CloseDirPositions(0)) { g_in_doten_sequence=false; return false; }
      Print((cur>0) ? "[CLOSE BUY]" : "[CLOSE SELL]");
    }
    bool opened = OpenDirWithGuard(dir);
    if(!opened){ g_in_doten_sequence=false; return false; }
    g_in_doten_sequence=false;
    g_last_reverse_at = TimeCurrent();
    Print((dir>0) ? "[OPEN BUY]" : "[OPEN SELL]");
    return true;
  }
}

//================= 参考: シグナル例（Ref×BB） =========================
bool SignalSELL(int sh, datetime &sigBar, datetime &sigRef){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  double refH=iHigh(_Symbol,RefTF,RefShift); if(refH<=0) return false;
  const double tol  = 15*_Point;
  const double tolB = BandTouchTolPts*_Point;
  double hi   = HighN(sh);
  double cl   = CloseN(sh);
  double probe= hi;
  bool touchBB     = (u >= refH - tol && u <= refH + tol);
  bool touchPx     = (probe >= refH - tol);
  bool bandTouchOK = (!RequireBandTouch)  || (probe >= u - tolB);
  bool pass        = (touchBB && touchPx && bandTouchOK);
  if(!pass) return false;
  if(!CopyBarTime(sh,sigBar)) return false;
  sigRef = iTime(_Symbol,RefTF,RefShift); if(sigRef==0) sigRef=sigBar;
  return true;
}
bool SignalBUY(int sh, datetime &sigBar, datetime &sigRef){
  double u,m,l; if(!GetFastBB(sh,u,m,l)) return false;
  double refL=iLow(_Symbol,RefTF,RefShift); if(refL<=0) return false;
  const double tol  = 15*_Point;
  const double tolB = BandTouchTolPts*_Point;
  double lo   = LowN(sh);
  double cl   = CloseN(sh);
  double probe= lo;
  bool touchBB     = (l >= refL - tol && l <= refL + tol);
  bool touchPx     = (probe <= refL + tol);
  bool bandTouchOK = (!RequireBandTouch)  || (probe <= l + tolB);
  bool pass        = (touchBB && touchPx && bandTouchOK);
  if(!pass) return false;
  if(!CopyBarTime(sh,sigBar)) return false;
  sigRef = iTime(_Symbol,RefTF,RefShift); if(sigRef==0) sigRef=sigBar;
  return true;
}

//================= Per-Pos SL（例） ==================================
bool ClosePositionsBeyondLossPoints(double lossPtsThreshold){
  g_lastCloseContext = "PERPOS_SL";
  bool anyClosed=false, more=true;
  while(more){
    more=false;
    for(int i=PositionsTotal()-1; i>=0; --i){
      ulong ticket = PositionGetTicket(i); if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((string)PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=Magic)     continue;
      long   ptype = (long)PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lossPts = (ptype==POSITION_TYPE_BUY) ? (open - bid)/_Point
                                                  : (ask  - open)/_Point;
      if(lossPts >= lossPtsThreshold){
        trade.SetExpertMagicNumber(Magic);
        trade.SetDeviationInPoints(SlippagePoints);
        bool r=false; int tries=0;
        while(tries<=2 && !r){ r = trade.PositionClose(ticket); if(!r) Sleep(200); tries++; }
        if(r){ LOG("[EXEC] Close (PerPosSL) ticket=%I64u lossPts=%.1f thr=%.1f", ticket, lossPts, lossPtsThreshold); }
        anyClosed |= r; more=true; break;
      }
    }
  }
  return anyClosed;
}

//================= OnInit / OnTick ==================================
int OnInit(){
  trade.SetExpertMagicNumber(Magic);
  trade.SetDeviationInPoints(SlippagePoints);
  return INIT_SUCCEEDED;
}

void OnTick(){
  // 個別SL（例）
  if(UsePerPosSL && PerPosSL_Points>0) ClosePositionsBeyondLossPoints(PerPosSL_Points);

  // --- ダミーのシグナル駆動例（売り優先→買い） ---
  // 実際にはあなたのシグナル条件に差し替えてください
  datetime sb=0,sr=0, bb=0,br=0;
  bool sS = SignalSELL(0,sb,sr);
  bool sB = (!sS) && SignalBUY(0,bb,br);

  if(!sS && !sB) return;
  int dir = sS ? -1 : +1;

  // 反対側クローズ→必要ならドテン
  int haveOpp = CountPositionsSide(-dir);
  if(haveOpp>0){
     if(UseCloseThenDoten) { CloseThenDoten_BySignal(dir); }
     else                  { CloseDirPositions(-dir); }
     return;
  }

  // 同方向：AllowMultipleならADD、禁止ならスキップ
  int sameCnt = CountPositionsSide(dir);
  if(sameCnt>0 && !AllowMultiple) return;

  ExecuteBySignalDir(dir);
}
