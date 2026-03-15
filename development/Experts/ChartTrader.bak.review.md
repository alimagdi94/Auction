## ChartTrader.mq5 (v1.15) — Production Readiness Review

**Decision: GO for production use as an execution tool**

### Scope of review
- **File**: `ChartTrader.bak.mq5` (ChartTrader.mq5 v1.15).
- **Role**: Discretionary **execution panel**, not a strategy; it sends user‑driven market/pending orders with visual SL/TP lines, scale‑out and hotkeys.

### Reasons for GO
- **Mature feature set for manual trading**:
  - Supports market and pending orders, configurable default SL/TP in points, scale‑out, and SL/TP assignment via chart lines.
  - Includes a full, dockable panel with clearly labeled buttons and color coding aligned to industry conventions (green buy, red sell, yellow entry).
  - Hotkey support for Buy/Sell/Close All etc. is present and configurable via inputs.
- **Input and UX design suitable for live desks**:
  - Risk inputs are expressed as **risk units** and default SL/TP distances, making it straightforward to standardise profiles across symbols.
  - Panel size/position and visual toggles (header PnL, timer, margin, zone labels) allow adapting to different monitor layouts without code changes.
  - Visual preview of target/stop zones (lines + labels + PnL box) helps prevent mis‑clicks and clarifies R:R before sending an order.
- **Production‑oriented implementation**:
  - Uses the standard `CTrade` wrapper from `<Trade\Trade.mqh>` and a single magic number, simplifying interaction with other EAs.
  - The top‑level banner and description already mark it as “Professional Chart Trader — Production Ready”, and the layout of inputs and GUI code is consistent with other shipped tools.

### Assumptions and operator responsibilities
- **Manual tool, not an autonomous strategy**:
  - ChartTrader **does not implement entry/exit logic**; it simply executes what the trader requests.
  - Risk discipline (position sizing, maximum exposure, session times) is expected to be enforced by the trader or by separate risk‑control infrastructure.
- **Account/risk constraints**:
  - Default SL/TP distances and risk units should be tuned per symbol and account size before go‑live.
  - Desks that require hard global risk limits (e.g., max daily loss) should pair ChartTrader with supervisory tools or EAs that enforce those policies.

### Preconditions for production
- Load a symbol‑appropriate preset with:
  - `InpDefSL` / `InpDefTP` and `InpAdjStep` suited to the instrument’s volatility.
  - `InpDefRiskUnits` and `InpRiskStep` aligned with firm or personal risk rules.
  - Confirm hotkey mappings do not conflict with platform/global shortcuts.
- Verify on demo that:
  - SL/TP preview lines match the intended prices and PnL readouts.
  - Panel remains responsive and correctly re‑anchors when chart is resized or timeframe is changed.

### Final verdict
Given its limited, well‑defined scope as a **manual chart‑based execution panel**, the v1.15 ChartTrader implementation in `ChartTrader.bak.mq5` is **GO for production** on live accounts, assuming:

- Inputs are tuned per symbol and account, and  
- External or human risk controls govern overall exposure and drawdown.

