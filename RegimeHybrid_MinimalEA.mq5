//+------------------------------------------------------------------+
//|  RegimeHybrid_MinimalEA.mq5                                      |
//|  Break=trend-follow / Range=mean-revert / ---=do nothing         |
//|  Minimal, single-position EA for MQL5                            |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade Trade;

//=== Inputs =========================================================
input ENUM_TIMEFRAMES InpTF         = PERIOD_M15; // 判定足
// BB for signals
input int    Fast_Period            = 20;
input double Fast_Dev               = 2.0;
// ADX / BBW_Z / Donchian for Regime
input int    ADX_Period             = 14;
input double ADX_Thr_Range          = 18.0;     // <= → Range票
input double ADX_Thr_Break          = 22.0;     // >= → Break票
input int    BBW_PeriodLook         = 100;      // BB幅Zの参照本数
input double BBW_Z_RangeMax         = -0.30;    // <= → Range票
input double BBW_Z_BreakMin         =  0.50;    // >= → Break票
input int    Don_Period             = 20;       // 直近高安ブレイク

// Trading
input double Lots                   = 0.10;
input double ATR_Mult_SL            = 1.8;
input double ATR_Mult_TP            = 2.2;
input int    ATR_Period             = 14;
input int    MaxSpreadPoints        = 25;       // これ超は発注スキップ
input ulong  Magic                  = 20250917;

// Misc
input bool   AllowShort             = true;
input bool   AllowLong              = true;

// --- Trend-only 強化用 ---
input bool   TrendOnly               = true;     // trueでRangeエントリ無効
input ENUM_TIMEFRAMES HTF            = PERIOD_H1;// 上位TFで順方向確認
input int    HTF_MA_Period           = 100;      // 上位TFの傾き判定
input double MinADX_Strict           = 25.0;     // ブレイク採用の下限
input double MinBBWZ_Strict          = 0.80;     // BB幅Zの下限
input int    Don_Period_Strict       = 55;       // 強いブレイク用ドンチャン
input double BreakBuffer_ATR         = 0.30;     // ブレイクにATRバッファを要求
// 伸ばす系（TP無し or 大きめ、ATRトレーリング）
input bool   UseATR_Trailing         = true;
input double Trail_ATR_Mult          = 3.0;      // ATR×3のチャンデリア風
input double BreakEven_ATR           = 1.0;      // +ATR×1で建値へ



//=== Inputs =========================================================
input bool UseSessionFilter = true;
input int  SessStartHour    = 7;
input int  SessEndHour      = 22;

//=== Helpers: session ===============================================
// 推奨：参照渡し版（公式仕様）
bool InSession(){
  if(!UseSessionFilter) return true;
  MqlDateTime dt;
  TimeCurrent(dt);                 // ← 参照渡しオーバーロード
  int h = dt.hour;
  if(SessStartHour <= SessEndHour) return (h >= SessStartHour && h < SessEndHour);
  return (h >= SessStartHour || h < SessEndHour);  // 日跨ぎ
}




//=== Risk-based position sizing (他EAポジも含めて管理) ===============
input bool   UseRiskSizing            = true;   // リスク%でロット自動計算
input double RiskPerTradePct          = 0.5;    // 1トレードあたり口座の % リスク
input double MaxAccountRiskPct        = 2.0;    // 口座全体で許容する合計リスク上限%
input double FallbackLots             = 0.10;   // 自動計算が不可のときのロット
input double AssumeATRmultIfNoSL      = 2.0;    // 既存ポジにSL無い場合の仮想SL(ATR倍)
input double MaxSymbolExposureLots    = 2.0;    // 同一シンボル合計ロット上限（任意）


//=== Handles / State ================================================
int hBB = INVALID_HANDLE;      // iBands upper/middle/lower
int hADX= INVALID_HANDLE;      // iADX main
int hATR= INVALID_HANDLE;      // iATR
int hHTF_MA = INVALID_HANDLE;   // 上位TF EMAのハンドル

datetime lastBarTime = 0;
double   g_lastRegime = 0;     // -1=Range, 0=Unknown, +1=Break

//=== Helpers: market/price =========================================

double Pip() { return (_Digits==3 || _Digits==5) ? 10*_Point : _Point; }

bool NewBar(){
  datetime t[2];
  if(CopyTime(_Symbol, InpTF, 0, 2, t) != 2) return false;
  if(t[0] != lastBarTime){ lastBarTime = t[0]; return true; }
  return false;
}


