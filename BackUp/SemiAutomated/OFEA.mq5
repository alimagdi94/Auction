//+------------------------------------------------------------------+
//|                                                    NAS100_EA.mq5 |
//|   Autonomous Inside-Bar Breakout EA — NASDAQ Optimised          |
//|   Architecture: Brain · Muscle · Shield · Math                  |
//|   Signal: Inside Bar + EMA Trend Filter + ATR Sizing            |
//+------------------------------------------------------------------+
#property copyright   "Ali Magdy"
#property version     "1.00"
#property description "NAS100 Inside-Bar breakout EA — autonomous execution"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

input group "═══ A. Pattern Logic ═══"
input int    PoleLength         = 5;       // Trend-pole lookback (bars) for inside bar context
input double MinMotherBarATR    = 0.8;     // Mother bar must be >= this × ATR (filters tiny bars)
input double MaxMotherBarATR    = 3.5;     // Mother bar must be <= this × ATR (filters gap bars)
input bool   RequireCleanBreak  = true;    // Entry bar must close beyond the mother bar (optional)

input group "═══ B. Strategy Context ═══"
input int    EMA_Fast           = 50;      // Fast EMA period (trend direction)
input int    EMA_Slow           = 200;     // Slow EMA period (trend filter)
input int    ATR_Period         = 14;      // ATR period for volatility normalisation
input bool   SpreadFilter       = true;    // Block trades when spread is too wide
input double MaxSpread          = 20.0;    // Max allowable spread in points (NAS100: ~15 typical)
input bool   AllowBuy           = true;    // Allow long trades
input bool   AllowSell          = true;    // Allow short trades
input double BufferPoints       = 8.0;     // Entry stop order offset above/below mother bar (points)

input group "═══ C. Money Management ═══"
input bool   UseRiskPercent     = true;    // true = dynamic risk; false = fixed lot
input double RiskPercent        = 1.0;     // % of account balance to risk per trade
input double FixedLot           = 0.10;    // Fixed lot size (used when UseRiskPercent = false)

input group "═══ D. Trade Exit ═══"
input bool   UseStopLoss        = true;    // Hard stop loss
input bool   UseTakeProfit      = true;    // Hard take profit
input double RiskRewardRatio    = 2.0;     // TP = SL × RR
input double SL_ATR_Mult        = 1.5;     // Stop loss = this × ATR beyond mother bar extreme

input group "═══ E. Position Guardian ═══"
input bool   UseBreakEven       = true;    // Auto-move SL to break-even
input double BreakEvenTrigger   = 1.0;     // Pips profit to trigger break-even (× ATR)
input double BreakEvenBuffer    = 5.0;     // Extra points locked in above entry (covers spread)
input bool   UseTrailing        = true;    // Dynamic trailing stop
input double TrailStart         = 1.2;     // Profit (× ATR) before trailing begins
input double TrailStep          = 0.35;    // Trailing heartbeat distance (× ATR)

input group "═══ F. Account Safety ═══"
input double MaxEquityProfit    = 0.0;     // Stop trading when account profit reaches this (0 = off)
input double MaxEquityLoss      = 0.0;     // Kill EA when account loss reaches this (0 = off)
input bool   CleanOldOrders     = true;    // Delete pending orders when new signal fires (OCO)

input group "═══ G. EA Identity ═══"
input ulong  Magic              = 20260226; // Unique magic number

//+------------------------------------------------------------------+
//| GLOBAL STATE (Memory Layer — cached to avoid per-tick API cost)  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     ordInfo;

datetime g_LastBarTime  = 0;      // New-bar detection
int      g_HandleATR    = INVALID_HANDLE;
int      g_HandleEMA_F  = INVALID_HANDLE;
int      g_HandleEMA_S  = INVALID_HANDLE;

double   g_Pip          = 0.0;    // Standardised pip size (auto-detected)
double   g_VolMin       = 0.01;
double   g_VolMax       = 100.0;
double   g_VolStep      = 0.01;
double   g_TickSize     = 0.0;    // Tick value in deposit currency
double   g_TickValue    = 0.0;
double   g_StopsLevel   = 0.0;    // Broker minimum stop distance (points)

