//+------------------------------------------------------------------+
//|                    XAUUSD MultiStrategy EA                       |
//|                    Version 2.0 — 2026                           |
//|                                                                  |
//|  Stratégies combinées :                                          |
//|   1. ORB   — Opening Range Breakout (price action H1)           |
//|   2. PA    — Pin Bar + Engulfing (price action)                  |
//|   3. MACD  — Signal line crossover avec filtre RSI               |
//|   4. EMA   — Triple EMA Trend Following                          |
//|                                                                  |
//|  Risk Management :                                               |
//|   - Sizing basé sur % du capital (ATR)                           |
//|   - Trailing Stop dynamique (ATR)                                |
//|   - Filtre de session (Londres / New York)                       |
//|   - Protection drawdown maximal                                  |
//|   - Max positions simultanées                                    |
//+------------------------------------------------------------------+
#property copyright "XAUUSD MultiStrategy EA"
#property link      "https://github.com/meedihkm/openclaw"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Indicators\Trend.mqh>

//--- Objets trading
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//+------------------------------------------------------------------+
//| PARAMÈTRES GÉNÉRAUX                                              |
//+------------------------------------------------------------------+
input group "=== STRATÉGIES ACTIVES ==="
input bool   UseORB      = true;   // ORB — Opening Range Breakout
input bool   UsePA       = true;   // PA  — Price Action (Pin Bar / Engulfing)
input bool   UseMACD     = true;   // MACD — Signal Crossover + RSI
input bool   UseEMA      = true;   // EMA — Triple EMA Trend

input group "=== GESTION DU RISQUE ==="
input double RiskPercent   = 1.0;   // Risque par trade (% du capital)
input double MaxDrawdown   = 15.0;  // Drawdown max autorisé (%)
input int    MaxPositions  = 3;     // Positions simultanées max
input double FixedLot      = 0.0;   // Lot fixe (0 = calcul automatique)
input bool   UseTrailing   = true;  // Activer Trailing Stop

input group "=== PARAMÈTRES ATR ==="
input int    ATR_Period    = 14;    // Période ATR
input double SL_ATR_Mult   = 1.5;  // Multiplicateur SL (x ATR)
input double TP_ATR_Mult   = 3.0;  // Multiplicateur TP (x ATR)
input double Trail_ATR     = 1.0;  // Multiplicateur Trailing (x ATR)

input group "=== STRATÉGIE ORB ==="
input int    ORB_Hour      = 9;    // Heure début range (serveur)
input int    ORB_Minutes   = 60;   // Durée du range (minutes)
input double ORB_Buffer    = 0.5;  // Buffer breakout (x ATR)

input group "=== STRATÉGIE EMA ==="
input int    EMA_Fast      = 8;    // EMA rapide
input int    EMA_Mid       = 21;   // EMA médiane
input int    EMA_Slow      = 55;   // EMA lente

input group "=== STRATÉGIE MACD ==="
input int    MACD_Fast     = 12;   // MACD EMA rapide
input int    MACD_Slow     = 26;   // MACD EMA lente
input int    MACD_Signal   = 9;    // MACD Signal
input int    RSI_Period    = 14;   // Période RSI
input double RSI_OB        = 70.0; // RSI Survente (overbought)
input double RSI_OS        = 30.0; // RSI Survendu (oversold)

input group "=== FILTRE SESSION ==="
input bool   FilterSession = true; // Activer filtre session
input int    LondonOpen    = 8;    // Ouverture Londres (heure serveur)
input int    LondonClose   = 17;   // Fermeture Londres
input int    NYOpen        = 13;   // Ouverture New York
input int    NYClose       = 22;   // Fermeture New York

input group "=== PARAMÈTRES AVANCÉS ==="
input int    MagicNumber   = 202601; // Magic Number EA
input int    Slippage      = 20;     // Slippage max (points)
input string EA_Comment    = "XAUUSD_MS"; // Commentaire trades

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
double initialBalance;
int    handleATR, handleMACD, handleRSI;
int    handleEMA_Fast, handleEMA_Mid, handleEMA_Slow;