bool GetBands(int sh, double &u,double &m,double &l){
  double bu[], bm[], bl[];
  if(CopyBuffer(hBB, 0, sh, 1, bu)!=1) return false;
  if(CopyBuffer(hBB, 1, sh, 1, bm)!=1) return false;
  if(CopyBuffer(hBB, 2, sh, 1, bl)!=1) return false;
  u=bu[0]; m=bm[0]; l=bl[0]; return true;
}

double CloseN(int sh){ double v[]; if(CopyClose(_Symbol, InpTF, sh, 1, v)!=1) return 0; return v[0]; }
double HighN (int sh){ double v[]; if(CopyHigh (_Symbol, InpTF, sh, 1, v)!=1) return 0; return v[0]; }
double LowN  (int sh){ double v[]; if(CopyLow  (_Symbol, InpTF, sh, 1, v)!=1) return 0; return v[0]; }

bool SpreadOK(){
  double sp = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
  return (sp <= MaxSpreadPoints);
}

bool Flat(){
  long total=0;
  if(!PositionSelect(_Symbol)) return true;
  if((total=(long)PositionsTotal())<1) return true;
  // 単一銘柄単一ポジ運用（他銘柄を考慮しない簡易）
  if(!PositionSelect(_Symbol)) return true;
  double vol = PositionGetDouble(POSITION_VOLUME);
  return (vol<=0.0);
}

int CurrDir(){ // +1=BUY, -1=SELL, 0=FLAT
  if(!PositionSelect(_Symbol)) return 0;
  long type = (long)PositionGetInteger(POSITION_TYPE);
  return (type==POSITION_TYPE_BUY? +1 : -1);
}

// ロット正規化（最小/最大/ステップ）
double NormalizeLots(double lots){
  double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  lots = MathMax(minlot, MathMin(maxlot, MathFloor(lots/step + 1e-8)*step));
  return lots;
}

// pip価値（口座通貨建て）。TICK_VALUE/TICK_SIZEから算出。
double PipValuePerLot(){
  double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  double pip = Pip();
  if(ts<=0) return 0.0;
  return tv * (pip/ts); // 1ロットあたり1pipの価値
}

// ATR（最新）
double ATRvalue(){
  double a[]; if(CopyBuffer(hATR,0,0,1,a)!=1) return 0.0;
  return a[0];
}

// 既存ポジションの**口座通貨建てリスク総量**を見積もる（他EA含む）
double CurrentOpenRiskMoney(){
  double totalRisk = 0.0;
  int total = PositionsTotal();
  double atr = ATRvalue();
  double pipVal = PipValuePerLot();
  if(pipVal<=0) return 0.0;

  for(int i=0;i<total;i++){
    ulong ticket = PositionGetTicket(i);
    if(!PositionSelectByTicket(ticket)) continue;
    string sym = PositionGetString(POSITION_SYMBOL);
    if(sym != _Symbol) { // 他シンボルも**合計リスク**に含める
      // ここでは全口座リスクで絞るため、他シンボルも集計
    }
    int    type = (int)PositionGetInteger(POSITION_TYPE);
    double vol  = PositionGetDouble(POSITION_VOLUME);
    double sl   = PositionGetDouble(POSITION_SL);
    double price= PositionGetDouble(POSITION_PRICE_OPEN);

    // SLが設定されていないポジは「ATR×AssumeATRmultIfNoSL」を仮想SL距離として見積もる
    double stopDistance = 0.0;
    if(sl>0.0){
      stopDistance = MathAbs(price - sl);
    }else{
      stopDistance = atr * AssumeATRmultIfNoSL;
    }
    // 距離をpipsへ
    double stopPips = stopDistance / Pip();
    double posRisk  = stopPips * pipVal * vol; // 口座通貨建ての損失見積もり
    totalRisk += posRisk;
  }
  return totalRisk;
}

// 同一シンボルのエクスポージャ（合計ロット）
double CurrentSymbolExposureLots(){
  double lots=0.0;
  int total=PositionsTotal();
  for(int i=0;i<total;i++){
    ulong ticket = PositionGetTicket(i);
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetString(POSITION_SYMBOL)==_Symbol){
      lots += PositionGetDouble(POSITION_VOLUME);
    }
  }
  return lots;
}

// 目標リスク額から必要ロットを計算（ATR×距離 / pip価値）
double LotsFromRiskMoney(double riskMoney, double stopDistancePts){
  double pipVal = PipValuePerLot();
  if(pipVal<=0) return 0.0;
  double stopPips = (stopDistancePts) / Pip(); // 価格距離→pips
  if(stopPips <= 0.0) return 0.0;
  double lots = riskMoney / (stopPips * pipVal);
  return NormalizeLots(lots);
}

