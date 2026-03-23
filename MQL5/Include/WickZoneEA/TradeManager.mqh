//+------------------------------------------------------------------+
//|                                                TradeManager.mqh  |
//|                 WickZone EA - Entry Logic & Position Opening      |
//+------------------------------------------------------------------+
#ifndef WICKZONE_TRADEMANAGER_MQH
#define WICKZONE_TRADEMANAGER_MQH

#include "Utils.mqh"
#include "WickFilter.mqh"
#include "ZoneDetector.mqh"
#include "RiskManager.mqh"
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Trade Manager Class                                              |
//+------------------------------------------------------------------+
class CTradeManager
{
private:
   CTrade            m_trade;
   CWickFilter      *m_wickFilter;
   CZoneDetector    *m_zoneDetector;
   CRiskManager     *m_riskManager;

   int               m_magicNumber;
   int               m_maxOpenPositions;
   double            m_defaultLots;
   int               m_slippage;

   int               CountOpenPositions(string symbol);
   ENUM_ORDER_TYPE   GetEntryDirection(const WickCandle &wc);
   bool              IsPriceAtWickTrigger(const WickCandle &wc, double bid, double ask);

public:
                     CTradeManager();
                    ~CTradeManager();

   void              Init(CWickFilter *wf, CZoneDetector *zd, CRiskManager *rm,
                          double lots, int magic, int maxPositions, int slippage);
   void              MatchWickCandlesToZones();
   void              EvaluateEntries(string symbol);
   bool              OpenPosition(string symbol, WickCandle &wc);
};

//+------------------------------------------------------------------+
CTradeManager::CTradeManager()
{
   m_wickFilter       = NULL;
   m_zoneDetector     = NULL;
   m_riskManager      = NULL;
   m_magicNumber      = 123456;
   m_maxOpenPositions = 3;
   m_defaultLots      = 0.01;
   m_slippage         = 10;
}

//+------------------------------------------------------------------+
CTradeManager::~CTradeManager()
{
}

