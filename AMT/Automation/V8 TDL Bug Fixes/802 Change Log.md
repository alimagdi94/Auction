:**Fix 1 — BUG 1: POC Gravity C3 signal inverted**
**Fix 2 — BUG 2: Absorption direction in OFS score uses bar direction instead of absorption location**
**Fix 3 — BUG 3: DeltaDiv added to conviction regardless of entry direction**
**Fix 4 — BUG 4: g_hasTrades transition doesn't trigger history reload**
**Fix 5 — LogWarning and LogRisk log level gate too restrictive**
**Fix 6 — Risk defaults alert when all loss limits are disabled**
Now update the version number and header to document all the v8.02 changes:Now update the OnInit log line that still references v8.01:Now do a final verification that all fixes landed correctly:All 6 fixes verified. Now copy to outputs:All 6 fixes from the code review are implemented. Here's a summary of what changed under the `[V8-17]` tag:

| # | Category | What changed |
|---|----------|-------------|
| BUG 1 | POC Gravity C3 | Negated the formula — `c3 = -(pocPos * 2.0 - 1.0)`. POC at HIGH is now correctly bearish (distribution), POC at LOW is bullish (accumulation). This affected 15% of the HFT composite score on every single bar. |
| BUG 2 | Absorption OFS | Replaced the single `cAbsorb = hasAbsorb ? (is_bullish ? 1.0 : 0.0) : 0.5` line with a proper low/high location scan, mirroring the C4 logic. Bars with absorption only at the HIGH (sellers absorbing buying) now score bearish regardless of close direction. |
| BUG 3 | DeltaDiv conviction | Added a `divSupportsBuy = !g_bars[bi].is_bullish` gate before adding the "DeltaDiv" tag. Delta divergence is a reversal signal, so it only counts toward conviction in the direction *opposing* bar close. |
| BUG 4 | g_hasTrades reload | Set `g_needs_reload = true` when `g_hasTrades` transitions in `OnTick()`. History bars built in proxy mode (bid-direction classification) are now discarded and rebuilt with proper tick-flag data. |
| Quality | LogWarning / LogRisk gate | Both functions now gate on `LOG_TRADES_ONLY` instead of `LOG_FULL`, so session halts, consecutive loss counter changes, and size reductions are visible whenever trade logging is on. |
| Quality | Risk defaults alert | `OnInit()` fires an `Alert()` if auto-trading is live and all three of `InpMaxDailyLossPercent`, `InpHaltConsecLosses`, and `InpMaxConsecLosses` are simultaneously zero — matching the existing V8-12 pattern. |