// Marginチェックで縮小
double CapLotsByMargin(double lots, int dir){
  double price = (dir>0 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol,SYMBOL_BID));
  double margin=0.0;
  if(OrderCalcMargin((dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL), _Symbol, lots, price, margin)){
    double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

    if(margin > free*0.95){ // 余裕を見て95%
      // ざっくり比例で縮小
      double ratio = (free*0.95)/MathMax(1e-9, margin);
      lots = NormalizeLots(lots * ratio);
    }
  }
  return lots;
}


// 上位TFのEMAの傾きで順方向確認（直近0と1を比較）
bool HTF_MA_Up(){
  if(hHTF_MA == INVALID_HANDLE) return true; // フェイルオープン
  double buf[2];
  if(CopyBuffer(hHTF_MA, 0, 0, 2, buf) != 2) return true;
  return (buf[0] > buf[1]);
}
bool HTF_MA_Dn(){
  if(hHTF_MA == INVALID_HANDLE) return true;
  double buf[2];
  if(CopyBuffer(hHTF_MA, 0, 0, 2, buf) != 2) return true;
  return (buf[0] < buf[1]);
}

// 厳しめドンチャン・ブレイク（確定足）
bool DonchianBreakStrict(int sh, bool &upBreak, bool &dnBreak){
  upBreak=false; dnBreak=false;
  int need = Don_Period_Strict + sh + 1;
  MqlRates r[]; if(CopyRates(_Symbol, InpTF, 0, need, r) < need) return false;
  double hi=-DBL_MAX, lo=DBL_MAX;
  for(int i=1+sh; i<=Don_Period_Strict+sh; ++i){ hi=MathMax(hi,r[i].high); lo=MathMin(lo,r[i].low); }
  double c=r[sh].close; double a=ATRvalue();
  // ATRバッファ要求 → ヒゲじゃなく「実体でしっかり抜けた」だけ採用
  upBreak=(c > hi + BreakBuffer_ATR*a);
  dnBreak=(c < lo - BreakBuffer_ATR*a);
  return true;
}


//=== Regime detection ===============================================
// BB幅のZスコア（Fast BB）
bool FastBBW_Z(int look, int sh, double &z){
  if(look<20) look=20;
  double ub[], lb[];
  if(CopyBuffer(hBB,0,sh,look,ub)!=look) return false;
  if(CopyBuffer(hBB,2,sh,look,lb)!=look) return false;
  double sum=0, sum2=0;
  for(int i=0;i<look;i++){
    double w=(ub[i]-lb[i])/_Point;
    sum  += w; sum2 += w*w;
  }
  double n=look, mean=sum/n;
  double var = MathMax(1e-12, sum2/n - mean*mean);
  double sd  = MathSqrt(var);
  double cur = (ub[0]-lb[0])/_Point;
  z = (cur - mean) / (sd>0?sd:1.0);
  return true;
}

bool GetADX(int sh, double &adx){
  if(hADX==INVALID_HANDLE) return false;
  double d[]; if(CopyBuffer(hADX,0,sh,1,d)!=1) return false; // MAIN
  adx = d[0]; return true;
}

bool DonchianBreak(int sh, bool &upBreak, bool &dnBreak){
  upBreak=false; dnBreak=false;
  int need = Don_Period + sh + 1;
  MqlRates r[]; if(CopyRates(_Symbol, InpTF, 0, need, r) < need) return false;
  double hi=-DBL_MAX, lo=DBL_MAX;
  for(int i=1+sh; i<=Don_Period+sh; ++i){ hi=MathMax(hi, r[i].high); lo=MathMin(lo, r[i].low); }
  double c = r[sh].close;
  double tol = 0; // 最小版は許容0
  upBreak = (c > hi + tol);
  dnBreak = (c < lo - tol);
  return true;
}

// +1=Break, -1=Range, 0=Unknown
int DetectRegime(int sh){
  double adx=0, z=0;
  bool haveADX = GetADX(sh, adx);
  bool haveZ   = FastBBW_Z(BBW_PeriodLook, sh, z);
  bool upB=false, dnB=false;
  bool haveDon = DonchianBreak(sh, upB, dnB);

  int voteBreak=0, voteRange=0;
  if(haveADX){ if(adx>=ADX_Thr_Break) voteBreak++; else if(adx<=ADX_Thr_Range) voteRange++; }
  if(haveZ){   if(z>=BBW_Z_BreakMin)  voteBreak++; else if(z<=BBW_Z_RangeMax)  voteRange++; }
  if(haveDon){ if(upB||dnB)           voteBreak++; else                        voteRange++; }

  if(voteBreak>voteRange) return +1;
  if(voteRange>voteBreak) return -1;

  // --- TrendOnly: 弱い/曖昧は捨て、強い時だけ +1 ---
  if(TrendOnly){
    double adx2=0, z2=0;
    bool hadx = GetADX(sh, adx2);
    bool hz   = FastBBW_Z(BBW_PeriodLook, sh, z2);
    bool up=false, dn=false;
    bool hdon = DonchianBreakStrict(sh, up, dn);

    bool trendOK = (hadx && hz && hdon &&
                    adx2>=MinADX_Strict && z2>=MinBBWZ_Strict && (up||dn));
    if(trendOK) return +1;
    return 0;   // それ以外は ---
  }

  return 0;     // 票が拮抗：---
}