double   g_BalanceAtStart = 0.0;  // Captured at OnInit for equity-stop math

//+------------------------------------------------------------------+
//| Signal descriptor — output of the Brain, consumed by Muscle     |
//+------------------------------------------------------------------+
struct TradeSetup
  {
   bool   valid;
   int    direction;   // ORDER_TYPE_BUY_STOP or ORDER_TYPE_SELL_STOP
   double entryPrice;
   double slPrice;
   double tpPrice;
   double lotSize;
  };

//+------------------------------------------------------------------+
//| INITIALISATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // ── Cache broker/symbol constants ─────────────────────────────
   RefreshSymbolInfo();

   if(g_VolStep <= 0 || g_TickSize <= 0)
     {
      Alert("NAS100 EA: Symbol info invalid — check broker connection.");
      return INIT_FAILED;
     }

   // ── Build indicator handles ───────────────────────────────────
   g_HandleATR   = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   g_HandleEMA_F = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_HandleEMA_S = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_HandleATR == INVALID_HANDLE ||
      g_HandleEMA_F == INVALID_HANDLE ||
      g_HandleEMA_S == INVALID_HANDLE)
     {
      Alert("NAS100 EA: Failed to create indicator handles — aborting.");
      return INIT_FAILED;
     }

   g_BalanceAtStart = AccountInfoDouble(ACCOUNT_BALANCE);
   PrintFormat("NAS100 EA v1.00 initialised | Symbol:%s | TF:%s | Magic:%I64u | Balance:%.2f",
               _Symbol, EnumToString(Period()), Magic, g_BalanceAtStart);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| DEINITIALISATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(g_HandleATR);
   IndicatorRelease(g_HandleEMA_F);
   IndicatorRelease(g_HandleEMA_S);
   PrintFormat("NAS100 EA deinitialized. Reason: %d", reason);
  }

//+------------------------------------------------------------------+
//| THE CLOCK — Main tick handler                                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   // ── Always: manage open positions (trailing needs real-time) ──
   ManagePositions();

   // ── New bar check ─────────────────────────────────────────────
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_LastBarTime)
      return;
   g_LastBarTime = currentBarTime;

   // ── New bar actions ───────────────────────────────────────────
   RefreshSymbolInfo();

   if(CleanOldOrders)
      DeleteAllPending();

   PlaceOrders();
  }

//+------------------------------------------------------------------+
//| CACHE REFRESH — fills global state from broker API              |
//+------------------------------------------------------------------+
void RefreshSymbolInfo()
  {
   // Detect 3/5-digit brokers for pip normalisation
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // NAS100 is quoted in points (e.g. 18250.5), so pip = point
   g_Pip       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   g_VolMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_VolMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_VolStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_TickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_TickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_StopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_Pip;
  }

