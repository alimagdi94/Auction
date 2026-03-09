//+------------------------------------------------------------------+
//|  OrderFlowEA_v820.mq5                                            |
//|  Order Flow EA — Production Grade v8.20                          |
//|                                                                    |
//|  v8.20 — March 2026 production-readiness patch (4 fixes).       |
//|                                                                    |
//|  [V8-20] RISK-MODEL-DECLARE: instance-scoped model formalised    |
//|    The EA previously mixed account-wide equity measurements with  |
//|    per-instance halt flags, with no single authoritative comment  |
//|    declaring the intended scope. CheckDailyLoss() used            |
//|    ACCOUNT_EQUITY vs g_dayStartBalance — the equity side is       |
//|    account-wide but the reference baseline is instance-scoped,    |
//|    creating an implicit dependency on other EAs' open P&L. Fix:   |
//|    (1) RISK-MODEL section header added above CheckNewDay() that   |
//|    declares the chosen model: instance-scoped. (2) CheckDailyLoss |
//|    now subtracts instance open-P&L from ACCOUNT_EQUITY to derive  |
//|    an instance-only equity, keeping the guard self-consistent.    |
//|    (3) All misleading "account-wide" comments removed; variable   |
//|    names and log strings updated to reflect instance scope.       |
//|                                                                    |
//|  [V8-20] RETRY-DUPE-HARDEN: retry dedup now matches on direction,|
//|    price proximity, and comment prefix in addition to magic,      |
//|    symbol, and volume. The previous guard could falsely treat an  |
//|    older unrelated position/deal (same lot size) as the fill for  |
//|    the current retry, suppressing a legitimate second entry. The  |
//|    stronger identity set requires: same direction, same volume,   |
//|    price within 10× minDist of the current market, comment       |
//|    starting with "FP_" (our tag prefix). Logging states exactly  |
//|    which criteria matched so the journal is auditable.            |
//|                                                                    |
//|  [V8-20] MANAGE-ENTRY-SPLIT: ManagePositions ungated from        |
//|    g_autoTrade. The old guard `if(!g_autoTrade) return` stopped  |
//|    break-even, trailing, and pending expiry whenever the user set |
//|    InpATEnable=false — even with live open positions. Risk halts  |
//|    (daily, session, equity) never touched g_autoTrade, so they   |
//|    were unaffected; but the operational "disabled" case was.      |
//|    Fix: guard changed to `if(g_analysisMode) return` — analysis  |
//|    mode correctly excludes live position management (virtual only)|
//|    while all operational states allow it. New entries remain gated|
//|    by g_autoTrade in PlaceOrders(); no entry re-enablement.      |
//|                                                                    |
//|  [V8-20] PENDING-LIFECYCLE: pending tracking hardened end-to-end |
//|    g_pendingTickets / g_pendingBarTimes accumulated stale entries |
//|    when orders filled or were manually deleted outside the expiry |
//|    loop. Three gaps closed: (1) SyncPendingTracking() helper      |
//|    scrubs the arrays against live broker orders on each           |
//|    ManagePositions() call — missing/filled/deleted tickets are    |
//|    removed and logged. (2) OnTradeTransaction() removes filled    |
//|    entries when a DEAL_ENTRY_IN fires for our magic/symbol, so   |
//|    the tracking set is updated asynchronously as fills arrive.   |
//|    (3) OnInit() clears the arrays before re-registering live      |
//|    orders to prevent double-registration on warm restart.         |
//|                                                                    |
//|  v8.19 — March 2026 code-review patch (5 fixes applied).        |
//|  All v8.12 logic preserved; this release addresses:              |
//|                                                                    |
//|  [V8-28] MANAGE-SLEEP: Sleep(200) in ManagePositions replaced     |
//|    The SL-modify retry in ManagePositions() used Sleep(200) —     |
//|    the same blocking pattern fixed in trade_Send() by [V8-27].    |
//|    Up to 400 ms of tick-thread blocking during a trailing-stop    |
//|    retry on a fast market defeats the purpose of position mgmt.   |
//|    Fix: replaced with a GetTickCount64() spin-wait capped at 50ms.|
//|                                                                    |
//|  [V8-28] TRAIL-VALIDATE: OnInit() bounds for trail/BE parameters  |
//|    InpTrailStep, InpTrailStart, InpBreakEvenTrigger, and           |
//|    InpBreakEvenBuffer had no OnInit() validation. InpTrailStep=0  |
//|    causes trailSL=curBid on every tick (instant stop-out).        |
//|    Negative InpBreakEvenBuffer places BE stop on the wrong side.  |
//|    All four are now validated inside the if(InpATEnable) block,   |
//|    consistent with the existing SL/TP validation pattern.         |
//|                                                                    |
//|  [V8-27] SLTP-LOG-CLAMP: PlaceOrders logs actual sent SL/TP      |
//|    trade_Send() may clamp SL/TP to broker minDist. The success    |
//|    log in PlaceOrders used the pre-clamp sl/tp variables, so the  |
//|    journal recorded different values than the live order. Fix:    |
//|    trade_Send() gains outSL/outTP output params; PlaceOrders logs |
//|    sentSL/sentTP; LogWarning fired on each clamp event.           |
//|                                                                    |
//|  [V8-27] EQUITY-INPUT-VALIDATE: bounds check for equity inputs   |
//|    InpMaxEquityProfit and InpMaxEquityLoss had no OnInit()         |
//|    validation. Negative values were silently ignored (> 0.0 guard)|
//|    but likely represent data-entry errors. Both now require >= 0  |
//|    (0 = disabled) with INIT_PARAMETERS_INCORRECT on violation.    |
//|                                                                    |
//|  [V8-27] RETCODE-SLEEP: Sleep(200) replaced with 50ms spin-wait  |
//|    The retry loop in trade_Send() called Sleep(200) on requote /  |
//|    price_changed retcodes, blocking the tick thread for up to     |
//|    400 ms. During that window ManagePositions() cannot fire,      |
//|    delaying break-even and trailing stops on open positions during |
//|    the exact conditions (news, fast markets) that cause requotes. |
//|    Fix: replaced with a GetTickCount64() spin-wait capped at 50ms.|
//|                                                                    |
//|  [V8-26] EQUITY-HALT-PERSIST: equity halt state persisted to GV  |
//|    The equity profit/loss guards set g_autoTrade=false but never  |
//|    called RiskStateSave(). OnInit() always resets g_autoTrade=    |
//|    InpATEnable, so any restart silently re-enabled trading during |
//|    an active halt. Fix: dedicated g_equityHalted flag added to    |
//|    RiskStateSave/Load using the established GVKey pattern.        |
//|                                                                    |
//|  [V8-26] EQUITY-HALT-MANAGE: ManagePositions unaffected by halt  |
//|    The old equity halt set g_autoTrade=false, which also blocked  |
//|    ManagePositions() — stopping break-even and trailing stop moves|
//|    on open positions. Other halt types (daily loss, session halt) |
//|    do not affect position management. Fix: equity halt now uses   |
//|    g_equityHalted (gating only CheckRiskConditions), leaving      |
//|    ManagePositions() unaffected.                                  |
//|                                                                    |
//|  [V8-26] EQUITY-HALT-ALERT: Alert() fired on equity halt         |
//|    The equity guards used LogWarning() only. Every other halt     |
//|    type (daily loss, session halt) fires an Alert() popup. A live |
//|    equity halt silently stopped entries with no trader            |
//|    notification. Fix: Alert() added to both equity guard bodies,  |
//|    consistent with the established halt-notification pattern.     |
//|                                                                    |
//|  [V8-25] LEVMAP-STALE: levelMap rebuilt after SortLevels()       |
//|    SortLevels() physically reorders levels[] by price. The v8.08  |
//|    levelMap (price→levels[] index) was not updated after the sort,|
//|    leaving stale indices. Any tick arriving on the same bar after  |
//|    ComputeBarSignals() would write volume to the wrong price level,|
//|    silently corrupting footprint data. This affects the live bar   |
//|    on every tick after a signal evaluation and the last history    |
//|    bar after ReloadHistory(). Fix: new RebuildLevelMap(bi) helper |
//|    clears and re-registers all levels at their sorted positions;  |
//|    called from ComputeBarSignals() immediately after SortLevels(). |
//|                                                                    |
//|  [V8-25] EXTEND-OFFSET: offset recalculated after downward extend |
//|    After a downward levelMap extension, offset was set to 0 rather |
//|    than recalculated against the updated levelMapBase. Currently   |
//|    benign (slot 0 is always -1 after extend so the lookup falls   |
//|    through to new-level creation, and registration uses a fresh   |
//|    gIdx computation), but the stale variable is incorrect and      |
//|    creates a subtle maintenance hazard. Fix: offset recomputed as  |
//|    gridIdx - g_bars[bi].levelMapBase after the base is updated.   |
//|                                                                    |
//|  [V8-24] TICK-SEARCH-UPWARD: upward map extension single-resize  |
//|    The upward branch of the AccumulateTick() levelMap extension   |
//|    called ArrayResize once per slot (up to 16 heap allocations    |
//|    per extension). The downward branch already used a single      |
//|    resize. Fix: replaced per-slot loop with one ArrayResize()     |
//|    followed by a slot-initialisation loop, matching the downward  |
//|    path and restoring the O(1) intent of the TICK-SEARCH fix.    |
//|                                                                    |
//|  [V8-24] LEVMAP-FREE: levelMap freed explicitly in cleanup paths  |
//|    ReloadHistory() and OnDeinit() explicitly freed levels[] but   |
//|    not levelMap[], the dynamic array added to FPBar in v8.08.     |
//|    Fix: ArrayFree(g_bars[i].levelMap) added alongside the         |
//|    existing ArrayFree(g_bars[i].levels) at both cleanup sites.    |
//|                                                                    |
//|  [V8-24] RISKLOAD-LOG-COND: SL timestamps in restore log gate    |
//|    RiskStateLoad() logged restored state only when a loss-streak  |
//|    variable was non-default. After a restart with only SL cooldown|
//|    state active (no consecutive losses), the log never fired and  |
//|    the user could not confirm from the journal that the cooldown  |
//|    was recovered. Fix: condition extended with                     |
//|    g_lastSLBarTimeBuy > 0 || g_lastSLBarTimeSell > 0.            |
//|                                                                    |
//|  [V8-24] LEVMAP-SKIP: out-of-range levels registered in map      |
//|    The new-level registration block in AccumulateTick() was        |
//|    guarded by if(!skipSearch). A tick arriving at a price more    |
//|    than one step outside the current bar OHLC range created a     |
//|    level with no map entry; a second tick at the same price       |
//|    before the OHLC updated would create a duplicate level and     |
//|    silently corrupt volume and delta totals. Fix: registration    |
//|    now runs unconditionally with a defensive bounds check.        |
//|                                                                    |
//|  [V8-23] DELTA-THRESH-VALIDATE: InpDeltaConvThreshold validated  |
//|    The parameter had no OnInit() bounds check. A value of 0 makes |
//|    Component 2 trivially true for any directional bar; >= 1 makes |
//|    it permanently impossible (Component 2 silently disabled). Fix:|
//|    added range guard returning INIT_PARAMETERS_INCORRECT, matching|
//|    the validation pattern used for all other threshold inputs.    |
//|                                                                    |
//|  [V8-23] NEWDAY-DEFER-PERSIST: g_newDayDeferStart persisted      |
//|    The 24-hour new-day deferral deadline was not saved to          |
//|    GlobalVariables. A crash or VPS reboot during a weekend-gap    |
//|    deferral reset the clock to restart time; repeated restarts    |
//|    could prevent the snapshot from ever firing. Fix: variable     |
//|    added to RiskStateSave()/RiskStateLoad() via GVKey("NewDayDefer|
//|    "), matching the pattern used for g_dayStartDay and the SL     |
//|    timestamps added in v8.22.                                     |
//|                                                                    |
//|  [V8-23] CTR-ANALYSIS-VTICKET: g_virtualTicket persisted always  |
//|    CounterSave() was only called inside the InpShowVisuals block  |
//|    in EvalAndFireSignal(). g_virtualTicket is incremented in      |
//|    PlaceOrders() regardless of InpShowVisuals. With             |
//|    InpShowVisuals=false, virtual orders accumulated in memory and |
//|    reset to 900M on restart, colliding with chart objects from    |
//|    the prior session. Fix: CounterSave() called in PlaceOrders() |
//|    immediately after g_virtualTicket++ in the analysis-mode path. |
//|                                                                    |
//|  [V8-23] RISKSTATELOAD-LOG: LastSLBuy/Sell in restore log        |
//|    The RiskStateLoad() journal entry listed only the five v8.10   |
//|    fields. After a restart it was impossible to confirm from the  |
//|    journal whether SL cooldown state was recovered. Fix: both SL  |
//|    timestamps added to the format string.                         |
//|                                                                    |
//|  [V8-23] ARRAYRESIZE-INCONSISTENT: reserve param standardised    |
//|    10 of 14 tag ArrayResize calls in GetConvictionResult() omitted|
//|    the reserve parameter. Only the initial ArrayResize(tags,0,12) |
//|    supplied a reserve, so those 10 appends each triggered a heap  |
//|    reallocation despite the pre-allocation. Fix: all 14 append    |
//|    sites now use ArrayResize(tags, n+1, 12) uniformly.           |
//|                                                                    |
//|  [V8-23] C3-INDEX: POC gravity uses price distance, not index     |
//|    The C3 formula used poc_idx / (len-1) — a fraction of discrete |
//|    level slots. On instruments with non-uniform level density      |
//|    (wide spreads, price rounding, low-liquidity gaps), two bars    |
//|    with identically positioned POCs produce different pocPos      |
//|    values. Fix: replaced with (poc_price - bar_low) / bar_range,  |
//|    which is numerically invariant to level density.               |
//|                                                                    |
//|  [V8-23] BAR-ASYMMETRY: intentional bar offset documented        |
//|    EvalAndFireSignal() uses bi=nBars-1 (live bar); PlaceOrders()  |
//|    uses bi=nBars-2 (last closed bar). This was intentional but    |
//|    undocumented — a BUY arrow on bar N that produced no order     |
//|    had no explanation in the logs. Fix: explanatory comments added|
//|    at both call sites and at the bar index declarations.          |
//|                                                                    |
//|  [V8-23] TICK-SEARCH: O(1) level lookup in AccumulateTick()      |
//|    The tick hotpath used a reverse linear scan to match incoming  |
//|    prices to existing footprint levels: O(levels) per tick. On   |
//|    liquid futures with 50-200 levels and thousands of ticks per   |
//|    bar, this was the last O(n×m) path in the pipeline. Fix: a    |
//|    per-bar integer grid map (levelMap[] in FPBar) maps grid offset |
//|    to levels[] index in O(1). Map grows lazily with the bar range.|
//|                                                                    |
//|  [V8-23] CHANGELOG-ORPHAN: [V8-21] DEAD-UA prefix restored      |
//|    Lines 65-71 contained the body text of the v8.21 DEAD-UA      |
//|    entry but were missing their [V8-21] DEAD-UA WIRED: header    |
//|    prefix after the SL-COMMENT-CASE block was inserted above them.|
//|    Fix: prefix restored; changelog record is now complete.        |
//|                                                                    |
//|  [V8-22] SL-COOLDOWN-PERSIST: g_lastSLBarTimeBuy/Sell persisted  |
//|    Both datetime values were written on every SL hit but were     |
//|    never saved to GlobalVariables, so InpSLCooldownBars protection|
//|    was silently bypassed on every EA restart or crash. Fix: both  |
//|    values added to RiskStateSave()/RiskStateLoad() using the      |
//|    existing V8-10 scoping pattern.                                |
//|                                                                    |
//|  [V8-22] CVD-DRY: CVD slope extracted to ComputeCVDSlope()       |
//|    The 3-bar recency-weighted slope formula was duplicated        |
//|    verbatim in ComputeHFTSignal() (C6) and GetConvictionResult()  |
//|    (Component 4). A future formula change required two edits;     |
//|    a missed edit would cause silent divergence. Fix: shared       |
//|    helper ComputeCVDSlope(int bi) called from both sites.         |
//|                                                                    |
//|  [V8-22] UA-SCORE: UA tags excluded from componentCount          |
//|    UA_Lo/UA_Hi counted toward InpMinConvictionComp but had 0%     |
//|    weight in the HFT score the conviction gate is meant to        |
//|    reinforce — a UA flag alone could push a borderline trade      |
//|    through the gate. Fix: UA tags excluded from componentCount    |
//|    via the same carve-out pattern used for NakedPOC. UA flags     |
//|    are retained in the label string for display/logging.          |
//|                                                                    |
//|  [V8-22] CTR-ANALYSIS: Counters persisted on signal draw         |
//|    In analysis mode (g_autoTrade=false), OnTradeTransaction()     |
//|    never fires, so RiskStateSave() was never called. Counter      |
//|    values accumulated in memory and reset to 800M/900M on every   |
//|    restart — the CARRY-CTR crash-collision fix was entirely        |
//|    bypassed in analysis mode. Fix: a lightweight CounterSave()    |
//|    writes only the two counter GlobalVariables immediately after   |
//|    g_sigMarkerCount is incremented in EvalAndFireSignal().        |
//|                                                                    |
//|  [V8-22] NEWDAY-DEFER: 24-hour deadline on new-day deferral      |
//|    CheckNewDay() deferred indefinitely while any EA position was   |
//|    open, meaning a position held over a weekend gap could leave    |
//|    the day-start balance snapshot three calendar days stale.       |
//|    Fix: g_newDayDeferStart tracks the first defer tick;           |
//|    after 24 hours the snapshot fires regardless of open positions. |
//|                                                                    |
//|  [V8-22] ARRAYRESIZE: Pre-allocated tag array in GetConviction()  |
//|    The incremental ArrayResize(n+1) pattern triggered up to 10     |
//|    sequential heap reallocations per call. Fix: ArrayResize with  |
//|    12-slot reserve at initialisation eliminates all reallocations. |
//|                                                                    |
//|  [V8-22] DELTA-THRESHOLD: Strong-delta threshold exposed as input |
//|    The 0.35 conviction threshold was hardcoded in                  |
//|    GetConvictionResult() Component 2 with no parameter. Every     |
//|    other signal threshold is an input. Fix: new input parameter   |
//|    InpDeltaConvThreshold (default 0.35) exposes this value        |
//|    consistently with the rest of the input surface.               |
//|                                                                    |
//|  [V8-22] SL-COMMENT-CASE: Case-insensitive SL comment detection  |
//|    OnTradeTransaction() used StringFind(comment,"sl") which is    |
//|    case-sensitive; brokers writing "SL" or "S/L" missed the check |
//|    and fell through to the net-loss fallback, potentially          |
//|    misclassifying manual closes as SL hits. Fix: comment is       |
//|    lowercased before all StringFind checks.                        |
//|                                                                    |
//|  [V8-21] DEAD-UA WIRED: UA tags wired into GetConvictionResult() |
//|    is_unfinished_hi and is_unfinished_lo were correctly computed  |
//|    since v8.05 but never fed into any scoring function (five      |
//|    patch cycles of dead code). Fix: added UA_Hi and UA_Lo tags   |
//|    to GetConvictionResult() following the existing AskExh/BidExh |
//|    pattern. UA_Hi at bar HIGH supports SHORT; UA_Lo at bar LOW   |
//|    supports LONG.                                                 |
//|                                                                    |
//|  [V8-21] CARRY-PIV: Median-of-three pivot in both quicksorts    |
//|    SortLevelsPartition and SortPocPartition used last-element    |
//|    pivot, degrading to O(n²) on nearly-sorted input (common for  |
//|    price levels in trending markets). Fix: median-of-three pivot  |
//|    selection in both functions eliminates the degenerate case.   |
//|                                                                    |
//|  [V8-21] CARRY-CTR: Signal marker counters persisted            |
//|    g_sigMarkerCount and g_virtualTicket reset to hardcoded values |
//|    on every startup. After a crash (no OnDeinit), chart object    |
//|    names collide: ObjectCreate() silently fails and prior-session |
//|    objects stay while new signals produce no markers. Fix: both  |
//|    counters added to RiskStateSave()/RiskStateLoad() using the   |
//|    existing V8-10 scoping pattern.                               |
//|                                                                    |
//|  [V8-21] C6-SCALE: C6 scaling factor recalibrated to *2.25     |
//|    The *3.0 amplifier was calibrated for the old 2-point slope   |
//|    formula whose unscaled range was [-1, 1]. The v8.05 3-bar     |
//|    formula has a larger unscaled range ([-4/3, 4/3]), causing C6  |
//|    to saturate at ±1.0 more readily. Fix: scaling adjusted to    |
//|    *2.25, which maintains equivalent clamp-engagement frequency  |
//|    across both formulas (max unscaled = 4/3 × 2.25 ≈ 3.0, same  |
//|    as the old formula's maximum of 1.0 × 3.0).                  |
//|                                                                    |
//|  [V8-20] RESTART-WIPE: g_dayStartDay PERSISTED (RESTART-WIPE)   |
//|    g_dayStartDay was omitted from RiskStateSave/Load. Because it  |
//|    initialises to -1 and CheckNewDay() uses dt.day != -1 to fire, |
//|    every same-day EA restart wiped the V8-10 GlobalVariable state |
//|    (session halt, consecutive losses) that RiskStateLoad() had    |
//|    just restored. Fix: persist g_dayStartDay in GlobalVariables   |
//|    alongside the other risk fields.                               |
//|                                                                    |
//|  [V8-20] UNFINISHED AUCTION SPATIAL + CONDITION (DEAD-UA)        |
//|    With ascending sort, levels[0]=LOW and levels[len-1]=HIGH, so  |
//|    is_unfinished_hi/lo targets were swapped. Condition logic also  |
//|    incorrect ("both sides > 0" is always true for traded levels). |
//|    Fix: swap assignment targets; replace condition with the        |
//|    standard near-zero aggressor-side check (ask_vol near-zero at  |
//|    HIGH = unfinished hi; bid_vol near-zero at LOW = unfinished lo).|
//|                                                                    |
//|  [V8-20] REDUNDANT OFS SCAN ELIMINATED (CARRY-SCAN)             |
//|    PlaceOrders() and EvalAndFireSignal() each called              |
//|    ComputeOFScore(bi) and ComputeHFTSignal(bi) separately, but   |
//|    ComputeHFTSignal internally calls ComputeOFScore again,         |
//|    causing 3-4 full level scans per bar close. Fix: compute OFS   |
//|    once per call site and thread it through ComputeHFTSignal via  |
//|    an optional preOFS parameter. Level scan count per bar: 4→2.  |
//|                                                                    |
//|  [V8-20] ComputeNakedPOCs O(n log n) (CARRY-POC)                |
//|    The O(n²) double-loop caused startup stalls proportional to    |
//|    InpHistoryBars² (12.5M comparisons at 5,000 bars). Fix: sort  |
//|    POC prices once (O(n log n)), then forward-pass each bar using |
//|    binary search to mark retested POCs in O(n log n) total.      |
//|                                                                    |
//|  [V8-20] C6 CVD SLOPE INCLUDES bar bi-1 (CARRY-CVD)            |
//|    C6 and Conviction Component 4 computed slope as                |
//|    (nd[bi]-nd[bi-2])/2, never reading nd[bi-1]. A momentum        |
//|    reversal at bi-1 that recovered at bi yielded near-zero slope.  |
//|    Fix: recency-weighted 3-bar formula                            |
//|    slope = (2*(nd0-nd1) + (nd1-nd2)) / 3. Applied identically    |
//|    to both C6 and Conviction Component 4.                         |
//|                                                                    |
//|  Inherited from v8.04:
//|    All spatial comments and signal components assumed ascending.  |
//|    Fix: change >= to <=. levels[] is now genuinely ascending:     |
//|    levels[0]=bar LOW, levels[len-1]=bar HIGH. This is the root    |
//|    cause that invalidated the C3 and C5 bug identifications in    |
//|    the v8.01 review.                                              |
//|                                                                    |
//|  [V8-19] ABSORPTION SPATIAL LOOPS — 3 LOCATIONS (C3-REG/C5-REG) |
//|    After fixing the sort to ascending, the absorption loop bounds  |
//|    in ComputeOFScore(), ComputeHFTSignal() C4, and                |
//|    GetConvictionResult() had their LOW/HIGH variable assignments   |
//|    backwards (they were correct for the old descending order).    |
//|    All three corrected: i<chk now indexes LOW, i>=len-chk HIGH.  |
//|    C3 negation and exhaustion scan directions from v8.03 are       |
//|    already correct for ascending — no changes to those.           |
//|                                                                    |
//|  [V8-19] CheckNewDay() EXTRACTED — BUG A SCOPE FIX              |
//|    The V8-18 session-halt reset lived inside CheckDailyLoss(),    |
//|    which returns early when InpMaxDailyLossPercent = 0.0 (the     |
//|    default). Users running InpHaltConsecLosses without a daily-%  |
//|    limit never hit the reset, preserving the permanent-halt bug.  |
//|    Fix: new-day state is now reset in a standalone CheckNewDay()  |
//|    called unconditionally from the top of CheckRiskConditions(),  |
//|    regardless of any daily-loss percentage setting.               |
//|                                                                    |
//|  Inherited from v8.03:
//|    InpHaltConsecLosses a permanent kill switch: once fired, the   |
//|    EA would never trade again across restarts and calendar days   |
//|    with no documented recovery path. Fix: reset g_sessionHalted  |
//|    and g_consecutiveLosses in the new-day block of CheckDailyLoss |
//|    alongside the existing g_dailyLossHalted reset. Matches the   |
//|    documented intent of "session halt resets on the next day".    |
//|                                                                    |
//|  [V8-18] EA_VERSION CONSTANT — STALE STRINGS (BUG B)            |
//|    Alert() and log strings in 6+ locations still read "v8.01" or  |
//|    "v8.02" after the patch. A #define EA_VERSION / EA_NAME pair   |
//|    is now the single source of truth for all version strings.     |
//|                                                                    |
//|  [V8-18] HTF TREND FILTER BID/ASK PRICE (BUG C)                 |
//|    CheckHTFTrend() used SYMBOL_BID for both buy and sell trend    |
//|    comparisons. Long entries execute at the ASK; comparing BID to  |
//|    the EMA passes the filter even when ASK is below EMA on wide-  |
//|    spread instruments. Fix: use ASK for isBuy=true, BID for sells.|
//|                                                                    |
//|  [V8-18] EXHAUSTION DETECTION SPATIAL SWAP (BUG D)              |
//|    ask_vol exhaustion was scanned at the bar LOW and bid_vol at   |
//|    the bar HIGH. Near-zero ask at the low is normal structure on  |
//|    any bar that rallied — not buying exhaustion. Correct footprint |
//|    interpretation: ask exhaustion at HIGH (buyers ran out at top, |
//|    bearish); bid exhaustion at LOW (sellers ran out at bottom,    |
//|    bullish). Scan directions in ComputeBarSignals() swapped       |
//|    accordingly.                                                    |
//|                                                                    |
//|  Inherited from v8.02:
//|    ComputeHFTSignal() C3 was returning +1 for POC at the HIGH    |
//|    (distribution zone) and -1 for POC at the LOW (accumulation). |
//|    levels[] is price-ascending so poc_idx near len-1 = HIGH.     |
//|    Fix: negate the formula. Affects 15% of the HFT score.        |
//|                                                                    |
//|  [V8-17] ABSORPTION OFS DIRECTION (BUG 2)                       |
//|    ComputeOFScore() cAbsorb used bar-close direction as a proxy   |
//|    for absorption location, mis-scoring bars with absorption at   |
//|    the HIGH as bullish when they close up. Fix: mirror the C4     |
//|    location scan — absorption at LOW = bullish, HIGH = bearish.  |
//|                                                                    |
//|  [V8-17] DELTADIV CONVICTION DIRECTION (BUG 3)                  |
//|    GetConvictionResult() added "DeltaDiv" unconditionally to the  |
//|    conviction list regardless of trade direction. DeltaDiv is a   |
//|    reversal signal; it supports the trade opposing bar direction.  |
//|    Fix: gate the tag on directional alignment.                    |
//|                                                                    |
//|  [V8-17] g_hasTrades TRANSITION FORCES RELOAD (BUG 4)           |
//|    Proxy-classified history bars (bid-direction, not TICK_FLAG)  |
//|    were kept when g_hasTrades transitioned in OnTick(). Fix: set  |
//|    g_needs_reload=true on the transition to reclassify.           |
//|                                                                    |
//|  [V8-17] LogWarning / LogRisk GATE (QUALITY FIX)                |
//|    Both were gated on LOG_FULL, hiding risk events (session halt, |
//|    consecutive losses) at LOG_TRADES_ONLY. Fix: gate lowered to   |
//|    LOG_TRADES_ONLY.                                               |
//|                                                                    |
//|  [V8-17] RISK DEFAULTS ALERT (QUALITY FIX)                      |
//|    OnInit() now fires Alert() when InpATEnable is true and all    |
//|    three loss-protection inputs are simultaneously zero.           |
//|                                                                    |
//|  [V8-06] SL HIT DETECTION — CORRECT FP_ PREFIX GATE             |
//|    OnTradeTransaction() now gates on the EA's own FP_ comment     |
//|    prefix as primary classification. The previous fallback         |
//|    (dealNet < 0 when both "sl" and "tp" were absent) fired on    |
//|    manual closes and break-even exits, inflating                  |
//|    g_consecutiveLosses. Fix: match FP_ prefix first; fall back    |
//|    to net loss only when the broker has stripped the comment.     |
//|    (Replaces V8-04 which introduced the regression.)              |
//|                                                                    |
//|  [V8-07] DAILY LOSS SNAPSHOT — SETTLED BALANCE GATE             |
//|    CheckDailyLoss() now defers the day-start balance snapshot     |
//|    until PositionsTotal() == 0 for this EA's magic number, so    |
//|    an overnight position that closes at the day open does not     |
//|    produce a stale snapshot. The V8-05 changelog claimed this     |
//|    behaviour but the implementation was identical to v7.           |
//|                                                                    |
//|  [V8-08] CHART OBJECT CLEANUP — ALL PREFIXES COVERED            |
//|    CleanupAllTradeObjects() now deletes SIG_AR_, SIG_LB_,        |
//|    AN_AR_, AN_SL_, AN_TP_, AN_EL_ objects in addition to FP_.    |
//|    Previously these accumulated silently across sessions.          |
//|                                                                    |
//|  [V8-09] VALUE AREA — CME-STANDARD SINGLE-LEVEL LOOKAHEAD       |
//|    FindVA() now uses a single-level lookahead (CME standard).     |
//|    The two-level lookahead introduced a directional bias toward    |
//|    the second-next level on asymmetric profiles.                  |
//|                                                                    |
//|  [V8-10] RISK STATE PERSISTENCE ACROSS EA RESTARTS              |
//|    g_consecutiveLosses, g_sizeReductionLeft, g_sessionHalted,    |
//|    and g_dailyLossHalted are now persisted in MT5 GlobalVariables |
//|    keyed by magic number and symbol. State is restored on         |
//|    OnInit() and saved on every change, so an EA restart or        |
//|    disconnect mid-session does not silently reset risk counters.  |
//|                                                                    |
//|  [V8-11] SESSION TIME — CORRECTED INPUT DESCRIPTION             |
//|    InpSessionStartHour/EndHour descriptions corrected to say      |
//|    "broker server hour". TimeCurrent() returns server time, not   |
//|    UTC. Users on UTC brokers are unaffected; others must account  |
//|    for their broker's UTC offset.                                 |
//|                                                                    |
//|  [V8-12] ANALYSIS + AUTOTRADE CONFLICT ALERT                    |
//|    OnInit() now fires an Alert() when both InpATEnable and        |
//|    InpAnalysisMode are true so the user knows no real orders      |
//|    will be placed.                                                |
//|                                                                    |
//|  [V8-13] g_hasTrades LAZY RE-CHECK ON FIRST TICK               |
//|    If SYMBOL_LAST was zero at init (pre-open window), the EA      |
//|    now re-checks on the first tick that sees a valid LAST price.  |
//|                                                                    |
//|  [V8-14] ROLLING ATR BASELINE UPDATE                            |
//|    g_atrBaseline is refreshed with an exponential moving average  |
//|    on each new bar rather than being fixed at history-load time.  |
//|                                                                    |
//|  [V8-15] OFS WEIGHT INDIVIDUAL VALIDATION                       |
//|    OnInit() now validates that each OFS component weight >= 0     |
//|    and emits a clear error rather than silently clamping to 0.    |
//|                                                                    |
//|  [V8-16] TRAILING STOP SUPPRESSION LOG                          |
//|    ManagePositions() now logs when the trailing stop is           |
//|    suppressed because break-even has not yet moved newSL past     |
//|    the trail level, aiding strategy-tester diagnosis.             |
//|                                                                    |
//|  Inherited from v8.00:                                            |
//|    V8-01 Descriptive input parameters                             |
//|    V8-02 Calibrated default values                                |
//|    V8-03 Broker filling mode defensive comment                    |
//|    V8-04 SL hit detection (superseded by V8-06)                  |
//|    V8-05 Daily loss reset guard (superseded by V8-07)            |
//|                                                                    |
//|  [V8-19] GVKEY-ACCOUNT-SCOPE: GlobalVariable keys now include account login     |
//|    Keys were scoped to magic+symbol only. Two accounts open in the same MT5      |
//|    terminal share the same GlobalVariables namespace; one EA instance could load  |
//|    halt state written by an instance on a different account. Fix: account login   |
//|    number added to GVKey so each key is terminal-globally unique per account.    |
//|                                                                                   |
//|  [V8-19] PENDING-EXPIRY-RESTART: pending expiry rebuilt from broker order pool   |
//|    g_pendingTickets/g_pendingBarTimes are in-memory only. After an EA restart     |
//|    any existing broker pending orders were untracked and never expired. Fix:      |
//|    OnInit() scans pending orders owned by this EA and registers each one using    |
//|    the order open time as the placement reference, restoring expiry coverage.    |
//|                                                                                   |
//|  [V8-19] POSITION-CAP-PENDING: CountExposure() counts open+pending together      |
//|    InpMaxPositions was checked against open positions only. Pending stop orders   |
//|    bypassed the cap, allowing stacked exposure. Fix: new CountExposure() adds     |
//|    pending order count for this EA to the open position count; cap checked        |
//|    against the combined total.                                                    |
//|                                                                                   |
//|  [V8-19] SESSION-OVERNIGHT: CheckSessionTime() handles overnight windows         |
//|    dt.hour >= start && dt.hour < end fails for sessions spanning midnight (e.g.   |
//|    22:00–02:00). Fix: wrap-around detected when start >= end; in that case the   |
//|    window is active outside [end, start), correctly covering both sides of        |
//|    midnight. OnInit() validation updated to allow start >= end.                  |
//|                                                                                   |
//|  [V8-19] RETRY-DUPE-GUARD: connection/timeout retry reconciles broker state      |
//|    trade_Send() retried on timeout/connection failures without checking whether   |
//|    the original request already filled upstream, risking duplicate entries. Fix:  |
//|    on timeout/connection retcode, search open positions and recent history for    |
//|    a matching fill before sending again; abort retry if one is found.             |
//|                                                                                   |
//|  [V8-18] NEWDAY-MONTH-ROLLOVER: CheckNewDay() now uses a full YYYYMMDD date key  |
//|    g_dayStartDay stored only dt.day (1–31). Jan 5 and Feb 5 share dt.day=5, so  |
//|    no new-day reset fired on month or year rollover. Fix: replace with           |
//|    year*10000 + month*100 + day; backward-compatible with GlobalVariable storage.|
//|                                                                                   |
//|  [V8-18] VISUAL-TICKET-IDENTITY: POSITION_IDENTIFIER used as visual key         |
//|    DrawTradeEntry used res.order; ManagePositions used PositionGetTicket();       |
//|    DrawTradeExit used DEAL_POSITION_ID. On netting accounts POSITION_TICKET can  |
//|    diverge from POSITION_IDENTIFIER after partial close/modification, breaking   |
//|    SL/TP line updates and exit markers. Fix: ManagePositions now derives         |
//|    posId = POSITION_IDENTIFIER for all visual calls; other sites already use     |
//|    the stable identifier (res.order == DEAL_POSITION_ID for market orders).      |
//|                                                                                   |
//|  [V8-18] RETRY-SLTP-RECLAMP: SL/TP re-clamped on each requote retry             |
//|    trade_Send() refreshed req.price on requote/price-changed retries but kept    |
//|    the attempt-1 SL/TP clamping. If price moved materially, stops could fall     |
//|    inside broker minDist relative to the new price. Fix: SL/TP are reset to the  |
//|    caller's original values and re-clamped against the refreshed fill price on   |
//|    every retry; outSL/outTP reflect the final values actually submitted.          |
//|                                                                                   |
//|  [V8-18] CALCLOT-ROBUST-RISK: OrderCalcProfit replaces tick-value shortcut      |
//|    CalcLot() derived per-point value from SYMBOL_TRADE_TICK_VALUE*_Point/tickSize|
//|    — unreliable on CFDs, futures, and brokers with inconsistent tick metadata.   |
//|    Fix: OrderCalcProfit estimates the actual account-currency loss for 1 lot at  |
//|    the SL price, giving a broker-correct risk basis. Margin fallback retained.   |
//|                                                                                   |
//|  [V8-18] EQUITY-GUARD-INSTANCE-SCOPE: equity guards use session-open balance    |
//|    CheckRiskConditions() compared equity to live ACCOUNT_BALANCE (account-wide), |
//|    but halt state is persisted per-instance. In multi-symbol deployment, one     |
//|    instance's P&L could trigger another instance's equity halt. Fix: equity      |
//|    guards now reference g_dayStartBalance (this instance's session-open snapshot)|
//|    so all risk guards are consistently instance-scoped.                           |
//|                                                                                   |
//|  [V8-17] DAYSTART-BALANCE-PERSIST: g_dayStartBalance persisted in GV           |
//|    Not included in RiskStateSave/Load. OnInit() always wrote current balance    |
//|    as the session baseline; after a mid-session restart, daily loss was measured |
//|    from the post-loss restart balance, potentially allowing the full configured   |
//|    daily drawdown on top of losses already incurred. Fix: GVKey("DayStartBal")  |
//|    added to both Save and Load; restore log extended with DayStartBal field.     |
//|                                                                                   |
//|  [V8-17] SIZERED-SL-DECREMENT: penalty counter ticks on all trade closes        |
//|    g_sizeReductionLeft only decremented on win/neutral closes; SL hits left it   |
//|    frozen. A losing streak during the penalty phase extended the half-size        |
//|    penalty indefinitely, violating the "N trades at half-size" contract.          |
//|    Fix: decrement added to the isSLHit branch of OnTradeTransaction().           |
//|                                                                                   |
//|  [V8-17] PENDING-EXPIRY-MULTIPOS: per-order pending expiry tracking             |
//|    Single scalar g_pendingPlacedBarTime was overwritten by each new pending.     |
//|    With InpMaxPositions > 1 and InpCleanOldOrders = false, earlier orders never  |
//|    expired independently. Fix: parallel arrays g_pendingTickets/g_pendingBarTimes|
//|    track per-ticket placement times; expiry loop deletes per-order, not bulk.    |
//|                                                                                   |
//|  [V8-17] RELOAD-VISUAL-LEAK: CleanupAllTradeObjects on chart-change reload      |
//|    g_needs_reload path did not call CleanupAllTradeObjects(), leaving orphaned   |
//|    SL/TP lines, arrows, and labels after every timeframe switch. Fix: cleanup    |
//|    called before ReloadHistory(), guarded by CountOpenPositions()==0 to preserve |
//|    live position annotations during g_hasTrades reclassification reloads.        |
//|                                                                                   |
//|  [V8-17] CALCLOT-MARGIN-ORDERTYPE: direction-correct margin fallback            |
//|    CalcLot() hardcoded ORDER_TYPE_BUY in the margin-fallback path regardless of  |
//|    trade direction. On instruments with asymmetric margin, sell-lot calculations  |
//|    used the wrong requirement. Fix: isBuy parameter added to CalcLot(); call     |
//|    site in PlaceOrders() passes direction; OrderCalcMargin uses correct type.    |
//|                                                                                   |
//|  [V8-16] LOGEXEC-GATE: LogTradeExec gate lowered to LOG_TRADES_ONLY         |
//|    LogTradeExec was gated at LOG_SIGNALS, making ORDER PLACED, CalcLot,      |
//|    spread filter blocks, BuyStop/SellStop skips, and SLTP-CLAMP warnings     |
//|    invisible at LOG_TRADES_ONLY. Fix: gate matches LogWarning / LogRisk.     |
//|                                                                               |
//|  [V8-16] ATR-PERIOD-VALIDATE: InpATR_Period validated in OnInit()            |
//|    InpATR_Period had no bounds check. Value <= 0 caused iATR() to return     |
//|    INVALID_HANDLE; all ATR features (SL/TP, adaptive threshold, spread ATR   |
//|    filter) silently degraded with no alert. Fix: INIT_PARAMETERS_INCORRECT   |
//|    on InpATR_Period < 1, consistent with all other indicator inputs.          |
//|                                                                               |
//|  [V8-16] BANNER-STALE: file header banner updated to v8.16                   |
//|    Lines 2–6 still read v8.13 after two patch cycles. Fix: updated.          |
//|                                                                               |
//|  [V8-16] TP-FORMAT-ASYMMETRY: isTPHit expanded with full-text TP variants    |
//|    V8-15 SL-SLASH-FORMAT added "stop loss"/"stop-loss" to isSLHit but its   |
//|    stated isTPHit symmetry omitted "take profit"/"take-profit". A broker      |
//|    writing "take profit" left the mutual-exclusion guard incomplete; a TP      |
//|    close with negative net could be misclassified as an SL hit and inflate   |
//|    g_consecutiveLosses. Fix: isTPHit gains both variants; isSLHit guard       |
//|    rewritten as && !isTPHit (single evaluation, four variants covered).       |
//|                                                                               |
//|  [V8-15] EQUITY-HALT-RECOVER: g_equityHalted resets on new trading day     |
//|    Once set, g_equityHalted was never cleared — acting as a permanent kill   |
//|    switch with no documented recovery path. Fix: reset in CheckNewDay()      |
//|    alongside g_dailyLossHalted / g_sessionHalted. If the threshold is still  |
//|    breached at the first CheckRiskConditions() of the new day, the halt is   |
//|    immediately re-applied using the fresh post-settlement balance snapshot.   |
//|                                                                               |
//|  [V8-15] SPINWAIT-CPU: Sleep(10) replaces spin-wait in retry loops           |
//|    The spin-wait introduced in v8.27/v8.28 blocks the tick thread identically |
//|    to Sleep() in MQL5's single-threaded model, but burns 100% CPU for ≤150ms |
//|    across 3 retries. Sleep(10) is sufficient for broker price refresh.        |
//|                                                                               |
//|  [V8-15] NAKED-POC-STALE: ComputeNakedPOCs() called on every bar close       |
//|    NakedPOC labels in conviction strings and logs went stale intraday as new  |
//|    bars retested prior POC prices. Fix: call ComputeNakedPOCs() once per bar  |
//|    close in OnTick() before PlaceOrders(). Cost: O(n log n) per bar.         |
//|                                                                               |
//|  [V8-15] SIZE-RED-NEWDAY: g_sizeReductionLeft reset on new trading day       |
//|    The 50%-size penalty was not cleared in CheckNewDay(), silently carrying   |
//|    an intraday consecutive-loss penalty into the next session indefinitely.   |
//|    Fix: reset alongside g_consecutiveLosses in CheckNewDay().                 |
//|                                                                               |
//|  [V8-15] SL-SLASH-FORMAT: broker "s/l" / "stop loss" comment formats added  |
//|    StringFind(commentTail,"sl") missed brokers writing "s/l", "stop loss",   |
//|    "stop-loss". SL hits from these brokers fell through to the neutral branch,|
//|    silently failing to increment g_consecutiveLosses. Fix: all common formats |
//|    added to isSLHit; matching t/p expansion applied to isTPHit for symmetry.  |
//|                                                                               |
//|  [V8-29] ABSLOW-SL-FP: false SL-hit from "AbsLow" label in      |
//|    OnTradeTransaction() used StringFind(commentLower,"sl") across  |
//|    the full comment. The label "AbsLow" lowercases to "abslow"    |
//|    which contains "sl" at position 2 — misclassifying every TP    |
//|    or manual close on an AbsLow-tagged order as an SL hit,        |
//|    silently inflating g_consecutiveLosses and potentially          |
//|    triggering a spurious session halt.                             |
//|    Fix: scope search to commentTail (text after last "|"), where  |
//|    the broker appends its exit reason. Label tokens in earlier     |
//|    segments are no longer scanned.                                 |
//|                                                                    |
//|  [V8-29] DEAD-VAR-SIGBAR: removed unused global g_lastSignalBar. |
//|    The variable was written in three places but never read.        |
//|    The signal frequency gate uses g_lastSignalBarTime + iBarShift |
//|    exclusively. Dead variable since the bar-time gate was adopted. |
//|                                                                    |
//|  Inherited from v7.00:                                             |
//|    V7-01 True risk-based lot sizing                                |
//|    V7-02 HTF trend filter                                          |
//|    V7-03 Session time filter                                       |
//|    V7-04 Daily loss limit                                          |
//|    V7-05 Consecutive loss protection                               |
//|    V7-06 Adaptive signal threshold                                 |
//|    V7-07 Conviction diversity gate                                 |
//|    V7-08 SL cooldown per direction                                 |
//|    V7-09 Absorption volume gate                                    |
//|    V7-10 ATR-relative spread check                                 |
//|    V7-11 Pending order staleness timeout                           |
//|    V7-12 Recalibrated HFT weights (C4: 10%, C6: 15%)             |
//|    V7-13 Modular PlaceOrders / ConvictionResult struct             |
//+------------------------------------------------------------------+
#property copyright   "Ali Magdy"
#property version     "8.20"
#property description "Order Flow EA v8.20 — Production-Grade (Code Review Fixes Applied)"
#property strict