// Variables ORB
double orbHigh = 0, orbLow = 0;
bool   orbFormed = false;
datetime orbDate = 0;

//+------------------------------------------------------------------+
//| INITIALISATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Vérifier le symbole
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSDm" && _Symbol != "GOLD")
      PrintFormat("Attention : EA optimisé XAUUSD, symbole actuel : %s", _Symbol);

   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Configurer l'objet trade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Créer les handles d'indicateurs
   handleATR      = iATR(_Symbol, PERIOD_H1, ATR_Period);
   handleMACD     = iMACD(_Symbol, PERIOD_H1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE);
   handleEMA_Fast = iMA(_Symbol, PERIOD_H1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Mid  = iMA(_Symbol, PERIOD_H1, EMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow = iMA(_Symbol, PERIOD_H1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR == INVALID_HANDLE || handleMACD == INVALID_HANDLE ||
      handleRSI == INVALID_HANDLE || handleEMA_Fast == INVALID_HANDLE)
   {
      Print("Erreur création indicateurs : ", GetLastError());
      return INIT_FAILED;
   }

   Print("=== XAUUSD MultiStrategy EA v2.0 initialisé ===");
   PrintFormat("Stratégies : ORB=%s | PA=%s | MACD=%s | EMA=%s",
               UseORB?"ON":"OFF", UsePA?"ON":"OFF",
               UseMACD?"ON":"OFF", UseEMA?"ON":"OFF");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINITIALISATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR);
   IndicatorRelease(handleMACD);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleEMA_Fast);
   IndicatorRelease(handleEMA_Mid);
   IndicatorRelease(handleEMA_Slow);
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   // Vérifications de base
   if(!IsNewBar()) return;
   if(!CheckDrawdown()) return;
   if(!CheckSession()) return;

   // Trailing stop dynamique
   if(UseTrailing) ManageTrailingStop();

   // Compter positions ouvertes
   int openPos = CountPositions();
   if(openPos >= MaxPositions) return;

   // Lire les données de marché
   double atr[];
   if(CopyBuffer(handleATR, 0, 0, 3, atr) < 3) return;
   double currentATR = atr[1]; // bougie fermée

   // ======== STRATÉGIE ORB ========
   if(UseORB)
   {
      UpdateORB(currentATR);
      int orbSignal = GetORBSignal(currentATR);
      if(orbSignal != 0) ExecuteTrade(orbSignal, currentATR, "ORB");
      if(CountPositions() >= MaxPositions) return;
   }

   // ======== STRATÉGIE PRICE ACTION ========
   if(UsePA)
   {
      int paSignal = GetPriceActionSignal();
      if(paSignal != 0) ExecuteTrade(paSignal, currentATR, "PA");
      if(CountPositions() >= MaxPositions) return;
   }

   // ======== STRATÉGIE MACD + RSI ========
   if(UseMACD)
   {
      int macdSignal = GetMACDSignal();
      if(macdSignal != 0) ExecuteTrade(macdSignal, currentATR, "MACD");
      if(CountPositions() >= MaxPositions) return;
   }

   // ======== STRATÉGIE EMA TREND ========
   if(UseEMA)
   {
      int emaSignal = GetEMASignal();
      if(emaSignal != 0) ExecuteTrade(emaSignal, currentATR, "EMA");
   }
}

