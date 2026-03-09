High Frequency Mode — What Changed & Why
Signal Generation (fire more, faster)
ParameterTrade ModeHF ModeWhyInpSignalThreshold3520Lower bar = more signals per sessionInpSignalFreqBars31Fire every bar — no artificial debounceInpTickMultiplier52Finer footprint buckets = more granular imbalance detectionInpHistoryBars20050Less history to process = faster bar-close computation
Signal Quality Gates (keep the floor, don't trade blind)
ParameterTrade ModeHF ModeWhyInpMinConvictionComp01At least 1 component required — prevents pure-noise entriesInpAdaptiveThreshMin35.015.0Very low floor — allow HF trades in calm vol regimesInpAdaptiveThreshMax4050.0Wider ceiling — still aggressive in high-volInpSLCooldownBars21Re-engage after 1 bar onlyInpHTFEnablefalsetrueCounter-trend HF scalps have catastrophic SL ratesInpHTFEMA5021Faster EMA responds to intraday trend changes
Session & Spread (non-negotiable in HF)
ParameterTrade ModeHF ModeWhyInpSessionEnablefalsetrueDead hours produce false footprint data — mandatoryInpSpreadFilterfalsetrueWide spreads instantly negate small HF targetsInpMaxSpread3.01.5 pipsHF needs tight spreads or edge disappears entirelyInpSpreadATRRatio0.00.25Secondary ATR-relative guard catches news spikes
Entries & Sizing
ParameterTrade ModeHF ModeWhyInpBufferPips200.01.0Minimal buffer — tight fills on market ordersInpRiskPercent1.0%0.5%More trades = more exposure; halve per-trade risk
Exits — tight and fast
ParameterTrade ModeHF ModeWhyInpSLModeBar (0)ATR (2)HF SL must adapt to intraday vol, not a fixed bar rangeInpSLATRMult15.00.8×Very tight — accept more hits in exchange for better geometryInpRiskRewardRatio60.01.5:1Lower R:R achievable with high signal frequencyInpBreakEvenTrigger600.05.0 pipsMove to BE at 5 pips — protect capital immediatelyInpBreakEvenBuffer200.00.5 pipsNear-zero buffer, don't give back entry edgeInpTrailStart1200.08.0 pipsTrail activates at 8 pips — lock gains earlyInpTrailStep300.02.0 pips2 pip step follows price closely
Risk Guards (tighter — HF drawdowns compound fast)
ParameterTrade ModeHF ModeWhyInpMaxEquityProfit0$1,000Take profits off the table more aggressivelyInpMaxEquityLoss0$500Tighter equity stop — HF can spiral in minutesInpMaxDailyLossPercent02%Hard daily stop — essential in HFInpMaxConsecLosses04Size reduction after 4 consecutive SL hitsInpHaltConsecLosses08Full halt after 8 — something is systematically broken