// [V8-18] Single source of truth for the EA version string.
#define EA_VERSION "8.20"
#define EA_NAME    "OrderFlowEA v" EA_VERSION

//==========================================================================
// SECTION 1: ENUMERATIONS
//==========================================================================

enum ENUM_FOOT_CHART_MODE
  {
   FOOT_CHART_VOLUME = 0,
   FOOT_CHART_DELTA  = 1,
   FOOT_CHART_BIDASK = 2
  };

enum ENUM_ORDER_MODE
  {
   ORDER_MODE_MARKET  = 0,
   ORDER_MODE_PENDING = 1
  };

enum ENUM_SL_MODE
  {
   SL_MODE_BAR  = 0,
   SL_MODE_PIPS = 1,
   SL_MODE_ATR  = 2
  };

enum ENUM_TP_MODE
  {
   TP_MODE_RR   = 0,
   TP_MODE_PIPS = 1,
   TP_MODE_ATR  = 2
  };

enum ENUM_LOG_MODE
  {
   LOG_SILENT      = 0,
   LOG_TRADES_ONLY = 1,
   LOG_SIGNALS     = 2,
   LOG_FULL        = 3
  };

//==========================================================================
// SECTION 2: INPUTS
//==========================================================================

input group "━━━━━━━━━━━━━━━  Logging  ━━━━━━━━━━━━━━━"
input bool          InpLoggingEnable = true;      // Write EA messages to the MT5 journal
input ENUM_LOG_MODE InpLogMode       = LOG_FULL;  // Verbosity: Silent | Trades only | Signals | Full

input group "━━━━━━━━━━━━━━━  Footprint Data & History  ━━━━━━━━━━━━━━━"
input int    InpTickSize        = 10;    // Price level bucket size in points (e.g. 10 = 1 pip on 5-digit)
input double InpImbalanceRatio  = 300.0; // Diagonal imbalance threshold — ask[i]/bid[i+1] must exceed X% to flag
input int    InpStackedImbCount = 3;     // Consecutive imbalanced cells required to confirm a stacked imbalance
input double InpAbsorptionRatio = 4.0;  // Absorption threshold — level volume must exceed X× bar average volume
input double InpAbsVolMult      = 2.0;  // Absorption dominance — absorbing side must be X× the opposing side [V7-09]
input int    InpHistoryBars     = 200;  // Number of completed bars of tick history to load on startup
input double InpVAPercent       = 70.0; // Value Area coverage as a percent of total bar volume (typically 70%)
input double InpHVNRatio        = 2.0;  // High Volume Node threshold — level must be X× the bar average volume
input double InpLVNRatio        = 0.35; // Low Volume Node threshold — level must be ≤ X× the bar average volume

input group "━━━━━━━━━━━━━━━  Aggregation  ━━━━━━━━━━━━━━━"
input ENUM_FOOT_CHART_MODE InpChartMode      = FOOT_CHART_DELTA; // Footprint display: Volume | Delta | Bid/Ask
input int                  InpTickMultiplier = 5;                 // Bucket width multiplier (effective step = TickSize × Mult)

input group "━━━━━━━━━━━━━━━  Bid/Ask Exhaustion Signal  ━━━━━━━━━━━━━━━"
input bool   InpExhaustionEnable  = true;  // Enable bid/ask exhaustion detection at bar extremes
input int    InpExhaustionCells   = 3;     // Consecutive near-zero cells needed to confirm exhaustion
input double InpExhaustionZeroRat = 0.05; // Exhaustion sensitivity — cell volume ≤ X× average flags as near-zero

input group "━━━━━━━━━━━━━━━  Order Flow Score (OFS) Weights  ━━━━━━━━━━━━━━━"
input double InpOFWtDelta         = 40.0; // OFS component weight: Net delta ratio (%)
input double InpOFWtImb           = 25.0; // OFS component weight: Diagonal imbalance direction (%)
input double InpOFWtStacked       = 20.0; // OFS component weight: Stacked imbalances present (%)
input double InpOFWtAbsorb        = 15.0; // OFS component weight: Absorption detected (%)

input group "━━━━━━━━━━━━━━━  Signal Alerts  ━━━━━━━━━━━━━━━"
input bool   InpShowSignals       = false; // Draw signal arrows and labels on the chart in real time
input int    InpSignalThreshold   = 60;   // Minimum HFT composite score to fire a signal (range 1–99)
input int    InpSignalFreqBars    = 3;    // Minimum bars between consecutive signal alerts (debounce)
input string InpSignalBuySound    = "";   // Alert sound file for a BUY signal (empty = silent)
input string InpSignalSellSound   = "";   // Alert sound file for a SELL signal (empty = silent)

input group "━━━━━━━━━━━━━━━  V7 — Signal Quality Filters  ━━━━━━━━━━━━━━━"
input int    InpMinConvictionComp   = 0;    // Min distinct conviction sources required to trade (0 = disabled) [V7-07]
input bool   InpAdaptiveThreshold   = false; // Scale the signal threshold up/down with ATR volatility [V7-06]
input double InpAdaptiveThreshMin   = 35.0;  // Adaptive threshold floor — score cannot fall below this [V7-06]
input double InpAdaptiveThreshMax   = 75.0;  // Adaptive threshold ceiling — score cannot rise above this [V7-06]
input int    InpSLCooldownBars      = 0;    // Bars to block re-entry in the same direction after a stop-loss (0 = off) [V7-08]
// [V8-22] DELTA-THRESHOLD: exposed as an input for consistency with all other signal thresholds.
input double InpDeltaConvThreshold  = 0.35; // Strong net-delta conviction threshold — delta ratio must exceed this (0–1) [V8-22]

input group "━━━━━━━━━━━━━━━  V7 — Higher-Timeframe Trend Filter  ━━━━━━━━━━━━━━━"
input bool            InpHTFEnable  = false;     // Only trade in the direction of the HTF EMA trend [V7-02]
input ENUM_TIMEFRAMES InpHTFPeriod  = PERIOD_H1; // Higher timeframe used for the trend EMA
input int             InpHTFEMA     = 50;         // EMA period on the higher timeframe (e.g. 50, 100, 200)

input group "━━━━━━━━━━━━━━━  V7 — Session Time Filter  ━━━━━━━━━━━━━━━"
input bool   InpSessionEnable    = false; // Restrict automated trading to a defined time window [V7-03]
input int    InpSessionStartHour = 7;     // Session open — broker server hour, inclusive (e.g. 7 = 07:00 server time) [V8-11]
input int    InpSessionEndHour   = 17;    // Session close — broker server hour, exclusive (e.g. 17 = up to 16:59 server time) [V8-11]

