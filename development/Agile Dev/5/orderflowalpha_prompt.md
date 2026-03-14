# OrderFlowAlpha – Risk Containment Without Destroying the Equity Curve

You are reviewing and modifying the MT5 EA **OrderFlowAlpha.mq5**.

The objective is **NOT to redesign the strategy**.

The existing entry logic produces a **very high win‑rate with a smooth, steady equity climb**. That behavior must be preserved.

However, the system occasionally accumulates **large floating losses from stranded trades**. These rare tail events damage the equity curve and sometimes appear as forced closes at the end of the backtest window.

Your task is to **add tail‑risk containment mechanisms** without turning the strategy into a normal stop‑loss based system.

---

# Core Design Constraints

Do **NOT**:

- Change entry logic
- Modify signal generation
- Alter TP calculation
- Introduce tight broker stop losses
- Convert the strategy into conventional SL/TP trading

Instead, implement **soft defensive mechanisms** that only activate when trades become abnormal.

The natural trade behavior must remain untouched.

---

# Observed Behavior

Typical backtests show:

- ~96% TP win rate
- Typical winners around $4–$8
- Occasional trades that drift against the position for many hours or days
- No hard stop loss currently used

These drifting positions create the majority of drawdown.

The objective is to **contain these rare tail events** while preserving the high win‑rate structure.

---

# Required Improvements

## 1. Implement a Soft Stop (Hidden Stop Loss)

Add an optional EA‑managed floating loss limit.

This stop is **not placed with the broker**. Instead, it is executed via market close logic inside the EA.

### New Inputs

```mq5
input bool   InpUseSoftStop  = true;
input double InpSoftStopPips = 120.0;
```

### Behavior

If floating loss of a position exceeds `InpSoftStopPips`:

1. Close the position using `TRADE_ACTION_DEAL`
2. Retry close up to 3 times if requote or connection errors occur
3. Log the event

Example log message:

```
SOFT STOP CLOSE | ticket=...
```

Important:

This is **not part of normal exit logic**. It should trigger only during abnormal price movement.

---

# 2. Implement Maximum Trade Duration

Some trades remain open for extremely long periods.

Add a maximum holding time mechanism.

### Inputs

```mq5
input bool InpUseMaxHoldTime = true;
input int  InpMaxHoldMinutes = 720;   // 12 hours
```

### Behavior

If a trade has been open longer than `InpMaxHoldMinutes`:

1. Close the trade at market
2. Log the event

Example log:

```
TIME EXIT | ticket=...
```

This prevents multi‑day stranded trades.

---

# 3. Ensure Break‑Even Protection Works

Break‑even should activate once a trade has moved modestly in profit.

Ensure the break‑even system:

- Moves SL to entry + buffer after a small favorable move
- Does not interfere with normal TP exits

Example typical configuration:

```
InpUseBreakEven = true
InpBreakEvenTrigger = 20
InpBreakEvenBuffer  = 2
```

Do **not hardcode values**. Just ensure the mechanism behaves correctly.

---

# 4. Trailing Stop Protection

Trailing stop should protect extended winners but activate only after meaningful movement.

Example configuration:

```
InpTrailStart = 35
InpTrailStep  = 15
```

This allows winners to run while preventing full reversal.

---

# 5. Prevent Position Stacking

Large drawdowns occur when multiple trades drift simultaneously.

Ensure the EA strictly respects:

```
InpMaxPositions = 1
```

If the current logic occasionally bypasses this limit, fix it.

---

# 6. Add Portfolio Equity Guard

Introduce a global floating loss guard.

### Input

```mq5
input double InpMaxFloatingLoss = 300.0;
```

### Behavior

If total floating loss across all positions exceeds the limit:

1. Close all open positions
2. Block new entries for the remainder of the trading session

Example log message:

```
EQUITY GUARD TRIGGERED
```

---

# Strategy Preservation Requirement

The strategy relies on:

- Extremely high win rate
- Small TP targets
- Smooth equity growth

Risk controls must **only activate during abnormal market behavior**.

If the EA begins producing frequent stop exits, the implementation is incorrect.

---

# Verification Steps

After implementing changes:

1. Compile with zero errors
2. Run backtest for January 2025
3. Confirm:

- TP win rate remains ~95% or higher
- Soft stop triggers rarely
- No large multi‑day floating losses
- No forced "end of test" closes
- Equity curve maintains steady climb

---

# Deliverables

Provide:

1. Modified code sections
2. Exact insertion points
3. Newly added input parameters
4. Explanation of the new logic
5. Any edge cases handled

If performance changes significantly, explain the reason before modifying parameters.

