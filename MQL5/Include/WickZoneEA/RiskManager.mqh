//+------------------------------------------------------------------+
//|                                                RiskManager.mqh   |
//|                    WickZone EA - SL, BE, Trailing Stop           |
//+------------------------------------------------------------------+
#ifndef WICKZONE_RISKMANAGER_MQH
#define WICKZONE_RISKMANAGER_MQH

#include "Utils.mqh"
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Risk Manager Class                                               |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
   double            m_beActivationPoints;
   double            m_beLockPoints;
   double            m_tsActivationPoints;
   double            m_tsStepPoints;
   double            m_riskPercent;
   double            m_slBufferPoints;

   CTrade            m_trade;
   CPositionInfo     m_posInfo;

   bool              IsBreakevenActive(double entryPrice, double currentSL, ENUM_POSITION_TYPE type);

public:
                     CRiskManager();
                    ~CRiskManager();

   void              Init(double beActivation, double beLock,
                          double tsActivation, double tsStep,
                          double riskPct, double slBuffer, int magic);

   double            CalcStopLoss(ENUM_ORDER_TYPE direction, const ZoneInfo &zone, string symbol);
   double            CalcLotSize(string symbol, double entryPrice, double slPrice);
   void              ManageOpenPositions(string symbol, int magicNumber);

   // Getters for config
   double            GetBEActivation()  { return m_beActivationPoints; }
   double            GetTSActivation()  { return m_tsActivationPoints; }
};

//+------------------------------------------------------------------+
CRiskManager::CRiskManager()
{
   m_beActivationPoints = 200;
   m_beLockPoints       = 10;
   m_tsActivationPoints = 300;
   m_tsStepPoints       = 50;
   m_riskPercent        = 1.0;
   m_slBufferPoints     = 10;
}

//+------------------------------------------------------------------+
CRiskManager::~CRiskManager()
{
}

//+------------------------------------------------------------------+
void CRiskManager::Init(double beActivation, double beLock,
                         double tsActivation, double tsStep,
                         double riskPct, double slBuffer, int magic)
{
   m_beActivationPoints = beActivation;
   m_beLockPoints       = beLock;
   m_tsActivationPoints = tsActivation;
   m_tsStepPoints       = tsStep;
   m_riskPercent        = riskPct;
   m_slBufferPoints     = slBuffer;
   m_trade.SetExpertMagicNumber(magic);
}

//+------------------------------------------------------------------+
//| Calculate SL based on zone boundaries                            |
//+------------------------------------------------------------------+
double CRiskManager::CalcStopLoss(ENUM_ORDER_TYPE direction, const ZoneInfo &zone, string symbol)
{
   double buffer = m_slBufferPoints * SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minStopLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                         SymbolInfoDouble(symbol, SYMBOL_POINT);

   double sl = 0;

   if(direction == ORDER_TYPE_BUY)
   {
      // SL below the zone lower boundary
      sl = zone.lower - buffer;

      // Ensure minimum stop distance
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(bid - sl < minStopLevel && minStopLevel > 0)
         sl = bid - minStopLevel - buffer;
   }
   else if(direction == ORDER_TYPE_SELL)
   {
      // SL above the zone upper boundary
      sl = zone.upper + buffer;

      // Ensure minimum stop distance
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(sl - ask < minStopLevel && minStopLevel > 0)
         sl = ask + minStopLevel + buffer;
   }

   return NormalizeDouble(sl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                      |
//+------------------------------------------------------------------+
double CRiskManager::CalcLotSize(string symbol, double entryPrice, double slPrice)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * m_riskPercent / 100.0;

   double slDistance = MathAbs(entryPrice - slPrice);
   if(slDistance <= 0)
   {
      LogError("SL distance is zero, using minimum lot");
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   }

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
   {
      LogError("Invalid tick value/size");
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   }

   double slTicks = slDistance / tickSize;
   double lots = riskAmount / (slTicks * tickValue);

   // Clamp to broker limits
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   // Round to lot step
   lots = MathFloor(lots / lotStep) * lotStep;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Check if BE was already activated (SL moved past entry)          |
//+------------------------------------------------------------------+
bool CRiskManager::IsBreakevenActive(double entryPrice, double currentSL, ENUM_POSITION_TYPE type)
{
   if(type == POSITION_TYPE_BUY)
      return (currentSL >= entryPrice);
   else
      return (currentSL <= entryPrice && currentSL > 0);
}

//+------------------------------------------------------------------+
//| Manage all open positions: BE + Trailing Stop                    |
//+------------------------------------------------------------------+
void CRiskManager::ManageOpenPositions(string symbol, int magicNumber)
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);

      double profitPoints = 0;
      double currentPrice = 0;

      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = bid;
         profitPoints = (bid - entryPrice) / point;
      }
      else
      {
         currentPrice = ask;
         profitPoints = (entryPrice - ask) / point;
      }

      // Skip if not in profit
      if(profitPoints <= 0) continue;

      double newSL = currentSL;
      bool   modifySL = false;

      //--- Break Even Logic
      if(profitPoints >= m_beActivationPoints && !IsBreakevenActive(entryPrice, currentSL, posType))
      {
         if(posType == POSITION_TYPE_BUY)
            newSL = entryPrice + m_beLockPoints * point;
         else
            newSL = entryPrice - m_beLockPoints * point;

         modifySL = true;
         LogInfo("BE activated for ticket #" + IntegerToString((int)ticket) +
                 " Entry=" + DoubleToString(entryPrice, _Digits) +
                 " NewSL=" + DoubleToString(newSL, _Digits));
      }

      //--- Trailing Stop Logic
      if(profitPoints >= m_tsActivationPoints)
      {
         double trailSL = 0;

         if(posType == POSITION_TYPE_BUY)
         {
            trailSL = currentPrice - m_tsStepPoints * point;
            if(trailSL > currentSL && trailSL > entryPrice)
            {
               newSL = trailSL;
               modifySL = true;
            }
         }
         else
         {
            trailSL = currentPrice + m_tsStepPoints * point;
            if((trailSL < currentSL || currentSL == 0) && trailSL < entryPrice)
            {
               newSL = trailSL;
               modifySL = true;
            }
         }
      }

      //--- Apply modification
      if(modifySL)
      {
         newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));

         // Only modify if SL actually changed
         if(MathAbs(newSL - currentSL) > point)
         {
            if(!m_trade.PositionModify(ticket, newSL, currentTP))
            {
               LogError("Failed to modify position #" + IntegerToString((int)ticket) +
                        " Error=" + IntegerToString(GetLastError()));
            }
         }
      }
   }
}

#endif