input group "━━━━━━━━━━━━━━━  Automated Trading — Core  ━━━━━━━━━━━━━━━"
input bool            InpAnalysisMode      = false;             // Analysis mode: visualise signals without sending live orders
input bool            InpATEnable          = true;              // Enable fully automated order placement
input ENUM_ORDER_MODE InpOrderMode         = ORDER_MODE_MARKET; // Order type: Market execution | Stop-limit pending
input int             InpATR_Period        = 14;                // ATR indicator period used for SL/TP and spread filter
input bool            InpSpreadFilter      = true;              // Block new entries when the spread exceeds defined limits
input double          InpMaxSpread         = 3.0;               // Maximum allowable spread in pips (absolute limit)
input double          InpSpreadATRRatio    = 0.0;               // Maximum spread as a fraction of ATR (0 = disabled) [V7-10]
input bool            InpAllowBuy          = true;              // Allow long (buy) trade entries
input bool            InpAllowSell         = true;              // Allow short (sell) trade entries
input double          InpBufferPips        = 3.0;               // Buffer above/below the signal bar high/low for pending entry (pips)
input int             InpPendingExpiryBars = 0;                 // Delete unfilled pending orders after N bars (0 = never expire) [V7-11]

input group "━━━━━━━━━━━━━━━  Automated Trading — Position Sizing  ━━━━━━━━━━━━━━━"
input bool   InpUseRiskPercent    = true; // Size positions by percent risk (true) or use a fixed lot (false)
input double InpRiskPercent       = 1.0;  // Risk per trade as a percentage of account balance [V7-01]
input double InpFixedLot          = 0.1;  // Fixed lot size applied when risk-percent sizing is disabled

input group "━━━━━━━━━━━━━━━  Automated Trading — Stop Loss  ━━━━━━━━━━━━━━━"
input bool         InpUseStopLoss = true;        // Attach a stop-loss to every opened trade
input ENUM_SL_MODE InpSLMode      = SL_MODE_ATR; // SL placement: Bar high/low | Fixed pips | ATR multiple
input double       InpSLPips      = 20.0;         // Stop-loss distance in pips (used in Pips mode)
input double       InpSLATRMult   = 1.5;          // Stop-loss as an ATR multiple (used in ATR mode, e.g. 1.5× ATR)

input group "━━━━━━━━━━━━━━━  Automated Trading — Take Profit  ━━━━━━━━━━━━━━━"
input bool         InpUseTakeProfit   = true;       // Attach a take-profit to every opened trade
input ENUM_TP_MODE InpTPMode          = TP_MODE_RR; // TP placement: Risk:Reward ratio | Fixed pips | ATR multiple
input double       InpRiskRewardRatio = 2.0;         // Reward-to-risk ratio for TP (used in R:R mode, e.g. 2.0 = 2:1)
input double       InpTPPips          = 40.0;        // Take-profit distance in pips (used in Pips mode)
input double       InpTPATRMult       = 3.0;         // Take-profit as an ATR multiple (used in ATR mode, e.g. 3.0× ATR)

input group "━━━━━━━━━━━━━━━  Automated Trading — Trade Management  ━━━━━━━━━━━━━━━"
input bool   InpUseBreakEven      = true; // Move stop-loss to break-even once a profit target is reached
input double InpBreakEvenTrigger  = 15.0; // Profit in pips required to trigger the break-even move
input double InpBreakEvenBuffer   = 2.0;  // Pips above/below entry price for the break-even stop placement
input bool   InpUseTrailing       = true; // Enable a trailing stop that follows price after activation
input double InpTrailStart        = 20.0; // Profit in pips before the trailing stop activates
input double InpTrailStep         = 5.0;  // Trailing stop step size in pips (how often the SL ratchets)

input group "━━━━━━━━━━━━━━━  Automated Trading — Account Safety  ━━━━━━━━━━━━━━━"
input double InpMaxEquityProfit      = 3000.0; // Halt all trading when open P&L exceeds this value in account currency (0 = off)
input double InpMaxEquityLoss        = 1500.0; // Halt all trading when open drawdown exceeds this value in account currency (0 = off)
input double InpMaxDailyLossPercent  = 0.0;    // Halt trading for the day when daily loss exceeds X% of start balance (0 = off) [V7-04]
input int    InpMaxConsecLosses      = 0;       // Consecutive stop-loss hits before activating 50% size reduction (0 = off) [V7-05]
input int    InpHaltConsecLosses     = 0;       // Consecutive stop-loss hits to halt trading for the full session (0 = off) [V7-05]
input int    InpSizeReductionTrades  = 3;       // Number of trades to trade at half-size after the consecutive-loss limit [V7-05]
input bool   InpCleanOldOrders       = true;    // Delete the EA's own pending orders before placing a new signal order
input int    InpMaxPositions         = 1;       // Maximum number of concurrent open positions allowed for this EA
input ulong  InpMagic                = 20260226; // Magic number — unique identifier for this EA instance's orders

input group "━━━━━━━━━━━━━━━  Visuals  ━━━━━━━━━━━━━━━"
input bool  InpShowVisuals     = true;               // Enable all chart drawings (arrows, labels, lines)
input bool  InpShowSLTPLines   = true;               // Draw horizontal SL and TP lines for each open trade
input bool  InpShowEntryLabel  = true;               // Show entry annotation with HFT score and conviction label
input bool  InpShowExitLabel   = true;               // Show exit annotation with net P&L
input color InpVizBuyColor     = clrDodgerBlue;      // Colour for buy entry arrows and labels
input color InpVizSellColor    = clrOrangeRed;       // Colour for sell entry arrows and labels
input color InpVizSLColor      = clrFireBrick;       // Colour for stop-loss lines
input color InpVizTPColor      = clrMediumSeaGreen;  // Colour for take-profit lines

//==========================================================================
// SECTION 3: DATA STRUCTURES
//==========================================================================

struct PriceLevel
  {
   double price;
   long   bid_vol;
   long   ask_vol;
   long   total_vol;
   long   delta;
   bool   is_imb_buy;
   bool   is_imb_sell;
   bool   is_absorption;
   bool   is_stacked_imb_buy;
   bool   is_stacked_imb_sell;
   bool   is_unfinished_hi;
   bool   is_unfinished_lo;
   bool   is_hvn;
   bool   is_lvn;
   bool   is_exhaustion_bid;
   bool   is_exhaustion_ask;
  };

struct FPBar
  {
   datetime   bar_time;
   long       total_vol;
   long       total_delta;
   double     high;
   double     low;
   int        poc_idx;
   int        va_lo_idx;
   int        va_hi_idx;
   bool       sorted;
   bool       is_bullish;
   int        level_count;
   bool       is_delta_divergence;
   bool       is_naked_poc;
   // [V8-23] TICK-SEARCH: O(1) price-to-level lookup.
   //    levelMap[gridIdx - levelMapBase] = index into levels[], or -1 if unoccupied.
   //    Eliminates the O(levels) reverse linear scan on every in-range tick.
   int        levelMapBase;   // absolute grid index of the first map slot
   int        levelMap[];     // maps relative offset → levels[] index; -1 = empty
   PriceLevel levels[];
  };

// [V7-13] Conviction result carries both display label and component count
// so the diversity gate (InpMinConvictionComp) can be applied without
// re-scanning the bar flags a second time.
struct ConvictionResult
  {
   string label;          // Display string (e.g. "AbsLow+StackBuy+DeltaDiv")
   int    componentCount; // Number of distinct conviction components found
  };

//==========================================================================
// SECTION 4: GLOBALS
//==========================================================================

// --- Core data state ---
FPBar  g_bars[];
double g_step;
double g_baseStep;
int    g_basePts  = 10;
int    g_tickMult = 1;
long   g_chart;
bool   g_hasTrades;
double g_prevBid;
double g_imbRatio;
long   g_last_tick_time_ms = 0;
bool   g_needs_reload      = false;
int    g_histBars          = 100;
double g_vaPercent         = 0.0;

// --- Signal state ---
bool     g_signalsEnabled    = true;
int      g_signalFreqBars    = 5;
int      g_signalThreshold   = 50;
datetime g_lastSignalBarTime = 0;

// --- Automated trading state ---
bool     g_autoTrade   = false;
ulong    g_Magic       = 20260226;
datetime g_LastBarTime = 0;
int      g_handleATR   = INVALID_HANDLE;
double   g_Pip         = 0.0001;
double   g_VolMin      = 0.01;
double   g_VolMax      = 100.0;
double   g_VolStep     = 0.01;

// --- Analysis Mode state ---
bool  g_analysisMode  = false;
ulong g_virtualTicket = 900000000UL;

// --- Signal marker state ---
ulong g_sigMarkerCount = 800000000UL;

// --- Performance caches ---
int   g_sigCacheBarIdx = -1;
long  g_sigCacheVol    = -1;

// --- Throttle ---
ulong g_lastManageTick = 0;

// [V7-02] HTF trend filter handle
int   g_htfEMAHandle = INVALID_HANDLE;

// [V7-06] ATR baseline for adaptive threshold
double g_atrBaseline      = 0.0;
bool   g_atrBaselineReady = false;

// [V7-04] Daily loss tracking
double   g_dayStartBalance = 0.0;
int      g_dayStartDay     = -1;
bool     g_dailyLossHalted = false;

// [V7-05] Consecutive loss tracking
int  g_consecutiveLosses  = 0;
int  g_sizeReductionLeft  = 0;   // trades remaining at 50% size
bool g_sessionHalted      = false;

// [V8-26] EQUITY-HALT-PERSIST: dedicated flag for equity-guard halts.
//    Replaces the old g_autoTrade=false approach so ManagePositions() keeps
//    running on open positions and the halt survives EA restarts/reconnects.
bool g_equityHalted       = false;

// [V7-08] Per-direction SL cooldown (stores bar_time of last SL hit)
datetime g_lastSLBarTimeBuy  = 0;
datetime g_lastSLBarTimeSell = 0;

// [V8-22] NEWDAY-DEFER: deadline for new-day deferral (set on first defer tick)
datetime g_newDayDeferStart = 0;

// [V7-11] Pending order placement tracking (bar_time when pending was placed)
datetime g_pendingPlacedBarTime = 0;
// [V8-17] PENDING-EXPIRY-MULTIPOS: per-ticket placement tracking replaces the scalar
//    timestamp so expiry fires independently for each pending regardless of InpMaxPositions.
ulong    g_pendingTickets[];
datetime g_pendingBarTimes[];

#define FP_HIST_MIN        1
#define FP_HIST_MAX        5000
#define FP_MANAGE_THROTTLE 250

// [V8-10] GlobalVariable key helpers for risk-state persistence across EA restarts.
//   Keys are scoped to account login + magic number + symbol so that two EA instances
//   running on different accounts inside the same MT5 terminal never share state.
//   MT5 GlobalVariables are terminal-wide (not account-scoped), so without the login
//   component one account could load halt/counter state written by another account.
//   [V8-19] GVKEY-ACCOUNT-SCOPE: AccountInfoInteger(ACCOUNT_LOGIN) added to prefix.
string GVKey(const string field)
  { return StringFormat("FPEA_%I64u_%I64u_%s_%s",
                        (ulong)AccountInfoInteger(ACCOUNT_LOGIN),
                        (ulong)InpMagic, _Symbol, field); }

void RiskStateSave()
  {
   GlobalVariableSet(GVKey("ConsecLoss"),    (double)g_consecutiveLosses);
   GlobalVariableSet(GVKey("SizeRedLeft"),   (double)g_sizeReductionLeft);
   GlobalVariableSet(GVKey("SessHalted"),    g_sessionHalted    ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("DayLossHalted"), g_dailyLossHalted  ? 1.0 : 0.0);
   // [V8-20] Persist calendar day so CheckNewDay() can distinguish a genuine new-day
   //    rollover from a same-day restart. Without this, g_dayStartDay is always -1 on
   //    startup, causing CheckNewDay() to wipe V8-10 restored risk state every time the
   //    EA restarts on the same calendar day.
   GlobalVariableSet(GVKey("DayStartDay"),   (double)g_dayStartDay);
   // [V8-21] CARRY-CTR: persist chart-object name counters so a crash-restart does not
   //    reset them to their hardcoded values and silently collide with objects from the
   //    prior session (ObjectCreate fails silently, leaving stale markers on the chart).
   GlobalVariableSet(GVKey("SigMarkerCnt"),  (double)g_sigMarkerCount);
   GlobalVariableSet(GVKey("VirtualTicket"), (double)g_virtualTicket);
   // [V8-22] SL-COOLDOWN-PERSIST: persist per-direction SL timestamps so
   //    InpSLCooldownBars protection survives EA restarts and crashes.
   GlobalVariableSet(GVKey("LastSLBuy"),  (double)g_lastSLBarTimeBuy);
   GlobalVariableSet(GVKey("LastSLSell"), (double)g_lastSLBarTimeSell);
   // [V8-23] NEWDAY-DEFER-PERSIST: persist the defer-start timestamp so a crash or
   //    VPS reboot during a weekend-gap deferral does not silently reset the 24-hour
   //    deadline clock, allowing repeated restarts to prevent the snapshot indefinitely.
   GlobalVariableSet(GVKey("NewDayDefer"), (double)g_newDayDeferStart);
   // [V8-26] EQUITY-HALT-PERSIST: persist equity halt so a restart cannot silently
   //    re-enable trading while an equity profit/loss threshold is still breached.
   GlobalVariableSet(GVKey("EquityHalted"), g_equityHalted ? 1.0 : 0.0);
   // [V8-17] DAYSTART-BALANCE-PERSIST: persist the session-open balance snapshot so a
   //    mid-session restart measures daily loss from the true open, not the restart balance.
   //    Without this, RiskStateLoad() restores g_dayStartDay = today, CheckNewDay() exits
   //    early, and g_dayStartBalance stays at the OnInit() fallback (current balance).
   GlobalVariableSet(GVKey("DayStartBal"), g_dayStartBalance);
  }

void RiskStateLoad()
  {
   if(GlobalVariableCheck(GVKey("ConsecLoss")))
      g_consecutiveLosses = (int)GlobalVariableGet(GVKey("ConsecLoss"));
   if(GlobalVariableCheck(GVKey("SizeRedLeft")))
      g_sizeReductionLeft = (int)GlobalVariableGet(GVKey("SizeRedLeft"));
   if(GlobalVariableCheck(GVKey("SessHalted")))
      g_sessionHalted     = (GlobalVariableGet(GVKey("SessHalted")) != 0.0);
   if(GlobalVariableCheck(GVKey("DayLossHalted")))
      g_dailyLossHalted   = (GlobalVariableGet(GVKey("DayLossHalted")) != 0.0);
   // [V8-20] Restore the calendar day so CheckNewDay() returns early on same-day restarts.
   if(GlobalVariableCheck(GVKey("DayStartDay")))
      g_dayStartDay = (int)GlobalVariableGet(GVKey("DayStartDay"));
   // [V8-21] CARRY-CTR: restore chart-object counters so new objects use names that do
   //    not collide with any objects still on the chart from the crashed session.
   if(GlobalVariableCheck(GVKey("SigMarkerCnt")))
      g_sigMarkerCount = (ulong)GlobalVariableGet(GVKey("SigMarkerCnt"));
   if(GlobalVariableCheck(GVKey("VirtualTicket")))
      g_virtualTicket  = (ulong)GlobalVariableGet(GVKey("VirtualTicket"));
   // [V8-22] SL-COOLDOWN-PERSIST: restore SL timestamps so the cooldown gate
   //    remains active across restarts for the correct number of bars.
   if(GlobalVariableCheck(GVKey("LastSLBuy")))
      g_lastSLBarTimeBuy  = (datetime)GlobalVariableGet(GVKey("LastSLBuy"));
   if(GlobalVariableCheck(GVKey("LastSLSell")))
      g_lastSLBarTimeSell = (datetime)GlobalVariableGet(GVKey("LastSLSell"));
   // [V8-23] NEWDAY-DEFER-PERSIST: restore the defer-start timestamp so the 24-hour
   //    deadline continues from its original start after a restart, not from the
   //    restart time. Without this, repeated restarts effectively reset the clock.
   if(GlobalVariableCheck(GVKey("NewDayDefer")))
      g_newDayDeferStart = (datetime)GlobalVariableGet(GVKey("NewDayDefer"));
   // [V8-26] EQUITY-HALT-PERSIST: restore equity halt state.
   if(GlobalVariableCheck(GVKey("EquityHalted")))
      g_equityHalted = (GlobalVariableGet(GVKey("EquityHalted")) != 0.0);
   // [V8-17] DAYSTART-BALANCE-PERSIST: restore session-open balance.
   if(GlobalVariableCheck(GVKey("DayStartBal")))
      g_dayStartBalance = GlobalVariableGet(GVKey("DayStartBal"));
   // [V8-24] RISKLOAD-LOG-COND: condition extended to include SL timestamps.
   //    Previously the log only fired when a loss-streak variable was non-default.
   //    After a restart with only SL cooldown active (no consecutive losses) the
   //    log was silent — the user could not confirm from the journal that the
   //    cooldown had been recovered.
   if(g_consecutiveLosses > 0 || g_sizeReductionLeft > 0 ||
      g_sessionHalted || g_dailyLossHalted || g_equityHalted ||
      g_lastSLBarTimeBuy > 0 || g_lastSLBarTimeSell > 0)
      LogRisk(StringFormat(
         "[V8-10] Risk state restored from GlobalVariables | ConsecLoss=%d | SizeRedLeft=%d"
         " | SessHalted=%s | DayLossHalted=%s | EquityHalted=%s | DayStartDay=%d"
         " | DayStartBal=%.2f | LastSLBuy=%s | LastSLSell=%s",  // [V8-17]
         g_consecutiveLosses, g_sizeReductionLeft,
         g_sessionHalted   ?"YES":"NO",
         g_dailyLossHalted ?"YES":"NO",
         g_equityHalted    ?"YES":"NO",
         g_dayStartDay,
         g_dayStartBalance,
         (g_lastSLBarTimeBuy  > 0 ? TimeToString(g_lastSLBarTimeBuy,  TIME_DATE|TIME_MINUTES) : "none"),
         (g_lastSLBarTimeSell > 0 ? TimeToString(g_lastSLBarTimeSell, TIME_DATE|TIME_MINUTES) : "none")));
  }

// [V8-22] CTR-ANALYSIS: lightweight counter flush called on every signal draw so
//    g_sigMarkerCount is always current in GlobalVariables even in analysis mode
//    (where OnTradeTransaction never fires and RiskStateSave is never called).
void CounterSave()
  {
   GlobalVariableSet(GVKey("SigMarkerCnt"),  (double)g_sigMarkerCount);
   GlobalVariableSet(GVKey("VirtualTicket"), (double)g_virtualTicket);
  }


//==========================================================================
// SECTION 5: LOGGING HELPERS
//==========================================================================

void LogSystem(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_FULL) return;
   Print(msg);
  }

void LogWarning(const string msg)
  {
   // [V8-17] Gate lowered to LOG_TRADES_ONLY: warnings affect trade decisions and
   //    must be visible to any user who has trade-level logging enabled.
   if(!InpLoggingEnable || InpLogMode < LOG_TRADES_ONLY) return;
   Print("[WARN] ", msg);
  }

void LogSignal(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_SIGNALS) return;
   Print("[SIGNAL] ", msg);
  }

void LogTradeExec(const string msg)
  {
   // [V8-16] LOGEXEC-GATE: gate lowered to LOG_TRADES_ONLY.
   //    Order placement, lot sizing, spread filter blocks, BuyStop/SellStop skips,
   //    and SLTP-CLAMP events are all execution-level trade facts. They must be
   //    visible to any user who has trade-level logging enabled, matching the intent
   //    of the V8-17 gate fixes applied to LogWarning and LogRisk.
   if(!InpLoggingEnable || InpLogMode < LOG_TRADES_ONLY) return;
   Print("[EXEC] ", msg);
  }

void LogTradeClosed(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_TRADES_ONLY) return;
   Print("[TRADE] ", msg);
  }

void LogRisk(const string msg)
  {
   // [V8-17] Gate lowered to LOG_TRADES_ONLY: risk events (session halt, consecutive
   //    loss counter, size reduction) directly affect whether orders are placed.
   //    Previously gated on LOG_FULL, making them invisible at LOG_TRADES_ONLY.
   if(!InpLoggingEnable || InpLogMode < LOG_TRADES_ONLY) return;
   Print("[RISK] ", msg);
  }

//==========================================================================
// SECTION 6: VISUAL HELPERS
//==========================================================================

string ObjName(const string prefix, ulong ticket)
  { return StringFormat("FP_%s_%I64u", prefix, ticket); }

void DrawTradeEntry(ulong ticket, bool isBuy, double entryPx,
                    double sl, double tp, datetime barTime,
                    const string conviction, int hftScore, int ofsScore)
  {
   if(!InpShowVisuals) return;
   long  chart  = g_chart;
   color clrDir = isBuy ? InpVizBuyColor : InpVizSellColor;
   string dirStr = isBuy ? "BUY" : "SELL";

   string arNm = ObjName("AR", ticket);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, barTime, entryPx))
     {
      ObjectSetInteger(chart, arNm, OBJPROP_ARROWCODE,  isBuy ? 233 : 234);
      ObjectSetInteger(chart, arNm, OBJPROP_COLOR,      clrDir);
      ObjectSetInteger(chart, arNm, OBJPROP_WIDTH,      2);
      ObjectSetInteger(chart, arNm, OBJPROP_SELECTABLE, false);
      ObjectSetString( chart, arNm, OBJPROP_TOOLTIP,
         StringFormat("%s ENTRY | #%I64u\nHFT: %d  OFS: %d\nConviction: %s\nEntry: %s",
                      dirStr, ticket, hftScore, ofsScore, conviction,
                      DoubleToString(entryPx, _Digits)));
     }

   if(InpShowSLTPLines)
     {
      if(sl > 0.0)
        {
         string slNm = ObjName("SL", ticket);
         if(ObjectCreate(chart, slNm, OBJ_HLINE, 0, 0, sl))
           {
            ObjectSetInteger(chart, slNm, OBJPROP_COLOR,      InpVizSLColor);
            ObjectSetInteger(chart, slNm, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chart, slNm, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chart, slNm, OBJPROP_SELECTABLE, false);
            ObjectSetString( chart, slNm, OBJPROP_TOOLTIP,
               StringFormat("SL | #%I64u | %s", ticket, DoubleToString(sl, _Digits)));
           }
        }
      if(tp > 0.0)
        {
         string tpNm = ObjName("TP", ticket);
         if(ObjectCreate(chart, tpNm, OBJ_HLINE, 0, 0, tp))
           {
            ObjectSetInteger(chart, tpNm, OBJPROP_COLOR,      InpVizTPColor);
            ObjectSetInteger(chart, tpNm, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chart, tpNm, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chart, tpNm, OBJPROP_SELECTABLE, false);
            ObjectSetString( chart, tpNm, OBJPROP_TOOLTIP,
               StringFormat("TP | #%I64u | %s", ticket, DoubleToString(tp, _Digits)));
           }
        }
     }

   if(InpShowEntryLabel)
     {
      string lbNm = ObjName("EL", ticket);
      string txt  = StringFormat("%s  HFT:%d OFS:%d\n%s",
                                 (isBuy ? "▲" : "▼"), hftScore, ofsScore, conviction);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, barTime, entryPx))
        {
         ObjectSetString( chart, lbNm, OBJPROP_TEXT,      txt);
         ObjectSetInteger(chart, lbNm, OBJPROP_COLOR,     clrDir);
         ObjectSetInteger(chart, lbNm, OBJPROP_FONTSIZE,  8);
         ObjectSetString( chart, lbNm, OBJPROP_FONT,      "Consolas");
         ObjectSetInteger(chart, lbNm, OBJPROP_ANCHOR,    isBuy ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chart, lbNm, OBJPROP_SELECTABLE,false);
        }
     }
   ChartRedraw(chart);
  }

void DrawAnalysisEntry(ulong vTicket, bool isBuy, double entryPx,
                       double sl, double tp, datetime barTime,
                       const string conviction, int hftScore, int ofsScore)
  {
   if(!InpShowVisuals) return;
   long  chart  = g_chart;
   color clrDir = isBuy ? InpVizBuyColor : InpVizSellColor;
   string dirStr = isBuy ? "BUY" : "SELL";

   string arNm = StringFormat("AN_AR_%I64u", vTicket);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, barTime, entryPx))
     {
      ObjectSetInteger(chart, arNm, OBJPROP_ARROWCODE,  isBuy ? 233 : 234);
      ObjectSetInteger(chart, arNm, OBJPROP_COLOR,      clrDir);
      ObjectSetInteger(chart, arNm, OBJPROP_WIDTH,      2);
      ObjectSetInteger(chart, arNm, OBJPROP_SELECTABLE, false);
      ObjectSetString( chart, arNm, OBJPROP_TOOLTIP,
         StringFormat("[ANALYSIS] %s ENTRY | #V%I64u\nHFT: %d  OFS: %d\nConviction: %s",
                      dirStr, vTicket, hftScore, ofsScore, conviction));
     }

   if(InpShowSLTPLines)
     {
      if(sl > 0.0)
        {
         string slNm = StringFormat("AN_SL_%I64u", vTicket);
         if(ObjectCreate(chart, slNm, OBJ_HLINE, 0, 0, sl))
           { ObjectSetInteger(chart,slNm,OBJPROP_COLOR,InpVizSLColor);
             ObjectSetInteger(chart,slNm,OBJPROP_STYLE,STYLE_DOT);
             ObjectSetInteger(chart,slNm,OBJPROP_WIDTH,1);
             ObjectSetInteger(chart,slNm,OBJPROP_SELECTABLE,false); }
        }
      if(tp > 0.0)
        {
         string tpNm = StringFormat("AN_TP_%I64u", vTicket);
         if(ObjectCreate(chart, tpNm, OBJ_HLINE, 0, 0, tp))
           { ObjectSetInteger(chart,tpNm,OBJPROP_COLOR,InpVizTPColor);
             ObjectSetInteger(chart,tpNm,OBJPROP_STYLE,STYLE_DOT);
             ObjectSetInteger(chart,tpNm,OBJPROP_WIDTH,1);
             ObjectSetInteger(chart,tpNm,OBJPROP_SELECTABLE,false); }
        }
     }

   if(InpShowEntryLabel)
     {
      string lbNm = StringFormat("AN_EL_%I64u", vTicket);
      string txt  = StringFormat("[A] %s  HFT:%d OFS:%d\n%s",
                                 (isBuy ? "▲" : "▼"), hftScore, ofsScore, conviction);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, barTime, entryPx))
        {
         ObjectSetString( chart,lbNm,OBJPROP_TEXT,txt);
         ObjectSetInteger(chart,lbNm,OBJPROP_COLOR,clrDir);
         ObjectSetInteger(chart,lbNm,OBJPROP_FONTSIZE,8);
         ObjectSetString( chart,lbNm,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(chart,lbNm,OBJPROP_ANCHOR,isBuy?ANCHOR_LEFT_UPPER:ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chart,lbNm,OBJPROP_SELECTABLE,false);
        }
     }
   ChartRedraw(chart);
  }

