//+------------------------------------------------------------------+
//|  XAUUSD ORB-EMA EA  —  XAUUSD H1                                |
//|  Stratégie : Pullback sur EMA50 dans la direction du trend       |
//|              confirmé par un Pin Bar ou Engulfing                |
//+------------------------------------------------------------------+
#property version "1.0"
#include <Trade\Trade.mqh>

input double RiskPct    = 1.0;   // Risque par trade (% capital)
input double SL_Mult    = 1.5;   // Stop Loss  (x ATR)
input double TP_Mult    = 3.0;   // Take Profit (x ATR)
input int    SessionStart = 8;   // Heure ouverture (serveur)
input int    SessionEnd   = 20;  // Heure fermeture
input int    Magic        = 1001;

CTrade trade;

int hEMA, hATR;

int OnInit()
{
   hEMA = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_H1, 14);
   if(hEMA == INVALID_HANDLE || hATR == INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(Magic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { IndicatorRelease(hEMA); IndicatorRelease(hATR); }

//--- Execute uniquement sur nouvelle bougie H1
void OnTick()
{
   static datetime lastBar = 0;
   if(iTime(_Symbol, PERIOD_H1, 0) == lastBar) return;
   lastBar = iTime(_Symbol, PERIOD_H1, 0);

   // Filtre session
   int h = TimeHour(TimeCurrent());
   if(h < SessionStart || h >= SessionEnd) return;

   // Une seule position à la fois
   if(PositionsTotal() > 0) return;

   // Lecture indicateurs (bougie -1 fermée)
   double ema[], atr[];
   if(CopyBuffer(hEMA, 0, 1, 2, ema) < 2) return;
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;

   double O = iOpen(_Symbol, PERIOD_H1, 1);
   double H = iHigh(_Symbol, PERIOD_H1, 1);
   double L = iLow (_Symbol, PERIOD_H1, 1);
   double C = iClose(_Symbol, PERIOD_H1, 1);
   double range = H - L;
   if(range == 0) return;

   // ---- SIGNAL : Pullback sur EMA50 + confirmation Price Action ----
   //
   //  ACHAT  : prix au-dessus EMA50 + bougie touche l'EMA + Pin Bar bas ou Engulfing haussier
   //  VENTE  : prix en dessous EMA50 + bougie touche l'EMA + Pin Bar haut ou Engulfing baissier

   bool nearEMA   = (L <= ema[0] * 1.001 && H >= ema[0] * 0.999);
   bool aboveEMA  = C > ema[0];
   bool belowEMA  = C < ema[0];

   double lowerWick = MathMin(O, C) - L;
   double upperWick = H - MathMax(O, C);
   double body      = MathAbs(C - O);

   bool bullPin     = (lowerWick > range * 0.55) && (upperWick < range * 0.25) && (C > O);
   bool bearPin     = (upperWick > range * 0.55) && (lowerWick < range * 0.25) && (C < O);

   double prevC = iClose(_Symbol, PERIOD_H1, 2);
   double prevO = iOpen (_Symbol, PERIOD_H1, 2);
   bool bullEngulf  = (C > O) && (prevC < prevO) && (C > prevO) && (O < prevC);
   bool bearEngulf  = (C < O) && (prevC > prevO) && (C < prevO) && (O > prevC);

   int signal = 0;
   if(nearEMA && aboveEMA && (bullPin || bullEngulf)) signal =  1;
   if(nearEMA && belowEMA && (bearPin || bearEngulf)) signal = -1;
   if(signal == 0) return;

   // ---- Calcul lot, SL, TP ----
   double slDist  = atr[0] * SL_Mult;
   double tpDist  = atr[0] * TP_Mult;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tick    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot     = MathFloor((balance * RiskPct / 100.0) / (slDist / tickSz * tick) / lotStep) * lotStep;
   lot = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), lot);

   if(signal == 1)
      trade.Buy (lot, _Symbol, 0,
                 NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - slDist, _Digits),
                 NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + tpDist, _Digits));
   else
      trade.Sell(lot, _Symbol, 0,
                 NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) + slDist, _Digits),
                 NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - tpDist, _Digits));
}
//+------------------------------------------------------------------+