//+------------------------------------------------------------------+
//| THE BRAIN — Signal Detection                                     |
//| Strategy: Inside Bar with EMA trend filter + ATR validation     |
//|                                                                  |
//| An Inside Bar is a bar whose High < previous bar High AND        |
//| Low > previous bar Low. The "mother bar" defines the range.     |
//| We enter on a breakout of the mother bar in the trend direction. |
//+------------------------------------------------------------------+
TradeSetup DetectSignal()
  {
   TradeSetup setup;
   setup.valid = false;

   // Need at least PoleLength+2 bars of confirmed data
   int barsRequired = MathMax(PoleLength + 3, EMA_Slow + 2);
   if(Bars(_Symbol, PERIOD_CURRENT) < barsRequired)
      return setup;

   // ── Pull indicator values ─────────────────────────────────────
   double atr[], emaF[], emaS[];
   if(CopyBuffer(g_HandleATR,   0, 1, 3, atr)  < 3) return setup;
   if(CopyBuffer(g_HandleEMA_F, 0, 1, 1, emaF) < 1) return setup;
   if(CopyBuffer(g_HandleEMA_S, 0, 1, 1, emaS) < 1) return setup;

   double ATR    = atr[1];   // completed bar
   double EMA_F_ = emaF[0];
   double EMA_S_ = emaS[0];

   if(ATR <= 0)
      return setup;

   // ── Spread check ─────────────────────────────────────────────
   if(SpreadFilter)
     {
      double currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_Pip;
      if(currentSpread > MaxSpread * g_Pip)
        {
         // Log only occasionally to avoid spam
         static datetime s_lastSpreadLog = 0;
         if(TimeCurrent() - s_lastSpreadLog > 60)
           {
            PrintFormat("NAS100 EA: Spread %.1f > max %.1f — skipping bar.",
                        currentSpread / g_Pip, MaxSpread);
            s_lastSpreadLog = TimeCurrent();
           }
         return setup;
        }
     }

   // ── Price data: bar[1]=inside candidate, bar[2]=mother bar ──
   double insideHigh  = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double insideLow   = iLow(_Symbol,   PERIOD_CURRENT, 1);
   double motherHigh  = iHigh(_Symbol,  PERIOD_CURRENT, 2);
   double motherLow   = iLow(_Symbol,   PERIOD_CURRENT, 2);
   double motherRange = motherHigh - motherLow;

   // ── Inside Bar pattern test ───────────────────────────────────
   bool isInsideBar = (insideHigh < motherHigh && insideLow > motherLow);
   if(!isInsideBar)
      return setup;

   // ── Mother bar ATR size filter ────────────────────────────────
   if(motherRange < ATR * MinMotherBarATR || motherRange > ATR * MaxMotherBarATR)
      return setup;

   // ── EMA trend filter ─────────────────────────────────────────
   bool bullTrend = (EMA_F_ > EMA_S_);
   bool bearTrend = (EMA_F_ < EMA_S_);

   // ── Equity circuit breakers ──────────────────────────────────
   if(!EquityCheckPassed())
      return setup;

   // ── Determine trade direction ─────────────────────────────────
   double entryBuy  = motherHigh + BufferPoints * g_Pip;
   double entrySell = motherLow  - BufferPoints * g_Pip;
   double slBuy     = motherLow  - SL_ATR_Mult * ATR;
   double slSell    = motherHigh + SL_ATR_Mult * ATR;
   double slDistBuy  = entryBuy  - slBuy;
   double slDistSell = slSell    - entrySell;

   bool doLong  = AllowBuy  && bullTrend && (slDistBuy  > g_StopsLevel);
   bool doShort = AllowSell && bearTrend && (slDistSell > g_StopsLevel);

   // Prefer alignment with trend; if both somehow valid, pick dominant
   if(!doLong && !doShort)
      return setup;

   // ── No existing position/pending in same direction ────────────
   if(doLong  && HasActiveTradeOrOrder(ORDER_TYPE_BUY_STOP))  doLong  = false;
   if(doShort && HasActiveTradeOrOrder(ORDER_TYPE_SELL_STOP)) doShort = false;
   if(!doLong && !doShort)
      return setup;

   // ── Build setup ───────────────────────────────────────────────
   setup.valid     = true;
   if(doLong)
     {
      setup.direction  = ORDER_TYPE_BUY_STOP;
      setup.entryPrice = NormalizeDouble(entryBuy,  _Digits);
      setup.slPrice    = NormalizeDouble(slBuy,     _Digits);
      setup.tpPrice    = UseTakeProfit
                         ? NormalizeDouble(entryBuy + slDistBuy * RiskRewardRatio, _Digits)
                         : 0.0;
      setup.lotSize    = CalcLot(slDistBuy);
     }
   else
     {
      setup.direction  = ORDER_TYPE_SELL_STOP;
      setup.entryPrice = NormalizeDouble(entrySell, _Digits);
      setup.slPrice    = NormalizeDouble(slSell,    _Digits);
      setup.tpPrice    = UseTakeProfit
                         ? NormalizeDouble(entrySell - slDistSell * RiskRewardRatio, _Digits)
                         : 0.0;
      setup.lotSize    = CalcLot(slDistSell);
     }

   return setup;
  }