void UpdateSLLine(ulong ticket, double newSL)
  {
   if(!InpShowVisuals || !InpShowSLTPLines) return;
   string nm = ObjName("SL", ticket);
   if(ObjectFind(g_chart, nm) >= 0)
      ObjectSetDouble(g_chart, nm, OBJPROP_PRICE, newSL);
  }

void DrawTradeExit(ulong ticket, bool wasLong, double exitPx,
                   double netPnl, datetime exitTime)
  {
   if(!InpShowVisuals) return;
   long  chart = g_chart;
   bool  win   = (netPnl >= 0.0);
   color clrPnl= win ? clrLime : clrOrangeRed;

   ObjectDelete(chart, ObjName("SL", ticket));
   ObjectDelete(chart, ObjName("TP", ticket));

   string arNm = ObjName("XR", ticket);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, exitTime, exitPx))
     {
      ObjectSetInteger(chart,arNm,OBJPROP_ARROWCODE, wasLong?234:233);
      ObjectSetInteger(chart,arNm,OBJPROP_COLOR,clrPnl);
      ObjectSetInteger(chart,arNm,OBJPROP_WIDTH,2);
      ObjectSetInteger(chart,arNm,OBJPROP_SELECTABLE,false);
      ObjectSetString( chart,arNm,OBJPROP_TOOLTIP,
         StringFormat("EXIT | #%I64u | Net: %.2f [%s]",ticket,netPnl,win?"WIN":"LOSS"));
     }

   if(InpShowExitLabel)
     {
      string lbNm = ObjName("XL", ticket);
      string txt  = StringFormat("%s%.2f", win?"+":"", netPnl);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, exitTime, exitPx))
        {
         ObjectSetString( chart,lbNm,OBJPROP_TEXT,txt);
         ObjectSetInteger(chart,lbNm,OBJPROP_COLOR,clrPnl);
         ObjectSetInteger(chart,lbNm,OBJPROP_FONTSIZE,9);
         ObjectSetString( chart,lbNm,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(chart,lbNm,OBJPROP_ANCHOR,wasLong?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);
         ObjectSetInteger(chart,lbNm,OBJPROP_SELECTABLE,false);
        }
     }
   ChartRedraw(chart);
  }

// [V8-08] CleanupAllTradeObjects — deletes every object family created by this EA.
//    Previously only FP_ objects were removed; SIG_AR_, SIG_LB_, and the AN_*
//    analysis objects accumulated silently across sessions.
void CleanupAllTradeObjects()
  {
   long chart = g_chart;
   for(int i = ObjectsTotal(chart,0,-1)-1; i >= 0; i--)
     {
      string nm = ObjectName(chart,i,0,-1);
      if(StringFind(nm,"FP_")     == 0 ||
         StringFind(nm,"SIG_AR_") == 0 ||
         StringFind(nm,"SIG_LB_") == 0 ||
         StringFind(nm,"AN_AR_")  == 0 ||
         StringFind(nm,"AN_SL_")  == 0 ||
         StringFind(nm,"AN_TP_")  == 0 ||
         StringFind(nm,"AN_EL_")  == 0)
         ObjectDelete(chart,nm);
     }
  }

void DrawSignalMarker(ulong markerId, bool isBuy, double price,
                      datetime barTime, int hftScore, int ofsScore,
                      const string conviction)
  {
   if(!InpShowVisuals) return;
   long  chart  = g_chart;
   color clrDir = isBuy ? InpVizBuyColor : InpVizSellColor;

   string arNm = StringFormat("SIG_AR_%I64u", markerId);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, barTime, price))
     {
      ObjectSetInteger(chart,arNm,OBJPROP_ARROWCODE,isBuy?233:234);
      ObjectSetInteger(chart,arNm,OBJPROP_COLOR,clrDir);
      ObjectSetInteger(chart,arNm,OBJPROP_WIDTH,2);
      ObjectSetInteger(chart,arNm,OBJPROP_SELECTABLE,false);
      ObjectSetString( chart,arNm,OBJPROP_TOOLTIP,
         StringFormat("[SIGNAL] %s | HFT: %d  OFS: %d\nConviction: %s\nPrice: %s | Bar: %s",
                      isBuy?"BUY":"SELL",hftScore,ofsScore,conviction,
                      DoubleToString(price,_Digits),
                      TimeToString(barTime,TIME_DATE|TIME_MINUTES)));
     }

   if(InpShowEntryLabel)
     {
      string lbNm = StringFormat("SIG_LB_%I64u", markerId);
      string txt  = StringFormat("%s  HFT:%d OFS:%d\n%s",
                                 isBuy?"▲":"▼",hftScore,ofsScore,conviction);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, barTime, price))
        {
         ObjectSetString( chart,lbNm,OBJPROP_TEXT,txt);
         ObjectSetInteger(chart,lbNm,OBJPROP_COLOR,clrDir);
         ObjectSetInteger(chart,lbNm,OBJPROP_FONTSIZE,8);
         ObjectSetString( chart,lbNm,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(chart,lbNm,OBJPROP_ANCHOR,isBuy?ANCHOR_LEFT_UPPER:ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chart,lbNm,OBJPROP_SELECTABLE,false);
        }
     }
   ChartRedraw(chart);
  }

//==========================================================================
// SECTION 7: FORWARD DECLARATIONS
//==========================================================================

void ComputeBarSignals(int bi);

//==========================================================================
// SECTION 8: TICK PROCESSING PIPELINE
//==========================================================================

double NormP(double p)
  { return MathFloor(p / g_step) * g_step; }

int FindBarIndex(datetime bt)
  {
   int lo = 0, hi = ArraySize(g_bars) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if(g_bars[mid].bar_time == bt) return mid;
      if(g_bars[mid].bar_time < bt)  lo = mid + 1;
      else                            hi = mid - 1;
     }
   return -1;
  }

int InsertBar(datetime bt)
  {
   int n = ArraySize(g_bars);

   if(n > 0 && bt > g_bars[n-1].bar_time)
     {
      ArrayResize(g_bars, n+1, 128);
      g_bars[n].bar_time            = bt;
      g_bars[n].total_vol           = 0;
      g_bars[n].total_delta         = 0;
      g_bars[n].high                = 0.0;
      g_bars[n].low                 = 0.0;
      g_bars[n].sorted              = true;
      g_bars[n].is_bullish          = true;
      g_bars[n].level_count         = 0;
      g_bars[n].poc_idx             = -1;
      g_bars[n].va_lo_idx           = -1;
      g_bars[n].va_hi_idx           = -1;
      g_bars[n].is_delta_divergence = false;
      g_bars[n].is_naked_poc        = false;
      g_bars[n].levelMapBase        = 0;
      ArrayResize(g_bars[n].levelMap, 0);
      ArrayResize(g_bars[n].levels, 64, 64);
      return n;
     }

   int pos = n;
   for(int i = n-1; i >= 0; i--)
     {
      if(g_bars[i].bar_time == bt) return i;
      if(g_bars[i].bar_time < bt) { pos = i+1; break; }
      pos = i;
     }

   ArrayResize(g_bars, n+1, 128);
   ArrayResize(g_bars[n].levels, 0);

   for(int i = n; i > pos; i--)
     {
      g_bars[i].bar_time            = g_bars[i-1].bar_time;
      g_bars[i].total_vol           = g_bars[i-1].total_vol;
      g_bars[i].total_delta         = g_bars[i-1].total_delta;
      g_bars[i].high                = g_bars[i-1].high;
      g_bars[i].low                 = g_bars[i-1].low;
      g_bars[i].sorted              = g_bars[i-1].sorted;
      g_bars[i].is_bullish          = g_bars[i-1].is_bullish;
      g_bars[i].level_count         = g_bars[i-1].level_count;
      g_bars[i].poc_idx             = g_bars[i-1].poc_idx;
      g_bars[i].va_lo_idx           = g_bars[i-1].va_lo_idx;
      g_bars[i].va_hi_idx           = g_bars[i-1].va_hi_idx;
      g_bars[i].is_delta_divergence = g_bars[i-1].is_delta_divergence;
      g_bars[i].is_naked_poc        = g_bars[i-1].is_naked_poc;
      g_bars[i].levelMapBase        = g_bars[i-1].levelMapBase;
      int mc = ArraySize(g_bars[i-1].levelMap);
      ArrayResize(g_bars[i].levelMap, mc);
      for(int k = 0; k < mc; k++) g_bars[i].levelMap[k] = g_bars[i-1].levelMap[k];
      int lc = g_bars[i-1].level_count;
      ArrayResize(g_bars[i].levels, lc, 64);
      for(int k = 0; k < lc; k++) g_bars[i].levels[k] = g_bars[i-1].levels[k];
     }

   g_bars[pos].bar_time            = bt;
   g_bars[pos].total_vol           = 0;
   g_bars[pos].total_delta         = 0;
   g_bars[pos].high                = 0.0;
   g_bars[pos].low                 = 0.0;
   g_bars[pos].sorted              = true;
   g_bars[pos].is_bullish          = true;
   g_bars[pos].level_count         = 0;
   g_bars[pos].poc_idx             = -1;
   g_bars[pos].va_lo_idx           = -1;
   g_bars[pos].va_hi_idx           = -1;
   g_bars[pos].is_delta_divergence = false;
   g_bars[pos].is_naked_poc        = false;
   g_bars[pos].levelMapBase        = 0;
   ArrayResize(g_bars[pos].levelMap, 0);
   ArrayResize(g_bars[pos].levels, 64, 64);
   return pos;
  }

int GetBar(datetime bt)
  { int idx = FindBarIndex(bt); return (idx >= 0) ? idx : InsertBar(bt); }

void AccumulateTick(int bi, double price, long vol, bool isBuy, bool isSell)
  {
   if(price == 0.0) return;
   price = NormP(price);

   int used = g_bars[bi].level_count;
   int idx  = -1;

   bool skipSearch = (price > g_bars[bi].high + g_step ||
                      price < g_bars[bi].low  - g_step);
   // [V8-23] TICK-SEARCH: O(1) level lookup via per-bar grid map.
   //    The old path was a reverse linear scan: O(levels) per tick — the last
   //    O(n×m) hotpath in the tick pipeline.  The price grid is discrete with
   //    step g_step, so every valid price maps to a unique integer offset.
   //    levelMap[offset] holds the levels[] index for that grid slot (or -1).
   //    The map grows lazily when prices extend the bar range.
   if(!skipSearch)
     {
      int gridIdx = (int)MathRound(price / g_step);
      int mapSize = ArraySize(g_bars[bi].levelMap);

      if(mapSize == 0)
        {
         // First tick for this bar: anchor the map at this grid index.
         g_bars[bi].levelMapBase = gridIdx;
         ArrayResize(g_bars[bi].levelMap, 32);
         for(int k = 0; k < 32; k++) g_bars[bi].levelMap[k] = -1;
         mapSize = 32;
        }

      int offset = gridIdx - g_bars[bi].levelMapBase;

      if(offset < 0)
        {
         // Price below map start — extend downward.
         int extend  = (-offset) + 16;
         int oldSize = mapSize;
         int newSize = oldSize + extend;
         ArrayResize(g_bars[bi].levelMap, newSize);
         // Shift existing slots upward to make room at the front.
         for(int k = oldSize - 1; k >= 0; k--)
            g_bars[bi].levelMap[k + extend] = g_bars[bi].levelMap[k];
         for(int k = 0; k < extend; k++) g_bars[bi].levelMap[k] = -1;
         g_bars[bi].levelMapBase -= extend;
         offset  = gridIdx - g_bars[bi].levelMapBase;   // [V8-25] EXTEND-OFFSET: recalc after base shift
         mapSize = newSize;
        }
      else if(offset >= mapSize)
        {
         // Price above map end — extend upward in one allocation.
         // [V8-24] TICK-SEARCH-UPWARD: the old path called ArrayResize once per
         //    slot (up to 16 heap allocations per extension). The downward branch
         //    already used a single resize. Unified here to match.
         int newSize = offset + 16;
         ArrayResize(g_bars[bi].levelMap, newSize);
         for(int k = mapSize; k < newSize; k++) g_bars[bi].levelMap[k] = -1;
         mapSize = newSize;
        }

      idx = g_bars[bi].levelMap[offset];
     }

   if(idx == -1)
     {
      if(used >= ArraySize(g_bars[bi].levels))
         ArrayResize(g_bars[bi].levels, used+64, 64);
      idx = used;
      g_bars[bi].levels[idx].price               = price;
      g_bars[bi].levels[idx].bid_vol             = 0;
      g_bars[bi].levels[idx].ask_vol             = 0;
      g_bars[bi].levels[idx].total_vol           = 0;
      g_bars[bi].levels[idx].delta               = 0;
      g_bars[bi].levels[idx].is_imb_buy          = false;
      g_bars[bi].levels[idx].is_imb_sell         = false;
      g_bars[bi].levels[idx].is_absorption       = false;
      g_bars[bi].levels[idx].is_hvn              = false;
      g_bars[bi].levels[idx].is_lvn              = false;
      g_bars[bi].levels[idx].is_stacked_imb_buy  = false;
      g_bars[bi].levels[idx].is_stacked_imb_sell = false;
      g_bars[bi].levels[idx].is_unfinished_hi    = false;
      g_bars[bi].levels[idx].is_unfinished_lo    = false;
      g_bars[bi].levels[idx].is_exhaustion_bid   = false;
      g_bars[bi].levels[idx].is_exhaustion_ask   = false;
      g_bars[bi].level_count++;
      g_bars[bi].sorted = false;
      // [V8-23] TICK-SEARCH: register the new level in the O(1) map so future
      //    ticks at the same price grid slot resolve without any scan.
      // [V8-24] LEVMAP-SKIP: registration is now unconditional. The old guard
      //    (if(!skipSearch)) left out-of-range levels unregistered. A second tick
      //    at the same out-of-range price before the OHLC refreshed would compute
      //    skipSearch=true again, find idx=-1, and create a duplicate level —
      //    silently corrupting volume and delta totals.
      {
       int gIdx = (int)MathRound(price / g_step);
       if(ArraySize(g_bars[bi].levelMap) > 0)
         {
          int off = gIdx - g_bars[bi].levelMapBase;
          if(off >= 0 && off < ArraySize(g_bars[bi].levelMap))
             g_bars[bi].levelMap[off] = idx;
          // If still out of map bounds the price is a true out-of-band anomaly
          // (> bar_high+g_step or < bar_low-g_step). The next in-range tick will
          // grow the map from the in-range side; this slot will not be reached
          // via the fast path until the OHLC updates and skipSearch becomes false.
         }
      }
     }

   if(isBuy)  g_bars[bi].levels[idx].ask_vol += vol;
   if(isSell) g_bars[bi].levels[idx].bid_vol += vol;

   g_bars[bi].levels[idx].total_vol += vol;
   g_bars[bi].levels[idx].delta      = g_bars[bi].levels[idx].ask_vol
                                      - g_bars[bi].levels[idx].bid_vol;

   g_bars[bi].total_vol   += vol;
   g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));
   g_bars[bi].sorted       = false;
  }

void Classify(const MqlTick &t, bool &isBuy, bool &isSell)
  {
   isBuy  = false;
   isSell = false;
   if(g_hasTrades)
     {
      isBuy  = (t.flags & TICK_FLAG_BUY)  == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
      if(!isBuy && !isSell)
        {
         if(t.last >= t.ask)      isBuy  = true;
         else if(t.last <= t.bid) isSell = true;
        }
     }
   else
     {
      if(g_prevBid > 0.0)
        {
         if(t.bid > g_prevBid)      isBuy  = true;
         else if(t.bid < g_prevBid) isSell = true;
        }
     }
  }

void ProcessTicks(MqlTick &ticks[], int startIdx, int count,
                  bool skipAlreadySeen, bool updateLastTimeMs,
                  bool reset_cache = false)
  {
   static datetime current_bar_time = 0;
   static int      current_sh       = -1;
   static datetime next_bar_time    = 0;
   static int    s_ohlc_sh   = -2;
   static bool   s_ohlc_bull = true;
   static double s_ohlc_high = 0.0;
   static double s_ohlc_low  = 0.0;

   if(reset_cache)
     {
      current_bar_time = 0;
      current_sh       = -1;
      next_bar_time    = 0;
      s_ohlc_sh        = -2;
     }

   if(count <= 0) return;
   int endIdx = MathMin(startIdx + count, ArraySize(ticks));

   for(int i = startIdx; i < endIdx; i++)
     {
      if(skipAlreadySeen && ticks[i].time_msc <= g_last_tick_time_ms) continue;

      double price;
      long   vol;
      if(g_hasTrades)
        {
         price = ticks[i].last;
         vol   = (long)ticks[i].volume;
         if(vol <= 0 || price == 0.0) continue;
        }
      else
        {
         price = ticks[i].bid;
         vol   = 1;
         if(price == 0.0) continue;
        }

      bool isBuy, isSell;
      Classify(ticks[i], isBuy, isSell);

      if(ticks[i].bid != 0.0) g_prevBid = ticks[i].bid;

      if(ticks[i].time < current_bar_time || ticks[i].time >= next_bar_time)
        {
         current_sh = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
         if(current_sh < 0) continue;
         current_bar_time = iTime(_Symbol, PERIOD_CURRENT, current_sh);
         next_bar_time    = current_bar_time + PeriodSeconds(PERIOD_CURRENT);
        }

      int      sh = current_sh;
      datetime bt = current_bar_time;
      int      bi = GetBar(bt);

      if(sh == 0 || sh != s_ohlc_sh)
        {
         s_ohlc_sh   = sh;
         s_ohlc_bull = (iClose(_Symbol,PERIOD_CURRENT,sh) >= iOpen(_Symbol,PERIOD_CURRENT,sh));
         s_ohlc_high = iHigh(_Symbol,PERIOD_CURRENT,sh);
         s_ohlc_low  = iLow (_Symbol,PERIOD_CURRENT,sh);
        }
      g_bars[bi].is_bullish = s_ohlc_bull;
      g_bars[bi].high       = s_ohlc_high;
      g_bars[bi].low        = s_ohlc_low;

      AccumulateTick(bi, price, vol, isBuy, isSell);

      if(updateLastTimeMs) g_last_tick_time_ms = ticks[i].time_msc;
     }
  }

int LoadHistory(datetime t0, datetime t1)
  {
   MqlTick ticks[];
   uint    flag   = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   int     copied = CopyTicksRange(_Symbol, ticks, flag,
                                   (long)t0*1000, (long)t1*1000);
   if(copied <= 0) return -1;
   g_prevBid = ticks[0].bid;
   ProcessTicks(ticks, 0, copied, false, true, true);
   return copied;
  }

//==========================================================================
// SECTION 9: LEVEL SORTING & PROFILE HELPERS
//==========================================================================

void SortLevelsPartition(PriceLevel &lv[], int lo, int hi)
  {
   if(lo >= hi) return;
   // [V8-19] BUG FIX (SORT-DIR): the original partition used >= pivot, which is the
   //    Lomuto descending variant and produced levels[0]=HIGH, levels[len-1]=LOW.
   //    All spatial comments, POC gravity (C3), and exhaustion detection assume
   //    ascending order (levels[0]=LOW, levels[len-1]=HIGH). Fix: change to <=
   //    so that smaller prices (lower levels) are placed at lower indices.
   // [V8-21] CARRY-PIV: median-of-three pivot selection eliminates O(n²) degenerate
   //    behaviour on already-sorted or nearly-sorted level arrays (common in trending
   //    markets). Swap the median into lv[hi] so the Lomuto loop is unchanged.
   int    mid = lo + (hi - lo) / 2;
   if(lv[mid].price < lv[lo].price)  { PriceLevel t=lv[lo];  lv[lo]=lv[mid]; lv[mid]=t; }
   if(lv[hi].price  < lv[lo].price)  { PriceLevel t=lv[lo];  lv[lo]=lv[hi];  lv[hi]=t;  }
   if(lv[mid].price < lv[hi].price)  { PriceLevel t=lv[hi];  lv[hi]=lv[mid]; lv[mid]=t; }
   double pivot = lv[hi].price;
   int    i     = lo - 1;
   for(int j = lo; j < hi; j++)
     {
      if(lv[j].price <= pivot)
        { i++; PriceLevel tmp = lv[i]; lv[i] = lv[j]; lv[j] = tmp; }
     }
   i++;
   PriceLevel tmp = lv[i]; lv[i] = lv[hi]; lv[hi] = tmp;
   SortLevelsPartition(lv, lo, i-1);
   SortLevelsPartition(lv, i+1, hi);
  }

void SortLevels(PriceLevel &lv[], int n)
  { if(n > 1) SortLevelsPartition(lv, 0, n-1); }

int FindPOC(const PriceLevel &lv[], int count)
  {
   int  best = -1;
   long mx   = 0;
   for(int i = 0; i < count; i++)
      if(lv[i].total_vol > mx) { mx = lv[i].total_vol; best = i; }
   return best;
  }

double GetEffectiveVAPercent()
  {
   if(g_vaPercent > 0.0) return g_vaPercent;
   return (InpVAPercent > 0.0) ? InpVAPercent : 70.0;
  }

void FindVA(const PriceLevel &lv[], int count, long totVol, int poc,
            int &lo, int &hi)
  {
   lo = poc; hi = poc;
   if(poc < 0) return;
   long target = (long)(totVol * GetEffectiveVAPercent() / 100.0);
   long cur    = lv[poc].total_vol;

   while(cur < target && (lo > 0 || hi < count-1))
     {
      // [V8-09] Single-level lookahead (CME-standard Value Area).
      //    The previous two-level lookahead introduced a directional bias on
      //    asymmetric profiles because it evaluated a level the algorithm had
      //    not yet committed to expanding into.
      double up  = (hi+1 < count) ? (double)lv[hi+1].total_vol : 0.0;
      double dn  = (lo-1 >= 0)    ? (double)lv[lo-1].total_vol : 0.0;
      bool canUp = (hi < count-1);
      bool canDn = (lo > 0);

      if(canUp && (!canDn || up >= dn)) { hi++; cur += lv[hi].total_vol; }
      else if(canDn)                    { lo--; cur += lv[lo].total_vol; }
      else break;
     }
  }

// [V8-25] LEVMAP-STALE: rebuild the O(1) price→level map after SortLevels().
//    SortLevels physically reorders levels[] by price; any pre-sort levelMap
//    entry now points to the wrong levels[] slot. Called from ComputeBarSignals()
//    immediately after every SortLevels() call so AccumulateTick() sees a
//    consistent map on the next live tick for the same bar.
void RebuildLevelMap(int bi)
  {
   int len = g_bars[bi].level_count;
   int ms  = ArraySize(g_bars[bi].levelMap);

   // Clear all existing entries.
   for(int k = 0; k < ms; k++) g_bars[bi].levelMap[k] = -1;

   // Re-register every level at its correct (post-sort) grid offset.
   for(int i = 0; i < len; i++)
     {
      int gIdx = (int)MathRound(g_bars[bi].levels[i].price / g_step);
      int off  = gIdx - g_bars[bi].levelMapBase;
      if(off >= 0 && off < ms)
         g_bars[bi].levelMap[off] = i;
     }
  }

//==========================================================================
// SECTION 10: SIGNAL COMPUTATION
//==========================================================================

