//+------------------------------------------------------------------+
//|  XAUUSD SMC-EA  —  Smart Money Concepts                         |
//|  Logique : BOS H1 + retest Order Block + filtre H4              |
//+------------------------------------------------------------------+
#property version "2.0"
#include <Trade\Trade.mqh>

//--- Inputs
input double RiskPct      = 1.0;   // Risque/trade (% capital)
input int    SwingLookback= 10;    // Bougies pour détecter les swings H1
input double ATR_Filter   = 0.5;   // ATR min (filtre range trop étroit, en $)
input double ATR_Max      = 4.0;   // ATR max (filtre news/spike, en $)
input int    SessionStart = 7;     // Heure début (serveur)
input int    SessionEnd   = 20;    // Heure fin
input int    Magic        = 2001;

CTrade trade;
int hATR_H1, hATR_H4, hEMA_H4;

//--- State machine
struct OB {                        // Order Block
   double top, bot;
   bool   valid;
   bool   bullish;
};

OB   currentOB;
bool waitingRetest = false;

int OnInit()
{
   hATR_H1 = iATR(_Symbol, PERIOD_H1, 14);
   hATR_H4 = iATR(_Symbol, PERIOD_H4, 14);
   hEMA_H4 = iMA (_Symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR_H1==INVALID_HANDLE || hATR_H4==INVALID_HANDLE || hEMA_H4==INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(Magic);
   ZeroMemory(currentOB);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   IndicatorRelease(hATR_H4);
   IndicatorRelease(hEMA_H4);
}

//+------------------------------------------------------------------+

void OnTick()
{
   static datetime lastBar = 0;
   if(iTime(_Symbol, PERIOD_H1, 0) == lastBar) return;
   lastBar = iTime(_Symbol, PERIOD_H1, 0);

   // Filtre session
   int h = TimeHour(TimeCurrent());
   if(h < SessionStart || h >= SessionEnd) return;

   // Une seule position ouverte à la fois
   if(PositionsTotal() > 0) { waitingRetest = false; return; }

   // Lecture ATR
   double atr1[], atr4[], ema4[];
   if(CopyBuffer(hATR_H1, 0, 1, 1, atr1) < 1) return;
   if(CopyBuffer(hATR_H4, 0, 0, 1, atr4) < 1) return;
   if(CopyBuffer(hEMA_H4, 0, 0, 1, ema4) < 1) return;

   // Filtre volatilité — on ne trade pas si trop calme ou sur news
   if(atr1[0] < ATR_Filter || atr1[0] > ATR_Max) { waitingRetest = false; return; }

   // Direction macro H4 : prix vs EMA50 H4
   double closeH4 = iClose(_Symbol, PERIOD_H4, 0);
   int    trend   = (closeH4 > ema4[0]) ? 1 : -1;

   // ──────────────────────────────────────────────────────────────
   //  PHASE 1 : Détection Break of Structure (BOS) H1
   //  Un BOS haussier = la dernière bougie clôture au-dessus
   //  du dernier swing high H1 (dans la fenêtre SwingLookback)
   // ──────────────────────────────────────────────────────────────
   if(!waitingRetest)
   {
      double swingHigh = 0, swingLow  = DBL_MAX;
      int    shIdx     = 0, slIdx     = 0;

      for(int i = 2; i <= SwingLookback; i++)
      {
         double hi = iHigh(_Symbol, PERIOD_H1, i);
         double lo = iLow (_Symbol, PERIOD_H1, i);
         if(hi > swingHigh) { swingHigh = hi; shIdx = i; }
         if(lo < swingLow)  { swingLow  = lo; slIdx = i; }
      }

      double closeNow = iClose(_Symbol, PERIOD_H1, 1);

      // BOS haussier : clôture au-dessus du swing high ET trend H4 haussier
      if(trend == 1 && closeNow > swingHigh)
      {
         // L'Order Block = dernière bougie baissière AVANT la cassure
         int obIdx = FindLastBearCandle(shIdx);
         if(obIdx > 0)
         {
            currentOB.top     = iHigh (_Symbol, PERIOD_H1, obIdx);
            currentOB.bot     = iLow  (_Symbol, PERIOD_H1, obIdx);
            currentOB.bullish = true;
            currentOB.valid   = true;
            waitingRetest     = true;
         }
      }
      // BOS baissier : clôture en dessous du swing low ET trend H4 baissier
      else if(trend == -1 && closeNow < swingLow)
      {
         int obIdx = FindLastBullCandle(slIdx);
         if(obIdx > 0)
         {
            currentOB.top     = iHigh (_Symbol, PERIOD_H1, obIdx);
            currentOB.bot     = iLow  (_Symbol, PERIOD_H1, obIdx);
            currentOB.bullish = false;
            currentOB.valid   = true;
            waitingRetest     = true;
         }
      }
      return;
   }

   // ──────────────────────────────────────────────────────────────
   //  PHASE 2 : Attente du retest de l'Order Block
   //  + confirmation : bougie de rejet sur l'OB
   // ──────────────────────────────────────────────────────────────
   if(!currentOB.valid) return;

   double C  = iClose(_Symbol, PERIOD_H1, 1);
   double O  = iOpen (_Symbol, PERIOD_H1, 1);
   double Hi = iHigh (_Symbol, PERIOD_H1, 1);
   double Lo = iLow  (_Symbol, PERIOD_H1, 1);

   // Invalidation OB si le prix clôture à l'intérieur sans rebond
   if(currentOB.bullish && C < currentOB.bot) { ZeroMemory(currentOB); waitingRetest = false; return; }
   if(!currentOB.bullish && C > currentOB.top) { ZeroMemory(currentOB); waitingRetest = false; return; }

   bool retestBull = currentOB.bullish  && Lo <= currentOB.top && C > currentOB.top && C > O;
   bool retestBear = !currentOB.bullish && Hi >= currentOB.bot && C < currentOB.bot && C < O;

   if(!retestBull && !retestBear) return;

   // ──────────────────────────────────────────────────────────────
   //  ENTRÉE : SL sous/sur la mèche de l'OB, TP = 2.5x SL
   // ──────────────────────────────────────────────────────────────
   double slDist, slPrice, tpPrice, entryPrice;

   if(retestBull)
   {
      slPrice   = currentOB.bot - atr1[0] * 0.3;          // marge sous l'OB
      entryPrice= SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      slDist    = entryPrice - slPrice;
      tpPrice   = entryPrice + slDist * 2.5;
   }
   else
   {
      slPrice   = currentOB.top + atr1[0] * 0.3;
      entryPrice= SymbolInfoDouble(_Symbol, SYMBOL_BID);
      slDist    = slPrice - entryPrice;
      tpPrice   = entryPrice - slDist * 2.5;
   }

   if(slDist <= 0) return;

   double lot = CalcLot(slDist);
   if(lot <= 0) return;

   if(retestBull)
      trade.Buy (lot, _Symbol, 0,
                 NormalizeDouble(slPrice,  _Digits),
                 NormalizeDouble(tpPrice,  _Digits));
   else
      trade.Sell(lot, _Symbol, 0,
                 NormalizeDouble(slPrice,  _Digits),
                 NormalizeDouble(tpPrice,  _Digits));

   ZeroMemory(currentOB);
   waitingRetest = false;
}

//+------------------------------------------------------------------+
//|  Helpers                                                         |
//+------------------------------------------------------------------+
int FindLastBearCandle(int fromIdx)
{
   for(int i = fromIdx; i >= 1; i--)
      if(iClose(_Symbol, PERIOD_H1, i) < iOpen(_Symbol, PERIOD_H1, i)) return i;
   return -1;
}

int FindLastBullCandle(int fromIdx)
{
   for(int i = fromIdx; i >= 1; i--)
      if(iClose(_Symbol, PERIOD_H1, i) > iOpen(_Symbol, PERIOD_H1, i)) return i;
   return -1;
}

double CalcLot(double slDist)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double tick     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double riskAmt  = balance * RiskPct / 100.0;
   double lot      = MathFloor(riskAmt / (slDist / tickSz * tick) / lotStep) * lotStep;
   return MathMax(lotMin, lot);
}
//+------------------------------------------------------------------+
