//+------------------------------------------------------------------+
//|                                                  WickFilter.mqh  |
//|                  WickZone EA - Multi-TF Wick Candle Filter       |
//+------------------------------------------------------------------+
#ifndef WICKZONE_WICKFILTER_MQH
#define WICKZONE_WICKFILTER_MQH

#include "Utils.mqh"

//+------------------------------------------------------------------+
//| Wick Filter Class                                                |
//+------------------------------------------------------------------+
class CWickFilter
{
private:
   ENUM_TIMEFRAMES   m_timeframes[];
   WickCandle        m_storedCandles[];
   int               m_maxStoredCandles;
   double            m_wickThreshold;    // 0.0 - 1.0 (0.5 = 50%)
   int               m_lookbackBars;
   double            m_minCandleRange;   // minimum range in points to filter dojis
   int               m_expiryBars;       // candles expire after N bars of their TF

   bool              CandleAlreadyStored(const CandleData &cd);

public:
                     CWickFilter();
                    ~CWickFilter();

   void              Init(ENUM_TIMEFRAMES &tfs[], double wickThreshold,
                          int lookback, int maxCandles, double minRange, int expiryBars);
   void              ScanAllTimeframes(string symbol);
   void              ScanTimeframe(string symbol, ENUM_TIMEFRAMES tf);
   bool              PassesWickFilter(const MqlRates &rate);

   int               GetStoredCount()              { return ArraySize(m_storedCandles); }
   WickCandle       *GetStoredCandleRef(int index);
   void              GetStoredCandle(int index, WickCandle &out);
   void              RemoveByIndex(int index);
   void              PurgeExpired(datetime currentTime);
   void              PurgeTriggered();
   void              RemoveUnmatched();
};

//+------------------------------------------------------------------+
CWickFilter::CWickFilter()
{
   m_maxStoredCandles = 20;
   m_wickThreshold    = 0.5;
   m_lookbackBars     = 50;
   m_minCandleRange   = 10;
   m_expiryBars       = 100;
}

//+------------------------------------------------------------------+
CWickFilter::~CWickFilter()
{
   ArrayFree(m_storedCandles);
   ArrayFree(m_timeframes);
}

//+------------------------------------------------------------------+
void CWickFilter::Init(ENUM_TIMEFRAMES &tfs[], double wickThreshold,
                        int lookback, int maxCandles, double minRange, int expiryBars)
{
   ArrayResize(m_timeframes, ArraySize(tfs));
   ArrayCopy(m_timeframes, tfs);
   m_wickThreshold    = wickThreshold;
   m_lookbackBars     = lookback;
   m_maxStoredCandles = maxCandles;
   m_minCandleRange   = minRange;
   m_expiryBars       = expiryBars;
}