void ComputeBarSignals(int bi)
  {
   int len = g_bars[bi].level_count;
   if(len <= 0) return;

   if(!g_bars[bi].sorted)
     {
      SortLevels(g_bars[bi].levels, len);
      RebuildLevelMap(bi);   // [V8-25] LEVMAP-STALE: re-sync map after sort reorders levels[]
      g_bars[bi].sorted = true;
     }

   // 1. POC
   g_bars[bi].poc_idx = FindPOC(g_bars[bi].levels, len);

   // 2. Value Area
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, g_bars[bi].poc_idx,
          g_bars[bi].va_lo_idx, g_bars[bi].va_hi_idx);

   // 3. Imbalance, Absorption (with V7-09 volume gate), HVN/LVN
   long avgVol = (len > 0) ? (g_bars[bi].total_vol / len) : 1;
   for(int i = 0; i < len; i++)
     {
      g_bars[bi].levels[i].is_imb_buy          = false;
      g_bars[bi].levels[i].is_imb_sell         = false;
      g_bars[bi].levels[i].is_stacked_imb_buy  = false;
      g_bars[bi].levels[i].is_stacked_imb_sell = false;
      g_bars[bi].levels[i].is_unfinished_hi    = false;
      g_bars[bi].levels[i].is_unfinished_lo    = false;
      g_bars[bi].levels[i].is_hvn              = false;
      g_bars[bi].levels[i].is_lvn              = false;
      g_bars[bi].levels[i].is_exhaustion_bid   = false;
      g_bars[bi].levels[i].is_exhaustion_ask   = false;

      // [V7-09] Absorption: volume threshold AND absorbing-side dominance
      bool volThresh = (g_bars[bi].levels[i].total_vol > avgVol * InpAbsorptionRatio);
      bool sideDom   = false;
      if(volThresh && InpAbsVolMult > 0.0)
        {
         long askV = g_bars[bi].levels[i].ask_vol;
         long bidV = g_bars[bi].levels[i].bid_vol;
         // Bullish absorption: ask side strongly dominant at the level
         // Bearish absorption: bid side strongly dominant at the level
         sideDom = (askV > 0 && bidV > 0) &&
                   (askV >= (long)(bidV * InpAbsVolMult) ||
                    bidV >= (long)(askV * InpAbsVolMult));
        }
      else if(volThresh)
        {
         sideDom = true;  // no side-dominance filter if AbsVolMult == 0
        }
      g_bars[bi].levels[i].is_absorption = (volThresh && sideDom);

      g_bars[bi].levels[i].is_hvn =
         (!g_bars[bi].levels[i].is_absorption &&
          g_bars[bi].levels[i].total_vol >= (long)(avgVol * InpHVNRatio));
      g_bars[bi].levels[i].is_lvn =
         (g_bars[bi].levels[i].total_vol > 0 &&
          g_bars[bi].levels[i].total_vol <= (long)(avgVol * InpLVNRatio));

      // Diagonal imbalance
      if(i < len-1)
        {
         long nextBid = g_bars[bi].levels[i+1].bid_vol;
         if(nextBid > 0 &&
            ((double)g_bars[bi].levels[i].ask_vol / nextBid) * 100.0 >= g_imbRatio)
            g_bars[bi].levels[i].is_imb_buy = true;
        }
      if(i > 0)
        {
         long prevAsk = g_bars[bi].levels[i-1].ask_vol;
         if(prevAsk > 0 &&
            ((double)g_bars[bi].levels[i].bid_vol / prevAsk) * 100.0 >= g_imbRatio)
            g_bars[bi].levels[i].is_imb_sell = true;
        }
     }

   // 4. Stacked Imbalances — [V7-13] single-pass for buy and sell simultaneously
   int  countBuy = 0, countSell = 0;
   for(int i = 0; i < len; i++)
     {
      // --- Buy stacked ---
      if(g_bars[bi].levels[i].is_imb_buy)
         countBuy++;
      else
        {
         if(countBuy >= InpStackedImbCount)
            for(int j = i-countBuy; j < i; j++)
               g_bars[bi].levels[j].is_stacked_imb_buy = true;
         countBuy = 0;
        }
      // --- Sell stacked ---
      if(g_bars[bi].levels[i].is_imb_sell)
         countSell++;
      else
        {
         if(countSell >= InpStackedImbCount)
            for(int j = i-countSell; j < i; j++)
               g_bars[bi].levels[j].is_stacked_imb_sell = true;
         countSell = 0;
        }
     }
   if(countBuy  >= InpStackedImbCount)
      for(int j = len-countBuy;  j < len; j++) g_bars[bi].levels[j].is_stacked_imb_buy  = true;
   if(countSell >= InpStackedImbCount)
      for(int j = len-countSell; j < len; j++) g_bars[bi].levels[j].is_stacked_imb_sell = true;

   // 5. Unfinished Auctions
   // [V8-20] Ascending sort: levels[0]=bar LOW, levels[len-1]=bar HIGH.
   //    is_unfinished_lo → levels[0] (bar LOW): sellers couldn't find buyers → near-zero bid_vol at LOW.
   //    is_unfinished_hi → levels[len-1] (bar HIGH): buyers couldn't find sellers → near-zero ask_vol at HIGH.
   //    Condition: near-zero on the AGGRESSOR side (ask at HIGH, bid at LOW), not "both sides active"
   //    which is universally true for any traded level and captured nothing.
   if(len > 1)
     {
      long avgV   = MathMax(1, g_bars[bi].total_vol / len);
      long exhThr = MathMax(1L, (long)(avgV * InpExhaustionZeroRat));
      // Unfinished LOW: sellers ran out at the bottom (near-zero bid_vol at levels[0])
      g_bars[bi].levels[0].is_unfinished_lo =
         (g_bars[bi].levels[0].total_vol > 0 &&
          g_bars[bi].levels[0].bid_vol <= exhThr);
      // Unfinished HIGH: buyers ran out at the top (near-zero ask_vol at levels[len-1])
      g_bars[bi].levels[len-1].is_unfinished_hi =
         (g_bars[bi].levels[len-1].total_vol > 0 &&
          g_bars[bi].levels[len-1].ask_vol <= exhThr);
     }

   // 6. Delta Divergence
   g_bars[bi].is_delta_divergence =
      ( g_bars[bi].is_bullish && g_bars[bi].total_delta < 0) ||
      (!g_bars[bi].is_bullish && g_bars[bi].total_delta > 0);

   // 7. Bid/Ask Exhaustion
   // [V8-19] Ascending sort: levels[0]=bar LOW, levels[len-1]=bar HIGH.
   //    Standard footprint: near-zero ASK at the HIGH = buyers exhausted at the top (bearish).
   //    Near-zero BID at the LOW = sellers exhausted at the bottom (bullish).
   //    askRun scans downward from len-1 (HIGH); bidRun scans upward from 0 (LOW).
   //    These scan directions are correct for ascending order.
   if(InpExhaustionEnable && len >= InpExhaustionCells)
     {
      long avgV   = MathMax(1, g_bars[bi].total_vol / len);
      long exhThr = MathMax(1L, (long)(avgV * InpExhaustionZeroRat));

      // Ask exhaustion at HIGH (buyers ran out at the top = bearish)
      int askRun = 0;
      for(int i = len-1; i >= 0; i--)
        {
         if(g_bars[bi].levels[i].total_vol > 0 &&
            g_bars[bi].levels[i].ask_vol <= exhThr) askRun++;
         else break;
        }
      if(askRun >= InpExhaustionCells)
         for(int i = len-1; i >= len-askRun; i--)
            g_bars[bi].levels[i].is_exhaustion_ask = true;

      // Bid exhaustion at LOW (sellers ran out at the bottom = bullish)
      int bidRun = 0;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].total_vol > 0 &&
            g_bars[bi].levels[i].bid_vol <= exhThr) bidRun++;
         else break;
        }
      if(bidRun >= InpExhaustionCells)
         for(int i = 0; i < bidRun; i++)
            g_bars[bi].levels[i].is_exhaustion_bid = true;
     }
  }

// [V8-20] Helper: quicksort two parallel arrays (poc prices and their source bar indices)
//    by price ascending. Used by ComputeNakedPOCs for O(n log n) range queries.
void SortPocPartition(double &px[], int &bx[], int lo, int hi)
  {
   if(lo >= hi) return;
   // [V8-21] CARRY-PIV: median-of-three pivot — eliminates O(n²) degenerate sort on
   //    nearly-sorted POC-price input (common in trending environments). Swap the median
   //    into px[hi]/bx[hi] so the existing Lomuto partition loop is unchanged.
   int mid = lo + (hi - lo) / 2;
   if(px[mid] < px[lo]) { double tp=px[lo]; px[lo]=px[mid]; px[mid]=tp; int tb=bx[lo]; bx[lo]=bx[mid]; bx[mid]=tb; }
   if(px[hi]  < px[lo]) { double tp=px[lo]; px[lo]=px[hi];  px[hi]=tp;  int tb=bx[lo]; bx[lo]=bx[hi];  bx[hi]=tb;  }
   if(px[mid] < px[hi]) { double tp=px[hi]; px[hi]=px[mid]; px[mid]=tp; int tb=bx[hi]; bx[hi]=bx[mid]; bx[mid]=tb; }
   double pivot = px[hi]; int ip = lo - 1;
   for(int j = lo; j < hi; j++)
     {
      if(px[j] <= pivot)
        {
         ip++;
         double tp = px[ip]; px[ip] = px[j]; px[j] = tp;
         int    tb = bx[ip]; bx[ip] = bx[j]; bx[j] = tb;
        }
     }
   ip++;
   double tp = px[ip]; px[ip] = px[hi]; px[hi] = tp;
   int    tb = bx[ip]; bx[ip] = bx[hi]; bx[hi] = tb;
   SortPocPartition(px, bx, lo,   ip-1);
   SortPocPartition(px, bx, ip+1, hi);
  }

// Returns first index k in sorted arr[] where arr[k] >= val
int NpocBinLo(const double &arr[], int n, double val)
  { int lo=0, hi=n; while(lo<hi){ int m=(lo+hi)/2; if(arr[m]<val) lo=m+1; else hi=m; } return lo; }

// Returns first index k in sorted arr[] where arr[k] > val
int NpocBinHi(const double &arr[], int n, double val)
  { int lo=0, hi=n; while(lo<hi){ int m=(lo+hi)/2; if(arr[m]<=val) lo=m+1; else hi=m; } return lo; }

// [V8-20] O(n log n) replacement for the previous O(n²) implementation.
//    Algorithm:
//      Phase 1 — collect (pocPrice, barIdx) pairs; O(n).
//      Phase 2 — sort pairs by price; O(n log n).
//      Phase 3 — forward pass over bars: for each bar j, binary-search the sorted
//                price array for range [lo_j, hi_j] and mark any entry with barIdx < j
//                as retested; O(n log n + total_marks) where total_marks ≤ n.
//      Phase 4 — assign is_naked_poc from the retested[] flags; O(n).
//    Total: O(n log n). Replaces the O(n²) double loop that caused visible startup
//    stalls at InpHistoryBars = 1,000–5,000 on low-powered VPS hardware.
void ComputeNakedPOCs()
  {
   int n = ArraySize(g_bars);
   if(n == 0) return;

   // Phase 1: collect POC prices and their source bar indices
   double pocPx[];
   int    pocBx[];
   bool   retested[];
   ArrayResize(pocPx,   n);
   ArrayResize(pocBx,   n);
   ArrayResize(retested, n);
   int cnt = 0;

   for(int i = 0; i < n; i++)
     {
      g_bars[i].is_naked_poc = false;
      retested[i]            = false;
      if(!g_bars[i].sorted) ComputeBarSignals(i);
      int pi = g_bars[i].poc_idx;
      if(pi < 0 || pi >= g_bars[i].level_count) continue;
      pocPx[cnt] = g_bars[i].levels[pi].price;
      pocBx[cnt] = i;
      cnt++;
     }
   if(cnt == 0) return;
   ArrayResize(pocPx, cnt);
   ArrayResize(pocBx, cnt);

   // Phase 2: sort pairs by price
   SortPocPartition(pocPx, pocBx, 0, cnt-1);

   // Phase 3: forward bar pass — binary-search for POC prices inside each bar's range
   double half = g_step * 0.5;
   for(int j = 0; j < n; j++)
     {
      double lo = g_bars[j].low  - half;
      double hi = g_bars[j].high + half;
      int    k0 = NpocBinLo(pocPx, cnt, lo);
      int    k1 = NpocBinHi(pocPx, cnt, hi);
      for(int k = k0; k < k1; k++)
         if(pocBx[k] < j) retested[pocBx[k]] = true;
     }

   // Phase 4: assign naked POC status
   for(int i = 0; i < n; i++)
     {
      int pi = g_bars[i].poc_idx;
      if(pi < 0 || pi >= g_bars[i].level_count) continue;
      g_bars[i].is_naked_poc = !retested[i];
     }
  }

int ComputeOFScore(int bi)
  {
   int  len  = g_bars[bi].level_count;
   long tvol = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0) return 50;

   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio = MathMax(-1.0, MathMin(1.0, rawDr));
   double cDelta = (dRatio + 1.0) * 0.5;

   int  imbBuy = 0, imbSell = 0;
   bool hasStackBuy = false, hasStackSell = false, hasAbsorb = false;
   for(int i = 0; i < len; i++)
     {
      if(g_bars[bi].levels[i].is_imb_buy)          imbBuy++;
      if(g_bars[bi].levels[i].is_imb_sell)         imbSell++;
      if(g_bars[bi].levels[i].is_stacked_imb_buy)  hasStackBuy  = true;
      if(g_bars[bi].levels[i].is_stacked_imb_sell) hasStackSell = true;
      if(g_bars[bi].levels[i].is_absorption)        hasAbsorb    = true;
     }
   int    totalImb = imbBuy + imbSell;
   double cImb = 0.5;
   if(totalImb > 0)
     {
      double rawImb = ((double)(imbBuy - imbSell) / (double)totalImb + 1.0) * 0.5;
      cImb = MathIsValidNumber(rawImb) ? rawImb : 0.5;
     }

   double cStack;
   if     (hasStackBuy  && !hasStackSell) cStack = 1.0;
   else if(hasStackSell && !hasStackBuy)  cStack = 0.0;
   else                                    cStack = 0.5;

   // [V8-19] Ascending sort: levels[0]=LOW, levels[len-1]=HIGH.
   //    i < chkA indexes the LOW end (bullish absorption); i >= len-chkA indexes HIGH (bearish).
   bool absOfsLow = false, absOfsHigh = false;
   {
      int chkA = MathMin(3, len/3+1);
      for(int i = 0;        i < chkA; i++) if(g_bars[bi].levels[i].is_absorption) absOfsLow  = true;
      for(int i = len-chkA; i < len; i++) if(g_bars[bi].levels[i].is_absorption) absOfsHigh = true;
   }
   double cAbsorb = (!absOfsLow && !absOfsHigh) ? 0.5
                  : ( absOfsLow && !absOfsHigh)  ? 1.0
                  : (!absOfsLow &&  absOfsHigh)  ? 0.0
                  : 0.5;  // absorption at both extremes = neutral

   double wD = MathMax(0.0, InpOFWtDelta)   / 100.0;
   double wI = MathMax(0.0, InpOFWtImb)     / 100.0;
   double wS = MathMax(0.0, InpOFWtStacked) / 100.0;
   double wA = MathMax(0.0, InpOFWtAbsorb)  / 100.0;
   double wT = wD + wI + wS + wA;
   if(wT <= 0.0) wT = 1.0;

   double raw = (cDelta*wD + cImb*wI + cStack*wS + cAbsorb*wA) / wT;
   if(!MathIsValidNumber(raw)) raw = 0.5;
   int score = (int)(raw * 100.0 + 0.5);
   return MathMax(0, MathMin(100, score));
  }

// [V8-22] CVD-DRY: shared helper for the 3-bar recency-weighted CVD slope.
//    Previously duplicated verbatim in ComputeHFTSignal (C6) and GetConvictionResult
//    (Component 4). A single change here propagates to both call sites automatically.
double ComputeCVDSlope(int bi)
  {
   if(bi < 2) return 0.0;
   long v0 = MathMax(1, g_bars[bi].total_vol);
   long v1 = MathMax(1, g_bars[bi-1].total_vol);
   long v2 = MathMax(1, g_bars[bi-2].total_vol);
   double nd0 = (double)g_bars[bi].total_delta   / v0;
   double nd1 = (double)g_bars[bi-1].total_delta / v1;
   double nd2 = (double)g_bars[bi-2].total_delta / v2;
   if(!MathIsValidNumber(nd0)) nd0 = 0.0;
   if(!MathIsValidNumber(nd1)) nd1 = 0.0;
   if(!MathIsValidNumber(nd2)) nd2 = 0.0;
   return (2.0 * (nd0 - nd1) + (nd1 - nd2)) / 3.0;
  }

// [V7-12] Updated weights: C4 10% (was 15%), C6 15% (was 10%)
// [V8-20] Optional preOFS parameter: callers that have already called ComputeOFScore()
//    pass the result here to avoid an additional level scan. Default -1 triggers the
//    internal call (backward-compatible for all existing call sites).
double ComputeHFTSignal(int bi, int preOFS = -1)
  {
   int  len  = g_bars[bi].level_count;
   long tvol = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0) return 0.0;

   // C1: OFS Score (30%) — reuse preOFS when supplied to avoid redundant level scan
   double c1 = ((preOFS >= 0 ? preOFS : ComputeOFScore(bi)) - 50.0) / 50.0;

   // C2: Delta exhaustion / divergence (20%)
   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio = MathMax(-1.0, MathMin(1.0, rawDr));
   double c2 = g_bars[bi].is_delta_divergence ? -dRatio : dRatio;

   // C3: POC gravity (15%)
   // levels[] is now sorted price-ascending (levels[0]=bar LOW, levels[len-1]=bar HIGH).
   // poc_idx near 0 → POC at the LOW → accumulation zone → bullish (+1.0).
   // poc_idx near len-1 → POC at the HIGH → distribution zone → bearish (-1.0).
   // Formula: -(pocPos * 2 - 1) maps [0..1] to [+1..-1], which is correct for ascending.
   // [V8-17] negation introduced; remains correct after [V8-19] sort fix.
   // [V8-23] C3-INDEX: replaced level-index formula with price-distance formula.
   //    The old formula used poc_idx / (len-1) — a fraction of discrete level slots.
   //    On instruments with non-uniform level density (wide spreads, price rounding,
   //    low-liquidity gaps) two bars with the same POC price but different slot counts
   //    produce different pocPos values. The price-distance formula is numerically
   //    invariant to level density and directly measures the intended signal.
   double c3 = 0.0;
   if(g_bars[bi].poc_idx >= 0 && len > 2)
     {
      double range  = g_bars[bi].high - g_bars[bi].low;
      double pocPos = (range > g_step)
                      ? (g_bars[bi].levels[g_bars[bi].poc_idx].price - g_bars[bi].low) / range
                      : 0.5;
      c3 = -(pocPos * 2.0 - 1.0);
     }

   // C4: Absorption at extremes (10%) — [V7-12] reduced from 15%
   // [V8-19] Ascending sort: i < chk = LOW end (bullish); i >= len-chk = HIGH end (bearish).
   double c4 = 0.0;
   {
      int  chk = MathMin(3, len/3+1);
      bool absLow = false, absHigh = false;
      for(int i = 0;        i < chk;  i++)
         if(g_bars[bi].levels[i].is_absorption) absLow  = true;
      for(int i = len-chk; i < len;  i++)
         if(g_bars[bi].levels[i].is_absorption) absHigh = true;
      if(absLow  && !absHigh) c4 = +1.0;
      else if(absHigh && !absLow) c4 = -1.0;
     }

   // C5: Bid/Ask exhaustion (10%)
   double c5 = 0.0;
   {
      bool exhAsk = false, exhBid = false;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].is_exhaustion_ask) exhAsk = true;
         if(g_bars[bi].levels[i].is_exhaustion_bid) exhBid = true;
        }
      if(exhBid && !exhAsk) c5 = +1.0;
      if(exhAsk && !exhBid) c5 = -1.0;
     }

   // C6: 3-bar normalised CVD momentum slope (15%) — [V7-12] increased from 10%
   // [V8-20] Recency-weighted 3-bar formula: slope = (2*(nd0-nd1) + (nd1-nd2)) / 3.
   // [V8-21] C6-SCALE: amplifier recalibrated to *2.25 (max unscaled = 4/3; 4/3 * 2.25 = 3.0).
   // [V8-22] CVD-DRY: formula extracted to ComputeCVDSlope() and called here.
   double c6 = 0.0;
   if(bi >= 2)
     {
      double slope = ComputeCVDSlope(bi);
      c6 = MathMax(-1.0, MathMin(1.0, slope * 2.25));
     }

   // [V7-12] Updated weights
   const double w1=0.30, w2=0.20, w3=0.15, w4=0.10, w5=0.10, w6=0.15;
   double raw = c1*w1 + c2*w2 + c3*w3 + c4*w4 + c5*w5 + c6*w6;
   if(!MathIsValidNumber(raw)) raw = 0.0;
   return MathMax(-1.0, MathMin(1.0, raw)) * 100.0;
  }

// [V7-13] Returns ConvictionResult with both label and component count.
//    Component count is used by the diversity gate in EvalAndFireSignal()
//    and PlaceOrders() to ensure InpMinConvictionComp distinct sources agree.
ConvictionResult GetConvictionResult(int bi, bool isBuy)
  {
   ConvictionResult res;
   res.label          = "";
   res.componentCount = 0;

   string tags[];
   // [V8-22] ARRAYRESIZE: reserve 12 slots upfront so each ArrayResize(n+1) below
   //    reuses the pre-allocated buffer rather than triggering a heap reallocation.
   // [V8-23] ARRAYRESIZE-INCONSISTENT: all 14 append sites now supply the same
   //    reserve parameter so the initial reservation is consistently honoured.
   ArrayResize(tags, 0, 12);
   int len = g_bars[bi].level_count;

   // Component 1: Delta divergence
   // [V8-17] BUG FIX: DeltaDiv is a *reversal* signal. A bar that closed up with negative
   //    delta (is_bullish=true) supports a SHORT (price likely to fall toward delta), not a
   //    LONG. The previous code added "DeltaDiv" to the conviction list unconditionally,
   //    inflating the conviction count for the wrong direction on divergent bars.
   if(g_bars[bi].is_delta_divergence)
     {
      // Divergence on a bullish bar (close up, delta down) supports SHORT.
      // Divergence on a bearish bar (close down, delta up) supports LONG.
      bool divSupportsBuy = !g_bars[bi].is_bullish;
      if((isBuy && divSupportsBuy) || (!isBuy && !divSupportsBuy))
        {
         int n = ArraySize(tags); ArrayResize(tags, n+1, 12);
         tags[n] = "DeltaDiv";
        }
     }

   // Component 2: Strong net delta direction
   // [V8-22] DELTA-THRESHOLD: threshold now driven by InpDeltaConvThreshold (default 0.35).
   if(g_bars[bi].total_vol > 0)
     {
      double dr = (double)g_bars[bi].total_delta / (double)g_bars[bi].total_vol;
      if(isBuy && dr > InpDeltaConvThreshold)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "BullDelta"; }
      else if(!isBuy && dr < -InpDeltaConvThreshold)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "BearDelta"; }
     }

   // Component 3: Stacked imbalance / absorption / exhaustion (single pass)
   // [V8-19] Ascending sort: i < chk = LOW end (absLow); i >= len-chk = HIGH end (absHigh).
   bool hasSB = false, hasSS = false;
   bool exhBid= false, exhAsk= false;
   bool absLow= false, absHigh= false;
   int  chk   = MathMin(3, len/3+1);
   for(int i = 0; i < len; i++)
     {
      if(g_bars[bi].levels[i].is_stacked_imb_buy)  hasSB   = true;
      if(g_bars[bi].levels[i].is_stacked_imb_sell) hasSS   = true;
      if(g_bars[bi].levels[i].is_exhaustion_bid)   exhBid  = true;
      if(g_bars[bi].levels[i].is_exhaustion_ask)   exhAsk  = true;
      if(i < chk      && g_bars[bi].levels[i].is_absorption) absLow  = true;
      if(i >= len-chk && g_bars[bi].levels[i].is_absorption) absHigh = true;
     }

   if(isBuy)
     {
      if(hasSB)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "StackBuy"; }
      if(absLow)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "AbsLow"; }
      if(exhBid)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "BidExh"; }
      // [V8-21] DEAD-UA: is_unfinished_lo at bar LOW = sellers failed to find buyers;
      //    price is expected to return up — supports a LONG entry.
      if(len > 0 && g_bars[bi].levels[0].is_unfinished_lo)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "UA_Lo"; }
     }
   else
     {
      if(hasSS)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "StackSell"; }
      if(absHigh)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "AbsHigh"; }
      if(exhAsk)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "AskExh"; }
      // [V8-21] DEAD-UA: is_unfinished_hi at bar HIGH = buyers failed to find sellers;
      //    price is expected to return down — supports a SHORT entry.
      if(len > 0 && g_bars[bi].levels[len-1].is_unfinished_hi)
        { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "UA_Hi"; }
     }

   // Component 4: CVD momentum (mirrors C6 slope, same 3-bar recency-weighted formula [V8-20])
   // [V8-22] CVD-DRY: formula extracted to ComputeCVDSlope() and called here.
   if(bi >= 2)
     {
      double slope = ComputeCVDSlope(bi);
      if(MathIsValidNumber(slope))
        {
         if(isBuy && slope > 0.1)
           { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "CVD+"; }
         else if(!isBuy && slope < -0.1)
           { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "CVD-"; }
        }
     }

   // Naked POC as informational suffix
   if(g_bars[bi].is_naked_poc)
     { int n = ArraySize(tags); ArrayResize(tags,n+1,12); tags[n] = "NakedPOC"; }

   int total = ArraySize(tags);
   if(total == 0) { res.label = "Mixed"; res.componentCount = 0; return res; }

   // Build label from top 3 components; count all (excluding NakedPOC from gate)
   int capLabel = MathMin(total, 3);
   for(int i = 0; i < capLabel; i++)
     { if(i > 0) res.label += "+"; res.label += tags[i]; }

   // Count distinct signal components.
   // NakedPOC is contextual, not a scored signal — excluded from gate.
   // UA_Lo/UA_Hi have 0% weight in the HFT score; including them in componentCount
   // would let a borderline trade pass the conviction gate on a signal the score
   // cannot see. Excluded here; both tags are still shown in the label string.
   // [V8-22] UA-SCORE fix.
   res.componentCount = 0;
   for(int i = 0; i < total; i++)
      if(tags[i] != "NakedPOC" && tags[i] != "UA_Lo" && tags[i] != "UA_Hi")
         res.componentCount++;

   return res;
  }

//==========================================================================
// SECTION 11: HISTORY MANAGEMENT
//==========================================================================

void ReloadHistory()
  {
   int n = ArraySize(g_bars);
   // [V8-24] LEVMAP-FREE: free levelMap alongside levels at every cleanup site.
   for(int i = 0; i < n; i++)
     {
      ArrayFree(g_bars[i].levelMap);
      ArrayFree(g_bars[i].levels);
     }
   ArrayFree(g_bars);
   g_last_tick_time_ms  = 0;
   g_lastSignalBarTime  = 0;
   g_sigCacheBarIdx     = -1;
   g_sigCacheVol        = -1;

   int bars_total = iBars(_Symbol, PERIOD_CURRENT);
   if(bars_total <= 0) return;

   int      maxShift  = MathMin(g_histBars, bars_total-1);
   datetime startTime = iTime(_Symbol, PERIOD_CURRENT, maxShift);
   datetime endTime   = TimeCurrent();
   int loaded = LoadHistory(startTime, endTime);

   if(loaded > 0)
     {
      ComputeNakedPOCs();
      // [V7-06] Compute ATR baseline from the current ATR value if not yet set
      if(!g_atrBaselineReady && g_handleATR != INVALID_HANDLE)
        {
         double atrBuf[];
         int barsOnChart = iBars(_Symbol, PERIOD_CURRENT);
         if(barsOnChart > InpATR_Period + 1 &&
            CopyBuffer(g_handleATR, 0, 1, 50, atrBuf) > 0)
           {
            double sum = 0.0; int cnt = 0;
            for(int i = 0; i < ArraySize(atrBuf); i++)
              { if(atrBuf[i] > 0.0) { sum += atrBuf[i]; cnt++; } }
            if(cnt > 0)
              {
               g_atrBaseline      = sum / cnt;
               g_atrBaselineReady = true;
               LogSystem(StringFormat("ATR baseline set: %.5f (from %d bars)", g_atrBaseline, cnt));
              }
           }
        }
      LogSystem(StringFormat(EA_NAME " — History: %d ticks, %d bars",
                             loaded, ArraySize(g_bars)));
     }
   else
     {
      static bool s_alerted = false;
      if(!s_alerted)
        { Alert("OrderFlowEA: No tick data for ", _Symbol, ". Attach to chart with tick history."); s_alerted = true; }
     }
  }

//==========================================================================
// SECTION 12: RISK & FILTER HELPERS
//==========================================================================

// [V7-03] Returns true if current server time falls inside the active session window.
// [V8-19] SESSION-OVERNIGHT: support overnight session windows such as 22:00–02:00.
//    When InpSessionStartHour >= InpSessionEndHour the window wraps midnight; the
//    EA should trade from start until the end of the day AND from 00:00 until end.
//    Equivalently: active = NOT in the gap [end, start).
//    Same-day windows (start < end) keep the original inclusive/exclusive semantics.
bool CheckSessionTime()
  {
   if(!InpSessionEnable) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpSessionStartHour < InpSessionEndHour)
      // Normal same-day window: [start, end)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   else
      // Overnight wrap-around window: active EXCEPT in the gap [end, start)
      return !(h >= InpSessionEndHour && h < InpSessionStartHour);
  }

