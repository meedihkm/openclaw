//+------------------------------------------------------------------+
//|                                                TradeManager.mqh  |
//|                 WickZone EA - Limit Order Entry & Management      |
//+------------------------------------------------------------------+
#ifndef WICKZONE_TRADEMANAGER_MQH
#define WICKZONE_TRADEMANAGER_MQH

#include "Utils.mqh"
#include "WickFilter.mqh"
#include "ZoneDetector.mqh"
#include "RiskManager.mqh"
#include <Trade/Trade.mqh>
#include <Trade/OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Trade Manager Class                                              |
//+------------------------------------------------------------------+
class CTradeManager
{
private:
   CTrade            m_trade;
   COrderInfo        m_orderInfo;
   CWickFilter      *m_wickFilter;
   CZoneDetector    *m_zoneDetector;
   CRiskManager     *m_riskManager;

   int               m_magicNumber;
   int               m_maxOpenPositions;
   double            m_defaultLots;
   int               m_slippage;
   double            m_limitOffset;     // points below/above wick for limit placement
   int               m_limitExpiryHours;

   int               CountOpenPositions(string symbol);
   int               CountPendingOrders(string symbol);
   ENUM_ORDER_TYPE   GetEntryDirection(const WickCandle &wc);
   double            CalcLimitPrice(const WickCandle &wc, string symbol);
   bool              IsOrderStillPending(ulong ticket);
   void              CancelOrder(ulong ticket);

public:
                     CTradeManager();
                    ~CTradeManager();

   void              Init(CWickFilter *wf, CZoneDetector *zd, CRiskManager *rm,
                          double lots, int magic, int maxPositions, int slippage,
                          double limitOffset, int limitExpiryHours);
   void              MatchWickCandlesToZones();
   void              PlaceLimitOrders(string symbol);
   void              ManagePendingOrders(string symbol);
   bool              PlaceLimitOrder(string symbol, WickCandle &wc);
};

//+------------------------------------------------------------------+
CTradeManager::CTradeManager()
{
   m_wickFilter        = NULL;
   m_zoneDetector      = NULL;
   m_riskManager       = NULL;
   m_magicNumber       = 123456;
   m_maxOpenPositions  = 3;
   m_defaultLots       = 0.01;
   m_slippage          = 10;
   m_limitOffset       = 5;
   m_limitExpiryHours  = 48;
}

//+------------------------------------------------------------------+
CTradeManager::~CTradeManager()
{
}