//+------------------------------------------------------------------+
//| DÉTECTION NOUVELLE BOUGIE H1                                     |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBar != lastBar)
   {
      lastBar = currentBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| STRATÉGIE 1 : ORB - Opening Range Breakout                       |
//+------------------------------------------------------------------+
void UpdateORB(double atr)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%d.%02d.%02d", dt.year, dt.mon, dt.day));

   // Réinitialiser le range chaque jour
   if(today != orbDate)
   {
      orbHigh   = 0;
      orbLow    = DBL_MAX;
      orbFormed = false;
      orbDate   = today;
   }

   int startHour   = ORB_Hour;
   int endMinutes  = ORB_Hour * 60 + ORB_Minutes;
   int currentMins = dt.hour * 60 + dt.min;

   // Construire le range pendant la période ORB
   if(currentMins >= startHour * 60 && currentMins < endMinutes)
   {
      double hi = iHigh(_Symbol, PERIOD_H1, 0);
      double lo = iLow(_Symbol, PERIOD_H1, 0);
      if(hi > orbHigh) orbHigh = hi;
      if(lo < orbLow)  orbLow  = lo;
      orbFormed = false;
   }
   // Valider le range une fois la période terminée
   else if(currentMins >= endMinutes && orbHigh > 0 && orbLow < DBL_MAX && !orbFormed)
   {
      orbFormed = true;
      PrintFormat("ORB formé → High=%.2f | Low=%.2f | Range=%.2f pips",
                  orbHigh, orbLow, (orbHigh - orbLow) / _Point / 10);
   }
}