//=== Entry/Exit =====================================================
bool SLTP_FromATR(int dir, double &sl, double &tp){
  if(hATR==INVALID_HANDLE) return false;
  double a[]; if(CopyBuffer(hATR,0,0,1,a)!=1) return false;
  double price = (dir>0 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol,SYMBOL_BID));
  double atr=a[0];
  if(dir>0){ sl = price - atr*ATR_Mult_SL; tp = price + atr*ATR_Mult_TP; }
  else     { sl = price + atr*ATR_Mult_SL; tp = price - atr*ATR_Mult_TP; }
  return true;
}

void CloseIfOpposite(int dirWanted){
  int cur = CurrDir();
  if(cur==0 || cur==dirWanted) return;
  Trade.PositionClose(_Symbol);
}




// エントリー直前に呼ぶロット算出
double CalcLotsForEntry(int sig){
  if(!UseRiskSizing) return NormalizeLots(FallbackLots);

  double atr = ATRvalue(); if(atr<=0) return NormalizeLots(FallbackLots);
//  extern input double ATR_Mult_SL; // ※ 既存の EA 入力を使います
  double stopDistance = atr * ATR_Mult_SL;

  double base = MathMax(100.0, MathMin(AccountInfoDouble(ACCOUNT_BALANCE),
                                       AccountInfoDouble(ACCOUNT_EQUITY)));
  double perTrade = base * (RiskPerTradePct/100.0);
  double capTotal = base * (MaxAccountRiskPct/100.0);

  double used = CurrentOpenRiskMoney();
  double room = MathMax(0.0, capTotal - used);
  if(room <= 0.0) return 0.0;

  double target = MathMin(perTrade, room);
  double lots = LotsFromRiskMoney(target, stopDistance);

  if(MaxSymbolExposureLots>0){
    double left = MaxSymbolExposureLots - CurrentSymbolExposureLots();
    if(left <= 0) return 0.0;
    lots = MathMin(lots, left);
  }
  lots = CapLotsByMargin(lots, sig);
  return NormalizeLots(lots);
}



//=== Lifecycle ======================================================
int OnInit(){
  hBB  = iBands(_Symbol, InpTF, Fast_Period, 0, Fast_Dev, PRICE_CLOSE);
  hADX = iADX  (_Symbol, InpTF, ADX_Period);
  hATR = iATR  (_Symbol, InpTF, ATR_Period);
  if(hBB==INVALID_HANDLE || hADX==INVALID_HANDLE || hATR==INVALID_HANDLE){
    Print("Handle init failed"); return(INIT_FAILED);
  }
  if(TrendOnly){
  hHTF_MA = iMA(_Symbol, HTF, HTF_MA_Period, 0, MODE_EMA, PRICE_CLOSE);
  if(hHTF_MA == INVALID_HANDLE){
    Print("HTF MA handle init failed");
    return(INIT_FAILED);
  }
}

  datetime t0[]; if(CopyTime(_Symbol, InpTF, 0,1, t0)==1) lastBarTime=t0[0];
  return(INIT_SUCCEEDED);
}


void OnDeinit(const int reason){}

void OnTick(){
  if(!NewBar()) return;
  if(!InSession()) return;

  int regime = DetectRegime(1);
  if(regime==0 && g_lastRegime!=0) regime=(int)g_lastRegime;
  if(regime!=0) g_lastRegime=regime;

  if(regime > 0){
    TradeBreakout();     // ←関数は呼び出すだけ
  }else if(regime < 0){
    TradeRange();
  }else{
    return;              // --- は何もしない
  }
}

