---

# ARCHITECTURE.md (Technical Specification)

## 1. System Hierarchy

The system is built as a single-threaded, event-driven Expert Advisor (EA) for MetaTrader 5. It operates on a "Tick" basis but makes logic decisions on a "New Bar" basis to ensure stability.

---

## 2. Input Parameters (Configuration Layer)

These are the external controls exposed to the user. They control the behavior of the "Brain," "Muscle," and "Shield."

### A. Strategy Logic (Pattern Specific)

* **`Pattern Inputs`:** These vary by strategy (e.g., `PoleLength`, `LookbackPeriod`, `Thresholds`).
* **`Logic Filters`:** Specific conditions that must be met (e.g., `MinGrindWidth`, `TrendFilter`).
* **Note:** Each strategy defines its own unique "Brain" parameters here.

### B. Strategy Settings (Context)

* **`ATR_Period` (int):** Lookback period for volatility normalization (Standard: 14).
* **`SpreadFilter` (bool):** Master switch to block trades during high spreads.
* **`MaxSpread` (double):** The maximum allowable spread in Pips.
* **`AllowBuy` / `AllowSell` (bool):** Directional switches to bias the strategy (e.g., trend following).
* **`BufferPips` (double):** Distance (in Pips) *above/below* the signal bar to place the pending entry order.

### C. Money Management (Sizing)

* **`UseRiskPercent` (bool):** Toggle between Dynamic Risk and Fixed Lots.
* **`RiskPercent` (double):** % of Account Balance to risk per trade (SL distance).
* **`FixedLot` (double):** Fallback lot size if `UseRiskPercent` is false.

### D. Trade Management (The Exit)

* **`UseStopLoss` (bool):** Master switch for hard stops.
* **`UseTakeProfit` (bool):** Master switch for hard targets.
* **`RiskRewardRatio` (double):** Multiplier for TP based on SL distance (e.g., 2.0 = Target is 2x the risk).

### E. The Guardian (Protection)

* **`UseBreakEven` (bool):** Toggle for auto-moving SL to entry.
* **`BreakEvenTrigger` (double):** Pips profit required to trigger the move.
* **`BreakEvenBuffer` (double):** Pips *above* entry to lock in (covers commissions).


* **`UseTrailing` (bool):** Toggle for dynamic trailing stops.
* **`TrailStart` (double):** Pips profit required to *start* trailing.
* **`TrailStep` (double):** The "Heartbeat" distance. The stop only moves if price moves this much (reduces server spam).



### F. Hard Equity Stops (Account Safety)

* **`MaxEquityProfit` (double):** Hard target to stop trading (Account Total).
* **`MaxEquityLoss` (double):** Hard stop to kill EA (Account Total).
* **`CleanOldOrders` (bool):** If true, deletes pending orders when a new signal arrives (OCO Logic).

---

## 3. Global State (Memory Layer)

These variables are cached in RAM to prevent expensive API calls every millisecond.

| Variable | Type | Purpose |
| --- | --- | --- |
| `Magic` | `ulong` | Unique ID (`20260226`) to identify this EA's trades. |
| `LastBarTime` | `datetime` | Timestamp of the last processed bar (New Bar detection). |
| `handleATR` | `int` | Pointer to the compiled ATR indicator handle. |
| `g_Pip` | `double` | **Standardized Point Size.** Auto-detects 3/5 digit brokers (0.0001 or 0.01). |
| `g_VolMin` | `double` | Broker's Minimum Lot Size (e.g., 0.01). |
| `g_VolMax` | `double` | Broker's Maximum Lot Size (e.g., 100.0). |
| `g_VolStep` | `double` | Broker's Lot Step (e.g., 0.01 or 0.1). |
| `g_TickSize` | `double` | Value of one tick in deposit currency (Crucial for Risk Math). |

---

## 4. The Logic Core (Function Map)

### A. Initialization (`OnInit`)

1. **Cache:** Calls `RefreshSymbolInfo()` to fill the Global State.
2. **Indicators:** Creates the `iATR` handle.
3. **Validation:** Checks if the indicator handle is valid; aborts if failed.

### B. The Clock (`OnTick`)

1. **Check:** Is it a New Bar? (`IsNewBar`).
2. **If Yes:**
* Refresh caching (spreads/swaps change).
* Clean old pending orders (`DeleteAllPending`).
* **Execute:** Run `PlaceOrders()`.


3. **Always:** Run `ManagePositions()` (Trailing stops need real-time attention).

### C. The Brain (Signal Detection)

* **Input:** Price Data (Open, High, Low, Close) & Indicators (ATR, MA, etc.).
* **Logic:**
1. **Spread Check:** **CRITICAL**. Checks if `CurrentSpread > MaxSpread`. If true, ABORT immediately.
2. **Pattern Recognition:** Scans for specific Price Action setup (e.g., Flag, Pin Bar, Inside Bar).
3. **Validation:** Checks all constraints (Trend Filters, Retracement Limits).

* **Output:** Valid Trade Setup (Direction, Entry Price, SL, TP).

### D. The Muscle (Order Execution)

* **Logic:**
1. Checks Equity Stops.
2. **Execution:**
* Calculates precise Entry, Stop Loss, and Take Profit levels based on the valid setup.
* Calculates Lot Size via `CalcLot()` (Risk Management).
* Sends the appropriate order type (`BuyStop`, `SellStop`, `Market`, etc.) to the server.





### E. The Shield (`ManagePositions`)

* **Logic (Loop through all open trades):**
1. **Break Even:**
* If `Profit > Trigger`: Calculate `Entry + Buffer`.
* **Constraint:** Is `NewSL` valid vs `SYMBOL_TRADE_STOPS_LEVEL`?
* **Action:** Modify Position.


2. **Trailing Stop:**
* If `Profit > Start`: Calculate `Price - Step`.
* **Constraint:** Is `NewSL` better than `CurrentSL`?
* **Constraint:** Is `NewSL` valid vs Broker Limits?
* **Action:** Modify Position.





### F. The Math (`CalcLot`)

* **Formula:** `(AccountBalance * Risk%) / (StopLossPoints * TickValue)`.
* **Sanitization:** Rounds the result to `g_VolStep` and clamps between `g_VolMin` and `g_VolMax`.

---

## 5. Critical Constraints & Safety

* **Stop Level Awareness:** The EA actively reads `SYMBOL_TRADE_STOPS_LEVEL`. If a user requests a 10-point trail but the broker requires 50, the EA **automatically uses 50**. This prevents "Invalid Stops" errors.
* **Normalization:** All price calculations are passed through `NormalizeDouble(val, _Digits)` before being sent to the server.
* **Efficiency:** `OnTick` returns immediately if no processing is needed, ensuring minimal CPU usage.
