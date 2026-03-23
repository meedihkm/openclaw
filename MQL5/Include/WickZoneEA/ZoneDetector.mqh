//+------------------------------------------------------------------+
//|                                                ZoneDetector.mqh  |
//|                   WickZone EA - OB / FVG / P-D Zone Detection    |
//+------------------------------------------------------------------+
#ifndef WICKZONE_ZONEDETECTOR_MQH
#define WICKZONE_ZONEDETECTOR_MQH

#include "Utils.mqh"

//+------------------------------------------------------------------+
//| Zone Detector Class                                              |
//+------------------------------------------------------------------+
class CZoneDetector
{
private:
   ZoneInfo          m_zones[];
   int               m_maxZones;
   int               m_obLookback;
   int               m_fvgLookback;
   double            m_zoneTolerance;    // points
   double            m_atrMultiplier;    // for OB impulse detection
   int               m_atrPeriod;
   int               m_swingLookback;    // for premium/discount

   bool              ZoneAlreadyExists(ENUM_ZONE_TYPE type, double upper, double lower, ENUM_TIMEFRAMES tf);
   void              AddZone(const ZoneInfo &zone);
   double            GetATR(string symbol, ENUM_TIMEFRAMES tf, int period, int shift);

public:
                     CZoneDetector();
                    ~CZoneDetector();

   void              Init(int obLookback, int fvgLookback, double tolerance,
                          int maxZones, double atrMult, int atrPeriod, int swingLookback);
   void              DetectAllZones(string symbol, ENUM_TIMEFRAMES tf);
   void              DetectOrderBlocks(string symbol, ENUM_TIMEFRAMES tf);
   void              DetectFVG(string symbol, ENUM_TIMEFRAMES tf);
   void              DetectPremiumDiscount(string symbol, ENUM_TIMEFRAMES tf);

   bool              IsNearAnyZone(double price, ZoneInfo &matchedZone);
   bool              IsNearBullishZone(double price, ZoneInfo &matchedZone);
   bool              IsNearBearishZone(double price, ZoneInfo &matchedZone);

   void              InvalidateZone(int index);
   void              PurgeMitigated(string symbol, ENUM_TIMEFRAMES tf);
   int               GetZoneCount()      { return ArraySize(m_zones); }
   void              GetZone(int index, ZoneInfo &out);
};

//+------------------------------------------------------------------+
CZoneDetector::CZoneDetector()
{
   m_maxZones      = 50;
   m_obLookback    = 30;
   m_fvgLookback   = 30;
   m_zoneTolerance = 20;
   m_atrMultiplier = 1.5;
   m_atrPeriod     = 14;
   m_swingLookback = 50;
}

//+------------------------------------------------------------------+
CZoneDetector::~CZoneDetector()
{
   ArrayFree(m_zones);
}

//+------------------------------------------------------------------+
void CZoneDetector::Init(int obLookback, int fvgLookback, double tolerance,
                          int maxZones, double atrMult, int atrPeriod, int swingLookback)
{
   m_obLookback    = obLookback;
   m_fvgLookback   = fvgLookback;
   m_zoneTolerance = tolerance;
   m_maxZones      = maxZones;
   m_atrMultiplier = atrMult;
   m_atrPeriod     = atrPeriod;
   m_swingLookback = swingLookback;
}

