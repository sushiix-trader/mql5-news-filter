# News Filter — self-contained package for any MQL5 EA

**Package:** include + exporter + CSV + docs (this repository)

Reusable economic-calendar filter. Live/demo uses the MT5 calendar; Strategy
Tester uses a deterministic CSV replay (`AUTO` by default). Only
**high-impact** events are considered, further limited by `NFA_Currencies`.

## Package contents

| File | Role |
|------|------|
| `NewsFilter_Advanced.mqh` | Drop-in module (`NFA_*` inputs) |
| `NewsFilter_DropIn_Example.mq5` | Minimal wiring skeleton |
| `export_news_calendar_csv.mq5` | Builds/refreshes the replay CSV (writes to `MQL5\Files`) |
| `MQL5Book/` | CalendarCache support used by the exporter |
| `news_calendar_replay.csv` | Replay calendar for Strategy Tester (~32MB) |
| `stage_csv_to_files.sh` | Copies package CSV → `MQL5/Files/` for the tester |
| `README.md` | This guide |

Compile and run `export_news_calendar_csv.mq5` from **this** folder. Copy or
symlink the package into your MT5 `MQL5` tree (or `#include` it via a relative
path from your EA).

## Public seam (three calls)

| Call | When | Does |
|------|------|------|
| `NFA_Init()` | `OnInit` | Load live calendar or CSV; return false on strict CSV failure |
| `NFA_Manage(magic)` | Every tick (before new-bar guards) | Optional flatten / cancel pendings (`0` = all magics) |
| `NFA_EntryAllowed(symbol)` | Before every entry | `false` inside the news window; never sends orders |

## Drop-in checklist