// [V7-02] Returns true if the signal direction aligns with the HTF EMA trend.
bool CheckHTFTrend(bool isBuy)
  {
   if(!InpHTFEnable) return true;
   if(g_htfEMAHandle == INVALID_HANDLE) return true;   // degrade gracefully
   double emaBuf[];
   if(CopyBuffer(g_htfEMAHandle, 0, 1, 1, emaBuf) < 1) return true;
   double emaVal  = emaBuf[0];
   // [V8-18] BUG FIX (BUG C): A long entry executes at the ASK, not the BID. Using BID
   //    for buy-direction comparison could pass the trend filter even when the actual
   //    entry price (ASK) is below the EMA — i.e. the trade is entered against the
   //    filter's intent. On instruments with spreads >= 1 pip this is material at EMA
   //    boundaries. Fix: compare ASK for buys, BID for sells (the respective fill prices).
   double curPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   aligned  = isBuy ? (curPrice > emaVal) : (curPrice < emaVal);
   if(!aligned)
      LogTradeExec(StringFormat(
         "CheckHTFTrend: %s blocked — %s %.5f %s HTF EMA(%.0f) %.5f",
         isBuy?"BUY":"SELL", isBuy?"ASK":"BID", curPrice, isBuy?"<=":">", (double)InpHTFEMA, emaVal));
   return aligned;
  }

// [V8-19] BUG FIX (BUG A scope): The V8-18 fix placed the new-day state reset inside
//    CheckDailyLoss(), which returns immediately when InpMaxDailyLossPercent = 0.0
//    (the default). A user running InpHaltConsecLosses without a daily-loss percentage
//    never hits the reset code, so the permanent-halt defect survives on default params.
//    Fix: extract new-day logic into CheckNewDay() and call it unconditionally from the
//    top of CheckRiskConditions(), independent of the daily-loss percentage gate.

// ==========================================================================
// RISK GOVERNANCE MODEL — INSTANCE-SCOPED (declared V8-20)
//
//   All risk guards in this EA are INSTANCE-SCOPED: they measure P&L and
//   exposure attributable to THIS EA INSTANCE only (this magic + this symbol).
//
//   Implementation pillars:
//     • g_dayStartBalance — set from ACCOUNT_BALANCE at the start of each
//       trading day, AFTER this instance's positions have settled (CheckNewDay).
//       Represents the account equity contribution this instance began the day
//       with. Persisted via GVKey("DayStartBal") so mid-session restarts do
//       not reset the baseline.
//     • Instance open P&L — derived in CheckDailyLoss/CheckRiskConditions by
//       summing PositionGetDouble(POSITION_PROFIT) for our magic + symbol.
//       This is subtracted from ACCOUNT_EQUITY to get an instance-only view
//       of equity movement, making the daily-loss guard independent of what
//       other EA instances on the same account are doing.
//     • g_equityHalted — instance-scoped; persisted per magic + symbol GVKey.
//     • g_dailyLossHalted / g_sessionHalted — same scoping.
//
//   Consequence: a second EA instance on the same account cannot trigger this
//   instance's equity or daily-loss halt, and vice-versa.
// ==========================================================================

void CheckNewDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // [V8-18] NEWDAY-MONTH-ROLLOVER: use a full YYYYMMDD key so month/year rollovers
   //    are correctly detected. dt.day alone repeats every month (e.g. Jan-05 and
   //    Feb-05 both have dt.day=5), causing CheckNewDay() to skip the new-day reset
   //    on the first trading day of every new month and year.
   int dateKey = dt.year * 10000 + dt.mon * 100 + dt.day;
   if(dateKey == g_dayStartDay) return;

   // [V8-07] Defer snapshot until previous session's positions have settled.
   // [V8-22] NEWDAY-DEFER: cap the deferral at 24 hours. A position held over a
   //    weekend gap could otherwise leave the day-start balance snapshot days stale,
   //    making CheckDailyLoss() compare equity against an increasingly meaningless
   //    baseline. If positions are still open after 24 h, fire the snapshot anyway.
   bool positionsOpen = false;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && (ulong)PositionGetInteger(POSITION_MAGIC) == g_Magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
        { positionsOpen = true; break; }
     }
   if(positionsOpen)
     {
      if(g_newDayDeferStart == 0) g_newDayDeferStart = TimeCurrent();
      if(TimeCurrent() - g_newDayDeferStart < 86400) return;   // defer up to 24 h
      LogRisk("CheckNewDay: 24-hour defer deadline reached — forcing new-day snapshot with open position(s).");
     }
   g_newDayDeferStart = 0;

   g_dayStartDay       = dateKey;   // [V8-18] YYYYMMDD — safe across month/year rollover
   g_dayStartBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLossHalted   = false;
   g_sessionHalted     = false;
   g_consecutiveLosses = 0;
   // [V8-15] SIZE-RED-NEWDAY: reset the size-reduction penalty on a new trading day.
   //    The penalty phase is tied to a run of consecutive intraday losses; carrying it
   //    forward to the next session silently penalises the EA for the wrong session's
   //    performance. g_consecutiveLosses is already reset here; g_sizeReductionLeft
   //    follows for consistency.
   g_sizeReductionLeft = 0;
   // [V8-15] EQUITY-HALT-RECOVER: equity halt resets on a new trading day so the
   //    EA can resume after the account recovers overnight. Unlike session/daily-loss
   //    halts, equity halt cannot self-reset intraday because the triggering condition
   //    (equity >= balance ± threshold) may still be true. The new-day balance snapshot
   //    fires after open positions settle, so the equity comparison will use fresh
   //    post-settlement values. If the threshold is still breached on the first
   //    CheckRiskConditions() of the new day, the halt is immediately re-applied.
   g_equityHalted = false;
   RiskStateSave();   // [V8-10]
   LogRisk(StringFormat("New day — balance snapshot: %.2f | All session risk state reset. [V8-07/V8-18/V8-19]",
                        g_dayStartBalance));
  }

// [V7-04] Returns true if daily loss limit has not been breached.
//    New-day balance snapshot is now handled by CheckNewDay() above,
//    called unconditionally from CheckRiskConditions().
// [V8-20] RISK-MODEL-DECLARE: loss is measured instance-scoped.
//    instEquity = ACCOUNT_EQUITY - open P&L from OTHER instances/symbols.
//    This is equivalent to g_dayStartBalance + this instance's running P&L,
//    making the guard independent of other EAs on the same account.
bool CheckDailyLoss()
  {
   if(InpMaxDailyLossPercent <= 0.0) return true;
   if(g_dailyLossHalted) return false;

   // Derive instance-only equity: start from account equity, then remove
   // open P&L that belongs to other symbols or magic numbers on this account.
   // This gives: instEquity ≈ g_dayStartBalance + this EA's cumulative P&L.
   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double otherPnL      = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == g_Magic &&
         PositionGetString(POSITION_SYMBOL)        == _Symbol)  continue;
      // POSITION_COMMISSION was deprecated in MT5 build 2755+ and is not
      // available on live positions. Commission is only recoverable from
      // closed deal history. For the purpose of isolating this instance's
      // running P&L, POSITION_PROFIT + POSITION_SWAP is the correct and
      // complete set of live-position floating values. [V8-20]
      otherPnL += PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);
     }
   double instEquity = accountEquity - otherPnL;   // this EA's equity contribution

   double lossLimit  = g_dayStartBalance * InpMaxDailyLossPercent / 100.0;
   if(g_dayStartBalance - instEquity >= lossLimit)
     {
      g_dailyLossHalted = true;
      RiskStateSave();   // [V8-10]
      Alert(StringFormat(EA_NAME " — DAILY LOSS LIMIT REACHED (%.1f%%). Halted until next day.", InpMaxDailyLossPercent));
      LogRisk(StringFormat(
         "DAILY LOSS LIMIT REACHED [instance-scoped] | DayStart: %.2f"
         " | InstEquity: %.2f | OtherPnL excluded: %.2f | Limit: %.2f [V8-20]",
         g_dayStartBalance, instEquity, otherPnL, lossLimit));
      return false;
     }
   return true;
  }

// [V7-06] Returns the effective signal threshold scaled to current ATR volatility.
int ComputeAdaptiveThreshold()
  {
   if(!InpAdaptiveThreshold || !g_atrBaselineReady || g_atrBaseline <= 0.0)
      return g_signalThreshold;
   if(g_handleATR == INVALID_HANDLE) return g_signalThreshold;

   double atrBuf[];
   int barsOnChart = iBars(_Symbol, PERIOD_CURRENT);
   if(barsOnChart <= InpATR_Period + 1) return g_signalThreshold;
   if(CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) < 1) return g_signalThreshold;
   double atrNow = atrBuf[0];
   if(atrNow <= 0.0) return g_signalThreshold;

   double ratio  = atrNow / g_atrBaseline;
   double scaled = g_signalThreshold * ratio;
   int thresh = (int)MathRound(scaled);
   thresh = MathMax((int)InpAdaptiveThreshMin, MathMin((int)InpAdaptiveThreshMax, thresh));
   return thresh;
  }

// [V7-08] Returns true if the SL cooldown for the given direction has elapsed.
bool CheckSLCooldown(bool isBuy)
  {
   if(InpSLCooldownBars <= 0) return true;
   datetime lastSLBarTime = isBuy ? g_lastSLBarTimeBuy : g_lastSLBarTimeSell;
   if(lastSLBarTime == 0) return true;
   int barsSinceSL = iBarShift(_Symbol, PERIOD_CURRENT, lastSLBarTime);
   if(barsSinceSL >= 0 && barsSinceSL < InpSLCooldownBars)
     {
      LogTradeExec(StringFormat(
         "CheckSLCooldown: %s blocked — %d bars since last SL (cooldown=%d)",
         isBuy?"BUY":"SELL", barsSinceSL, InpSLCooldownBars));
      return false;
     }
   return true;
  }

//==========================================================================
// SECTION 13: SIGNAL EVALUATION & DISPATCH
//==========================================================================

void EvalAndFireSignal()
  {
   if(!g_signalsEnabled) return;
   int nBars = ArraySize(g_bars);
   if(nBars == 0) return;

   // [V8-23] BAR-ASYMMETRY (documented): signals evaluate bar bi = nBars-1, the
   //    live current bar, so the chart arrow appears on the bar where the signal
   //    condition is first satisfied. PlaceOrders() evaluates bi = nBars-2 (the
   //    most recently *closed* bar) because automated entries are gated on bar-close
   //    confirmation; an open bar can still invalidate the setup before close.
   //    Consequence visible on chart: a BUY arrow on bar N does NOT guarantee an
   //    entry order if bar N closes bearish. This is intentional design.
   int bi = nBars - 1;
   if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0) return;
   if(!g_bars[bi].sorted) ComputeBarSignals(bi);

   if(bi == g_sigCacheBarIdx && g_bars[bi].total_vol == g_sigCacheVol) return;
   g_sigCacheBarIdx = bi;
   g_sigCacheVol    = g_bars[bi].total_vol;

   if(g_lastSignalBarTime > 0)
     {
      int barsSinceLast = iBarShift(_Symbol, PERIOD_CURRENT, g_lastSignalBarTime);
      if(barsSinceLast >= 0 && barsSinceLast < g_signalFreqBars) return;
     }

   // [V8-20] Compute OFS once, pass to HFTSignal to eliminate the redundant internal scan.
   int    ofsScore   = ComputeOFScore(bi);
   double hftScore   = ComputeHFTSignal(bi, ofsScore);

   // [V7-06] Use adaptive threshold for signal alerts
   int    effThresh  = ComputeAdaptiveThreshold();

   bool isBuySignal  = (hftScore >=  (double)effThresh);
   bool isSellSignal = (hftScore <= -(double)effThresh);
   if(!isBuySignal && !isSellSignal) return;

   // [V7-07] Conviction diversity gate — require enough distinct components
   ConvictionResult conv = GetConvictionResult(bi, isBuySignal);
   if(conv.componentCount < InpMinConvictionComp)
     {
      LogSignal(StringFormat(
         "Signal suppressed — only %d conviction component(s) present, need %d. Label: %s",
         conv.componentCount, InpMinConvictionComp, conv.label));
      return;
     }

   g_lastSignalBarTime = g_bars[bi].bar_time;

   int    displayScore = (int)MathRound(isBuySignal ? hftScore : -hftScore);
   string dir          = isBuySignal ? "BUY" : "SELL";
   string tf           = EnumToString(Period());
   StringReplace(tf, "PERIOD_", "");

   LogSignal(StringFormat(
      EA_NAME " — %s | %s %s | HFT: %d (thresh=%d) | OFS: %d"
      " | Conviction: %s (%d comps) | Bar: %s | NakedPOC: %s | DeltaDiv: %s",
      dir, _Symbol, tf,
      displayScore, effThresh, ofsScore,
      conv.label, conv.componentCount,
      TimeToString(g_bars[bi].bar_time, TIME_DATE|TIME_MINUTES),
      g_bars[bi].is_naked_poc        ? "YES" : "NO",
      g_bars[bi].is_delta_divergence ? "YES" : "NO"));

   if(InpShowVisuals)
     {
      double sigPrice = isBuySignal
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      DrawSignalMarker(g_sigMarkerCount++, isBuySignal, sigPrice,
                       g_bars[bi].bar_time, displayScore, ofsScore, conv.label);
      CounterSave();   // [V8-22] CTR-ANALYSIS: flush counter to GlobalVariables immediately
     }

   if(isBuySignal)  PlaySound(InpSignalBuySound);
   else             PlaySound(InpSignalSellSound);
  }

//==========================================================================
// SECTION 14: AUTOMATED TRADING ENGINE
//==========================================================================

void RefreshSymbolInfo()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_Pip     = ((digits % 2) == 1) ? _Point * 10.0 : _Point;
   g_VolMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_VolMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_VolStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_VolStep <= 0.0) g_VolStep = 0.01;
   LogSystem(StringFormat(
      "SymbolInfo | %s | digits=%d | g_Pip=%.6f | Vol Min/Max/Step=%.2f/%.2f/%.2f",
      _Symbol, digits, g_Pip, g_VolMin, g_VolMax, g_VolStep));
  }

bool IsNewBar()
  {
   datetime current = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(current == 0 || current == g_LastBarTime) return false;
   g_LastBarTime = current;
   return true;
  }

bool IsTradeAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      static datetime s_t1 = 0;
      if(TimeCurrent()-s_t1 > 60) { LogWarning("Terminal trade not allowed."); s_t1=TimeCurrent(); }
      return false;
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      static datetime s_t2 = 0;
      if(TimeCurrent()-s_t2 > 60) { LogWarning("EA trade permission denied."); s_t2=TimeCurrent(); }
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      static datetime s_t3 = 0;
      if(TimeCurrent()-s_t3 > 60) { LogWarning("Account trade not allowed."); s_t3=TimeCurrent(); }
      return false;
     }
   return true;
  }

int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
      count++;
     }
   return count;
  }

// [V8-19] POSITION-CAP-PENDING: count open positions + pending entry orders together
//    so InpMaxPositions caps total exposure, not just filled positions.
//    Previously, stop orders placed by this EA were not counted; with InpMaxPositions=1
//    a second stop order could be placed while the first was still pending, doubling
//    intended exposure the moment both filled. The combined count is used wherever
//    the position cap is enforced.
int CountExposure()
  {
   int count = CountOpenPositions();
   for(int i = OrdersTotal()-1; i >= 0; i--)
     {
      ulong oTk = OrderGetTicket(i);
      if(oTk == 0) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != g_Magic) continue;
      if(OrderGetString(ORDER_SYMBOL)        != _Symbol)  continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY_STOP  || ot == ORDER_TYPE_SELL_STOP ||
         ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_SELL_LIMIT)
         count++;
     }
   return count;
  }

ENUM_ORDER_TYPE_FILLING GetBrokerFillingMode()
  {
   // SYMBOL_FILLING_MODE is a 2-bit mask: bit-0 = FOK supported, bit-1 = IOC supported.
   // ORDER_FILLING_RETURN is the broker default when neither is explicitly flagged —
   // there is no dedicated bitmask constant for it in MQL5.
   long flags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   static bool s_warned = false;
   if(!s_warned) { LogWarning(StringFormat("Filling flags=0x%X: FOK/IOC not flagged; defaulting to RETURN.", flags)); s_warned=true; }
   return ORDER_FILLING_RETURN;
  }

// [V7-01] True risk-based lot sizing.
//    lot = (Balance × RiskPct%) / (SLDistPoints × PointValuePerLot)
//    Margin-based approach retained as fallback when SL distance is unknown.
double CalcLot(double slDistPoints, bool isBuy = true)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot     = InpFixedLot;   // safe default; overwritten by all active branches below

   if(InpUseRiskPercent)
     {
      double riskAmt = balance * InpRiskPercent / 100.0;
      bool   usedTrueRisk = false;

      if(slDistPoints > 0.0)
        {
         // [V8-18] CALCLOT-ROBUST-RISK: use OrderCalcProfit to compute the actual
         //    account-currency loss for 1 lot at the proposed SL distance. This is
         //    broker-robust across CFDs, futures, and non-FX instruments where
         //    tickValue * (_Point / tickSize) gives incorrect results due to broker
         //    metadata inconsistencies or non-standard contract specifications.
         MqlTick cTick;
         double refPrice = 0.0;
         if(SymbolInfoTick(_Symbol, cTick))
            refPrice = isBuy ? cTick.ask : cTick.bid;

         double slPrice     = isBuy ? refPrice - slDistPoints * _Point
                                    : refPrice + slDistPoints * _Point;
         double lossFor1Lot = 0.0;
         ENUM_ORDER_TYPE calcType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

         if(refPrice > 0.0 &&
            OrderCalcProfit(calcType, _Symbol, 1.0, refPrice, slPrice, lossFor1Lot) &&
            lossFor1Lot < 0.0)
           {
            double lossAbs = MathAbs(lossFor1Lot);
            lot = riskAmt / lossAbs;
            usedTrueRisk = true;
            LogTradeExec(StringFormat(
               "CalcLot ROBUST-RISK | Bal: %.2f | Risk: %.1f%% = $%.2f"
               " | SL: %.0f pts | Loss/lot: $%.4f | Raw lot: %.4f",
               balance, InpRiskPercent, riskAmt, slDistPoints, lossAbs, lot));
           }
         else
            LogWarning("CalcLot: OrderCalcProfit unavailable — using margin fallback");
        }
      else
         LogWarning("CalcLot: SL distance = 0 — using margin fallback");

      if(!usedTrueRisk)
        {
         // Margin-based fallback: Allocation / MarginFor1Lot
         MqlTick lastTick;
         double  askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(SymbolInfoTick(_Symbol, lastTick) && lastTick.ask > 0.0) askPrice = lastTick.ask;
         double marginFor1Lot = 0.0;
         // [V8-17] CALCLOT-MARGIN-ORDERTYPE: use direction-correct order type so sell-side
         //    margin is accurate on instruments where buy/sell margin differs.
         ENUM_ORDER_TYPE margType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         bool   mok = OrderCalcMargin(margType, _Symbol, 1.0, askPrice, marginFor1Lot);
         if(mok && marginFor1Lot > 0.0)
            lot = riskAmt / marginFor1Lot;
         else
            lot = InpFixedLot;
        }
     }
   else
     {
      lot = InpFixedLot;
     }

   // [V7-05] Apply 50% size reduction penalty if in consecutive-loss penalty phase
   if(g_sizeReductionLeft > 0)
     {
      lot *= 0.5;
      LogRisk(StringFormat("CalcLot: 50%% size reduction active (%d trades remaining)", g_sizeReductionLeft));
     }

   // Normalise to broker constraints
   double step   = (g_VolStep > 0.0) ? g_VolStep : 0.01;
   double lotMin = (g_VolMin  > 0.0) ? g_VolMin  : 0.01;
   double lotMax = (g_VolMax  > 0.0) ? g_VolMax  : 100.0;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lotMin, MathMin(lotMax, lot));
   lot = NormalizeDouble(lot, 2);

   LogTradeExec(StringFormat("CalcLot FINAL | %s | Lot: %.2f", _Symbol, lot));
   return lot;
  }

void CalcSLTP(bool isBuy, double entry, double atrVal,
              double barHigh, double barLow, double bufDist,
              double &sl, double &tp)
  {
   sl = 0.0; tp = 0.0;

   if(InpUseStopLoss)
     {
      switch(InpSLMode)
        {
         case SL_MODE_BAR:
            sl = isBuy ? NormalizeDouble(barLow  - bufDist, _Digits)
                       : NormalizeDouble(barHigh + bufDist, _Digits);
            break;
         case SL_MODE_PIPS:
            sl = isBuy ? NormalizeDouble(entry - InpSLPips * g_Pip, _Digits)
                       : NormalizeDouble(entry + InpSLPips * g_Pip, _Digits);
            break;
         case SL_MODE_ATR:
            if(atrVal > 0.0)
               sl = isBuy ? NormalizeDouble(entry - InpSLATRMult * atrVal, _Digits)
                          : NormalizeDouble(entry + InpSLATRMult * atrVal, _Digits);
            else
              {
               LogWarning("CalcSLTP: ATR=0, fallback to Fixed-Pips SL");
               sl = isBuy ? NormalizeDouble(entry - InpSLPips * g_Pip, _Digits)
                          : NormalizeDouble(entry + InpSLPips * g_Pip, _Digits);
              }
            break;
        }
     }

   if(!InpUseTakeProfit) return;
   double slDist = (sl > 0.0) ? MathAbs(entry - sl) : InpSLPips * g_Pip;
   switch(InpTPMode)
     {
      case TP_MODE_RR:
         if(slDist > 0.0)
            tp = isBuy ? NormalizeDouble(entry + slDist * InpRiskRewardRatio, _Digits)
                       : NormalizeDouble(entry - slDist * InpRiskRewardRatio, _Digits);
         break;
      case TP_MODE_PIPS:
         tp = isBuy ? NormalizeDouble(entry + InpTPPips * g_Pip, _Digits)
                    : NormalizeDouble(entry - InpTPPips * g_Pip, _Digits);
         break;
      case TP_MODE_ATR:
         if(atrVal > 0.0)
            tp = isBuy ? NormalizeDouble(entry + InpTPATRMult * atrVal, _Digits)
                       : NormalizeDouble(entry - InpTPATRMult * atrVal, _Digits);
         else
           {
            LogWarning("CalcSLTP: ATR=0, fallback to Fixed-Pips TP");
            tp = isBuy ? NormalizeDouble(entry + InpTPPips * g_Pip, _Digits)
                       : NormalizeDouble(entry - InpTPPips * g_Pip, _Digits);
           }
         break;
     }
  }

bool trade_OrderDelete(ulong ticket)
  {
   if(!IsTradeAllowed()) return false;
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;
   bool ok = OrderSend(req, res);
   if(!ok)
      LogTradeExec(StringFormat("OrderDelete failed: ticket=%I64u retcode=%u", ticket, res.retcode));
   return ok;
  }

void DeleteAllPending()
  {
   ulong tickets[]; int tCount = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != g_Magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)        continue;
      ArrayResize(tickets, tCount+1);
      tickets[tCount++] = ticket;
     }
   for(int i = 0; i < tCount; i++) trade_OrderDelete(tickets[i]);
  }

// [V7-13] Modular risk pre-check. Returns true if conditions allow a new trade.
bool CheckRiskConditions(bool isBuy)
  {
   // [V8-19] New-day state reset runs unconditionally regardless of InpMaxDailyLossPercent.
   //    Previously this logic lived inside CheckDailyLoss() which returns early when the
   //    daily-loss percentage is 0 — leaving the session halt permanently active on default params.
   CheckNewDay();

   // [V7-04] Daily loss limit
   if(!CheckDailyLoss()) return false;

   // [V7-05] Session halt from consecutive losses
   if(g_sessionHalted)
     {
      LogRisk("Session halted due to consecutive loss limit. No new entries.");
      return false;
     }

   // Equity guards
   // [V8-26] EQUITY-HALT-PERSIST / EQUITY-HALT-MANAGE / EQUITY-HALT-ALERT:
   //    Old code set g_autoTrade=false, which (a) was not persisted, (b) also blocked
   //    ManagePositions() on open positions, and (c) fired no Alert(). Replaced with
   //    g_equityHalted which gates only new entries (CheckRiskConditions returns false),
   //    is persisted via RiskStateSave/Load, and fires Alert() matching other halt types.
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   // [V8-18] EQUITY-GUARD-INSTANCE-SCOPE: use g_dayStartBalance (this instance's
   //    session-open baseline) instead of live ACCOUNT_BALANCE as the equity reference.
   //    ACCOUNT_BALANCE is account-wide: with multiple EA instances on the same account,
   //    one instance's P&L shift would move the shared balance reference and could
   //    trigger another instance's equity halt prematurely. Using g_dayStartBalance
   //    makes all risk guards consistently instance-scoped, matching the daily-loss guard.
   //    Falls back to live ACCOUNT_BALANCE only if the session snapshot is not yet set.
   double instBalance = (g_dayStartBalance > 0.0) ? g_dayStartBalance
                                                   : AccountInfoDouble(ACCOUNT_BALANCE);
   if(!g_equityHalted && InpMaxEquityProfit > 0.0 && equity >= instBalance + InpMaxEquityProfit)
     {
      g_equityHalted = true;
      RiskStateSave();
      Alert(EA_NAME " — EQUITY PROFIT TARGET HIT (+"
            + DoubleToString(InpMaxEquityProfit, 2) + "). Auto-trading halted. [V8-26/V8-18]");
      LogRisk(StringFormat("EQUITY PROFIT HALT: equity=%.2f instBalance=%.2f threshold=+%.2f [instance-scoped]",
                           equity, instBalance, InpMaxEquityProfit));
     }
   if(!g_equityHalted && InpMaxEquityLoss > 0.0 && equity <= instBalance - InpMaxEquityLoss)
     {
      g_equityHalted = true;
      RiskStateSave();
      Alert(EA_NAME " — EQUITY LOSS LIMIT HIT (-"
            + DoubleToString(InpMaxEquityLoss, 2) + "). Auto-trading halted. [V8-26/V8-18]");
      LogRisk(StringFormat("EQUITY LOSS HALT: equity=%.2f instBalance=%.2f threshold=-%.2f [instance-scoped]",
                           equity, instBalance, InpMaxEquityLoss));
     }
   if(g_equityHalted)
     {
      static datetime s_lastEquityLog = 0;
      if(TimeCurrent() - s_lastEquityLog > 60)
        { LogRisk("Equity halt active. No new entries."); s_lastEquityLog = TimeCurrent(); }
      return false;
     }

   // [V8-19] POSITION-CAP-PENDING: use CountExposure() (open + pending) so that
   //    pending stop/limit orders already in the broker's queue count against the cap.
   if(InpMaxPositions > 0 && CountExposure() >= InpMaxPositions) return false;

   // [V7-10] Dual spread check: absolute pips AND ATR-relative
   double spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(InpSpreadFilter)
     {
      if(spreadPts > InpMaxSpread * g_Pip)
        { LogTradeExec(StringFormat("Spread filter: %.1f pips > limit %.1f pips", spreadPts/g_Pip, InpMaxSpread)); return false; }
      if(InpSpreadATRRatio > 0.0 && g_handleATR != INVALID_HANDLE)
        {
         double atrBuf[];
         if(CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) == 1 && atrBuf[0] > 0.0)
           {
            if(spreadPts > atrBuf[0] * InpSpreadATRRatio)
              { LogTradeExec(StringFormat("Spread ATR filter: %.5f > ATR×%.2f=%.5f", spreadPts, InpSpreadATRRatio, atrBuf[0]*InpSpreadATRRatio)); return false; }
           }
        }
     }

   // [V7-03] Session time
   if(!CheckSessionTime())
     { LogTradeExec("Session time filter: outside active window."); return false; }

   // [V7-08] SL cooldown per direction
   if(!CheckSLCooldown(isBuy)) return false;

   // [V7-02] HTF trend alignment
   if(!CheckHTFTrend(isBuy)) return false;

   return true;
  }