//+------------------------------------------------------------------+
void CTradeManager::Init(CWickFilter *wf, CZoneDetector *zd, CRiskManager *rm,
                          double lots, int magic, int maxPositions, int slippage)
{
   m_wickFilter       = wf;
   m_zoneDetector     = zd;
   m_riskManager      = rm;
   m_defaultLots      = lots;
   m_magicNumber      = magic;
   m_maxOpenPositions = maxPositions;
   m_slippage         = slippage;

   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(slippage);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                 |
//+------------------------------------------------------------------+
int CTradeManager::CountOpenPositions(string symbol)
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == m_magicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Determine entry direction from wick candle                       |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE CTradeManager::GetEntryDirection(const WickCandle &wc)
{
   // Dominant lower wick -> price rejected lower levels -> BUY
   if(wc.candle.lowerWick > wc.candle.upperWick)
      return ORDER_TYPE_BUY;

   // Dominant upper wick -> price rejected higher levels -> SELL
   return ORDER_TYPE_SELL;
}

//+------------------------------------------------------------------+
//| Check if current price has reached wick trigger level            |
//+------------------------------------------------------------------+
bool CTradeManager::IsPriceAtWickTrigger(const WickCandle &wc, double bid, double ask)
{
   ENUM_ORDER_TYPE dir = GetEntryDirection(wc);

   if(dir == ORDER_TYPE_BUY)
   {
      // For BUY: price must come back down to the wick trigger (lower wick zone)
      return (ask <= wc.wickTriggerPrice);
   }
   else
   {
      // For SELL: price must come back up to the wick trigger (upper wick zone)
      return (bid >= wc.wickTriggerPrice);
   }
}

//+------------------------------------------------------------------+
//| Match stored wick candles to detected zones                      |
//| Only candles near a relevant zone are kept                       |
//+------------------------------------------------------------------+
void CTradeManager::MatchWickCandlesToZones()
{
   if(m_wickFilter == NULL || m_zoneDetector == NULL) return;

   int count = m_wickFilter.GetStoredCount();

   for(int i = count - 1; i >= 0; i--)
   {
      WickCandle wc;
      m_wickFilter.GetStoredCandle(i, wc);

      if(wc.hasZone) continue;  // Already matched

      ZoneInfo matchedZone;
      bool matched = false;

      ENUM_ORDER_TYPE dir = GetEntryDirection(wc);

      // Match wick candles to directionally aligned zones
      if(dir == ORDER_TYPE_BUY)
         matched = m_zoneDetector.IsNearBullishZone(wc.wickTriggerPrice, matchedZone);
      else
         matched = m_zoneDetector.IsNearBearishZone(wc.wickTriggerPrice, matchedZone);

      if(matched)
      {
         WickCandle *ref = m_wickFilter.GetStoredCandleRef(i);
         if(ref != NULL)
         {
            ref.hasZone = true;
            ref.zone    = matchedZone;
         }

         LogDebug("Wick candle matched to " + ZoneTypeToString(matchedZone.type) +
                  " zone at " + TimeToString(wc.candle.time));
      }
   }

   // Remove wick candles that don't have a zone match
   // (only remove candles that have been scanned for at least one cycle)
}

//+------------------------------------------------------------------+
//| Evaluate all stored wick candles for entry                       |
//+------------------------------------------------------------------+
void CTradeManager::EvaluateEntries(string symbol)
{
   if(m_wickFilter == NULL) return;

   // Check position limit
   if(CountOpenPositions(symbol) >= m_maxOpenPositions)
      return;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   int count = m_wickFilter.GetStoredCount();

   for(int i = count - 1; i >= 0; i--)
   {
      WickCandle wc;
      m_wickFilter.GetStoredCandle(i, wc);

      // Only trade candles with a matched zone
      if(!wc.hasZone) continue;
      if(wc.state != ENTRY_PENDING) continue;
      if(!wc.zone.isValid) continue;

      // Check if price has returned to the wick trigger level
      if(IsPriceAtWickTrigger(wc, bid, ask))
      {
         if(OpenPosition(symbol, wc))
         {
            // Mark as triggered
            WickCandle *ref = m_wickFilter.GetStoredCandleRef(i);
            if(ref != NULL)
               ref.state = ENTRY_TRIGGERED;
         }

         // Re-check position limit
         if(CountOpenPositions(symbol) >= m_maxOpenPositions)
            return;
      }
   }
}

//+------------------------------------------------------------------+
//| Open a position based on wick candle setup                       |
//+------------------------------------------------------------------+
bool CTradeManager::OpenPosition(string symbol, WickCandle &wc)
{
   ENUM_ORDER_TYPE direction = GetEntryDirection(wc);

   // Calculate SL from zone
   double sl = m_riskManager.CalcStopLoss(direction, wc.zone, symbol);

   // Calculate entry price
   double entryPrice = 0;
   if(direction == ORDER_TYPE_BUY)
      entryPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
   else
      entryPrice = SymbolInfoDouble(symbol, SYMBOL_BID);

   // Calculate lot size based on risk
   double lots = m_riskManager.CalcLotSize(symbol, entryPrice, sl);

   // No TP - managed by trailing stop
   double tp = 0;

   string comment = "WickZone|" + ZoneTypeToString(wc.zone.type) + "|" +
                    EnumToString(wc.candle.timeframe);

   bool result = false;

   if(direction == ORDER_TYPE_BUY)
   {
      result = m_trade.Buy(lots, symbol, entryPrice, sl, tp, comment);
   }
   else
   {
      result = m_trade.Sell(lots, symbol, entryPrice, sl, tp, comment);
   }

   if(result)
   {
      LogInfo("Position opened: " + (direction == ORDER_TYPE_BUY ? "BUY" : "SELL") +
              " " + DoubleToString(lots, 2) + " lots" +
              " Entry=" + DoubleToString(entryPrice, _Digits) +
              " SL=" + DoubleToString(sl, _Digits) +
              " Zone=" + ZoneTypeToString(wc.zone.type));
   }
   else
   {
      LogError("Failed to open position: " + IntegerToString(GetLastError()) +
               " " + m_trade.ResultComment());
   }

   return result;
}

#endif
