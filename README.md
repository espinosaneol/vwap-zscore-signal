# VWAP Mean-Reversion Z-Score EA (MQL4)

A research prototype for MetaTrader 4 that detects short-term mean-reversion
opportunities using a statistically auto-calibrated lookback window — no
hardcoded parameters for the time scale.

Built by [Trade App Soft LLC](https://www.linkedin.com/company/trade-app-soft-llc)
as a demonstration of how we approach statistically-grounded execution logic.

> ⚠️ **This is a research/demonstration prototype, not a production trading
> strategy.** It has not been optimized, walk-forward tested, or validated
> for live trading. Use at your own risk. Nothing here is financial advice.

## What's in this repo

| File | Type | Description |
|---|---|---|
| `VWAP_ZScore_EA.mq4` | Expert Advisor | Full EA: estimates the model and places live orders automatically |
| `VWAP_ZScore_Signal_Script.mq4` | Script | Signal-only version: runs once, prints/exports the Z-score analysis, no order execution |

## The idea

Most mean-reversion strategies pick a lookback window (e.g. "20 bars") by
hand or by brute-force optimization. This project instead tries to *infer*
the window from the data itself:

1. **Build a return series.** Compute log-returns of a VWAP-style price
   `(Open + High + Low + Close) / 4` on M1 candles.
2. **Search for the optimal time scale (W).** For each candidate window
   size, compare the *observed* volatility of rolling means against the
   *theoretical* volatility a pure random walk would produce
   (`σ_actual / (σ_population / √W)`). Under a random walk this ratio is
   flat; where mean-reversion is present, it peaks. The window at the peak
   (after smoothing to avoid noisy local maxima) is treated as the
   "optimal" scale.
3. **Score the current window.** Convert the most recent window's mean
   return into a Z-score against that model.
4. **Signal.** A configurable confidence level (e.g. 90%) is converted into
   a Z-score threshold via the inverse normal CDF. When |Z| crosses that
   threshold, the model flags an expected reversion.
5. **Risk (EA only).** Entry, stop-loss, and take-profit are all derived
   from the same statistical distance — symmetric 1:1 by construction — and
   the EA hard-stops after a configurable number of trades
   (`ExecutionThrottle`) to prevent unsupervised runaway execution.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `N` | 512 | M1 bars used to estimate the model |
| `Wmin` | 15 | Minimum window size allowed when searching for the optimal W (prevents picking windows so short they're mostly noise/microstructure) |
| `Suavizado` | 5 | Smoothing window (in points) applied to the ratio curve before picking W |
| `Probabilidad` (EA) / `ZUmbral` (script) | 90% / 1.65 | Statistical confidence level for the signal threshold |
| `Lots` | 0.1 | Order size (EA only) |
| `ExecutionThrottle` | 200 | Max trades allowed without human review (EA only) |

## Design notes

**Z-score normalization.** The current window's mean return is normalized
against `sigmaPob` — the population standard deviation of the individual
log-returns — rather than against the standard deviation of the rolling
window means (`sigmamuV`). The idea: we're asking whether the current
window's behavior is unusual *relative to the population as a whole*, not
relative to the dispersion of other rolling windows (which is already
shaped by the very W we picked in step 2, so using it as the yardstick for
step 3 would be somewhat circular). `sigmamuV` is still used internally to
find the optimal W (comparing it against its theoretical expectation), but
the final signal Z-score uses `sigmaPob`. Both files (EA and script) use
this same criterion.

The Z-score is scaled by `sqrt(W)`:
`Z = mean(last W returns) * sqrt(W) / sigmaPob`. This matches the standard
error of a mean of W i.i.d. draws (`sigmaPob / sqrt(W)`), so the confidence
level configured in `Probabilidad` corresponds to an actual statistical
confidence level under the model's own random-walk null hypothesis.

**Price distances (entry, SL, TP) intentionally use `W`, not `sqrt(W)`.**
While the Z-score itself needs the `sqrt(W)` correction to be statistically
well-calibrated, the price-distance formulas (`distV`, `distC`, and the
SL/TP calculations in `EnviarOrden`/`PrintSenal`) were kept on the original
`W` scaling on purpose — using `sqrt(W)` there produced entry/exit levels
that were too tight to be practical (SL and TP collapsing close to the
entry price). So the two parts of the model are deliberately decoupled:
`sqrt(W)` for signal detection, `W` for position sizing in price terms.

**Minimum window (`Wmin`).** Without a floor, the optimal-W search can pick
very short windows (e.g. W=4 on a volatile M1 symbol), which are more
exposed to spread/slippage noise than to genuine cyclical structure. `Wmin`
restricts the search to windows of at least that many bars.

## Requirements

- MetaTrader 4
- A broker/symbol with M1 history available for at least `N` bars

## Disclaimer

This code is provided for educational and demonstration purposes only. It
is not investment advice, and no representation is made about its
profitability. Past or simulated performance is not indicative of future
results. Trading leveraged instruments carries substantial risk of loss.

## About

[Trade App Soft LLC](https://www.linkedin.com/company/trade-app-soft-llc)
builds and consults on automated trading systems — from strategy research
and MQL4/FIX execution to latency analysis. Get in touch if you'd like to
work with us.
