# OrderFlowEA v8.01 — Trader's Control Capsule
*Quick-reference dial guide: what to change and why*

---

## 🔴 TRADE MORE (Higher Frequency)

Lower the entry bar so signals fire more often. Do these together for best effect.

| Parameter | Default | Change To | Effect |
|-----------|---------|-----------|--------|
| `InpSignalThreshold` | 60 | 45–50 | The main gate. Lowering this is the single biggest lever for more trades. |
| `InpAdaptiveThreshold` | false | true | Lets the threshold auto-drop during low volatility, adding entries you'd otherwise miss. |
| `InpAdaptiveThreshMin` | 35.0 | 30.0 | Floor for adaptive mode — how low the threshold can go. |
| `InpMinConvictionComp` | 0 | 0 (keep off) | Enabling this would *reduce* trades. Keep at 0 for max frequency. |
| `InpHTFEnable` | false | keep false | Enabling this blocks counter-trend entries. Keep off for more trades. |
| `InpSessionEnable` | false | keep false | Enabling this restricts hours. Keep off unless you need a time filter. |
| `InpStackedImbCount` | 3 | 2 | Fewer consecutive imbalanced cells required = more stacked imbalance flags = higher scores. |
| `InpImbalanceRatio` | 300.0 | 200.0 | Less extreme ask/bid imbalance needed to flag a cell = more imbalances detected. |
| `InpSignalFreqBars` | 3 | 1 | Minimum bars between signal alerts — reduce debounce. |
| `InpSLCooldownBars` | 0 | keep 0 | Any value here blocks re-entry after a stop. Keep at 0 for max frequency. |

---

## 🟢 TRADE LESS (Lower Frequency / More Selective)

Raise the bar for entry quality. Use these to cut noise trades.

| Parameter | Default | Change To | Effect |
|-----------|---------|-----------|--------|
| `InpSignalThreshold` | 60 | 70–75 | Requires a stronger HFT score. Most powerful quality filter. |
| `InpMinConvictionComp` | 0 | 2–3 | Requires 2–3 independent signal components to agree (delta + stacked + absorption etc.). Major quality gate. |
| `InpAdaptiveThreshold` | false | true + raise `InpAdaptiveThreshMax` to 85 | Raises threshold during volatile periods. |
| `InpHTFEnable` | false | true | Only trade in the direction of the H1/H4 EMA trend. Eliminates counter-trend entries. |
| `InpHTFPeriod` | H1 | H4 | Slower HTF trend = fewer valid directions. |
| `InpHTFEMA` | 50 | 200 | Longer EMA = tighter trend filter. |
| `InpSessionEnable` | false | true | Restrict to your best hours (e.g., 07:00–12:00 for London open). |
| `InpStackedImbCount` | 3 | 4–5 | Require more consecutive imbalanced cells before flagging. |
| `InpImbalanceRatio` | 300.0 | 400.0 | Require more extreme ask/bid imbalance to flag a cell. |
| `InpAbsorptionRatio` | 4.0 | 6.0 | Require heavier volume at a level to call it absorption. |
| `InpSLCooldownBars` | 0 | 3–5 | Block re-entry in the same direction after a stop. Prevents revenge trading. |

---

## 🔵 MORE CONSERVATIVE (Tighter Risk / Capital Protection)

Protect the account. These dials do not affect signal frequency — only sizing and protection.

| Parameter | Default | Change To | Effect |
|-----------|---------|-----------|--------|
| `InpRiskPercent` | 1.0 | 0.5 | Risk half a percent per trade. |
| `InpMaxDailyLossPercent` | 0.0 | 2.0–3.0 | Halt trading for the day once daily loss exceeds X% of start balance. **Enable this.** |
| `InpHaltConsecLosses` | 0 | 4–5 | Halt the full session after N consecutive stop-outs. **Enable this.** |
| `InpMaxConsecLosses` | 0 | 2–3 | Cut size to 50% after N consecutive losses. Set lower than `InpHaltConsecLosses`. |
| `InpSizeReductionTrades` | 3 | 5 | Trade at half-size for longer after a streak. |
| `InpMaxEquityLoss` | 1500.0 | Set to ~5% of your account | Hard open-drawdown kill switch. Adjust to your account size. |
| `InpSLMode` | ATR | ATR (keep) | ATR mode is already the most adaptive for volatility. |
| `InpSLATRMult` | 1.5 | 1.2 | Tighter stop — more losses but smaller. Only good if your win rate is high. |
| `InpBreakEvenTrigger` | 15.0 pips | 10.0 | Move to break-even sooner. |
| `InpUseBreakEven` | true | true (keep on) | Always on for conservative approach. |
| `InpUseTrailing` | true | true (keep on) | Protects profits once the trade runs. |

