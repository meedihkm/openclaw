//+------------------------------------------------------------------+
//|                                                       Utils.mqh  |
//|                        WickZone EA - Shared Utilities            |
//+------------------------------------------------------------------+
#ifndef WICKZONE_UTILS_MQH
#define WICKZONE_UTILS_MQH

//--- Enumerations
enum ENUM_ZONE_TYPE
{
   ZONE_OB_BULLISH,
   ZONE_OB_BEARISH,
   ZONE_FVG_BULLISH,
   ZONE_FVG_BEARISH,
   ZONE_PREMIUM,
   ZONE_DISCOUNT
};

enum ENUM_CANDLE_DIR
{
   CANDLE_BULL,
   CANDLE_BEAR
};

enum ENUM_ENTRY_STATE
{
   ENTRY_PENDING,
   ENTRY_TRIGGERED,
   ENTRY_EXPIRED
};

//--- Structures
struct CandleData
{
   datetime          time;
   ENUM_TIMEFRAMES   timeframe;
   double            open;
   double            high;
   double            low;
   double            close;
   double            totalRange;
   double            upperWick;
   double            lowerWick;
   double            body;
   double            wickRatio;
   ENUM_CANDLE_DIR   direction;
};

struct ZoneInfo
{
   ENUM_ZONE_TYPE    type;
   double            upper;
   double            lower;
   ENUM_TIMEFRAMES   originTF;
   datetime          originTime;
   bool              isValid;
};

struct WickCandle
{
   CandleData        candle;
   ZoneInfo          zone;
   bool              hasZone;
   ENUM_ENTRY_STATE  state;
   double            wickTriggerPrice;  // price level where entry triggers
   datetime          expiryTime;
};

//+------------------------------------------------------------------+
//| Build CandleData from MqlRates                                   |
//+------------------------------------------------------------------+
CandleData RatesToCandleData(const MqlRates &rate, ENUM_TIMEFRAMES tf)
{
   CandleData cd;
   cd.time      = rate.time;
   cd.timeframe = tf;
   cd.open      = rate.open;
   cd.high      = rate.high;
   cd.low       = rate.low;
   cd.close     = rate.close;
   cd.totalRange = rate.high - rate.low;

   if(rate.close >= rate.open)
   {
      cd.direction  = CANDLE_BULL;
      cd.body       = rate.close - rate.open;
      cd.upperWick  = rate.high - rate.close;
      cd.lowerWick  = rate.open - rate.low;
   }
   else
   {
      cd.direction  = CANDLE_BEAR;
      cd.body       = rate.open - rate.close;
      cd.upperWick  = rate.high - rate.open;
      cd.lowerWick  = rate.close - rate.low;
   }

   cd.wickRatio = (cd.totalRange > 0) ? MathMax(cd.upperWick, cd.lowerWick) / cd.totalRange : 0;
   return cd;
}

//+------------------------------------------------------------------+
//| Calculate wick ratio (max wick / total range)                    |
//+------------------------------------------------------------------+
double CalcWickRatio(const CandleData &candle)
{
   if(candle.totalRange <= 0) return 0;
   return MathMax(candle.upperWick, candle.lowerWick) / candle.totalRange;
}

//+------------------------------------------------------------------+
//| Check if price is near a zone                                    |
//+------------------------------------------------------------------+
bool IsNearZone(double price, const ZoneInfo &zone, double tolerancePoints)
{
   if(!zone.isValid) return false;
   double tolerance = tolerancePoints * _Point;
   return (price >= zone.lower - tolerance && price <= zone.upper + tolerance);
}

//+------------------------------------------------------------------+
//| Get candle direction                                             |
//+------------------------------------------------------------------+
ENUM_CANDLE_DIR GetCandleDirection(double open, double close)
{
   return (close >= open) ? CANDLE_BULL : CANDLE_BEAR;
}

//+------------------------------------------------------------------+
//| Convert pips to price                                            |
//+------------------------------------------------------------------+
double PipsToPrice(double pips, string symbol)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      return pips * point * 10;
   return pips * point;
}

//+------------------------------------------------------------------+
//| Logging helpers                                                  |
//+------------------------------------------------------------------+
void LogInfo(string msg)
{
   Print("[WickZoneEA] INFO: ", msg);
}

void LogError(string msg)
{
   Print("[WickZoneEA] ERROR: ", msg);
}

void LogDebug(string msg)
{
#ifdef DEBUG_MODE
   Print("[WickZoneEA] DEBUG: ", msg);
#endif
}

//+------------------------------------------------------------------+
//| Get zone type as string                                          |
//+------------------------------------------------------------------+
string ZoneTypeToString(ENUM_ZONE_TYPE type)
{
   switch(type)
   {
      case ZONE_OB_BULLISH:  return "Bullish OB";
      case ZONE_OB_BEARISH:  return "Bearish OB";
      case ZONE_FVG_BULLISH: return "Bullish FVG";
      case ZONE_FVG_BEARISH: return "Bearish FVG";
      case ZONE_PREMIUM:     return "Premium";
      case ZONE_DISCOUNT:    return "Discount";
   }
   return "Unknown";
}

#endif