bool trade_Send(ENUM_TRADE_REQUEST_ACTIONS action,
                ENUM_ORDER_TYPE            orderType,
                double price, double sl, double tp, double lot,
                string comment, ulong &outTicket,
                double &outSL, double &outTP)   // [V8-27] SLTP-LOG-CLAMP: actual sent values
  {
   outTicket = 0;
   if(!IsTradeAllowed()) return false;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   MqlTick lastTick;
   if(!SymbolInfoTick(_Symbol, lastTick))
     { LogTradeExec(StringFormat("trade_Send: SymbolInfoTick failed (%d)", GetLastError())); return false; }
   double freshAsk = lastTick.ask;
   double freshBid = lastTick.bid;

   if(action == TRADE_ACTION_DEAL)
     {
      if(orderType == ORDER_TYPE_BUY)  price = freshAsk;
      else if(orderType == ORDER_TYPE_SELL) price = freshBid;
     }

   if(action == TRADE_ACTION_PENDING)
     {
      if(orderType == ORDER_TYPE_BUY_STOP && price <= freshAsk)
        { LogTradeExec("BuyStop skipped: entry not above current ask"); return false; }
      if(orderType == ORDER_TYPE_SELL_STOP && price >= freshBid)
        { LogTradeExec("SellStop skipped: entry not below current bid"); return false; }
     }

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = MathMax((double)stopsLevel, 1.0) * _Point;
   double refPrice   = (action == TRADE_ACTION_DEAL)
                       ? ((orderType == ORDER_TYPE_BUY) ? freshAsk : freshBid)
                       : price;

   req.action       = action;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = orderType;
   req.price        = NormalizeDouble(price, _Digits);
   req.sl           = NormalizeDouble(sl,    _Digits);
   req.tp           = NormalizeDouble(tp,    _Digits);
   req.magic        = g_Magic;
   req.comment      = comment;
   req.type_filling = GetBrokerFillingMode();
   req.expiration   = 0;

   // [V8-27] SLTP-LOG-CLAMP: initialise output params to unclamped values; updated
   //    below if broker minDist forces an adjustment so the caller can log accurately.
   outSL = sl;
   outTP = tp;

   if(sl > 0.0 && MathAbs(refPrice - sl) < minDist)
     {
      req.sl = NormalizeDouble(
         (orderType==ORDER_TYPE_BUY_STOP || orderType==ORDER_TYPE_BUY)
         ? refPrice - minDist : refPrice + minDist, _Digits);
      outSL = req.sl;   // [V8-27] record clamped value for caller
      LogWarning(StringFormat("SLTP-CLAMP: SL adjusted %.5f → %.5f (minDist=%.5f)",
                              sl, req.sl, minDist));
     }
   if(tp > 0.0 && MathAbs(refPrice - tp) < minDist)
     {
      req.tp = NormalizeDouble(
         (orderType==ORDER_TYPE_BUY_STOP || orderType==ORDER_TYPE_BUY)
         ? refPrice + minDist : refPrice - minDist, _Digits);
      outTP = req.tp;   // [V8-27] record clamped value for caller
      LogWarning(StringFormat("SLTP-CLAMP: TP adjusted %.5f → %.5f (minDist=%.5f)",
                              tp, req.tp, minDist));
     }

   bool ok = false;
   for(int attempt = 1; attempt <= 3; attempt++)
     {
      if(attempt > 1 && action == TRADE_ACTION_DEAL)
        {
         // [V8-20] RETRY-DUPE-HARDEN: strengthened from V8-19.
         //    V8-19 matched on magic + symbol + volume only — too loose.
         //    A same-volume position from an earlier (unrelated) entry would
         //    be mistaken for the current retry's fill and suppress a genuine
         //    second trade. The new identity set requires:
         //      1. Correct magic + symbol (unchanged)
         //      2. Correct direction (buy/sell must match orderType)
         //      3. Volume within floating-point tolerance (unchanged)
         //      4. Open price within 10× broker minDist of current market
         //         (rules out stale positions at very different prices)
         //      5. Comment starts with "FP_" (our tag prefix) — filters out
         //         positions opened by other tools sharing the same magic
         //    For deal history, criteria 1-3 + 5 apply; price proximity uses
         //    dealPrice vs current market.  Logging states each criterion so
         //    the journal is fully auditable.
         bool alreadyFilled    = false;
         bool isOurBuy         = (orderType == ORDER_TYPE_BUY);
         double marketRef      = isOurBuy ? freshAsk : freshBid;
         double priceProxLimit = minDist * 10.0;   // 10× broker stops level

         // 1. Live positions — require direction, volume, price proximity, comment
         for(int pi = PositionsTotal()-1; pi >= 0 && !alreadyFilled; pi--)
           {
            ulong ptk = PositionGetTicket(pi);
            if(ptk == 0) continue;
            if((ulong)PositionGetInteger(POSITION_MAGIC) != g_Magic) continue;
            if(PositionGetString(POSITION_SYMBOL)        != _Symbol)  continue;
            // direction check
            ENUM_POSITION_TYPE pDir = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            bool posIsBuy = (pDir == POSITION_TYPE_BUY);
            if(posIsBuy != isOurBuy) continue;
            // volume check
            if(MathAbs(PositionGetDouble(POSITION_VOLUME) - req.volume) >= 1e-8) continue;
            // price proximity check
            double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
            if(MathAbs(openPx - marketRef) > priceProxLimit) continue;
            // comment prefix check
            string posComment = PositionGetString(POSITION_COMMENT);
            if(StringFind(posComment, "FP_") != 0) continue;
            alreadyFilled = true;
            outTicket = ptk;
            LogTradeExec(StringFormat(
               "RETRY-DUPE-GUARD [pos]: fill confirmed ticket=%I64u dir=%s vol=%.2f"
               " openPx=%s marketRef=%s comment=%s [V8-20]",
               outTicket, isOurBuy?"BUY":"SELL", req.volume,
               DoubleToString(openPx,_Digits), DoubleToString(marketRef,_Digits),
               posComment));
           }
         // 2. Recent deal history (covers fill-to-position propagation window)
         if(!alreadyFilled &&
            HistorySelect(TimeCurrent() - 60, TimeCurrent() + 1))
           {
            int dTotal = HistoryDealsTotal();
            for(int di = dTotal-1; di >= 0 && !alreadyFilled; di--)
              {
               ulong dTk = HistoryDealGetTicket(di);
               if((ulong)HistoryDealGetInteger(dTk, DEAL_MAGIC)  != g_Magic) continue;
               if(HistoryDealGetString(dTk, DEAL_SYMBOL)         != _Symbol)  continue;
               if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTk, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
               // direction check
               ENUM_DEAL_TYPE dType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dTk, DEAL_TYPE);
               bool dealIsBuy = (dType == DEAL_TYPE_BUY);
               if(dealIsBuy != isOurBuy) continue;
               // volume check
               if(MathAbs(HistoryDealGetDouble(dTk, DEAL_VOLUME) - req.volume) >= 1e-8) continue;
               // price proximity check
               double dealPx = HistoryDealGetDouble(dTk, DEAL_PRICE);
               if(MathAbs(dealPx - marketRef) > priceProxLimit) continue;
               // comment prefix check
               string dealComment = HistoryDealGetString(dTk, DEAL_COMMENT);
               if(StringFind(dealComment, "FP_") != 0) continue;
               alreadyFilled = true;
               outTicket = (ulong)HistoryDealGetInteger(dTk, DEAL_POSITION_ID);
               LogTradeExec(StringFormat(
                  "RETRY-DUPE-GUARD [deal]: fill confirmed ticket=%I64u dir=%s vol=%.2f"
                  " dealPx=%s marketRef=%s comment=%s [V8-20]",
                  outTicket, isOurBuy?"BUY":"SELL", req.volume,
                  DoubleToString(dealPx,_Digits), DoubleToString(marketRef,_Digits),
                  dealComment));
              }
           }
         if(alreadyFilled)
           { ok = true; break; }   // outTicket already set and logged above; treat as success

         if(SymbolInfoTick(_Symbol, lastTick))
           {
            if(orderType == ORDER_TYPE_BUY)  req.price = NormalizeDouble(lastTick.ask, _Digits);
            else if(orderType == ORDER_TYPE_SELL) req.price = NormalizeDouble(lastTick.bid, _Digits);
            // [V8-18] RETRY-SLTP-RECLAMP: re-clamp SL/TP against the refreshed fill
            //    price on each retry. Attempt-1 clamping used the old price; if the
            //    market moved, stops may now be inside broker minDist at the new price
            //    or the prior clamp may no longer be needed. Reset to caller values
            //    and re-run the identical clamping logic. outSL/outTP stay accurate.
            double retryRef = req.price;
            req.sl = NormalizeDouble(sl, _Digits);
            req.tp = NormalizeDouble(tp, _Digits);
            outSL = sl; outTP = tp;
            if(sl > 0.0 && MathAbs(retryRef - sl) < minDist)
              {
               req.sl = NormalizeDouble(
                  (orderType == ORDER_TYPE_BUY) ? retryRef - minDist : retryRef + minDist, _Digits);
               outSL = req.sl;
              }
            if(tp > 0.0 && MathAbs(retryRef - tp) < minDist)
              {
               req.tp = NormalizeDouble(
                  (orderType == ORDER_TYPE_BUY) ? retryRef + minDist : retryRef - minDist, _Digits);
               outTP = req.tp;
              }
           }
        }
      ok = OrderSend(req, res);
      if(ok) break;
      uint rc = res.retcode;
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_CONNECTION && rc != TRADE_RETCODE_TIMEOUT) break;
      // [V8-15] SPINWAIT-CPU: spin-wait replaced with Sleep(10).
      //    The tick thread is blocked either way in MQL5's single-threaded execution
      //    model. Sleep(10) yields the CPU to other processes; a busy spin does not.
      //    10 ms is sufficient for a broker price refresh and reduces total retry
      //    latency from ≤150 ms to ≤30 ms across three attempts.
      Sleep(10);
     }

   if(!ok)
      LogTradeExec(StringFormat(
         "OrderSend FAILED: retcode=%u action=%s type=%s price=%s sl=%s tp=%s lot=%.2f",
         res.retcode, EnumToString(action), EnumToString(orderType),
         DoubleToString(req.price,_Digits), DoubleToString(req.sl,_Digits),
         DoubleToString(req.tp,_Digits), req.volume));
   else if(res.order != 0)
      outTicket = res.order;   // normal fill: use broker-assigned ticket
   // else: outTicket was set by dupe guard; leave it
   return ok;
  }

// [V7-13] PlaceOrders — now fully modular with all v7.00 filters applied.
void PlaceOrders()
  {
   if(!g_autoTrade && !g_analysisMode) return;
   if(!g_analysisMode && !IsTradeAllowed()) return;

   int nBars = ArraySize(g_bars);
   if(nBars < 2) return;

   // [V8-23] BAR-ASYMMETRY (documented): use last *closed* bar (nBars-2) for order
   //    placement confirmation. See matching comment in EvalAndFireSignal() for full
   //    explanation of why signal bar and order bar differ by one.
   int bi = nBars - 2;   // last closed bar
   if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0) return;
   if(!g_bars[bi].sorted) ComputeBarSignals(bi);

   double barHigh = g_bars[bi].high;
   double barLow  = g_bars[bi].low;
   if(barHigh == 0.0 || barLow == 0.0) return;

   // [V8-20] Compute OFS once and reuse: passing it to ComputeHFTSignal eliminates the
   //    redundant internal ComputeOFScore call, and removes the explicit duplicate call
   //    below. Previously this bar's levels were scanned 3-4 times per bar close.
   int    ofsScore = ComputeOFScore(bi);
   double hftScore = ComputeHFTSignal(bi, ofsScore);

   // [V7-06] Apply adaptive threshold in trading context too
   int effThresh = ComputeAdaptiveThreshold();
   bool isBuy  = (hftScore >=  (double)effThresh && InpAllowBuy);
   bool isSell = (hftScore <= -(double)effThresh && InpAllowSell);
   if(!isBuy && !isSell) return;

   bool direction = isBuy;

   // [V7-07] Conviction diversity gate
   ConvictionResult conv = GetConvictionResult(bi, direction);
   if(conv.componentCount < InpMinConvictionComp)
     {
      LogTradeExec(StringFormat(
         "PlaceOrders: conviction gate failed — %d component(s), need %d. Label: %s",
         conv.componentCount, InpMinConvictionComp, conv.label));
      return;
     }

   // [V7-13] Run all risk / filter checks (analysis mode bypasses real-money guards)
   if(!g_analysisMode && !CheckRiskConditions(direction)) return;
   if(g_analysisMode)
     {
      // Analysis mode still respects session and HTF for realistic simulation
      if(!CheckSessionTime()) return;
      if(!CheckHTFTrend(direction)) return;
     }

   if(!g_analysisMode && InpCleanOldOrders)
     {
      DeleteAllPending();
      ArrayResize(g_pendingTickets, 0);   // [V8-17] clear tracking on explicit clean
      ArrayResize(g_pendingBarTimes, 0);
     }

   // ATR
   double atrBuf[];
   double atrVal = 0.0;
   int    barsOnChart = iBars(_Symbol, PERIOD_CURRENT);
   if(g_handleATR != INVALID_HANDLE && barsOnChart > InpATR_Period + 1 &&
      CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) == 1)
      atrVal = atrBuf[0];

   double bufDist = InpBufferPips * g_Pip;

   MqlTick lv;
   if(!SymbolInfoTick(_Symbol, lv))
     { LogTradeExec("PlaceOrders: SymbolInfoTick failed"); return; }

   bool isMarket = (InpOrderMode == ORDER_MODE_MARKET);

   double entry;
   ENUM_TRADE_REQUEST_ACTIONS action;
   ENUM_ORDER_TYPE            orderType;

   if(isMarket)
     {
      entry     = direction ? lv.ask : lv.bid;
      action    = TRADE_ACTION_DEAL;
      orderType = direction ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
     }
   else
     {
      entry     = direction
                  ? NormalizeDouble(barHigh + bufDist, _Digits)
                  : NormalizeDouble(barLow  - bufDist, _Digits);
      action    = TRADE_ACTION_PENDING;
      orderType = direction ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
     }

   double sl, tp;
   CalcSLTP(direction, entry, atrVal, barHigh, barLow, bufDist, sl, tp);

   double slPoints = (sl > 0.0) ? MathAbs(entry - sl) / _Point : 0.0;
   double lot      = CalcLot(slPoints, direction);   // [V7-01] true risk-based; [V8-17] pass direction

   int    hftInt    = (int)MathRound(MathAbs(hftScore));
   // ofsScore already computed above — no second scan needed [V8-20]

   // [V7-13] Include bar timestamp and adaptive threshold in comment for traceability
   string tag = StringFormat("FP_%s_%s_HFT%d|%s|T%d|%s",
                             direction ? "Buy"  : "Sell",
                             isMarket  ? "MKT"  : "STP",
                             hftInt, conv.label, effThresh,
                             TimeToString(g_bars[bi].bar_time, TIME_MINUTES));

   ulong  ticket = 0;
   bool   sent   = false;
   // [V8-27] SLTP-LOG-CLAMP: sentSL/sentTP receive the values actually sent to the
   //    broker (potentially clamped to minDist). Logging these instead of sl/tp
   //    ensures the journal matches what the live order has on it.
   double sentSL = sl, sentTP = tp;

   if(g_analysisMode)
     {
      g_virtualTicket++;
      ticket = g_virtualTicket;
      sent   = true;
      // [V8-23] CTR-ANALYSIS-VTICKET: CounterSave() was only called inside the
      //    InpShowVisuals block in EvalAndFireSignal(), leaving g_virtualTicket
      //    unpersisted when InpShowVisuals=false. Virtual orders still accumulate
      //    in that path, so a restart resets the counter to 900M and collides with
      //    any analysis objects still on the chart. Fix: always flush here.
      CounterSave();
      DrawAnalysisEntry(ticket, direction, entry, sl, tp,
                        g_bars[bi].bar_time, conv.label, hftInt, ofsScore);
      LogTradeExec(StringFormat(
         "[ANALYSIS] ORDER | %s %s | #V%I64u | Entry: %s | SL: %s | TP: %s"
         " | Lot: %.2f | HFT: %d (thresh=%d) | OFS: %d | Conv: %s (%d)",
         direction?"BUY":"SELL", isMarket?"MKT":"STP",
         ticket, DoubleToString(entry,_Digits),
         DoubleToString(sl,_Digits), DoubleToString(tp,_Digits),
         lot, hftInt, effThresh, ofsScore, conv.label, conv.componentCount));
     }
   else
     {
      sent = trade_Send(action, orderType, entry, sl, tp, lot, tag, ticket, sentSL, sentTP);
      if(sent)
        {
         // [V7-11] Record placement bar time for pending expiry management
         if(!isMarket) g_pendingPlacedBarTime = g_bars[bi].bar_time;
         // [V8-17] PENDING-EXPIRY-MULTIPOS: register ticket+barTime for per-order expiry.
         if(!isMarket && ticket != 0)
           {
            int pn = ArraySize(g_pendingTickets);
            ArrayResize(g_pendingTickets, pn+1);
            ArrayResize(g_pendingBarTimes, pn+1);
            g_pendingTickets[pn] = ticket;
            g_pendingBarTimes[pn] = g_bars[bi].bar_time;
           }

         LogTradeExec(StringFormat(
            "ORDER PLACED [%s] %s | #%I64u | Entry: %s | SL: %s | TP: %s"
            " | Lot: %.2f | HFT: %d (thresh=%d) | OFS: %d | Conv: %s (%d)",
            direction?"BUY":"SELL", isMarket?"MKT":"STP",
            ticket, DoubleToString(entry,_Digits),
            DoubleToString(sentSL,_Digits),   // [V8-27] actual sent value
            DoubleToString(sentTP,_Digits),   // [V8-27] actual sent value
            lot, hftInt, effThresh, ofsScore, conv.label, conv.componentCount));

         DrawTradeEntry(ticket, direction, entry, sentSL, sentTP,
                        g_bars[bi].bar_time, conv.label, hftInt, ofsScore);
        }
     }
  }

// [V8-20] PENDING-LIFECYCLE: scrub g_pendingTickets / g_pendingBarTimes against
//    live broker orders. Removes entries for orders that have been filled, manually
//    deleted, expired by the broker, or are simply missing after a restart.
//    Called at the top of ManagePositions() so the expiry loop never operates on
//    stale state, and the tracking set remains a faithful mirror of live pendings.
void SyncPendingTracking()
  {
   int pn = ArraySize(g_pendingTickets);
   if(pn == 0) return;

   for(int pi = pn-1; pi >= 0; pi--)
     {
      ulong tk = g_pendingTickets[pi];
      // Check whether this ticket still exists as a live pending order for our instance
      bool stillAlive = false;
      if(OrderSelect(tk))
        {
         if((ulong)OrderGetInteger(ORDER_MAGIC) == g_Magic &&
            OrderGetString(ORDER_SYMBOL)        == _Symbol)
           {
            ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(ot == ORDER_TYPE_BUY_STOP  || ot == ORDER_TYPE_SELL_STOP ||
               ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_SELL_LIMIT)
               stillAlive = true;
           }
        }
      if(!stillAlive)
        {
         LogTradeExec(StringFormat(
            "PENDING-SYNC: ticket=%I64u no longer live (filled/deleted/missing). "
            "Removing from tracking. [V8-20]", tk));
         int rem = ArraySize(g_pendingTickets) - 1;
         for(int k = pi; k < rem; k++)
           { g_pendingTickets[k] = g_pendingTickets[k+1];
             g_pendingBarTimes[k] = g_pendingBarTimes[k+1]; }
         ArrayResize(g_pendingTickets,  rem);
         ArrayResize(g_pendingBarTimes, rem);
        }
     }
  }

// ManagePositions — break-even, trailing, and pending expiry.
void ManagePositions()
  {
   // [V8-20] MANAGE-ENTRY-SPLIT: position management is independent of entry permission.
   //    The previous guard `if(!g_autoTrade)` stopped break-even, trailing stop, and
   //    pending expiry whenever InpATEnable=false — even with live open positions.
   //    Risk halts (daily-loss, session, equity) never touched g_autoTrade, so they
   //    were already unaffected; the gap was the user-disabled case.
   //    New guard: skip only in analysis mode (virtual positions only — no live orders).
   //    New entries remain gated by `if(!g_autoTrade && !g_analysisMode)` in PlaceOrders().
   if(g_analysisMode) return;
   if(!IsTradeAllowed()) return;

   ulong now = GetTickCount64();
   if(now - g_lastManageTick < FP_MANAGE_THROTTLE) return;
   g_lastManageTick = now;

   // [V8-20] PENDING-LIFECYCLE: scrub stale tracking entries before expiry logic.
   //    Ensures filled/deleted/missing pendings are removed before the expiry loop
   //    attempts to interact with them, preventing silent no-ops or double-deletes.
   SyncPendingTracking();

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = MathMax((double)stopsLevel, 1.0) * _Point;
   double curBid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double curAsk     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // [V7-11] / [V8-17] PENDING-EXPIRY-MULTIPOS: per-order expiry.
   //    Each registered pending is checked individually; expired tickets are deleted
   //    one-at-a-time rather than triggering a bulk DeleteAllPending().
   if(InpPendingExpiryBars > 0)
     {
      for(int pi = ArraySize(g_pendingTickets)-1; pi >= 0; pi--)
        {
         int barsSincePlaced = iBarShift(_Symbol, PERIOD_CURRENT, g_pendingBarTimes[pi]);
         if(barsSincePlaced >= InpPendingExpiryBars)
           {
            LogTradeExec(StringFormat(
               "Pending expiry: ticket=%I64u %d bars elapsed (limit=%d). Deleting.",
               g_pendingTickets[pi], barsSincePlaced, InpPendingExpiryBars));
            trade_OrderDelete(g_pendingTickets[pi]);
            int rem = ArraySize(g_pendingTickets) - 1;
            for(int k = pi; k < rem; k++)
              { g_pendingTickets[k] = g_pendingTickets[k+1];
                g_pendingBarTimes[k] = g_pendingBarTimes[k+1]; }
            ArrayResize(g_pendingTickets, rem);
            ArrayResize(g_pendingBarTimes, rem);
           }
        }
     }

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;

      // [V8-18] VISUAL-TICKET-IDENTITY: derive the stable position identifier for
      //    chart-object naming. POSITION_IDENTIFIER equals the opening order ticket
      //    and matches DEAL_POSITION_ID in OnTradeTransaction and res.order in
      //    PlaceOrders — giving one coherent key across the full visual lifecycle.
      //    POSITION_TICKET (from PositionGetTicket) can diverge on netting accounts
      //    after partial closes; it is kept for req.position (SLTP modify requires it).
      ulong posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);

      ENUM_POSITION_TYPE pType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double             curSL  = PositionGetDouble(POSITION_SL);
      double             curTP  = PositionGetDouble(POSITION_TP);
      double             profit = (pType == POSITION_TYPE_BUY)
                                  ? (curBid - entry) / g_Pip
                                  : (entry  - curAsk) / g_Pip;

      double newSL = curSL;

      if(InpUseBreakEven && profit >= InpBreakEvenTrigger)
        {
         double beSL = (pType == POSITION_TYPE_BUY)
                       ? NormalizeDouble(entry + InpBreakEvenBuffer * g_Pip, _Digits)
                       : NormalizeDouble(entry - InpBreakEvenBuffer * g_Pip, _Digits);
         bool improvement = (pType == POSITION_TYPE_BUY)
                            ? (beSL > curSL + _Point)
                            : (beSL < curSL - _Point || curSL == 0.0);
         if(improvement)
           {
            double distEntry = (pType == POSITION_TYPE_BUY)
                               ? MathAbs(curBid - beSL) : MathAbs(curAsk - beSL);
            if(distEntry >= minDist) newSL = beSL;
           }
        }

      if(InpUseTrailing && profit >= InpTrailStart)
        {
         double trailSL = (pType == POSITION_TYPE_BUY)
                          ? NormalizeDouble(curBid - InpTrailStep * g_Pip, _Digits)
                          : NormalizeDouble(curAsk + InpTrailStep * g_Pip, _Digits);
         bool better = (pType == POSITION_TYPE_BUY)
                       ? (trailSL > newSL + _Point)
                       : (trailSL < newSL - _Point || newSL == 0.0);
         double distCur = (pType == POSITION_TYPE_BUY)
                          ? MathAbs(curBid - trailSL) : MathAbs(curAsk - trailSL);
         if(better && distCur >= minDist)
            newSL = trailSL;
         else if(!better && InpUseBreakEven && MathAbs(newSL - curSL) > _Point / 2.0)
            // [V8-16] Log when trailing would move SL backward vs break-even newSL
            LogTradeExec(StringFormat(
               "ManagePositions: trail suppressed by BE — trailSL=%s newSL=%s | ticket=%I64u [V8-16]",
               DoubleToString(trailSL,_Digits), DoubleToString(newSL,_Digits), ticket));
        }

      if(MathAbs(newSL - curSL) > _Point / 2.0)
        {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = NormalizeDouble(newSL, _Digits);
         req.tp       = NormalizeDouble(curTP, _Digits);
         req.magic    = g_Magic;

         bool modOk = false;
         for(int attempt = 1; attempt <= 3 && !modOk; attempt++)
           {
            modOk = OrderSend(req, res);
            if(!modOk)
              {
               uint rc = res.retcode;
               if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_CONNECTION &&
                  rc != TRADE_RETCODE_TIMEOUT) break;
               // [V8-15] SPINWAIT-CPU: spin-wait replaced with Sleep(10).
               //    The tick thread is blocked either way in MQL5's single-threaded execution
               //    model. Sleep(10) yields the CPU to other processes; a busy spin does not.
               //    10 ms is sufficient for a broker price refresh and reduces total retry
               //    latency from ≤150 ms to ≤30 ms across three attempts.
               Sleep(10);
              }
           }
         if(modOk)
            UpdateSLLine(posId, req.sl);   // [V8-18] posId = POSITION_IDENTIFIER
         else
            LogTradeExec(StringFormat(
               "ManagePositions modify failed: ticket=%I64u retcode=%u newSL=%s",
               ticket, res.retcode, DoubleToString(req.sl,_Digits)));
        }
     }
  }