int GetORBSignal(double atr)
{
   if(!orbFormed) return 0;

   double price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buffer = atr * ORB_Buffer;

   // Breakout haussier
   if(price > orbHigh + buffer && !HasOpenPosition(POSITION_TYPE_BUY, "ORB"))
      return 1;

   // Breakout baissier
   if(price < orbLow - buffer && !HasOpenPosition(POSITION_TYPE_SELL, "ORB"))
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| STRATÉGIE 2 : PRICE ACTION — Pin Bar & Engulfing                 |
//+------------------------------------------------------------------+
int GetPriceActionSignal()
{
   // Données des 3 dernières bougies fermées
   double open[3], high[3], low[3], close[3];
   if(CopyOpen (_Symbol, PERIOD_H1, 1, 3, open)  < 3) return 0;
   if(CopyHigh (_Symbol, PERIOD_H1, 1, 3, high)  < 3) return 0;
   if(CopyLow  (_Symbol, PERIOD_H1, 1, 3, low)   < 3) return 0;
   if(CopyClose(_Symbol, PERIOD_H1, 1, 3, close) < 3) return 0;

   // Bougie la plus récente (index 0 = bougie -1)
   double body0  = MathAbs(close[0] - open[0]);
   double range0 = high[0] - low[0];
   double body1  = MathAbs(close[1] - open[1]);

   if(range0 == 0) return 0;

   // ---- PIN BAR HAUSSIER ----
   // Mèche basse longue (>= 60%), petite mèche haute, corps en haut
   double lowerWick0 = (close[0] > open[0]) ? open[0] - low[0] : close[0] - low[0];
   double upperWick0 = (close[0] > open[0]) ? high[0] - close[0] : high[0] - open[0];
   bool bullPinBar = (lowerWick0 >= range0 * 0.6) &&
                     (upperWick0 <= range0 * 0.2) &&
                     (body0 <= range0 * 0.35) &&
                     (close[0] > close[1]); // contexte haussier

   // ---- PIN BAR BAISSIER ----
   double upperWickB = (close[0] < open[0]) ? high[0] - open[0] : high[0] - close[0];
   double lowerWickB = (close[0] < open[0]) ? close[0] - low[0] : open[0] - low[0];
   bool bearPinBar = (upperWickB >= range0 * 0.6) &&
                     (lowerWickB <= range0 * 0.2) &&
                     (body0 <= range0 * 0.35) &&
                     (close[0] < close[1]); // contexte baissier

   // ---- ENGULFING HAUSSIER ----
   bool bullEngulf = (close[1] < open[1]) &&          // bougie -2 bearish
                     (close[0] > open[0]) &&           // bougie -1 bullish
                     (open[0] <= close[1]) &&           // ouvre sous close précédent
                     (close[0] >= open[1]) &&           // clôture au-dessus open précédent
                     (body0 > body1 * 1.1);             // corps plus grand

   // ---- ENGULFING BAISSIER ----
   bool bearEngulf = (close[1] > open[1]) &&          // bougie -2 bullish
                     (close[0] < open[0]) &&           // bougie -1 bearish
                     (open[0] >= close[1]) &&           // ouvre au-dessus close précédent
                     (close[0] <= open[1]) &&           // clôture sous open précédent
                     (body0 > body1 * 1.1);             // corps plus grand

   if(bullPinBar || bullEngulf) return 1;
   if(bearPinBar || bearEngulf) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| STRATÉGIE 3 : MACD + RSI                                         |
//+------------------------------------------------------------------+
int GetMACDSignal()
{
   double macdMain[3], macdSignalLine[3], rsi[3];

   if(CopyBuffer(handleMACD, MAIN_LINE,   1, 3, macdMain)       < 3) return 0;
   if(CopyBuffer(handleMACD, SIGNAL_LINE, 1, 3, macdSignalLine) < 3) return 0;
   if(CopyBuffer(handleRSI,  0,           1, 3, rsi)            < 3) return 0;

   // Croisement MACD haussier + RSI pas en survente
   bool macdBullCross = (macdMain[1] > macdSignalLine[1]) &&
                        (macdMain[0] <= macdSignalLine[0]);
   bool macdBearCross = (macdMain[1] < macdSignalLine[1]) &&
                        (macdMain[0] >= macdSignalLine[0]);

   // Confirmation RSI
   bool rsiBullOk = rsi[1] > RSI_OS && rsi[1] < 55; // RSI remonte depuis zone survendue
   bool rsiBearOk = rsi[1] < RSI_OB && rsi[1] > 45; // RSI redescend depuis zone surachetée

   if(macdBullCross && rsiBullOk) return 1;
   if(macdBearCross && rsiBearOk) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| STRATÉGIE 4 : TRIPLE EMA TREND FOLLOWING                         |
//+------------------------------------------------------------------+
int GetEMASignal()
{
   double emaF[3], emaM[3], emaS[3];

   if(CopyBuffer(handleEMA_Fast, 0, 1, 3, emaF) < 3) return 0;
   if(CopyBuffer(handleEMA_Mid,  0, 1, 3, emaM) < 3) return 0;
   if(CopyBuffer(handleEMA_Slow, 0, 1, 3, emaS) < 3) return 0;

   double close[2];
   if(CopyClose(_Symbol, PERIOD_H1, 1, 2, close) < 2) return 0;

   // Alignement haussier : EMA8 > EMA21 > EMA55 + prix au-dessus
   bool bullAlign = (emaF[0] > emaM[0]) && (emaM[0] > emaS[0]) &&
                    (close[0] > emaF[0]);

   // Alignement baissier : EMA8 < EMA21 < EMA55 + prix en dessous
   bool bearAlign = (emaF[0] < emaM[0]) && (emaM[0] < emaS[0]) &&
                    (close[0] < emaF[0]);

   // Croisement haussier : EMA8 croise EMA21 vers le haut
   bool emaBullCross = (emaF[0] > emaM[0]) && (emaF[1] <= emaM[1]) && bullAlign;
   bool emaBearCross = (emaF[0] < emaM[0]) && (emaF[1] >= emaM[1]) && bearAlign;

   if(emaBullCross) return 1;
   if(emaBearCross) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| EXÉCUTION D'UN TRADE                                             |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal, double atr, string stratName)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp, lot;
   double slDist = atr * SL_ATR_Mult;
   double tpDist = atr * TP_ATR_Mult;

   if(signal == 1) // BUY
   {
      sl  = NormalizeDouble(ask - slDist, _Digits);
      tp  = NormalizeDouble(ask + tpDist, _Digits);
      lot = CalculateLotSize(slDist);
      if(lot <= 0) return;
      if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Comment + "_" + stratName))
         PrintFormat("[%s] BUY %.2f lots | SL=%.2f TP=%.2f | ATR=%.2f", stratName, lot, sl, tp, atr);
      else
         PrintFormat("[%s] Erreur BUY : %d", stratName, GetLastError());
   }
   else if(signal == -1) // SELL
   {
      sl  = NormalizeDouble(bid + slDist, _Digits);
      tp  = NormalizeDouble(bid - tpDist, _Digits);
      lot = CalculateLotSize(slDist);
      if(lot <= 0) return;
      if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Comment + "_" + stratName))
         PrintFormat("[%s] SELL %.2f lots | SL=%.2f TP=%.2f | ATR=%.2f", stratName, lot, sl, tp, atr);
      else
         PrintFormat("[%s] Erreur SELL : %d", stratName, GetLastError());
   }
}