//+------------------------------------------------------------------+
//| Check if a candle (by time+tf) is already stored                 |
//+------------------------------------------------------------------+
bool CWickFilter::CandleAlreadyStored(const CandleData &cd)
{
   int count = ArraySize(m_storedCandles);
   for(int i = 0; i < count; i++)
   {
      if(m_storedCandles[i].candle.time == cd.time &&
         m_storedCandles[i].candle.timeframe == cd.timeframe)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Scan all configured timeframes                                   |
//+------------------------------------------------------------------+
void CWickFilter::ScanAllTimeframes(string symbol)
{
   int tfCount = ArraySize(m_timeframes);
   for(int i = 0; i < tfCount; i++)
   {
      ScanTimeframe(symbol, m_timeframes[i]);
   }
}

//+------------------------------------------------------------------+
//| Scan a single timeframe for wick candles                         |
//+------------------------------------------------------------------+
void CWickFilter::ScanTimeframe(string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(symbol, tf, 1, m_lookbackBars, rates);
   if(copied <= 0)
   {
      LogError("CopyRates failed for " + EnumToString(tf));
      return;
   }

   for(int i = 0; i < copied; i++)
   {
      if(!PassesWickFilter(rates[i]))
         continue;

      CandleData cd = RatesToCandleData(rates[i], tf);

      if(CandleAlreadyStored(cd))
         continue;

      // Check storage limit
      if(ArraySize(m_storedCandles) >= m_maxStoredCandles)
      {
         LogDebug("Max stored candles reached, skipping");
         return;
      }

      // Build WickCandle
      WickCandle wc;
      wc.candle = cd;
      wc.hasZone = false;
      wc.state   = ENTRY_PENDING;

      // Trigger price is at the tip of the dominant wick
      // For bullish wick candle (long lower wick) -> trigger = lower wick area
      // For bearish wick candle (long upper wick) -> trigger = upper wick area
      if(cd.lowerWick > cd.upperWick)
      {
         // Dominant lower wick -> bullish signal
         // Trigger when price comes back down to the wick zone
         wc.wickTriggerPrice = cd.low + (cd.lowerWick * 0.5);
      }
      else
      {
         // Dominant upper wick -> bearish signal
         // Trigger when price comes back up to the wick zone
         wc.wickTriggerPrice = cd.high - (cd.upperWick * 0.5);
      }

      // Set expiry
      wc.expiryTime = cd.time + PeriodSeconds(tf) * m_expiryBars;

      int size = ArraySize(m_storedCandles);
      ArrayResize(m_storedCandles, size + 1);
      m_storedCandles[size] = wc;

      LogDebug("Stored wick candle: TF=" + EnumToString(tf) +
               " Time=" + TimeToString(cd.time) +
               " WickRatio=" + DoubleToString(cd.wickRatio, 2) +
               " Trigger=" + DoubleToString(wc.wickTriggerPrice, _Digits));
   }
}

//+------------------------------------------------------------------+
//| Check if candle passes the wick filter                           |
//+------------------------------------------------------------------+
bool CWickFilter::PassesWickFilter(const MqlRates &rate)
{
   double totalRange = rate.high - rate.low;

   // Filter out dojis / tiny candles
   if(totalRange < m_minCandleRange * _Point)
      return false;

   double body, upperWick, lowerWick;

   if(rate.close >= rate.open)
   {
      body      = rate.close - rate.open;
      upperWick = rate.high - rate.close;
      lowerWick = rate.open - rate.low;
   }
   else
   {
      body      = rate.open - rate.close;
      upperWick = rate.high - rate.open;
      lowerWick = rate.close - rate.low;
   }

   double maxWick = MathMax(upperWick, lowerWick);
   double wickRatio = maxWick / totalRange;

   return (wickRatio >= m_wickThreshold);
}

//+------------------------------------------------------------------+
//| Get reference to stored candle (for modification)                |
//+------------------------------------------------------------------+
WickCandle *CWickFilter::GetStoredCandleRef(int index)
{
   if(index < 0 || index >= ArraySize(m_storedCandles))
      return NULL;
   return &m_storedCandles[index];
}

//+------------------------------------------------------------------+
//| Get copy of stored candle                                        |
//+------------------------------------------------------------------+
void CWickFilter::GetStoredCandle(int index, WickCandle &out)
{
   if(index >= 0 && index < ArraySize(m_storedCandles))
      out = m_storedCandles[index];
}

//+------------------------------------------------------------------+
//| Remove candle at index                                           |
//+------------------------------------------------------------------+
void CWickFilter::RemoveByIndex(int index)
{
   int size = ArraySize(m_storedCandles);
   if(index < 0 || index >= size)
      return;

   for(int i = index; i < size - 1; i++)
      m_storedCandles[i] = m_storedCandles[i + 1];

   ArrayResize(m_storedCandles, size - 1);
}

//+------------------------------------------------------------------+
//| Remove candles past their expiry                                 |
//+------------------------------------------------------------------+
void CWickFilter::PurgeExpired(datetime currentTime)
{
   for(int i = ArraySize(m_storedCandles) - 1; i >= 0; i--)
   {
      if(m_storedCandles[i].expiryTime < currentTime)
      {
         LogDebug("Purging expired wick candle: " +
                  TimeToString(m_storedCandles[i].candle.time));
         RemoveByIndex(i);
      }
   }
}

//+------------------------------------------------------------------+
//| Remove triggered candles                                         |
//+------------------------------------------------------------------+
void CWickFilter::PurgeTriggered()
{
   for(int i = ArraySize(m_storedCandles) - 1; i >= 0; i--)
   {
      if(m_storedCandles[i].state == ENTRY_TRIGGERED)
         RemoveByIndex(i);
   }
}

//+------------------------------------------------------------------+
//| Remove candles that have no zone match                           |
//+------------------------------------------------------------------+
void CWickFilter::RemoveUnmatched()
{
   for(int i = ArraySize(m_storedCandles) - 1; i >= 0; i--)
   {
      if(!m_storedCandles[i].hasZone)
         RemoveByIndex(i);
   }
}

#endif