// Break: 順張り（確定足でBB上抜けBuy / 下抜けSell）
void TradeBreakout(){
  int sh=1; double u,m,l; if(!GetBands(sh,u,m,l)) return;
  double c = CloseN(sh);

  int sig=0;
  if(AllowLong  && c>=u) sig=+1;
  if(AllowShort && c<=l) sig=-1;
  if(sig==0 || !SpreadOK()) return;

  CloseIfOpposite(sig);
  if(!Flat()) return;

  double sl,tp; if(!SLTP_FromATR(sig,sl,tp)) return;

  double lots = CalcLotsForEntry(sig);
  if(lots <= 0.0){ Print("Lots=0 (risk cap / margin / exposure). Skip."); return; }

  double entry = (sig>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
  Trade.SetExpertMagicNumber(Magic);
  Trade.PositionOpen(_Symbol, (sig>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL), lots, entry, sl, tp);
}

// Range: 逆張り（確定足でBB上タッチ→Sell / 下タッチ→Buy）
void TradeRange(){
  int sh=1; double u,m,l; if(!GetBands(sh,u,m,l)) return;
  double h=HighN(sh), lo=LowN(sh);

  int sig=0;
  if(AllowShort && h>=u) sig=-1;
  if(AllowLong  && lo<=l) sig=+1;
  if(sig==0 || !SpreadOK()) return;

  CloseIfOpposite(sig);
  if(!Flat()) return;

  double sl,tp; if(!SLTP_FromATR(sig,sl,tp)) return;

  double lots = CalcLotsForEntry(sig);
  if(lots <= 0.0){ Print("Lots=0 (risk cap / margin / exposure). Skip."); return; }

  double entry = (sig>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
  Trade.SetExpertMagicNumber(Magic);
  Trade.PositionOpen(_Symbol, (sig>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL), lots, entry, sl, tp);
}


  int sig=0; // +1=BUY, -1=SELL
  // 実体でのバッファ抜け（再確認）
  if(AllowLong  && c >= u + BreakBuffer_ATR*a && HTF_MA_Up())  sig=+1;
  if(AllowShort && c <= l - BreakBuffer_ATR*a && HTF_MA_Dn())  sig=-1;
  if(sig==0) return;
  if(!SpreadOK()) return;

  CloseIfOpposite(sig);
  if(!Flat()) return;

  double sl,tp; if(!SLTP_FromATR(sig,sl,tp)) return;

  // 伸ばす方針：TPは大きめ or 付けない（トレーリングに任せる）
  if(UseATR_Trailing){ tp=0.0; } // 任意：TP外す

  double lots = CalcLotsForEntry(sig);
  if(lots<=0.0){ Print("Lots=0 (risk cap/margin/exposure). Skip."); return; }

  double entry=(sig>0?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID));
  Trade.SetExpertMagicNumber(Magic);
  if(Trade.PositionOpen(_Symbol,(sig>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL),lots,entry,sl,tp))
    Print("Break entry ok @",DoubleToString(entry,_Digits));
}


  // 新バーでのみ判定・発注（多重発注防止）
  if(!NewBar()) return;
  ManageTrailing();
  // --- ATRトレーリング ---
void ManageTrailing(){
  if(!UseATR_Trailing) return;
  if(!PositionSelect(_Symbol)) return;

  int dir = CurrDir(); if(dir==0) return;
  double a = ATRvalue(); if(a<=0) return;

  double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl        = PositionGetDouble(POSITION_SL);
  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

  // 建値ストップ（含み益 ATR×BreakEven_ATR 到達で建値へ）
  if(BreakEven_ATR>0){
    if(dir>0 && (bid - priceOpen) >= a*BreakEven_ATR){
      double be = priceOpen; if(sl < be) Trade.PositionModify(_Symbol, be, PositionGetDouble(POSITION_TP));
    }
    if(dir<0 && (priceOpen - ask) >= a*BreakEven_ATR){
      double be = priceOpen; if(sl > be || sl==0) Trade.PositionModify(_Symbol, be, PositionGetDouble(POSITION_TP));
    }
  }

  // チャンデリア風ATRトレーリング
  double trailSL = (dir>0 ? (bid - a*Trail_ATR_Mult)
                          : (ask + a*Trail_ATR_Mult));
  // 片方向のみ前進（戻さない）
  if(dir>0 && trailSL > sl) Trade.PositionModify(_Symbol, trailSL, PositionGetDouble(POSITION_TP));
  if(dir<0 && trailSL < sl) Trade.PositionModify(_Symbol, trailSL, PositionGetDouble(POSITION_TP));
}

  
  
if(!InSession()) return;


  // Regime 判定（確定足）
  int regime = DetectRegime(1);
  if(regime==0 && g_lastRegime!=0) regime=(int)g_lastRegime; // 初期は継続性
  if(regime!=0) g_lastRegime=regime;

  if(regime>0){
    // Break: 順張り
    TradeBreakout();
  }else if(regime<0){
    // Range: 逆張り
    TradeRange();
  }else{
    // --- : 何もしない
    return;
  }
}