---

## 🟡 MORE AGGRESSIVE (Larger Size / Wider Exits)

Let winning trades breathe and size up when conditions allow.

| Parameter | Default | Change To | Effect |
|-----------|---------|-----------|--------|
| `InpRiskPercent` | 1.0 | 1.5–2.0 | More at risk per trade. Only do this after extended forward-test profit. |
| `InpRiskRewardRatio` | 2.0 | 3.0 | Wider TP — requires price to travel further but bigger wins. |
| `InpSLATRMult` | 1.5 | 2.0 | Wider stop — fewer stop-outs, but larger losses when hit. |
| `InpBreakEvenTrigger` | 15.0 | 25.0 | Let the trade breathe before locking in. |
| `InpTrailStart` | 20.0 | 30.0 | Trailing activates later, preserving larger potential. |
| `InpTrailStep` | 5.0 | 8.0 | Coarser trail — less chance of being stopped by noise. |
| `InpMaxPositions` | 1 | 2 | Allow simultaneous positions (only if your risk % is reduced proportionally). |

---

## ⚙️ KEY DEFAULTS THAT ARE CURRENTLY OFF — CONSIDER ENABLING

These are disabled by default but are implemented and tested in the code.

| Parameter | Default | Recommendation |
|-----------|---------|----------------|
| `InpMaxDailyLossPercent` | 0.0 (off) | Set to 2–3%. This is the most important risk control in the EA and it's currently disabled. |
| `InpHaltConsecLosses` | 0 (off) | Set to 4–5. Prevents death spirals during broken market conditions. |
| `InpMaxConsecLosses` | 0 (off) | Set to 2–3. Scales down before halting, gives you a warning phase. |
| `InpHTFEnable` | false | Enable on trending instruments (indices, commodities). Disable on mean-reverting pairs. |
| `InpAdaptiveThreshold` | false | Enable for volatile instruments like XAUUSD or indices. The static threshold will misbehave during high-volatility regimes. |
| `InpSessionEnable` | false | Enable if you are trading FX — restrict to London (07:00–12:00) or NY (13:00–17:00) server time for best order flow conditions. |

---

## 📊 Footprint Engine Sensitivity (Advanced)

These affect how the tick data is interpreted. Change only if you understand footprint charts.

| Parameter | Default | Lower = More Sensitive | Higher = Less Sensitive |
|-----------|---------|----------------------|------------------------|
| `InpTickSize` | 10 | More price levels, more noise | Fewer levels, coarser view |
| `InpTickMultiplier` | 5 | Finer bucket width | Coarser bucket width |
| `InpVAPercent` | 70.0 | Narrower value area | Wider value area (CME standard = 70%) |
| `InpHVNRatio` | 2.0 | More HVN flags | Fewer, only very heavy nodes |
| `InpLVNRatio` | 0.35 | More LVN flags | Fewer, only very thin nodes |
| `InpAbsVolMult` | 2.0 | Less side-dominance required | Stricter absorption confirmation |

---

## 🔢 OFS Weight Tuning (Signal Component Balance)

The four weights must sum to 100 for the score to be correctly normalised.

| Component | Default | Bias Toward Delta | Bias Toward Structure |
|-----------|---------|-------------------|-----------------------|
| `InpOFWtDelta` | 40% | Raise to 55–60% | Lower to 25–30% |
| `InpOFWtImb` | 25% | Lower to 15% | Raise to 35% |
| `InpOFWtStacked` | 20% | Lower to 10% | Raise to 30% |
| `InpOFWtAbsorb` | 15% | Lower to 10% | Raise to 25% |

*Delta-biased config trades more with momentum. Structure-biased config trades more at institutional levels.*

---

## ⚠️ Things to Know Before Tuning

1. **All risk safety inputs default to OFF** — `InpMaxDailyLossPercent`, `InpMaxConsecLosses`, and `InpHaltConsecLosses` are all 0. The EA will trade indefinitely without them. Enable at minimum `InpMaxDailyLossPercent`.

2. **`InpSignalThreshold` is your master dial** — it is the single most impactful parameter. A change from 60 → 50 can triple trade frequency. Test in Analysis Mode first.

3. **Analysis Mode** (`InpAnalysisMode = true`) lets you see all signals drawn on the chart without real orders. Use this every time you change signal parameters before going live.

4. **Server time vs UTC** — `InpSessionStartHour` / `InpSessionEndHour` use broker server time (see `[V8-11]`). Check your broker's UTC offset before setting session hours.

5. **`InpMaxConsecLosses` must be strictly less than `InpHaltConsecLosses`** when both are enabled — the EA validates this and will refuse to start otherwise.

6. **The trailing stop fires every 250ms** (FP_MANAGE_THROTTLE). This is intentional and correct.