//+------------------------------------------------------------------+
//| THE MUSCLE — Order Execution                                     |
//+------------------------------------------------------------------+
void PlaceOrders()
  {
   TradeSetup s = DetectSignal();
   if(!s.valid)
      return;

   // Final lot sanity check before sending to server
   if(s.lotSize < g_VolMin || s.lotSize > g_VolMax)
     {
      PrintFormat("NAS100 EA: Lot size %.2f out of broker range [%.2f, %.2f] — skipping.",
                  s.lotSize, g_VolMin, g_VolMax);
      return;
     }

   bool sent = false;
   if(s.direction == ORDER_TYPE_BUY_STOP)
      sent = trade.BuyStop(s.lotSize, s.entryPrice, _Symbol,
                           UseStopLoss ? s.slPrice : 0.0,
                           s.tpPrice, ORDER_TIME_GTC, 0, "NAS100_EA_Long");
   else
      sent = trade.SellStop(s.lotSize, s.entryPrice, _Symbol,
                            UseStopLoss ? s.slPrice : 0.0,
                            s.tpPrice, ORDER_TIME_GTC, 0, "NAS100_EA_Short");

   if(sent)
      PrintFormat("NAS100 EA: %s stop placed | Entry:%.2f SL:%.2f TP:%.2f Lots:%.2f",
                  s.direction == ORDER_TYPE_BUY_STOP ? "BUY" : "SELL",
                  s.entryPrice, s.slPrice, s.tpPrice, s.lotSize);
   else
      PrintFormat("NAS100 EA: Order failed | Error:%d", GetLastError());
  }