1. **Include** (adjust `..\` depth for your EA folder):

```mql5
#include "NewsFilter_Advanced.mqh"   // or a relative path to this package
```

2. **Tester file** (required for CSV replay in Strategy Tester):

```mql5
#property tester_file "news_calendar_replay.csv"
```

3. **Init / tick** — see `NewsFilter_DropIn_Example.mq5`, or:

```mql5
int OnInit()
{
   if(!NFA_Init())
      return INIT_PARAMETERS_INCORRECT;
   return INIT_SUCCEEDED;
}

void OnTick()
{
   NFA_Manage(MyMagicNumber);   // or NFA_Manage(0) for all account trades/orders
   if(!NFA_EntryAllowed(_Symbol))
      return;
   // ... your entries ...
}
```

4. Leave `NFA_UseNewsFilter=false` until you want it on. Defaults: `AUTO` source,
   30m block before/after, flatten off.

5. **CSV for backtests**
   - Compile/run `export_news_calendar_csv.mq5` from this folder (connected terminal), **or**
   - Keep `news_calendar_replay.csv` in this folder and run `./stage_csv_to_files.sh`
   - Tester/`FileOpen` always reads from `MQL5\Files\` (plus `#property tester_file`)

6. Set `NFA_Currencies` to the currencies you care about (e.g. `USD,JPY`).

## Logging / debug

| Input | Default | What it logs |
|-------|---------|----------------|
| `NFA_LogBlocks` | true | Entry blocked by an active news window (throttled) |
| `NFA_LogSkippedEvents` | **false** | Debug: high-impact events **not** kept because currency mismatch or `NFA_ExcludeEvents` (up to 25 samples each + summary). Low-importance rows are counted only, not listed. |

Turn `NFA_LogSkippedEvents=true` when tuning currencies/exclusions. Flatten/cancel
actions always Print when they succeed or fail.

## What This Module Provides

- cached calendar reads, so no calendar API calls are made in the entry hot path
- deterministic CSV replay with a strict schema and coverage validation
- high-impact filtering, currency matching, and event-name exclusions
- symbol-to-currency derivation from the broker's base/profit metadata
- a manual override map for instruments whose currency metadata is incomplete
- a position-flatten sweep with broker-aware filling mode
- optional pending-order cancellation (off by default)
- magic-number scoping (`NFA_Manage(0)` = entire account)
- fail-open/fail-closed handling for unavailable calendar data
- throttled diagnostic logging (+ optional skip debug)

## The Split Between Deciding And Acting

`NFA_EntryAllowed(symbol)` is the decision layer. It returns whether a new
entry is allowed and never sends an order.

`NFA_Manage(magic)` is the action layer. It closes positions (and, only if
explicitly enabled, cancels pending orders). Call it every tick and outside
any "new bar only" guard.

## Important Assumptions

These modules are designed for:

- MQL5 Expert Advisors
- a broker whose terminal actually serves the economic calendar
- live/demo operation with the terminal calendar, or tester operation with the deterministic CSV replay described below
- an EA that knows its own magic number, for the advanced version

The calendar is a terminal feature, not a broker feed you can assume is present. Check the init log line before you rely on any of this.

## What The Inputs Mean

All inputs in this module use the `NFA_` prefix.

Core:

- `NFA_UseNewsFilter`: master switch. Off means the module is a complete no-op, so you can install it without changing behaviour and turn it on later.
- `NFA_CalendarSource`: `AUTO` (default) uses the terminal economic calendar live/demo and switches to CSV replay in Strategy Tester / optimization. Force `LIVE` or `CSV_REPLAY` only when you need to override that.
- `NFA_CsvFileName`: replay file under `MQL5\\Files` (and declared via `#property tester_file` on the EA). Used whenever the resolved source is CSV.
- `NFA_CsvStrict`: missing/malformed CSV or out-of-coverage tester time fails init / stops the tester when CSV is the resolved source.
- `NFA_BlockMinutesBefore`: how long before a release entries stop. Default 30.
- `NFA_BlockMinutesAfter`: how long after a release entries stay blocked. Default 30.
- `NFA_FailClosed`: what happens when the calendar is unavailable. False (default) trades on as if the filter were off. True blocks everything.

What counts as news:

- `NFA_Currencies`: the currencies you care about, comma separated. An event only matters if its country's currency is on this list.
- `NFA_ExcludeEvents`: comma-separated substrings. Any event whose name contains one is dropped before it can block anything. This is how you stop US crude oil inventories blocking your EURUSD trades, and you will want it.
- `NFA_SymbolOverrides`: a manual `SYMBOL=CCY` map for instruments MT5 cannot map itself. Almost every index CFD needs an entry here. Edit this first.

Advanced only:

- `NFA_FlattenPositions`: close open positions before a release. Off by default.
- `NFA_FlattenLeadMinutes`: how long before the release closing starts. Clamped to `NFA_BlockMinutesBefore`.
- `NFA_CancelPendings`: optional generic action for resting pending orders. It is **off by default**.
- `NFA_LogBlocks`: log each blocked entry (throttled). Default true.
- `NFA_LogSkippedEvents`: debug — log high-impact events skipped for currency/exclude (sampled + summary). Default false.

## How It Works Behind The Scenes

1. In live/demo with `AUTO` or `LIVE`, on init and every four hours after that, the module pulls three days of calendar events with `CalendarValueHistory`. In Strategy Tester with `AUTO` (or any mode resolved to CSV), it loads and validates the complete replay file once on init.
2. Each event is kept only if `CalendarEventById` reports it as `CALENDAR_IMPORTANCE_HIGH` (or the CSV row carries that level), its country currency is on your `NFA_Currencies` list, and its name does not match `NFA_ExcludeEvents`.
3. Survivors go into a small in-memory array. Nothing else touches the calendar API, so the per-tick cost is a binary-search window check.
4. For each symbol, the watched currencies are derived once from `SYMBOL_CURRENCY_BASE` and `SYMBOL_CURRENCY_PROFIT`, filtered to your list, plus the override map. The result is cached per symbol.
5. A gate is a time comparison: is now inside the window around a cached event for one of this symbol's currencies.

A failed currency lookup is deliberately not cached. Caching it would leave that symbol unprotected for the life of the EA, and you would never see why.

## Manual Installation

See the drop-in checklist at the top. Full skeleton: `NewsFilter_DropIn_Example.mq5`.

Pass your EA's magic number to `NFA_Manage`. The sweep only touches positions and orders carrying it. Passing 0 acts on everything in the account — only do that if this EA is the only thing trading it.

## Adding It With An AI Agent

If you use Claude Code, Cursor, or similar, this prompt works well:

```text
Add the news filter from NewsFilter_Advanced.mqh to my EA.

1. Include the module (path relative to the EA under Experts/).
2. Add #property tester_file "news_calendar_replay.csv".
3. Call NFA_Init() in OnInit().
4. Find EVERY place the EA sends an entry order. For each one, gate it with
   NFA_EntryAllowed(<the symbol being traded>) and skip the entry if it
   returns false. List the call sites you found and confirm the count.
5. Call NFA_Manage(<magic>) every tick before new-bar guards.
6. Do not change my strategy logic, lot sizing, stops, or targets.
7. Leave NFA_UseNewsFilter at false so behaviour is unchanged until I enable it.
```

Ask it to confirm the number of entry call sites. That is the step people get wrong.

## Two Things That Will Confuse You

I lost an hour to both of these. They are not bugs.

### The MT5 Calendar tab is not what the filter reads

The terminal's Calendar tab does not always display everything the calendar API returns. An event the API reports as high impact can be missing from the tab entirely. The module reads the API, so the tab will mislead you.

The module prints the authoritative list every time it refreshes:

```text
[NewsFilter] cached 4 event(s) (raw=150, name-excluded=2) | 2026.08.26 17:30 USD ...
```

That line is everything the filter can act on. Trust it over the tab.

### Log timestamps and calendar times are different clocks

Your Experts-tab log timestamps are in local PC time. `TimeCurrent()` and the calendar's event times are both in server time. On a UTC+3 broker viewed from a UTC+1 machine, a block that fired correctly twelve minutes before a release looks like it fired two hours and twelve minutes early.

Convert before you conclude the window is broken. Inside the module both sides of the comparison are server time, so it is consistent whatever your broker's offset.

## Pros

- Stops entries into a print your model never saw in backtest
- Costs one function call per entry path
- Cached, so no calendar API work per tick
- Master switch off means a genuine no-op, safe to install ahead of time
- Magic scoping in the advanced version keeps other EAs safe

## Cons

- The MT5 calendar rates some second-tier releases as high impact. You will need `NFA_ExcludeEvents`.
- Currency matching is blunt. A US energy release applies to every USD instrument, whether or not it is related.
- Index CFDs need a manual entry in `NFA_SymbolOverrides` or they are not covered at all.
- Live calendar mode depends on the terminal calendar feed; use CSV replay for deterministic tester runs.
- The CSV replay reproduces the exported scheduled event list, not the information set that was necessarily known at the original historical decision time.
- Blocking entries around news changes your trade distribution. Your backtest no longer describes what you are running.

That last point is the real cost. Measure it before you leave it on.

## Safety Notes

- Test on a demo account first. Every time.
- Turn `NFA_FlattenPositions` on only once you have watched the entry blocking behave for a while.
- The flatten sweep will close positions at market. Understand that before enabling it.
- Fail-open is the default. If your calendar feed dies, the filter stops protecting you and says so in the log. Nothing alerts you beyond that line.
- This is educational tooling, not trading advice and not a signal service.
- No warranty of any kind. Use at your own risk. Trading carries risk of loss.

## Compile Status

The integrated sources used by this exporter change must be compiled with
MetaEditor before running it. The cache-based exporter is intentionally
complete-or-fail by default; verify the compiler result and the export log
before copying the CSV into a tester data folder.

```text
export_news_calendar_csv.mq5     verify with current source before use
NewsFilter_DropIn_Example.mq5    0 errors, 0 warnings (previous build)
```

## Deterministic Historical CSV Replay

The live module reads `CalendarValueHistory()`. Strategy Tester calendar
availability is not assumed, so replay uses the same public calls and swaps
only the data-source adapter. The exporter uses the MT5 catalogue APIs
(`CalendarCountries`/`CalendarEventByCountry`) and the `CalendarCache` core
from MQL5 CodeBase 52977. It requests short, explicitly scoped ranges by
currency or country and saves each successful range as a reusable `.cal` file
under `MQL5\\Files`, so a later run can use the local cache instead of asking
the calendar service for that range again.

### 1. Export the calendar from a connected terminal

Compile and run `Scripts/export_news_calendar_csv.mq5` in the terminal that
will be used to build the replay. Its checked-in defaults are already set for
the project's five-year tester interval (`2021.07.01..2026.06.30`) with one
day of coverage padding on each side, and it writes
`news_calendar_replay.csv` to `MQL5\Files`. For that project interval, you
can run the script without changing its inputs. The exporter:

- exports all calendar currencies by default (`InpCurrencies` is blank); set it
  to a comma-separated list such as `USD,JPY` for a smaller pair-specific
  export;
- enumerates the event catalogue for each requested currency, then requests
  history by unique currency. Blank `InpCurrencies` enumerates every country
  instead; Worldwide/ALL-style rows remain country queries;
- uses `InpEventChunkDays=7` by default, stores each successful chunk using
  `InpCachePrefix`, and reports `cache hit` on later runs. Values above 30 days
  are rejected; `InpMaxSplitDepth` bounds event-by-event splitting when a short
  aggregate range still returns 5400/5401;
- falls back to `CalendarValueHistoryByEvent()` for a timed-out aggregate range,
  with up to eight bounded time splits by default, so one overloaded currency
  query does not prevent the rest of the export;
- fails the export on an unretrievable event by default
  (`InpSkipTimedOutEvents=false`), leaving the existing CSV unchanged. Set the
  option to `true` only when an explicitly incomplete archive is acceptable;
  skipped events are remembered for the rest of the run and counted in the log;
- retains successful cache chunks when a later range fails. The final replay
  CSV is still written only after every query/window succeeds, so a failed run
  leaves the existing CSV unchanged but can make progress on the next run;
- includes the local `Scripts/MQL5Book/CalendarCache.mqh` support files, which
  are adapted from the linked CodeBase package for this project's relative
  include layout;
- writes `event_time_mt5` in the chosen server basis (default NY-close align)
  plus human-readable `event_time_gmt`;
- keeps the event id, currency, importance, and event name;
- de-duplicates adjacent chunk overlap;
- writes a coverage metadata row, including the time basis and source label.

The raw MT5 time is intentional. Do not export a formatted local-PC time and
parse it later. `TimeCurrent()` and the calendar timestamp must be compared in
the same MT5/tester time coordinate.

The requested export range should cover the tester range plus the largest
news-window lead/lag. For example, for a test beginning at `2025.01.02` with
a 30-minute pre-block, export from at least `2025.01.01 23:30`.

### 2. Stage the file for the tester

Your EA should declare:

```mql5
#property tester_file "news_calendar_replay.csv"
```

Place the file in the terminal's `MQL5\\Files` folder before starting the
test. `tester_file` makes the file available to tester agents. Keep the same
file name and stage the broker-specific CSV selected by the backtest runner.

### 3. Enable the filter (AUTO source)

```text
NFA_UseNewsFilter=true
NFA_CalendarSource=NFA_CALENDAR_AUTO   ; default: live calendar live/demo, CSV in tester
NFA_CsvFileName=news_calendar_replay.csv
NFA_CsvStrict=true
NFA_BlockMinutesBefore=30
NFA_BlockMinutesAfter=30
NFA_FlattenPositions=true       ; optional
NFA_FlattenLeadMinutes=30       ; clamped to the block lead
NFA_CancelPendings=false        ; set true if your EA uses pending orders
```

With `AUTO`, the same inputs work for a charted EA and a Strategy Tester
backtest: the init log reports `source=LIVE (input=AUTO)` or
`source=CSV_REPLAY (input=AUTO)`. Force `CSV_REPLAY` only when you want CSV
outside the tester; force `LIVE` only for debugging (tester calendar history
is not reliable).

Strict mode fails `OnInit()` for a missing, malformed, or out-of-schema
replay file when CSV is the resolved source. It also stops a tester run if a
tick falls outside the file's declared coverage, rather than silently
evaluating with incomplete history. A valid file containing no matching
high-impact currency events is allowed; that is different from a missing file.

The replay file is deliberately not pre-filtered to only high-impact events.
The module applies the same high-impact, currency, and exclusion policy as
live mode, so changing `NFA_Currencies` or `NFA_ExcludeEvents` does not require
re-exporting the calendar.

### File contract

The canonical columns are:

```text
schema_version,event_id,event_time_mt5,currency,importance,event_name,coverage_from_mt5,coverage_to_mt5,time_basis,source,event_time_gmt
```

The first data row is a `__META__`/`coverage` row. Event rows must use
`time_basis=mt5_nyclose`, have the same coverage values, and be numeric in
`event_time_mt5`.

`event_time_mt5` is aligned to NY-close broker server time (Fusion/Pepperstone
style: GMT+3 in US DST, GMT+2 in US standard). The exporter applies US DST
rules that move each year (2nd Sunday in March → 1st Sunday in November since
2007): raw calendar times that behave like fixed GMT+3 are shifted **−1 hour
outside US DST** so winter releases line up with chart spikes (e.g. NFP at
15:30 year-round).

`event_time_gmt` is a human-readable GMT / UTC+0 clock
(`YYYY-MM-DD HH:MM:SSZ`) from the aligned MT5 time using the same US DST
offsets (−3h / −2h). The metadata row stores mode `nyclose_us_dst` in
`event_time_gmt`. The filter gates on `event_time_mt5`.

Event names must not contain commas: MT5 `FILE_CSV` readers do not reliably
honor quoted commas, so the exporter replaces `,` in names with ` -`.

### Limitations

- **Broker clock assumption.** Schema `mt5_nyclose` assumes an NY-close server
  (GMT+3 in US DST, GMT+2 in US standard), as used by Fusion/Pepperstone on
  this host. It is **not** automatically correct for fixed-GMT+2/GMT+3-only,
  GMT+0, or other broker timebases.
- **Calendar source vs wall clock.** Times come from the MT5 economic calendar
  dump, then adjusted for NY-close. They are scheduled-event times, not a
  guarantee that every print produced a spike on that exact minute.
- **Weak / multi-leg events.** Speeches, FOMC press conferences, and ECB
  decision-vs-presser sequences can move at more than one time. Max-range
  chart checks are noisy there; treat those names cautiously or exclude them.
- **Not point-in-time.** A later export can include revised, cancelled, or
  newly added events that were not known at the original decision time.
- **CSV hygiene.** Keep one replay file per intended server clock. Do not mix
  an NY-close CSV with a tester whose history is on a different offset.
- **Cache size.** Full multi-year `.cal` caches can be huge; keep
  `InpCachePrefix=""` unless disk is planned for it.

### Using this with another broker backtest

1. **Decide the tester’s server clock.** On a chart, note where a known US
   release (e.g. NFP) spikes in server time in both US winter and US summer.
   - Spikes at **15:30 both seasons** → NY-close; use `InpAlignMt5ToNycloseServer=true`
     (schema `mt5_nyclose`) as on this project.
   - Spikes at **16:30 winter / 15:30 summer** → raw fixed GMT+3 calendar clock;
     export with align **off** (`time_basis=mt5_datetime`).
   - Any other pattern → do not reuse this CSV; re-export and build an align
     rule for that broker (or keep raw and document the offset).
2. **Export in that broker’s terminal** (or the terminal whose history you
   will test), covering the tester range plus the largest block lead/lag.
3. **Stage** `news_calendar_replay.csv` into that terminal’s `MQL5\\Files`.
4. **Run** with `NFA_UseNewsFilter=true` and `NFA_CalendarSource=AUTO` (or
   explicit `CSV_REPLAY`) and an EA built for schema 4 /
   `mt5_nyclose` (or `mt5_datetime` if you exported raw).
5. **Smoke-test** one winter and one summer NFP/CPI day: block window must
   cover the chart spike (`news_calendar_replay_probe` is the project check).

Do not copy an NY-close CSV into a non-NY-close broker tester and assume
parity. Re-verify spikes, or re-export with the matching align mode.

### What this proves — and what it does not

This is a deterministic **scheduled-event replay**: it reproduces the event
schedule present in the exported calendar. It is not automatically a
point-in-time historical-calendar replay. A later export can contain revised,
cancelled, or newly added events that were not known at the original decision
time.

For research-grade point-in-time testing, extend the file with a
`known_from_mt5` field or versioned calendar snapshots and make the adapter
select only rows where `known_from_mt5 <= TimeCurrent()`. Until that is added,
label results as scheduled-event replay rather than claiming perfect
real-time information parity.