//+------------------------------------------------------------------+
//| CALCUL DE LA TAILLE DE POSITION                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(FixedLot > 0) return NormalizeLot(FixedLot);

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize == 0 || tickValue == 0) return 0;

   double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double slInTicks  = slDistance / tickSize;
   double lot        = riskAmount / (slInTicks * tickValue);

   return NormalizeLot(MathMax(minLot, MathMin(maxLot, lot)));
}

double NormalizeLot(double lot)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathFloor(lot / lotStep) * lotStep;
}

//+------------------------------------------------------------------+
//| GESTION DU TRAILING STOP (ATR)                                   |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double atr[];
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return;
   double trailDist = atr[0] * Trail_ATR;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != MagicNumber) continue;
      if(posInfo.Symbol() != _Symbol)   continue;

      double sl = posInfo.StopLoss();
      double tp = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(posInfo.PriceCurrent() - trailDist, _Digits);
         if(newSL > sl + _Point)
            trade.PositionModify(posInfo.Ticket(), newSL, tp);
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double newSL = NormalizeDouble(posInfo.PriceCurrent() + trailDist, _Digits);
         if(newSL < sl - _Point || sl == 0)
            trade.PositionModify(posInfo.Ticket(), newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| UTILITAIRES                                                       |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == MagicNumber && posInfo.Symbol() == _Symbol)
         count++;
   return count;
}

bool HasOpenPosition(ENUM_POSITION_TYPE type, string stratName)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != MagicNumber) continue;
      if(posInfo.Symbol() != _Symbol)   continue;
      if(posInfo.PositionType() == type)
      {
         if(stratName == "" || StringFind(posInfo.Comment(), stratName) >= 0)
            return true;
      }
   }
   return false;
}

bool CheckDrawdown()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;
   double ddPct = (balance - equity) / balance * 100.0;
   if(ddPct >= MaxDrawdown)
   {
      static datetime lastWarn = 0;
      if(TimeCurrent() - lastWarn > 3600)
      {
         PrintFormat("ALERTE : Drawdown %.1f%% ≥ limite %.1f%% — trading suspendu", ddPct, MaxDrawdown);
         lastWarn = TimeCurrent();
      }
      return false;
   }
   return true;
}

bool CheckSession()
{
   if(!FilterSession) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool inLondon = (h >= LondonOpen && h < LondonClose);
   bool inNY     = (h >= NYOpen     && h < NYClose);
   return inLondon || inNY;
}

//+------------------------------------------------------------------+
//| RAPPORT DANS LE JOURNAL (optionnel)                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id == CHARTEVENT_KEYDOWN && lparam == 82) // Touche 'R' = rapport
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double profit  = AccountInfoDouble(ACCOUNT_PROFIT);
      PrintFormat("=== RAPPORT EA ===");
      PrintFormat("Balance : %.2f | Equity : %.2f | Profit flottant : %.2f", balance, equity, profit);
      PrintFormat("Balance initiale : %.2f | P&L total : +%.2f%%",
                  initialBalance, (balance - initialBalance) / initialBalance * 100);
      PrintFormat("Positions ouvertes : %d / %d", CountPositions(), MaxPositions);
   }
}
//+------------------------------------------------------------------+