//+------------------------------------------------------------------+
//| Check if a similar zone already exists                           |
//+------------------------------------------------------------------+
bool CZoneDetector::ZoneAlreadyExists(ENUM_ZONE_TYPE type, double upper, double lower, ENUM_TIMEFRAMES tf)
{
   double tol = m_zoneTolerance * _Point;
   int count = ArraySize(m_zones);
   for(int i = 0; i < count; i++)
   {
      if(!m_zones[i].isValid) continue;
      if(m_zones[i].type != type) continue;
      if(m_zones[i].originTF != tf) continue;
      if(MathAbs(m_zones[i].upper - upper) < tol && MathAbs(m_zones[i].lower - lower) < tol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Add zone to array                                                |
//+------------------------------------------------------------------+
void CZoneDetector::AddZone(const ZoneInfo &zone)
{
   // Remove invalid zones first to make room
   for(int i = ArraySize(m_zones) - 1; i >= 0; i--)
   {
      if(!m_zones[i].isValid)
      {
         // Replace invalid zone
         m_zones[i] = zone;
         return;
      }
   }

   if(ArraySize(m_zones) >= m_maxZones)
   {
      // Remove oldest zone
      for(int i = 0; i < ArraySize(m_zones) - 1; i++)
         m_zones[i] = m_zones[i + 1];
      ArrayResize(m_zones, m_maxZones);
      m_zones[m_maxZones - 1] = zone;
      return;
   }

   int size = ArraySize(m_zones);
   ArrayResize(m_zones, size + 1);
   m_zones[size] = zone;
}

//+------------------------------------------------------------------+
//| Get ATR value                                                    |
//+------------------------------------------------------------------+
double CZoneDetector::GetATR(string symbol, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int handle = iATR(symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return 0;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, shift, 1, atr) <= 0)
   {
      IndicatorRelease(handle);
      return 0;
   }

   IndicatorRelease(handle);
   return atr[0];
}

//+------------------------------------------------------------------+
//| Detect all zone types on a timeframe                             |
//+------------------------------------------------------------------+
void CZoneDetector::DetectAllZones(string symbol, ENUM_TIMEFRAMES tf)
{
   DetectOrderBlocks(symbol, tf);
   DetectFVG(symbol, tf);
   DetectPremiumDiscount(symbol, tf);
}

//+------------------------------------------------------------------+
//| Detect Order Blocks                                              |
//| OB = last opposing candle before an impulsive move (body > ATR)  |
//+------------------------------------------------------------------+
void CZoneDetector::DetectOrderBlocks(string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 1, m_obLookback + 2, rates);
   if(copied < 3) return;

   for(int i = 0; i < copied - 1; i++)
   {
      double atr = GetATR(symbol, tf, m_atrPeriod, i + 1);
      if(atr <= 0) continue;

      double impBody = MathAbs(rates[i].close - rates[i].open);

      // Impulsive candle check
      if(impBody < atr * m_atrMultiplier)
         continue;

      // The OB is the candle before the impulse (i+1)
      MqlRates obCandle = rates[i + 1];

      // Bullish impulse (close > open) -> Bullish OB (the bearish candle before)
      if(rates[i].close > rates[i].open)
      {
         // OB zone = body of the preceding candle
         double obUpper = MathMax(obCandle.open, obCandle.close);
         double obLower = obCandle.low;

         if(!ZoneAlreadyExists(ZONE_OB_BULLISH, obUpper, obLower, tf))
         {
            ZoneInfo zone;
            zone.type       = ZONE_OB_BULLISH;
            zone.upper      = obUpper;
            zone.lower      = obLower;
            zone.originTF   = tf;
            zone.originTime = obCandle.time;
            zone.isValid    = true;
            AddZone(zone);

            LogDebug("Bullish OB detected: " + DoubleToString(obLower, _Digits) +
                     " - " + DoubleToString(obUpper, _Digits) +
                     " TF=" + EnumToString(tf));
         }
      }
      // Bearish impulse (close < open) -> Bearish OB
      else if(rates[i].close < rates[i].open)
      {
         double obUpper = obCandle.high;
         double obLower = MathMin(obCandle.open, obCandle.close);

         if(!ZoneAlreadyExists(ZONE_OB_BEARISH, obUpper, obLower, tf))
         {
            ZoneInfo zone;
            zone.type       = ZONE_OB_BEARISH;
            zone.upper      = obUpper;
            zone.lower      = obLower;
            zone.originTF   = tf;
            zone.originTime = obCandle.time;
            zone.isValid    = true;
            AddZone(zone);

            LogDebug("Bearish OB detected: " + DoubleToString(obLower, _Digits) +
                     " - " + DoubleToString(obUpper, _Digits) +
                     " TF=" + EnumToString(tf));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect Fair Value Gaps (3-candle pattern)                        |
//+------------------------------------------------------------------+
void CZoneDetector::DetectFVG(string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 1, m_fvgLookback + 2, rates);
   if(copied < 3) return;

   for(int i = 0; i < copied - 2; i++)
   {
      // Bullish FVG: gap between candle[i] low and candle[i+2] high
      // rates[i] = most recent of the 3, rates[i+2] = oldest
      if(rates[i].low > rates[i + 2].high)
      {
         double fvgUpper = rates[i].low;
         double fvgLower = rates[i + 2].high;

         if(!ZoneAlreadyExists(ZONE_FVG_BULLISH, fvgUpper, fvgLower, tf))
         {
            ZoneInfo zone;
            zone.type       = ZONE_FVG_BULLISH;
            zone.upper      = fvgUpper;
            zone.lower      = fvgLower;
            zone.originTF   = tf;
            zone.originTime = rates[i + 1].time;
            zone.isValid    = true;
            AddZone(zone);

            LogDebug("Bullish FVG detected: " + DoubleToString(fvgLower, _Digits) +
                     " - " + DoubleToString(fvgUpper, _Digits));
         }
      }

      // Bearish FVG: gap between candle[i+2] low and candle[i] high
      if(rates[i + 2].low > rates[i].high)
      {
         double fvgUpper = rates[i + 2].low;
         double fvgLower = rates[i].high;

         if(!ZoneAlreadyExists(ZONE_FVG_BEARISH, fvgUpper, fvgLower, tf))
         {
            ZoneInfo zone;
            zone.type       = ZONE_FVG_BEARISH;
            zone.upper      = fvgUpper;
            zone.lower      = fvgLower;
            zone.originTF   = tf;
            zone.originTime = rates[i + 1].time;
            zone.isValid    = true;
            AddZone(zone);

            LogDebug("Bearish FVG detected: " + DoubleToString(fvgLower, _Digits) +
                     " - " + DoubleToString(fvgUpper, _Digits));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect Premium / Discount zones                                  |
//| Above 50% of swing range = Premium, Below = Discount             |
//+------------------------------------------------------------------+
void CZoneDetector::DetectPremiumDiscount(string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, m_swingLookback, rates);
   if(copied < 10) return;

   // Find swing high and swing low
   double swingHigh = rates[0].high;
   double swingLow  = rates[0].low;

   for(int i = 1; i < copied; i++)
   {
      if(rates[i].high > swingHigh) swingHigh = rates[i].high;
      if(rates[i].low  < swingLow)  swingLow  = rates[i].low;
   }

   double range = swingHigh - swingLow;
   if(range <= 0) return;

   double equilibrium = swingLow + range * 0.5;

   // Premium zone (above equilibrium)
   if(!ZoneAlreadyExists(ZONE_PREMIUM, swingHigh, equilibrium, tf))
   {
      // Remove old premium/discount for this TF first
      for(int i = ArraySize(m_zones) - 1; i >= 0; i--)
      {
         if(m_zones[i].isValid && m_zones[i].originTF == tf &&
            (m_zones[i].type == ZONE_PREMIUM || m_zones[i].type == ZONE_DISCOUNT))
            m_zones[i].isValid = false;
      }

      ZoneInfo prem;
      prem.type       = ZONE_PREMIUM;
      prem.upper      = swingHigh;
      prem.lower      = equilibrium;
      prem.originTF   = tf;
      prem.originTime = TimeCurrent();
      prem.isValid    = true;
      AddZone(prem);

      ZoneInfo disc;
      disc.type       = ZONE_DISCOUNT;
      disc.upper      = equilibrium;
      disc.lower      = swingLow;
      disc.originTF   = tf;
      disc.originTime = TimeCurrent();
      disc.isValid    = true;
      AddZone(disc);
   }
}

//+------------------------------------------------------------------+
//| Check if price is near any active zone                           |
//+------------------------------------------------------------------+
bool CZoneDetector::IsNearAnyZone(double price, ZoneInfo &matchedZone)
{
   int count = ArraySize(m_zones);
   for(int i = 0; i < count; i++)
   {
      if(!m_zones[i].isValid) continue;
      if(IsNearZone(price, m_zones[i], m_zoneTolerance))
      {
         matchedZone = m_zones[i];
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check near bullish zones (OB bullish, FVG bullish, discount)     |
//+------------------------------------------------------------------+
bool CZoneDetector::IsNearBullishZone(double price, ZoneInfo &matchedZone)
{
   int count = ArraySize(m_zones);
   for(int i = 0; i < count; i++)
   {
      if(!m_zones[i].isValid) continue;
      if(m_zones[i].type != ZONE_OB_BULLISH &&
         m_zones[i].type != ZONE_FVG_BULLISH &&
         m_zones[i].type != ZONE_DISCOUNT)
         continue;
      if(IsNearZone(price, m_zones[i], m_zoneTolerance))
      {
         matchedZone = m_zones[i];
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check near bearish zones (OB bearish, FVG bearish, premium)      |
//+------------------------------------------------------------------+
bool CZoneDetector::IsNearBearishZone(double price, ZoneInfo &matchedZone)
{
   int count = ArraySize(m_zones);
   for(int i = 0; i < count; i++)
   {
      if(!m_zones[i].isValid) continue;
      if(m_zones[i].type != ZONE_OB_BEARISH &&
         m_zones[i].type != ZONE_FVG_BEARISH &&
         m_zones[i].type != ZONE_PREMIUM)
         continue;
      if(IsNearZone(price, m_zones[i], m_zoneTolerance))
      {
         matchedZone = m_zones[i];
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Invalidate zone by index                                         |
//+------------------------------------------------------------------+
void CZoneDetector::InvalidateZone(int index)
{
   if(index >= 0 && index < ArraySize(m_zones))
      m_zones[index].isValid = false;
}

//+------------------------------------------------------------------+
//| Remove zones that price has closed through (mitigated)           |
//+------------------------------------------------------------------+
void CZoneDetector::PurgeMitigated(string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, tf, 0, 1, rates) <= 0) return;

   double closePrice = rates[0].close;

   for(int i = ArraySize(m_zones) - 1; i >= 0; i--)
   {
      if(!m_zones[i].isValid) continue;

      // Skip premium/discount - these are dynamic ranges, not single-use
      if(m_zones[i].type == ZONE_PREMIUM || m_zones[i].type == ZONE_DISCOUNT)
         continue;

      // Bullish zones mitigated when price closes below zone lower
      if((m_zones[i].type == ZONE_OB_BULLISH || m_zones[i].type == ZONE_FVG_BULLISH) &&
         closePrice < m_zones[i].lower)
      {
         LogDebug("Zone mitigated: " + ZoneTypeToString(m_zones[i].type));
         m_zones[i].isValid = false;
      }

      // Bearish zones mitigated when price closes above zone upper
      if((m_zones[i].type == ZONE_OB_BEARISH || m_zones[i].type == ZONE_FVG_BEARISH) &&
         closePrice > m_zones[i].upper)
      {
         LogDebug("Zone mitigated: " + ZoneTypeToString(m_zones[i].type));
         m_zones[i].isValid = false;
      }
   }
}

//+------------------------------------------------------------------+
//| Get zone by index                                                |
//+------------------------------------------------------------------+
void CZoneDetector::GetZone(int index, ZoneInfo &out)
{
   if(index >= 0 && index < ArraySize(m_zones))
      out = m_zones[index];
}

#endif
