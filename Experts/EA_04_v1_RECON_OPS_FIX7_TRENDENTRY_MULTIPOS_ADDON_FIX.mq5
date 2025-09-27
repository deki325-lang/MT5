//+------------------------------------------------------------------+
//|  EA_04_v1_RECON_OPS_FIX7_TRENDENTRY_MULTIPOS_ADDON_FIX.mq5       |
//|  修正版: 反転時は全クローズ→必ず1本新規、同方向は積み増し対応     |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//=== Inputs =========================================================
input double InpLots          = 0.10;
input bool   EA4_ReconVerboseLog = true;

// --- Multi-position settings ---
input bool   EA4_AllowMultiPos = true;   // 同方向の積み増しを許可
input bool   EA4_AddOnSameDir  = true;   // 方向一致時にAddを実行
input int    EA4_AddMinBars    = 1;      // 追加の最小バー間隔
input int    EA4_AddMinPts     = 80;     // 追加の最小距離（pt）
input int    EA4_MaxAddPos     = 5;      // 追加の最大回数

// --- Add-on (積み増し) 状態管理 ---
int    g_addCount     = 0;
int    g_lastAddBar   = 0;
double g_lastAddPrice = 0.0;

//=== Utility ========================================================
double NormalizeLots(double lots) {
   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double steplot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double res = MathMax(minlot, MathMin(maxlot, lots));
   return MathFloor(res/steplot+0.5)*steplot;
}

// Spread check dummy
bool EA4_SpreadOK() {
   return true; // 簡易化。必要ならスプレッドチェックを実装
}

//=== Core Logic =====================================================
void CheckAndTrade(int desiredDir)
{
   if(desiredDir==0) return;
   if(PositionSelect(_Symbol)){
      long tcur = PositionGetInteger(POSITION_TYPE);
      if((desiredDir>0 && tcur==POSITION_TYPE_BUY) ||
         (desiredDir<0 && tcur==POSITION_TYPE_SELL))
      {
         // --- 方向一致：積み増し判定 ---
         if(EA4_ReconVerboseLog)
            Print("[RECON] aligned, checking add-on...");

         if(EA4_AllowMultiPos && EA4_AddOnSameDir)
         {
            int curBars = iBars(_Symbol, PERIOD_CURRENT);
            int  bars_since_add = (int)MathMax(0, curBars - g_lastAddBar);

            double px_now = (desiredDir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                          : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            double dist_pts = MathAbs(px_now - g_lastAddPrice) / _Point;

            bool bars_ok = (bars_since_add >= EA4_AddMinBars);
            bool dist_ok = (dist_pts       >= EA4_AddMinPts);
            bool room_ok = (g_addCount     <  EA4_MaxAddPos);

            if(EA4_ReconVerboseLog)
               PrintFormat("[ADD-CHECK] bars=%d/%d dist=%.1f/%d count=%d/%d",
                           bars_since_add, EA4_AddMinBars,
                           dist_pts, EA4_AddMinPts,
                           g_addCount, EA4_MaxAddPos);

            if(bars_ok && dist_ok && room_ok && EA4_SpreadOK())
            {
               double lots = NormalizeLots(InpLots);
               bool sent = (desiredDir>0)
                           ? trade.Buy(lots, NULL, 0, 0, 0)
                           : trade.Sell(lots, NULL, 0, 0, 0);

               if(sent)
               {
                  g_lastAddBar   = curBars;
                  g_lastAddPrice = px_now;
                  g_addCount++;

                  if(EA4_ReconVerboseLog)
                     PrintFormat("[ADD-ORDER] %s lots=%.2f (count=%d)",
                                 (desiredDir>0?"BUY":"SELL"), lots, g_addCount);
                  Alert(StringFormat("[OPEN %s ADD]", (desiredDir>0?"BUY":"SELL")));
               }
            }
         }
         return; // 同方向はここで終了
      }
      else {
         // --- 反転処理: 全クローズして新規1本 ---
         trade.PositionClose(_Symbol);
         double lots = NormalizeLots(InpLots);
         bool sent = (desiredDir>0)
                     ? trade.Buy(lots, NULL, 0, 0, 0)
                     : trade.Sell(lots, NULL, 0, 0, 0);
         if(sent) {
            g_addCount   = 0;
            g_lastAddBar = iBars(_Symbol, PERIOD_CURRENT);
            g_lastAddPrice = (desiredDir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            if(EA4_ReconVerboseLog)
               Print("[RECON] reverse entry done, counter reset");
         }
      }
   } else {
      // --- ポジション無し: 新規1本 ---
      double lots = NormalizeLots(InpLots);
      bool sent = (desiredDir>0)
                  ? trade.Buy(lots, NULL, 0, 0, 0)
                  : trade.Sell(lots, NULL, 0, 0, 0);
      if(sent) {
         g_addCount   = 0;
         g_lastAddBar = iBars(_Symbol, PERIOD_CURRENT);
         g_lastAddPrice = (desiredDir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID));
         if(EA4_ReconVerboseLog)
            Print("[RECON] first entry, counter reset");
      }
   }
}

//=== OnTick =========================================================
void OnTick()
{
   // ここではデモ用にランダム方向を発行
   int dir = (MathRand()%3)-1; // -1,0,+1
   CheckAndTrade(dir);
}