//+------------------------------------------------------------------+
//| THE SHIELD — Position Management (runs every tick)              |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   // Pull current ATR for dynamic stop calculations
   double atr[3];
   if(CopyBuffer(g_HandleATR, 0, 0, 3, atr) < 3)
      return;
   double ATR = atr[1];
   if(ATR <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Magic() != Magic || posInfo.Symbol() != _Symbol)
         continue;

      double openPrice   = posInfo.PriceOpen();
      double currentSL   = posInfo.StopLoss();
      double currentPrice= posInfo.PriceCurrent();
      bool   isLong      = (posInfo.PositionType() == POSITION_TYPE_BUY);
      ulong  ticket      = posInfo.Ticket();

      double profit      = isLong ? (currentPrice - openPrice) : (openPrice - currentPrice);

      // ── Break Even ───────────────────────────────────────────
      if(UseBreakEven && UseStopLoss)
        {
         double beTrigger = BreakEvenTrigger * ATR;
         double beTarget  = isLong
                            ? openPrice + BreakEvenBuffer * g_Pip
                            : openPrice - BreakEvenBuffer * g_Pip;

         bool beNotYetMoved = isLong  ? (currentSL < openPrice) : (currentSL > openPrice || currentSL == 0);
         if(profit >= beTrigger && beNotYetMoved)
           {
            double newSL = NormalizeDouble(beTarget, _Digits);
            if(IsSLValid(isLong, newSL, currentPrice) && newSL != currentSL)
              {
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
               PrintFormat("NAS100 EA: Break-even set | Ticket:%I64u SL:%.2f", ticket, newSL);
              }
           }
        }

      // ── Trailing Stop ────────────────────────────────────────
      if(UseTrailing && UseStopLoss)
        {
         double trailStart = TrailStart * ATR;
         double trailStep  = MathMax(TrailStep * ATR, g_StopsLevel);

         if(profit >= trailStart)
           {
            double newSL = isLong
                           ? NormalizeDouble(currentPrice - trailStep, _Digits)
                           : NormalizeDouble(currentPrice + trailStep, _Digits);

            bool isBetter = isLong  ? (newSL > currentSL) : (newSL < currentSL || currentSL == 0);
            if(isBetter && IsSLValid(isLong, newSL, currentPrice) && newSL != currentSL)
              {
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| THE MATH — Lot size calculation                                  |
//| Formula: (Balance × Risk%) / (SL_points × TickValue)           |
//+------------------------------------------------------------------+
double CalcLot(double slDistance)
  {
   if(!UseRiskPercent)
      return NormaliseLot(FixedLot);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;

   if(g_TickSize <= 0 || g_TickValue <= 0 || slDistance <= 0)
      return g_VolMin;

   double slPoints = slDistance / g_TickSize;  // SL in ticks
   double lot      = riskAmount / (slPoints * g_TickValue);

   return NormaliseLot(lot);
  }

//+------------------------------------------------------------------+
//| Rounds lot to broker step and clamps to [min, max]              |
//+------------------------------------------------------------------+
double NormaliseLot(double lot)
  {
   lot = MathFloor(lot / g_VolStep) * g_VolStep;
   lot = MathMax(g_VolMin, MathMin(g_VolMax, lot));
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
//| Equity circuit breaker — returns false if hard limits are hit   |
//+------------------------------------------------------------------+
bool EquityCheckPassed()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(MaxEquityProfit > 0 && equity >= g_BalanceAtStart + MaxEquityProfit)
     {
      static bool s_profitTripped = false;
      if(!s_profitTripped)
        {
         PrintFormat("NAS100 EA: MaxEquityProfit reached (%.2f). Halting new trades.", equity);
         s_profitTripped = true;
        }
      return false;
     }

   if(MaxEquityLoss > 0 && equity <= g_BalanceAtStart - MaxEquityLoss)
     {
      static bool s_lossTripped = false;
      if(!s_lossTripped)
        {
         PrintFormat("NAS100 EA: MaxEquityLoss reached (%.2f). EA halted.", equity);
         s_lossTripped = true;
        }
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Delete all pending orders placed by this EA                     |
//+------------------------------------------------------------------+
void DeleteAllPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!ordInfo.SelectByIndex(i))
         continue;
      if(ordInfo.Magic() != Magic || ordInfo.Symbol() != _Symbol)
         continue;
      trade.OrderDelete(ordInfo.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| Check if EA already has an active trade or pending in direction |
//+------------------------------------------------------------------+
bool HasActiveTradeOrOrder(ENUM_ORDER_TYPE pendingType)
  {
   // Check open positions
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Magic() != Magic || posInfo.Symbol() != _Symbol)
         continue;
      ENUM_POSITION_TYPE pt = posInfo.PositionType();
      if(pendingType == ORDER_TYPE_BUY_STOP  && pt == POSITION_TYPE_BUY)  return true;
      if(pendingType == ORDER_TYPE_SELL_STOP && pt == POSITION_TYPE_SELL) return true;
     }

   // Check pending orders
   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(!ordInfo.SelectByIndex(i))
         continue;
      if(ordInfo.Magic() != Magic || ordInfo.Symbol() != _Symbol)
         continue;
      if(ordInfo.OrderType() == pendingType)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Validate SL against broker minimum stops level                  |
//+------------------------------------------------------------------+
bool IsSLValid(bool isLong, double sl, double currentPrice)
  {
   double minDist = g_StopsLevel;
   if(isLong)  return (currentPrice - sl) >= minDist;
   else        return (sl - currentPrice) >= minDist;
  }

//+------------------------------------------------------------------+
//| Minimal status output on chart (execution info only)            |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
  {
   // Intentionally minimal — this EA is autonomous execution only.
  }

//+------------------------------------------------------------------+
//| OnTrade: log fills for transparency                              |
//+------------------------------------------------------------------+
void OnTrade()
  {
   // Log position openings and closings from history
   int deals = HistoryDealsTotal();
   if(deals <= 0)
      return;

   static int s_lastKnownDeals = 0;
   if(deals == s_lastKnownDeals)
      return;
   s_lastKnownDeals = deals;

   ulong ticket = HistoryDealGetTicket(deals - 1);
   if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)Magic)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
   double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
   string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      PrintFormat("NAS100 EA: Trade closed | Symbol:%s Profit:%.2f", symbol, profit);
  }
//+------------------------------------------------------------------+