//+------------------------------------------------------------------+
void CTradeManager::Init(CWickFilter *wf, CZoneDetector *zd, CRiskManager *rm,
                          double lots, int magic, int maxPositions, int slippage,
                          double limitOffset, int limitExpiryHours)
{
   m_wickFilter        = wf;
   m_zoneDetector      = zd;
   m_riskManager       = rm;
   m_defaultLots       = lots;
   m_magicNumber       = magic;
   m_maxOpenPositions  = maxPositions;
   m_slippage          = slippage;
   m_limitOffset       = limitOffset;
   m_limitExpiryHours  = limitExpiryHours;

   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(slippage);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
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
//| Count pending orders for this EA                                 |
//+------------------------------------------------------------------+
int CTradeManager::CountPendingOrders(string symbol)
{
   int count = 0;
   int total = OrdersTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == symbol &&
         OrderGetInteger(ORDER_MAGIC) == m_magicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Determine entry direction from wick candle                       |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE CTradeManager::GetEntryDirection(const WickCandle &wc)
{
   // Dominant lower wick -> price rejected lower levels -> BUY LIMIT
   if(wc.candle.lowerWick > wc.candle.upperWick)
      return ORDER_TYPE_BUY_LIMIT;

   // Dominant upper wick -> price rejected higher levels -> SELL LIMIT
   return ORDER_TYPE_SELL_LIMIT;
}

//+------------------------------------------------------------------+
//| Calculate the limit order price (under/above the wick)           |
//+------------------------------------------------------------------+
double CTradeManager::CalcLimitPrice(const WickCandle &wc, string symbol)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double offset = m_limitOffset * point;

   ENUM_ORDER_TYPE dir = GetEntryDirection(wc);

   if(dir == ORDER_TYPE_BUY_LIMIT)
   {
      // Place buy limit BELOW the wick trigger (in the lower wick zone)
      // Wick trigger is at midpoint of lower wick; limit goes slightly below
      return NormalizeDouble(wc.wickTriggerPrice - offset, digits);
   }
   else
   {
      // Place sell limit ABOVE the wick trigger (in the upper wick zone)
      // Wick trigger is at midpoint of upper wick; limit goes slightly above
      return NormalizeDouble(wc.wickTriggerPrice + offset, digits);
   }
}

//+------------------------------------------------------------------+
//| Check if a pending order is still active                         |
//+------------------------------------------------------------------+
bool CTradeManager::IsOrderStillPending(ulong ticket)
{
   if(ticket == 0) return false;

   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(OrderGetTicket(i) == ticket)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Cancel a pending order                                           |
//+------------------------------------------------------------------+
void CTradeManager::CancelOrder(ulong ticket)
{
   if(ticket == 0) return;

   if(m_trade.OrderDelete(ticket))
      LogInfo("Cancelled pending order #" + IntegerToString((int)ticket));
   else
      LogError("Failed to cancel order #" + IntegerToString((int)ticket) +
               " Error=" + IntegerToString(GetLastError()));
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
      if(dir == ORDER_TYPE_BUY_LIMIT)
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
}

//+------------------------------------------------------------------+
//| Place limit orders for matched wick candles                      |
//+------------------------------------------------------------------+
void CTradeManager::PlaceLimitOrders(string symbol)
{
   if(m_wickFilter == NULL) return;

   // Check total capacity (positions + pending orders)
   int totalActive = CountOpenPositions(symbol) + CountPendingOrders(symbol);
   if(totalActive >= m_maxOpenPositions)
      return;

   int count = m_wickFilter.GetStoredCount();

   for(int i = count - 1; i >= 0; i--)
   {
      WickCandle wc;
      m_wickFilter.GetStoredCandle(i, wc);

      // Only place orders for matched, pending candles without an existing order
      if(!wc.hasZone) continue;
      if(wc.state != ENTRY_PENDING) continue;
      if(!wc.zone.isValid) continue;
      if(wc.orderTicket != 0 && IsOrderStillPending(wc.orderTicket)) continue;

      // If order was filled or cancelled, skip if already triggered
      if(wc.orderTicket != 0 && !IsOrderStillPending(wc.orderTicket))
      {
         WickCandle *ref = m_wickFilter.GetStoredCandleRef(i);
         if(ref != NULL)
            ref.state = ENTRY_TRIGGERED;
         continue;
      }

      if(PlaceLimitOrder(symbol, wc))
      {
         totalActive++;
         if(totalActive >= m_maxOpenPositions)
            return;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage existing pending orders - cancel expired/invalid ones     |
//+------------------------------------------------------------------+
void CTradeManager::ManagePendingOrders(string symbol)
{
   if(m_wickFilter == NULL) return;

   int count = m_wickFilter.GetStoredCount();

   for(int i = count - 1; i >= 0; i--)
   {
      WickCandle wc;
      m_wickFilter.GetStoredCandle(i, wc);

      if(wc.orderTicket == 0) continue;

      // Check if order was filled (no longer pending -> triggered)
      if(!IsOrderStillPending(wc.orderTicket))
      {
         WickCandle *ref = m_wickFilter.GetStoredCandleRef(i);
         if(ref != NULL)
            ref.state = ENTRY_TRIGGERED;
         continue;
      }

      // Cancel if zone was invalidated
      if(!wc.zone.isValid)
      {
         CancelOrder(wc.orderTicket);
         WickCandle *ref = m_wickFilter.GetStoredCandleRef(i);
         if(ref != NULL)
         {
            ref.orderTicket = 0;
            ref.state = ENTRY_EXPIRED;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Place a single limit order for a wick candle setup               |
//+------------------------------------------------------------------+
bool CTradeManager::PlaceLimitOrder(string symbol, WickCandle &wc)
{
   ENUM_ORDER_TYPE direction = GetEntryDirection(wc);

   // Calculate limit price (under/above the wick)
   double limitPrice = CalcLimitPrice(wc, symbol);

   // Validate limit price vs current market
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double minStopLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                         SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(direction == ORDER_TYPE_BUY_LIMIT)
   {
      // Buy limit must be below current Ask
      if(limitPrice >= ask)
      {
         LogDebug("Buy limit price " + DoubleToString(limitPrice, _Digits) +
                  " >= Ask " + DoubleToString(ask, _Digits) + ", skipping");
         return false;
      }
      if(ask - limitPrice < minStopLevel && minStopLevel > 0)
      {
         LogDebug("Buy limit too close to market, skipping");
         return false;
      }
   }
   else
   {
      // Sell limit must be above current Bid
      if(limitPrice <= bid)
      {
         LogDebug("Sell limit price " + DoubleToString(limitPrice, _Digits) +
                  " <= Bid " + DoubleToString(bid, _Digits) + ", skipping");
         return false;
      }
      if(limitPrice - bid < minStopLevel && minStopLevel > 0)
      {
         LogDebug("Sell limit too close to market, skipping");
         return false;
      }
   }

   // Calculate SL from zone
   double sl = m_riskManager.CalcStopLoss(
      (direction == ORDER_TYPE_BUY_LIMIT) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
      wc.zone, symbol);

   // Calculate lot size based on risk (using limit price as entry)
   double lots = m_riskManager.CalcLotSize(symbol, limitPrice, sl);

   // No TP - managed by trailing stop
   double tp = 0;

   // Order expiry
   datetime expiry = TimeCurrent() + m_limitExpiryHours * 3600;

   string comment = "WickZone|" + ZoneTypeToString(wc.zone.type) + "|" +
                    EnumToString(wc.candle.timeframe);

   bool result = false;

   if(direction == ORDER_TYPE_BUY_LIMIT)
   {
      result = m_trade.BuyLimit(lots, limitPrice, symbol, sl, tp,
                                ORDER_TIME_SPECIFIED, expiry, comment);
   }
   else
   {
      result = m_trade.SellLimit(lots, limitPrice, symbol, sl, tp,
                                 ORDER_TIME_SPECIFIED, expiry, comment);
   }

   if(result)
   {
      ulong orderTicket = m_trade.ResultOrder();

      // Store ticket in wick candle
      int count = m_wickFilter.GetStoredCount();
      for(int i = 0; i < count; i++)
      {
         WickCandle stored;
         m_wickFilter.GetStoredCandle(i, stored);
         if(stored.candle.time == wc.candle.time &&
            stored.candle.timeframe == wc.candle.timeframe)
         {
            WickCandle *ref = m_wickFilter.GetStoredCandleRef(i);
            if(ref != NULL)
            {
               ref.orderTicket = orderTicket;
               ref.limitPrice  = limitPrice;
            }
            break;
         }
      }

      LogInfo("Limit order placed: " +
              (direction == ORDER_TYPE_BUY_LIMIT ? "BUY LIMIT" : "SELL LIMIT") +
              " " + DoubleToString(lots, 2) + " lots" +
              " @" + DoubleToString(limitPrice, _Digits) +
              " SL=" + DoubleToString(sl, _Digits) +
              " Zone=" + ZoneTypeToString(wc.zone.type) +
              " Ticket=#" + IntegerToString((int)orderTicket) +
              " Expiry=" + TimeToString(expiry));
   }
   else
   {
      LogError("Failed to place limit order: " + IntegerToString(GetLastError()) +
               " " + m_trade.ResultComment());
   }

   return result;
}

#endif
