//+------------------------------------------------------------------+
//|                                                 WickZoneEA.mq5   |
//|                     Multi-Timeframe Wick Zone Expert Advisor      |
//|                                                                  |
//|  Strategy:                                                       |
//|  1. Scan candles across multiple timeframes                      |
//|  2. Store candles with dominant wicks (wick > 50% of range)      |
//|  3. Filter: only keep candles near OB, FVG, or P/D zones        |
//|  4. Entry when price returns to the wick trigger level           |
//|  5. SL under the zone, no fixed TP                               |
//|  6. BE + Trailing Stop manage exits                              |
//+------------------------------------------------------------------+
#property copyright "WickZone EA"
#property version   "1.00"
#property strict

#include <WickZoneEA/Utils.mqh>
#include <WickZoneEA/WickFilter.mqh>
#include <WickZoneEA/ZoneDetector.mqh>
#include <WickZoneEA/RiskManager.mqh>
#include <WickZoneEA/TradeManager.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTF1           = PERIOD_M15;    // Timeframe 1
input ENUM_TIMEFRAMES InpTF2           = PERIOD_H1;     // Timeframe 2
input ENUM_TIMEFRAMES InpTF3           = PERIOD_H4;     // Timeframe 3
input ENUM_TIMEFRAMES InpTF4           = PERIOD_D1;     // Timeframe 4
input bool            InpUseTF1        = true;          // Use TF1
input bool            InpUseTF2        = true;          // Use TF2
input bool            InpUseTF3        = true;          // Use TF3
input bool            InpUseTF4        = true;          // Use TF4

input group "=== Wick Filter ==="
input double InpWickThreshold          = 50.0;          // Wick % threshold (50 = 50%)
input int    InpWickLookback           = 50;            // Bars to scan per TF
input int    InpMaxWickCandles         = 20;            // Max stored wick candles
input double InpMinCandleRange         = 10;            // Min candle range (points)
input int    InpWickExpiryBars         = 100;           // Wick candle expiry (bars)

input group "=== Zone Detection ==="
input int    InpOBLookback             = 30;            // OB lookback bars
input int    InpFVGLookback            = 30;            // FVG lookback bars
input double InpZoneTolerance          = 20.0;          // Zone proximity (points)
input int    InpMaxZones               = 50;            // Max zones stored
input double InpATRMultiplier          = 1.5;           // ATR multiplier for OB impulse
input int    InpATRPeriod              = 14;            // ATR period
input int    InpSwingLookback          = 50;            // Swing lookback for P/D

input group "=== Risk Management ==="
input double InpRiskPercent            = 1.0;           // Risk % per trade
input double InpSLBuffer               = 10.0;          // SL buffer (points)
input double InpBEActivation           = 200.0;         // BE activation (points profit)
input double InpBELock                 = 10.0;          // BE lock profit (points)
input double InpTSActivation           = 300.0;         // Trailing stop activation (points)
input double InpTSStep                 = 50.0;          // Trailing step (points)

input group "=== Trade Settings ==="
input int    InpMagic                  = 778899;        // Magic Number
input int    InpMaxPositions           = 3;             // Max open positions
input double InpDefaultLots            = 0.01;          // Default lot size (fallback)
input int    InpSlippage               = 10;            // Slippage (points)

//+------------------------------------------------------------------+
//| Global Module Instances                                          |
//+------------------------------------------------------------------+
CWickFilter   g_wickFilter;
CZoneDetector g_zoneDetector;
CRiskManager  g_riskManager;
CTradeManager g_tradeManager;

datetime      g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Build timeframes array
   ENUM_TIMEFRAMES tfs[];
   int tfCount = 0;

   if(InpUseTF1) { ArrayResize(tfs, tfCount + 1); tfs[tfCount++] = InpTF1; }
   if(InpUseTF2) { ArrayResize(tfs, tfCount + 1); tfs[tfCount++] = InpTF2; }
   if(InpUseTF3) { ArrayResize(tfs, tfCount + 1); tfs[tfCount++] = InpTF3; }
   if(InpUseTF4) { ArrayResize(tfs, tfCount + 1); tfs[tfCount++] = InpTF4; }

   if(tfCount == 0)
   {
      LogError("No timeframes selected!");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Initialize Wick Filter
   double wickThreshold = InpWickThreshold / 100.0;
   g_wickFilter.Init(tfs, wickThreshold, InpWickLookback, InpMaxWickCandles,
                     InpMinCandleRange, InpWickExpiryBars);

   //--- Initialize Zone Detector
   g_zoneDetector.Init(InpOBLookback, InpFVGLookback, InpZoneTolerance,
                        InpMaxZones, InpATRMultiplier, InpATRPeriod, InpSwingLookback);

   //--- Initialize Risk Manager
   g_riskManager.Init(InpBEActivation, InpBELock, InpTSActivation, InpTSStep,
                       InpRiskPercent, InpSLBuffer, InpMagic);

   //--- Initialize Trade Manager
   g_tradeManager.Init(&g_wickFilter, &g_zoneDetector, &g_riskManager,
                        InpDefaultLots, InpMagic, InpMaxPositions, InpSlippage);

   LogInfo("WickZone EA initialized successfully");
   LogInfo("Timeframes: " + IntegerToString(tfCount) +
           " | Wick threshold: " + DoubleToString(InpWickThreshold, 0) + "%" +
           " | Max positions: " + IntegerToString(InpMaxPositions));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   LogInfo("WickZone EA deinitialized. Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| Check for new bar on the fastest timeframe                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, InpTF1, 0);
   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- On new bar: run scans (expensive operations)
   if(IsNewBar())
   {
      //--- Detect zones on all active timeframes
      if(InpUseTF1) g_zoneDetector.DetectAllZones(_Symbol, InpTF1);
      if(InpUseTF2) g_zoneDetector.DetectAllZones(_Symbol, InpTF2);
      if(InpUseTF3) g_zoneDetector.DetectAllZones(_Symbol, InpTF3);
      if(InpUseTF4) g_zoneDetector.DetectAllZones(_Symbol, InpTF4);

      //--- Purge mitigated zones
      g_zoneDetector.PurgeMitigated(_Symbol, InpTF1);

      //--- Scan for wick candles
      g_wickFilter.ScanAllTimeframes(_Symbol);

      //--- Match wick candles to zones
      g_tradeManager.MatchWickCandlesToZones();

      //--- Clean up
      g_wickFilter.PurgeExpired(TimeCurrent());
      g_wickFilter.PurgeTriggered();
   }

   //--- Every tick: evaluate entries and manage positions
   g_tradeManager.EvaluateEntries(_Symbol);
   g_riskManager.ManageOpenPositions(_Symbol, InpMagic);
}

//+------------------------------------------------------------------+