//==========================================================================
// SECTION 15: EA LIFECYCLE HANDLERS
//==========================================================================

int OnInit()
  {
   // --- Input validation ---
   if(_Point <= 0.0)
     { Alert(EA_NAME ": Invalid symbol point size."); return INIT_FAILED; }
   if(InpTickSize <= 0)
     { Alert("InpTickSize must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(InpTickMultiplier <= 0)
     { Alert("InpTickMultiplier must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(InpImbalanceRatio < 100.0)
     { Alert("InpImbalanceRatio must be >= 100."); return INIT_PARAMETERS_INCORRECT; }
   if(InpVAPercent <= 0.0 || InpVAPercent > 100.0)
     { Alert("InpVAPercent must be between 1 and 100."); return INIT_PARAMETERS_INCORRECT; }
   if(InpStackedImbCount < 1)
     { Alert("InpStackedImbCount must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(InpAbsorptionRatio <= 0.0)
     { Alert("InpAbsorptionRatio must be > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpExhaustionEnable && InpExhaustionCells < 1)
     { Alert("InpExhaustionCells must be >= 1 when exhaustion is enabled."); return INIT_PARAMETERS_INCORRECT; }
   if(InpOFWtDelta < 0.0)
     { Alert("InpOFWtDelta must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpOFWtImb < 0.0)
     { Alert("InpOFWtImb must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpOFWtStacked < 0.0)
     { Alert("InpOFWtStacked must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpOFWtAbsorb < 0.0)
     { Alert("InpOFWtAbsorb must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpOFWtDelta + InpOFWtImb + InpOFWtStacked + InpOFWtAbsorb <= 0.0)
     { Alert("OFS weights sum to zero."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMinConvictionComp < 0)
     { Alert("InpMinConvictionComp must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
   // [V8-23] DELTA-THRESH-VALIDATE: delta ratio is clamped to [-1,1]; a threshold
   //    of 0 makes the check trivially true for any directional bar; >= 1 makes it
   //    permanently impossible — Component 2 is silently disabled. Both produce
   //    silent misbehaviour with no diagnostic. Validated here for consistency with
   //    all other threshold inputs (InpAdaptiveThreshMin/Max, InpSignalThreshold, etc).
   if(InpDeltaConvThreshold <= 0.0 || InpDeltaConvThreshold >= 1.0)
     { Alert("InpDeltaConvThreshold must be strictly between 0 and 1 (exclusive)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpAdaptiveThreshMin >= InpAdaptiveThreshMax)
     { Alert("InpAdaptiveThreshMin must be < InpAdaptiveThreshMax."); return INIT_PARAMETERS_INCORRECT; }
   // [V8-19] SESSION-OVERNIGHT: start == end would create a zero-width or always-active
   //    window with no useful meaning. start > end is valid (overnight). Only reject ==.
   if(InpSessionEnable && InpSessionStartHour == InpSessionEndHour)
     { Alert("InpSessionStartHour must not equal InpSessionEndHour (zero-width window)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpHTFEnable && InpHTFEMA < 2)
     { Alert("InpHTFEMA must be >= 2."); return INIT_PARAMETERS_INCORRECT; }
   // Consecutive loss limits: 0 means disabled; only validate when both are enabled
   if(InpMaxConsecLosses < 0)
     { Alert("InpMaxConsecLosses must be >= 0 (0 = disabled)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpHaltConsecLosses < 0)
     { Alert("InpHaltConsecLosses must be >= 0 (0 = disabled)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxConsecLosses > 0 && InpHaltConsecLosses > 0 && InpHaltConsecLosses <= InpMaxConsecLosses)
     { Alert("InpHaltConsecLosses must be > InpMaxConsecLosses when both are enabled."); return INIT_PARAMETERS_INCORRECT; }
   // [V8-27] EQUITY-INPUT-VALIDATE: negative values are silently treated as disabled
   //    (the > 0.0 guard at the call site skips them), but a negative entry is almost
   //    certainly a data-entry error. Consistent with all other monetary input checks.
   if(InpMaxEquityProfit < 0.0)
     { Alert("InpMaxEquityProfit must be >= 0 (0 = disabled)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxEquityLoss < 0.0)
     { Alert("InpMaxEquityLoss must be >= 0 (0 = disabled)."); return INIT_PARAMETERS_INCORRECT; }

   // [V8-16] ATR-PERIOD-VALIDATE: InpATR_Period <= 0 causes iATR() to return
   //    INVALID_HANDLE. All ATR-dependent features (SL/TP in ATR mode, adaptive
   //    threshold, spread ATR ratio filter) then silently degrade or are skipped
   //    with no journal entry or user alert. Validated here consistent with all
   //    other indicator-period inputs.
   if(InpATR_Period < 1)
     { Alert("InpATR_Period must be >= 1."); return INIT_PARAMETERS_INCORRECT; }

   if(InpATEnable)
     {
      if(InpUseStopLoss)
        {
         if((InpSLMode == SL_MODE_PIPS || InpSLMode == SL_MODE_ATR) && InpSLPips <= 0.0)
           { Alert("InpSLPips must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if(InpSLMode == SL_MODE_ATR && InpSLATRMult <= 0.0)
           { Alert("InpSLATRMult must be > 0."); return INIT_PARAMETERS_INCORRECT; }
        }
      if(InpUseTakeProfit)
        {
         if(InpTPMode == TP_MODE_RR && InpRiskRewardRatio <= 0.0)
           { Alert("InpRiskRewardRatio must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if((InpTPMode == TP_MODE_PIPS || InpTPMode == TP_MODE_ATR) && InpTPPips <= 0.0)
           { Alert("InpTPPips must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if(InpTPMode == TP_MODE_ATR && InpTPATRMult <= 0.0)
           { Alert("InpTPATRMult must be > 0."); return INIT_PARAMETERS_INCORRECT; }
        }
      // [V8-28] TRAIL-VALIDATE: validate position management params when AT is enabled.
      //    InpTrailStep=0 causes trailSL=curBid (buys) on every tick — instant stop-out.
      //    Negative InpBreakEvenBuffer places the BE stop on the wrong side of entry.
      if(InpUseBreakEven)
        {
         if(InpBreakEvenTrigger <= 0.0)
           { Alert("InpBreakEvenTrigger must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if(InpBreakEvenBuffer < 0.0)
           { Alert("InpBreakEvenBuffer must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
        }
      if(InpUseTrailing)
        {
         if(InpTrailStep <= 0.0)
           { Alert("InpTrailStep must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if(InpTrailStart < 0.0)
           { Alert("InpTrailStart must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
        }
      if(!InpUseRiskPercent && InpFixedLot <= 0.0)
        { Alert("InpFixedLot must be > 0."); return INIT_PARAMETERS_INCORRECT; }
      if(InpUseRiskPercent && InpRiskPercent <= 0.0)
        { Alert("InpRiskPercent must be > 0."); return INIT_PARAMETERS_INCORRECT; }
     }

   if(InpATEnable && InpAnalysisMode)
      Alert(EA_NAME ": InpATEnable=true but InpAnalysisMode=true — no real orders will be placed. [V8-12]");

   // [V8-17] Alert when all loss-protection limits are disabled. Running live with zero
   //    daily loss limit, zero halt threshold, and zero consecutive-loss limit exposes the
   //    account to unlimited session loss. At least one limit should be active.
   if(InpATEnable && !InpAnalysisMode &&
      InpMaxDailyLossPercent <= 0.0 && InpHaltConsecLosses <= 0 && InpMaxConsecLosses <= 0)
      Alert(EA_NAME " [V8-17]: WARNING — All loss-protection limits are disabled "
            "(InpMaxDailyLossPercent=0, InpHaltConsecLosses=0, InpMaxConsecLosses=0). "
            "The EA will trade with no daily drawdown cap. Enable at least one limit before live trading.");

   // --- Core state ---
   int pts = MathMax(1, MathMin(10000, InpTickSize));
   g_basePts  = pts;
   g_baseStep = g_basePts * _Point;
   int mul    = MathMax(1, MathMin(40, InpTickMultiplier));
   g_tickMult = mul;
   g_step     = g_baseStep * g_tickMult;

   g_chart    = ChartID();
   g_prevBid  = 0.0;
   g_imbRatio = InpImbalanceRatio;
   g_histBars = MathMax(FP_HIST_MIN, MathMin(FP_HIST_MAX, InpHistoryBars));
   g_vaPercent= (double)InpVAPercent;

   g_signalsEnabled  = InpShowSignals;
   g_signalFreqBars  = MathMax(1, InpSignalFreqBars);
   g_signalThreshold = MathMax(1, MathMin(99, InpSignalThreshold));
   g_lastSignalBarTime = 0;

   g_autoTrade   = InpATEnable;
   g_analysisMode= InpAnalysisMode;
   g_Magic       = InpMagic;
   g_LastBarTime = 0;

   g_sigMarkerCount = 800000000UL;
   g_virtualTicket  = 900000000UL;

   // --- Risk state init — [V8-10] restore from GlobalVariables if available ---
   g_consecutiveLosses  = 0;
   g_sizeReductionLeft  = 0;
   g_sessionHalted      = false;
   g_dailyLossHalted    = false;
   g_equityHalted       = false;
   g_dayStartDay        = -1;
   g_dayStartBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastSLBarTimeBuy   = 0;
   g_lastSLBarTimeSell  = 0;
   g_newDayDeferStart   = 0;
   g_pendingPlacedBarTime = 0;
   g_atrBaselineReady   = false;
   g_atrBaseline        = 0.0;
   RiskStateLoad();   // overwrite zeros with persisted values if present

   // [V8-19] PENDING-EXPIRY-RESTART: rebuild the in-memory pending-expiry arrays from
   //    the live broker order pool on every init. g_pendingTickets/g_pendingBarTimes are
   //    purely in-memory; after an EA restart any existing pending orders placed by this
   //    EA instance were invisible to ManagePositions() expiry logic. We scan all broker
   //    pending orders owned by our magic+symbol and re-register them using ORDER_TIME_SETUP
   //    as the placement reference so iBarShift-based expiry continues correctly from the
   //    order's original placement bar rather than the restart time.
   if(InpPendingExpiryBars > 0)
     {
      ArrayResize(g_pendingTickets,  0);
      ArrayResize(g_pendingBarTimes, 0);
      for(int oi = OrdersTotal()-1; oi >= 0; oi--)
        {
         ulong oTk = OrderGetTicket(oi);
         if(oTk == 0) continue;
         if((ulong)OrderGetInteger(ORDER_MAGIC)        != g_Magic) continue;
         if(OrderGetString(ORDER_SYMBOL)               != _Symbol)  continue;
         ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP &&
            ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;
         datetime placed = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
         // [V8-20] PENDING-LIFECYCLE: always append; arrays were cleared above.
         int pn = ArraySize(g_pendingTickets);
         ArrayResize(g_pendingTickets,  pn + 1);
         ArrayResize(g_pendingBarTimes, pn + 1);
         g_pendingTickets[pn]  = oTk;
         g_pendingBarTimes[pn] = placed;
         LogTradeExec(StringFormat(
            "PENDING-EXPIRY-RESTART: re-registered ticket=%I64u placed=%s [V8-20]",
            oTk, TimeToString(placed, TIME_DATE|TIME_MINUTES)));
        }
     }

   g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);

   RefreshSymbolInfo();

   // --- Indicator handles ---
   g_handleATR = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
   if(g_handleATR == INVALID_HANDLE)
      LogWarning(StringFormat("ATR handle failed (%d)", GetLastError()));

   // [V7-02] HTF EMA handle
   if(InpHTFEnable)
     {
      g_htfEMAHandle = iMA(_Symbol, InpHTFPeriod, InpHTFEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_htfEMAHandle == INVALID_HANDLE)
         LogWarning(StringFormat("HTF EMA handle failed (%d). Trend filter disabled.", GetLastError()));
     }

   ReloadHistory();

   LogSystem(StringFormat(
      EA_NAME " — Init | %s | TickSize: %dpts×%d | HistBars: %d"
      " | AutoTrade: %s | AnalysisMode: %s | HasTrades: %s"
      " | HTFFilter: %s (%s EMA%d) | Session: %s (%02d:00-%02d:00 server)"
      " | AdaptiveThresh: %s [%.0f–%.0f] | MinConvComp: %d | SLCooldown: %d bars"
      " | DailyLoss: %.1f%% | MaxConsec: %d/%d",
      _Symbol, g_basePts, g_tickMult, g_histBars,
      (g_autoTrade     ? "ON"  : "OFF"),
      (g_analysisMode  ? "ON"  : "OFF"),
      (g_hasTrades     ? "YES" : "NO"),
      (InpHTFEnable    ? "ON"  : "OFF"), EnumToString(InpHTFPeriod), InpHTFEMA,
      (InpSessionEnable? "ON"  : "OFF"), InpSessionStartHour, InpSessionEndHour,
      (InpAdaptiveThreshold ? "ON" : "OFF"), InpAdaptiveThreshMin, InpAdaptiveThreshMax,
      InpMinConvictionComp, InpSLCooldownBars,
      InpMaxDailyLossPercent, InpMaxConsecLosses, InpHaltConsecLosses));

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_handleATR != INVALID_HANDLE)
     { IndicatorRelease(g_handleATR); g_handleATR = INVALID_HANDLE; }
   if(g_htfEMAHandle != INVALID_HANDLE)
     { IndicatorRelease(g_htfEMAHandle); g_htfEMAHandle = INVALID_HANDLE; }

   CleanupAllTradeObjects();

   int n = ArraySize(g_bars);
   // [V8-24] LEVMAP-FREE: free levelMap alongside levels at every cleanup site.
   for(int i = 0; i < n; i++)
     {
      ArrayFree(g_bars[i].levelMap);
      ArrayFree(g_bars[i].levels);
     }
   ArrayFree(g_bars);

   LogSystem(StringFormat(EA_NAME " — Deinit (reason=%d)", reason));
  }

void OnTick()
  {
   // [V8-13] Lazy re-check for g_hasTrades: SYMBOL_LAST can be zero at session open
   //    or during the first few seconds on some broker configurations. If init ran
   //    during that window, re-check on the first tick that sees a valid LAST price.
   // [V8-17] BUG FIX: When g_hasTrades transitions here, all history bars that were
   //    built during the proxy window contain bid-direction-classified tick data
   //    (ask_vol/bid_vol based on bid movement, not TICK_FLAG). Force a full history
   //    reload to reclassify those bars with proper tick-flag data.
   if(!g_hasTrades && SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0)
     {
      g_hasTrades    = true;
      g_needs_reload = true;  // discard proxy-classified history and rebuild
      LogSystem("g_hasTrades re-checked: LAST price now available — forcing history reload to reclassify ticks. [V8-13/V8-17]");
     }

   if(ArraySize(g_bars) == 0)
     { ReloadHistory(); return; }

   if(g_needs_reload)
     {
      g_needs_reload = false;
      // [V8-17] RELOAD-VISUAL-LEAK: only clean visuals on chart-change reloads, not on
      //    g_hasTrades reclassification (open positions may have live SL/TP lines that
      //    must survive tick reclassification).
      if(CountOpenPositions() == 0) CleanupAllTradeObjects();
      ReloadHistory();
     }

   MqlTick ticks[];
   uint    flag     = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long    now_msc  = (long)TimeCurrent() * 1000;
   long    from_msc = g_last_tick_time_ms;

   if(from_msc == 0)
     {
      long lookback = 60000;
      from_msc = (now_msc > lookback) ? now_msc - lookback : now_msc;
     }

   int copied = CopyTicksRange(_Symbol, ticks, flag, from_msc, now_msc);
   if(copied > 0)
     {
      if(g_prevBid == 0.0) g_prevBid = ticks[0].bid;
      ProcessTicks(ticks, 0, copied, true, true);
     }

   EvalAndFireSignal();

   ManagePositions();
   if(IsNewBar())
     {
      if(g_autoTrade || g_analysisMode) RefreshSymbolInfo();
      // [V8-14] Rolling ATR baseline: update with EMA(2/51) each new bar so the
      //    adaptive threshold does not silently degrade to a fixed value after a
      //    volatility regime change.
      if(g_atrBaselineReady && g_handleATR != INVALID_HANDLE)
        {
         double atrBuf[];
         if(CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) == 1 && atrBuf[0] > 0.0)
           {
            const double alpha = 2.0 / 51.0;   // equivalent to 50-bar EMA
            g_atrBaseline = g_atrBaseline + alpha * (atrBuf[0] - g_atrBaseline);
           }
        }
      // [V8-15] NAKED-POC-STALE: recompute naked POC status on every bar close so
      //    is_naked_poc reflects actual retest history up to the current bar.
      //    ComputeNakedPOCs() is O(n log n) and runs once per bar, not per tick.
      //    Must precede PlaceOrders() since GetConvictionResult() reads is_naked_poc.
      ComputeNakedPOCs();
      PlaceOrders();
     }
  }

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if(ArraySize(g_bars) > 0)
        {
         int      bars_total       = iBars(_Symbol, PERIOD_CURRENT);
         int      span             = MathMin(g_histBars, bars_total-1);
         datetime expectedFirstBar = iTime(_Symbol, PERIOD_CURRENT, span);
         datetime expectedLastBar  = iTime(_Symbol, PERIOD_CURRENT, 0);
         if(g_bars[0].bar_time != expectedFirstBar ||
            g_bars[ArraySize(g_bars)-1].bar_time != expectedLastBar)
            g_needs_reload = true;
        }
     }
  }

// [V7-05] OnTradeTransaction — tracks consecutive SL hits, resets on wins.
//    Also logs closed trades and drives the SL cooldown per direction.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_Magic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)         return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   // [V8-20] PENDING-LIFECYCLE: when a pending order fills, remove it from the
   //    tracking arrays synchronously so ManagePositions() sees clean state.
   //    DEAL_ORDER holds the order ticket that was filled, which matches
   //    g_pendingTickets[] entries placed by PlaceOrders().
   if(dealEntry == DEAL_ENTRY_IN)
     {
      ulong filledOrderTk = (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER);
      int pn = ArraySize(g_pendingTickets);
      for(int pi = pn-1; pi >= 0; pi--)
        {
         if(g_pendingTickets[pi] == filledOrderTk)
           {
            LogTradeExec(StringFormat(
               "PENDING-FILL: ticket=%I64u filled. Removing from pending tracking. [V8-20]",
               filledOrderTk));
            int rem = pn - 1;
            for(int k = pi; k < rem; k++)
              { g_pendingTickets[k] = g_pendingTickets[k+1];
                g_pendingBarTimes[k] = g_pendingBarTimes[k+1]; }
            ArrayResize(g_pendingTickets,  rem);
            ArrayResize(g_pendingBarTimes, rem);
            break;
           }
        }
      return;   // DEAL_ENTRY_IN does not affect PnL/streak accounting below
     }

   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT) return;

   ENUM_DEAL_TYPE  dealType   = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double          dealPrice  = HistoryDealGetDouble(trans.deal,  DEAL_PRICE);
   double          dealVolume = HistoryDealGetDouble(trans.deal,  DEAL_VOLUME);
   double          dealProfit = HistoryDealGetDouble(trans.deal,  DEAL_PROFIT);
   double          dealSwap   = HistoryDealGetDouble(trans.deal,  DEAL_SWAP);
   double          dealComm   = HistoryDealGetDouble(trans.deal,  DEAL_COMMISSION);
   double          dealNet    = dealProfit + dealSwap + dealComm;
   datetime        dealTime   = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   ulong           ticket     = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   string          comment    = HistoryDealGetString(trans.deal,  DEAL_COMMENT);

   bool   wasLong = (dealType == DEAL_TYPE_SELL);
   string dir     = wasLong ? "LONG" : "SHORT";
   string pnlTag  = (dealNet >= 0.0) ? "WIN" : "LOSS";

   // [V8-22] SL-COMMENT-CASE: normalise to lower-case before all StringFind checks
   //    so brokers that write "SL", "S/L", or "Stop Loss" are handled correctly.
   //    The original comment is preserved in the log entry below.
   string commentLower = comment;
   StringToLower(commentLower);

   // [V8-06] SL hit detection: primary check uses the EA's own FP_ comment prefix.
   //    If the broker has stripped the comment entirely, fall back to net loss.
   //    This prevents manual closes and break-even exits from inflating
   //    g_consecutiveLosses (regression introduced by V8-04).
   bool isOurOrder = (StringFind(commentLower, "fp_") == 0);

   // [V8-29] ABSLOW-SL-FP: the previous bare StringFind(commentLower,"sl") matched "sl"
   //    inside the conviction label "abslow" (lowercase of "AbsLow"), misclassifying
   //    every TP or manual close on an AbsLow-tagged order as an SL hit. This silently
   //    inflated g_consecutiveLosses and could trigger a spurious session halt.
   //    Fix: scope the SL/TP keyword search to the tail after the last "|" separator.
   //    Our comment format is "FP_Dir_Type_HFTn|Label|Tn|HH:MM"; the broker appends
   //    its exit reason after the last segment, so scanning only the tail is sufficient.
   string commentTail = commentLower;
   {
    int p = -1, cur = 0;
    while((cur = StringFind(commentLower, "|", cur)) >= 0) { p = cur; cur++; }
    if(p >= 0) commentTail = StringSubstr(commentLower, p + 1);
   }
   // [V8-16] TP-FORMAT-ASYMMETRY: isTPHit now matches all common broker TP formats,
   //    mirroring the four-variant SL coverage added in V8-15 SL-SLASH-FORMAT.
   //    The isSLHit mutual-exclusion guard is extended with the same variants so a
   //    "take profit" close with negative net (swap/commission) is never misclassified
   //    as an SL hit and silently inflates g_consecutiveLosses.
   //    isTPHit is declared first so isSLHit can reference it directly (&& !isTPHit).
   bool isTPHit = (StringFind(commentTail, "tp")          >= 0 ||
                   StringFind(commentTail, "t/p")         >= 0 ||
                   StringFind(commentTail, "take profit")  >= 0 ||
                   StringFind(commentTail, "take-profit")  >= 0);
   bool isSLHit = isOurOrder
                  ? ( (StringFind(commentTail, "sl")         >= 0 ||
                       StringFind(commentTail, "s/l")        >= 0 ||
                       StringFind(commentTail, "stop loss")  >= 0 ||
                       StringFind(commentTail, "stop-loss")  >= 0)
                      && !isTPHit )
                  : (dealNet < 0.0);

   if(isSLHit)
     {
      g_consecutiveLosses++;

      // [V7-08] Record SL time for per-direction cooldown
      if(wasLong)  g_lastSLBarTimeBuy  = iTime(_Symbol, PERIOD_CURRENT, 0);
      else         g_lastSLBarTimeSell = iTime(_Symbol, PERIOD_CURRENT, 0);

      if(InpHaltConsecLosses > 0 && g_consecutiveLosses >= InpHaltConsecLosses && !g_sessionHalted)
        {
         g_sessionHalted = true;
         Alert(StringFormat(
            EA_NAME " — SESSION HALTED: %d consecutive SL hits reached (%d limit).",
            g_consecutiveLosses, InpHaltConsecLosses));
         LogRisk(StringFormat("SESSION HALTED after %d consecutive SL hits.", g_consecutiveLosses));
        }
      else if(InpMaxConsecLosses > 0 && g_consecutiveLosses >= InpMaxConsecLosses && g_sizeReductionLeft == 0)
        {
         g_sizeReductionLeft = InpSizeReductionTrades;
         LogRisk(StringFormat(
            "CONSEC LOSS LIMIT (%d). 50%% size reduction for next %d trades.",
            InpMaxConsecLosses, InpSizeReductionTrades));
        }

      // [V8-17] SIZERED-SL-DECREMENT: consume one penalty trade on every SL close.
      //    The "N trades at half-size" contract counts all trade closes, not only wins.
      //    Without this, a continued losing streak during the reduction phase freezes
      //    g_sizeReductionLeft until a win occurs — an indefinite unintended penalty.
      if(g_sizeReductionLeft > 0) g_sizeReductionLeft = MathMax(0, g_sizeReductionLeft - 1);
      RiskStateSave();   // [V8-10] persist after every loss-streak change
      LogRisk(StringFormat("SL HIT #%d consecutive | %s %s | Net: %.2f",
                           g_consecutiveLosses, dir, _Symbol, dealNet));
     }
   else if(isTPHit || dealNet > 0.0)
     {
      // Any positive close resets the streak
      if(g_consecutiveLosses > 0)
         LogRisk(StringFormat("WIN — resetting consecutive loss counter (was %d).", g_consecutiveLosses));
      g_consecutiveLosses = 0;
      if(g_sizeReductionLeft > 0) g_sizeReductionLeft = MathMax(0, g_sizeReductionLeft - 1);
      RiskStateSave();   // [V8-10]
      // Session halt resets on the next day (not on a single win — too easy to game)
     }
   else
     {
      // Partial win or break-even: decrement size reduction but don't reset streak
      if(g_sizeReductionLeft > 0) g_sizeReductionLeft = MathMax(0, g_sizeReductionLeft - 1);
      RiskStateSave();   // [V8-10]
     }

   LogTradeClosed(StringFormat(
      "CLOSED [%s] %s | #%I64u | Price: %s | Lot: %.2f"
      " | Profit: %.2f | Swap: %.2f | Comm: %.2f | Net: %.2f [%s]"
      " | Time: %s | Comment: %s | ConsecLosses: %d | SizeRedLeft: %d",
      dir, _Symbol, ticket,
      DoubleToString(dealPrice, _Digits), dealVolume,
      dealProfit, dealSwap, dealComm, dealNet,
      pnlTag,
      TimeToString(dealTime, TIME_DATE|TIME_MINUTES),
      comment, g_consecutiveLosses, g_sizeReductionLeft));

   DrawTradeExit(ticket, wasLong, dealPrice, dealNet, dealTime);
  }
