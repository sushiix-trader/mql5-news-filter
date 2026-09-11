//+------------------------------------------------------------------+
//| NewsFilter_Advanced.mqh                                          |
//| Shared drop-in economic-calendar filter for any MQL5 EA          |
//| Package: mql5-news-filter   Version 1.1                          |
//+------------------------------------------------------------------+
//
// Public seam (call these from any EA):
//
//   NFA_Init()                 OnInit — loads live calendar or CSV replay
//   NFA_EntryAllowed(symbol)   gate entries (decision; never sends orders)
//   NFA_Manage(magic)          flatten / cancel pendings (action; every tick)
//
// This module owns its own `input` group (NFA_*). Include it once, wire the
// three calls above, declare `#property tester_file "news_calendar_replay.csv"`
// when you want Strategy Tester replay, and leave NFA_UseNewsFilter=false
// until you are ready to enable it.
//
// Windows:
//   entry block   [T - NFA_BlockMinutesBefore, T + NFA_BlockMinutesAfter]
//   flatten       [T - NFA_FlattenLeadMinutes, T)   stops at T
//   pending cancel  same as the entry block window
//
// The flatten window deliberately stops at T. Closing into the blown spread
// straight after a print is usually worse than letting your own stop handle
// it, so the sweep does not chase a position once the number is out.
//
// The flatten lead is clamped to the entry-block window. A lead longer than
// the block would close a position while entries are still allowed, and the
// EA would immediately re-enter: a churn loop that pays spread both ways.
//
// FAIL-OPEN by default, and the flatten sweep NEVER runs on a stale cache.
// Blocking entries on bad data costs you an opportunity. Closing positions
// on bad data costs you money, so that path requires a good cache always.
//
// Data source: the MT5 built-in economic calendar, cached in memory, or a
// strict, deterministic CSV replay exported from that same calendar.
//
#property strict

#ifndef NEWS_FILTER_ADVANCED_MQH
#define NEWS_FILTER_ADVANCED_MQH

enum ENUM_NFA_CALENDAR_SOURCE
{
   NFA_CALENDAR_LIVE       = 0, // Always use the terminal economic calendar
   NFA_CALENDAR_CSV_REPLAY = 1, // Always use the historical CSV replay file
   NFA_CALENDAR_AUTO       = 2  // Live calendar live/demo; CSV in Strategy Tester
};

input string NFA_Header             = "----------- News Filter -----------";
input bool   NFA_UseNewsFilter      = false;  // Enable the filter
input ENUM_NFA_CALENDAR_SOURCE NFA_CalendarSource = NFA_CALENDAR_AUTO; // Auto: live calendar, CSV in tester
input string NFA_CsvFileName        = "news_calendar_replay.csv"; // Tester file name in MQL5\Files
input bool   NFA_CsvStrict          = true;   // Invalid/missing replay data fails EA initialization
input int    NFA_BlockMinutesBefore = 30;     // Block entries N minutes before release
input int    NFA_BlockMinutesAfter  = 30;     // Block entries N minutes after release
input bool   NFA_FailClosed         = false;  // Calendar down: true = block all, false = trade on

input string NFA_ActionHeader       = "----------- News Filter: Actions -----------";
input bool   NFA_FlattenPositions   = false;  // Close open positions before a release
input int    NFA_FlattenLeadMinutes = 30;     // Start closing N minutes before (clamped to block window)
input bool   NFA_CancelPendings     = false;  // Cancel resting pending orders in the block window
input int    NFA_SlippagePoints     = 50;     // Deviation for the flatten close

input string NFA_FilterHeader       = "----------- News Filter: What Counts -----------";
input string NFA_Currencies         = "USD,EUR,GBP,JPY,CHF,CAD,AUD,NZD,CNY";
input string NFA_ExcludeEvents      = "Crude Oil,Natural Gas,Gasoline,Distillate,Rig Count";
input string NFA_SymbolOverrides    = "NDX=USD,SP500=USD,US30=USD,GER40=EUR,UK100=GBP";

input string NFA_LogHeader          = "----------- News Filter: Logging -----------";
input bool   NFA_LogBlocks          = true;   // Log each blocked entry (throttled)
input bool   NFA_LogSkippedEvents   = false;  // Debug: log high-impact events skipped (currency/exclude)

#define NFA_REFRESH_SECONDS    14400
#define NFA_RETRY_SECONDS      60
#define NFA_LOOKAHEAD_SECONDS  259200
#define NFA_LOG_THROTTLE       60
#define NFA_MAX_CACHED_SYMBOLS 64
#define NFA_CSV_SCHEMA_VERSION 4
#define NFA_CSV_COLUMN_COUNT   11
#define NFA_CSV_META_CURRENCY  "__META__"
#define NFA_CSV_TIME_BASIS     "mt5_nyclose"

struct NFACalendarEvent
{
   datetime time;
   ulong    event_id;
   int      importance;
   string   currency;
   string   name;
};

NFACalendarEvent nfaEvents[];
bool     nfaStale             = true;
bool     nfaReplayLoaded      = false;
bool     nfaReplayWarned      = false;
ENUM_NFA_CALENDAR_SOURCE nfaResolvedSource = NFA_CALENDAR_LIVE;
datetime nfaNextRefresh       = 0;
datetime nfaLastWarnTime      = 0;
datetime nfaLastBlockLog     = 0;
datetime nfaLastCloseFail    = 0;
datetime nfaCoverageFrom     = 0;
datetime nfaCoverageTo       = 0;
int      nfaSkipLogCurrency  = 0;
int      nfaSkipLogExcluded  = 0;

#define NFA_SKIP_LOG_SAMPLE_MAX 25

string   nfaSymbolNames[NFA_MAX_CACHED_SYMBOLS];
string   nfaSymbolCcys[NFA_MAX_CACHED_SYMBOLS];
int      nfaSymbolCount    = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                     |
//+------------------------------------------------------------------+

// Resolve AUTO to CSV in the tester/optimizer, otherwise the live calendar.
// Explicit LIVE / CSV_REPLAY inputs are left unchanged.
ENUM_NFA_CALENDAR_SOURCE NFA_ResolveCalendarSource()
{
   if (NFA_CalendarSource == NFA_CALENDAR_AUTO)
   {
      if (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
         return NFA_CALENDAR_CSV_REPLAY;
      return NFA_CALENDAR_LIVE;
   }
   return NFA_CalendarSource;
}

string NFA_CalendarSourceLabel(const ENUM_NFA_CALENDAR_SOURCE source)
{
   if (source == NFA_CALENDAR_CSV_REPLAY)
      return "CSV_REPLAY";
   if (source == NFA_CALENDAR_AUTO)
      return "AUTO";
   return "LIVE";
}

bool NFA_UsingCsvReplay()
{
   return (nfaResolvedSource == NFA_CALENDAR_CSV_REPLAY);
}

void NFA_ResetSkipLogCounters()
{
   nfaSkipLogCurrency = 0;
   nfaSkipLogExcluded = 0;
}

void NFA_LogSkipSample(const string reason, const string currency,
                       const string event_name, const datetime event_time,
                       int &sample_count)
{
   if (!NFA_LogSkippedEvents)
      return;
   if (sample_count >= NFA_SKIP_LOG_SAMPLE_MAX)
      return;
   sample_count++;
   Print("[NewsFilter] skipped (", reason, "): ", currency, " ", event_name,
         " @ ", TimeToString(event_time, TIME_DATE|TIME_MINUTES));
}

void NFA_LogSkipSummary(const string where, const int ignored_other)
{
   if (!NFA_LogSkippedEvents)
      return;
   Print("[NewsFilter] skip summary (", where, "): high-impact currency-mismatch=",
         nfaSkipLogCurrency, ", name-excluded=", nfaSkipLogExcluded,
         ", other-ignored=", ignored_other,
         " (samples capped at ", NFA_SKIP_LOG_SAMPLE_MAX, " per reason)");
}

bool NFA_ListContains(const string haystack, const string needle)
{
   if (needle == "" || haystack == "")
      return false;

   string wanted = needle;
   StringTrimLeft(wanted);
   StringTrimRight(wanted);
   StringToUpper(wanted);

   string parts[];
   int count = StringSplit(haystack, StringGetCharacter(",", 0), parts);
   for (int i = 0; i < count; i++)
   {
      string part = parts[i];
      StringTrimLeft(part);
      StringTrimRight(part);
      StringToUpper(part);
      if (part == wanted)
         return true;
   }
   return false;
}

// True when the event name contains any term from NFA_ExcludeEvents.
// This is how you stop sector-specific releases (oil inventories, gas
// storage) blocking instruments that have nothing to do with them.
bool NFA_EventExcluded(const string event_name)
{
   if (NFA_ExcludeEvents == "")
      return false;

   string upper_name = event_name;
   StringToUpper(upper_name);

   string parts[];
   int count = StringSplit(NFA_ExcludeEvents, StringGetCharacter(",", 0), parts);
   for (int i = 0; i < count; i++)
   {
      string term = parts[i];
      StringTrimLeft(term);
      StringTrimRight(term);
      if (term == "")
         continue;
      StringToUpper(term);
      if (StringFind(upper_name, term) >= 0)
         return true;
   }
   return false;
}

// Manual symbol-to-currency map. Format: "NDX=USD,GER40=EUR".
// Edit NFA_SymbolOverrides to match your broker's instrument names.
string NFA_SymbolOverride(const string symbol)
{
   if (NFA_SymbolOverrides == "")
      return "";

   string pairs[];
   int count = StringSplit(NFA_SymbolOverrides, StringGetCharacter(",", 0), pairs);
   for (int i = 0; i < count; i++)
   {
      string kv[];
      if (StringSplit(pairs[i], StringGetCharacter("=", 0), kv) != 2)
         continue;
      StringTrimLeft(kv[0]);
      StringTrimRight(kv[0]);
      StringTrimLeft(kv[1]);
      StringTrimRight(kv[1]);
      if (kv[0] == symbol)
         return kv[1];
   }
   return "";
}

void NFA_Warn(const string where)
{
   datetime now = TimeCurrent();
   if (nfaLastWarnTime != 0 && now - nfaLastWarnTime < NFA_LOG_THROTTLE)
      return;
   nfaLastWarnTime = now;
   Print("[NewsFilter] WARNING: economic calendar unavailable (", where,
         "), error=", GetLastError(), " - entry gates are ",
         (NFA_FailClosed ? "BLOCKING (fail-closed)" : "open (fail-open)"),
         ", flatten sweep is disabled until the cache recovers");
}

// Broker-aware filling mode. Tested as a BITMASK, not with equality: a
// broker offering IOC|BOC but not FOK would otherwise get FOK and reject
// every order with retcode 10030.
ENUM_ORDER_TYPE_FILLING NFA_FillingMode(const string symbol)
{
   long modes = 0;
   if (!SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE, modes))
      return ORDER_FILLING_RETURN;

   if ((modes & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if ((modes & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool NFA_RetcodeOK(const uint retcode)
{
   return retcode == TRADE_RETCODE_DONE
       || retcode == TRADE_RETCODE_DONE_PARTIAL
       || retcode == TRADE_RETCODE_PLACED;
}

//+------------------------------------------------------------------+
//| CSV replay helpers                                                |
//+------------------------------------------------------------------+

string NFA_Trimmed(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   return value;
}

string NFA_UpperTrimmed(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   StringToUpper(value);
   return value;
}

// StringToInteger() is deliberately wrapped so malformed numeric fields are
// rejected instead of silently becoming zero.
bool NFA_ParseInteger(const string raw, long &value)
{
   string text = NFA_Trimmed(raw);
   int length = StringLen(text);
   if (length == 0)
      return false;

   int first = 0;
   ushort sign = StringGetCharacter(text, 0);
   if (sign == StringGetCharacter("-", 0) || sign == StringGetCharacter("+", 0))
      first = 1;
   if (first == length)
      return false;

   for (int i = first; i < length; i++)
   {
      ushort ch = StringGetCharacter(text, i);
      if (ch < StringGetCharacter("0", 0) || ch > StringGetCharacter("9", 0))
         return false;
   }

   value = StringToInteger(text);
   return true;
}

string NFA_CsvHeaderName(const int index)
{
   switch (index)
   {
      case 0: return "schema_version";
      case 1: return "event_id";
      case 2: return "event_time_mt5";
      case 3: return "currency";
      case 4: return "importance";
      case 5: return "event_name";
      case 6: return "coverage_from_mt5";
      case 7: return "coverage_to_mt5";
      case 8: return "time_basis";
      case 9: return "source";
      case 10: return "event_time_gmt";
   }
   return "";
}

bool NFA_ReadCsvFields(const int handle, string &fields[])
{
   for (int i = 0; i < NFA_CSV_COLUMN_COUNT; i++)
      fields[i] = FileReadString(handle);

   // Reject extra columns rather than silently shifting the meaning of data.
   return FileIsLineEnding(handle);
}

bool NFA_CsvLoadFailure(const string reason)
{
   nfaStale = true;
   Print("[NewsFilter] CSV replay load failed: ", reason,
         " (", (NFA_CsvStrict ? "strict initialization failure" :
         (NFA_FailClosed ? "entries blocked" : "fail-open")), ")");
   return !NFA_CsvStrict;
}

bool NFA_AppendReplayEvent(const NFACalendarEvent &candidate, string &reason)
{
   for (int i = 0; i < ArraySize(nfaEvents); i++)
   {
      if (nfaEvents[i].event_id != candidate.event_id ||
          nfaEvents[i].time != candidate.time)
         continue;

      if (nfaEvents[i].currency != candidate.currency ||
          nfaEvents[i].name != candidate.name ||
          nfaEvents[i].importance != candidate.importance)
      {
         reason = StringFormat("conflicting duplicate event_id=%I64u time=%I64d",
                               candidate.event_id, (long)candidate.time);
         return false;
      }
      return true;
   }

   int count = ArraySize(nfaEvents);
   int insert_at = count;
   while (insert_at > 0 && nfaEvents[insert_at - 1].time > candidate.time)
      insert_at--;

   ArrayResize(nfaEvents, count + 1);
   for (int i = count; i > insert_at; i--)
      nfaEvents[i] = nfaEvents[i - 1];
   nfaEvents[insert_at] = candidate;
   return true;
}

bool NFA_LoadReplayCsv()
{
   ArrayResize(nfaEvents, 0);
   nfaReplayLoaded = false;
   nfaCoverageFrom = 0;
   nfaCoverageTo = 0;

   if (NFA_CsvFileName == "")
      return NFA_CsvLoadFailure("NFA_CsvFileName is empty");

   ResetLastError();
   int handle = FileOpen(NFA_CsvFileName, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if (handle == INVALID_HANDLE)
      return NFA_CsvLoadFailure(StringFormat("cannot open '%s', error=%d",
                                             NFA_CsvFileName, GetLastError()));

   bool ok = true;
   string reason = "";
   string replay_source = "";
   string fields[NFA_CSV_COLUMN_COUNT];

   for (int i = 0; i < NFA_CSV_COLUMN_COUNT && ok; i++)
   {
      fields[i] = FileReadString(handle);
      if (NFA_UpperTrimmed(fields[i]) != NFA_UpperTrimmed(NFA_CsvHeaderName(i)))
      {
         ok = false;
         reason = StringFormat("header column %d must be '%s'", i,
                               NFA_CsvHeaderName(i));
      }
   }
   if (ok && !FileIsLineEnding(handle))
   {
      ok = false;
      reason = "header has extra columns";
   }

   bool metadata_seen = false;
   int accepted = 0;
   int ignored = 0;
   int ignored_other = 0;
   int currency_samples = 0;
   int excluded_samples = 0;
   NFA_ResetSkipLogCounters();

   while (ok && !FileIsEnding(handle))
   {
      if (!NFA_ReadCsvFields(handle, fields))
      {
         ok = false;
         reason = StringFormat("row has fewer/more than %d columns", NFA_CSV_COLUMN_COUNT);
         break;
      }

      long schema = 0;
      long event_id_value = 0;
      long event_time_value = 0;
      long importance_value = 0;
      long coverage_from_value = 0;
      long coverage_to_value = 0;

      if (!NFA_ParseInteger(fields[0], schema))
      {
         ok = false;
         reason = StringFormat("malformed schema_version field='%s'", fields[0]);
         break;
      }
      if (schema != NFA_CSV_SCHEMA_VERSION)
      {
         ok = false;
         reason = StringFormat("unsupported schema version got=%I64d expected=%d",
                               schema, NFA_CSV_SCHEMA_VERSION);
         break;
      }
      if (!NFA_ParseInteger(fields[1], event_id_value) || event_id_value < 0)
      {
         ok = false;
         reason = StringFormat("malformed event_id field='%s'", fields[1]);
         break;
      }
      if (!NFA_ParseInteger(fields[2], event_time_value) || event_time_value < 0)
      {
         ok = false;
         reason = StringFormat("malformed event_time_mt5 field='%s'", fields[2]);
         break;
      }
      if (!NFA_ParseInteger(fields[4], importance_value))
      {
         ok = false;
         reason = StringFormat("malformed importance field='%s'", fields[4]);
         break;
      }
      if (!NFA_ParseInteger(fields[6], coverage_from_value) ||
          !NFA_ParseInteger(fields[7], coverage_to_value))
      {
         ok = false;
         reason = StringFormat("malformed coverage fields from='%s' to='%s'",
                               fields[6], fields[7]);
         break;
      }

      string currency = NFA_UpperTrimmed(fields[3]);
      string event_name = NFA_Trimmed(fields[5]);
      string time_basis = NFA_UpperTrimmed(fields[8]);
      string source = NFA_Trimmed(fields[9]);

      if (!metadata_seen)
      {
         if (currency != NFA_CSV_META_CURRENCY || event_id_value != 0 ||
             event_time_value != 0 || importance_value != -1 ||
             NFA_UpperTrimmed(event_name) != "COVERAGE" ||
             time_basis != NFA_UpperTrimmed(NFA_CSV_TIME_BASIS) ||
             coverage_from_value <= 0 || coverage_to_value <= coverage_from_value ||
             source == "")
         {
            ok = false;
            reason = "first data row must be the valid coverage metadata row";
            break;
         }
         nfaCoverageFrom = (datetime)coverage_from_value;
         nfaCoverageTo = (datetime)coverage_to_value;
         replay_source = source;
         metadata_seen = true;
         continue;
      }

      if (currency == NFA_CSV_META_CURRENCY)
      {
         ok = false;
         reason = "duplicate coverage metadata row";
         break;
      }

      if (coverage_from_value != (long)nfaCoverageFrom ||
          coverage_to_value != (long)nfaCoverageTo ||
          time_basis != NFA_UpperTrimmed(NFA_CSV_TIME_BASIS) ||
          source != replay_source || event_id_value <= 0 ||
          event_time_value <= 0 || currency == "" ||
          event_name == "" || importance_value < 0)
      {
         ok = false;
         reason = "event row failed schema, coverage, or time-basis validation";
         break;
      }

      // The replay file intentionally contains all calendar importance levels;
      // the same high-impact/name/currency policy as live mode is applied here.
      if (importance_value != (long)CALENDAR_IMPORTANCE_HIGH)
      {
         ignored++;
         ignored_other++;
         continue;
      }
      if (!NFA_ListContains(NFA_Currencies, currency))
      {
         ignored++;
         nfaSkipLogCurrency++;
         NFA_LogSkipSample("currency", currency, event_name,
                           (datetime)event_time_value, currency_samples);
         continue;
      }
      if (NFA_EventExcluded(event_name))
      {
         ignored++;
         nfaSkipLogExcluded++;
         NFA_LogSkipSample("exclude", currency, event_name,
                           (datetime)event_time_value, excluded_samples);
         continue;
      }

      NFACalendarEvent candidate;
      candidate.time = (datetime)event_time_value;
      candidate.event_id = (ulong)event_id_value;
      candidate.importance = (int)importance_value;
      candidate.currency = currency;
      candidate.name = event_name;
      if (!NFA_AppendReplayEvent(candidate, reason))
      {
         ok = false;
         break;
      }
      accepted++;
   }

   FileClose(handle);

   if (!ok)
      return NFA_CsvLoadFailure(reason);
   if (!metadata_seen)
      return NFA_CsvLoadFailure("missing coverage metadata row");

   nfaReplayLoaded = true;
   nfaStale = false;
   nfaNextRefresh = 0;
   Print("[NewsFilter] CSV replay loaded '", NFA_CsvFileName,
         "': accepted=", accepted, ", ignored=", ignored,
         ", deduped_total=", ArraySize(nfaEvents),
         ", coverage=", TimeToString(nfaCoverageFrom, TIME_DATE|TIME_SECONDS),
         "..", TimeToString(nfaCoverageTo, TIME_DATE|TIME_SECONDS),
         ", source=", replay_source);
   NFA_LogSkipSummary("CSV load", ignored_other);
   return true;
}

bool NFA_ReplayTimeCovered()
{
   if (!NFA_UsingCsvReplay() || !nfaReplayLoaded)
      return true;

   datetime now = TimeCurrent();
   if (now >= nfaCoverageFrom && now <= nfaCoverageTo)
      return true;

   if (!nfaReplayWarned)
   {
      nfaReplayWarned = true;
      Print("[NewsFilter] CSV replay time ",
            TimeToString(now, TIME_DATE|TIME_SECONDS),
            " is outside coverage [",
            TimeToString(nfaCoverageFrom, TIME_DATE|TIME_SECONDS), "..",
            TimeToString(nfaCoverageTo, TIME_DATE|TIME_SECONDS), "]");
      if (NFA_CsvStrict && MQLInfoInteger(MQL_TESTER))
      {
         Print("[NewsFilter] stopping tester because replay coverage is incomplete");
         TesterStop();
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Event cache                                                       |
//+------------------------------------------------------------------+

void NFA_Refresh()
{
   if (!NFA_UseNewsFilter || NFA_UsingCsvReplay())
      return;

   datetime now = TimeCurrent();
   if (now < nfaNextRefresh)
      return;

   MqlCalendarValue values[];
   datetime from = now - (datetime)(NFA_BlockMinutesAfter * 60 + 3600);
   datetime to   = now + (datetime)NFA_LOOKAHEAD_SECONDS;

   ResetLastError();
   if (!CalendarValueHistory(values, from, to) || ArraySize(values) == 0)
   {
      nfaStale = true;
      nfaNextRefresh = now + NFA_RETRY_SECONDS;
      NFA_Warn("CalendarValueHistory");
      return;
   }

   ArrayResize(nfaEvents, 0);
   int excluded = 0;
   int ignored_other = 0;
   int currency_samples = 0;
   int excluded_samples = 0;
   NFA_ResetSkipLogCounters();

   for (int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent event;
      if (!CalendarEventById(values[i].event_id, event))
         continue;

      if (event.importance != CALENDAR_IMPORTANCE_HIGH)
      {
         ignored_other++;
         continue;
      }

      MqlCalendarCountry country;
      if (!CalendarCountryById(event.country_id, country))
         continue;

      if (!NFA_ListContains(NFA_Currencies, country.currency))
      {
         nfaSkipLogCurrency++;
         NFA_LogSkipSample("currency", country.currency, event.name,
                           values[i].time, currency_samples);
         continue;
      }

      if (NFA_EventExcluded(event.name))
      {
         excluded++;
         nfaSkipLogExcluded++;
         NFA_LogSkipSample("exclude", country.currency, event.name,
                           values[i].time, excluded_samples);
         continue;
      }

      int n = ArraySize(nfaEvents);
      ArrayResize(nfaEvents, n + 1);
      nfaEvents[n].time       = values[i].time;
      nfaEvents[n].event_id   = values[i].event_id;
      nfaEvents[n].importance = (int)event.importance;
      nfaEvents[n].currency   = country.currency;
      nfaEvents[n].name       = event.name;
   }

   nfaStale = false;
   nfaNextRefresh = now + NFA_REFRESH_SECONDS;

   // This log line is the only reliable preview of what the filter will act
   // on. The MT5 Calendar tab does not always display everything the
   // calendar API returns, so do not use the tab to predict behaviour here.
   string preview = "";
   for (int i = 0; i < ArraySize(nfaEvents) && i < 5; i++)
      preview += " | " + TimeToString(nfaEvents[i].time, TIME_DATE|TIME_MINUTES)
               + " " + nfaEvents[i].currency + " " + nfaEvents[i].name;

   Print("[NewsFilter] cached ", ArraySize(nfaEvents), " event(s) (raw=",
         ArraySize(values), ", name-excluded=", excluded, ")", preview);
   NFA_LogSkipSummary("live refresh", ignored_other);
}

//+------------------------------------------------------------------+
//| Symbol to currency mapping                                        |
//+------------------------------------------------------------------+

string NFA_SymbolCurrencies(const string symbol)
{
   for (int i = 0; i < nfaSymbolCount; i++)
      if (nfaSymbolNames[i] == symbol)
         return nfaSymbolCcys[i];

   string base = "";
   string profit = "";
   bool base_ok   = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE, base);
   bool profit_ok = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT, profit);

   // A failed lookup is not the same as an empty result. Caching a failure
   // would leave this symbol unprotected for the life of the EA, so retry.
   if (!base_ok && !profit_ok)
   {
      Print("[NewsFilter] WARNING: currency lookup failed for ", symbol, ", will retry");
      return "";
   }

   string result = "";
   if (NFA_ListContains(NFA_Currencies, base))
      result = base;
   if (profit != base && NFA_ListContains(NFA_Currencies, profit))
      result = (result == "" ? profit : result + "," + profit);

   string mapped = NFA_SymbolOverride(symbol);
   if (mapped != "" && !NFA_ListContains(result, mapped))
      result = (result == "" ? mapped : result + "," + mapped);

   if (nfaSymbolCount < NFA_MAX_CACHED_SYMBOLS)
   {
      nfaSymbolNames[nfaSymbolCount] = symbol;
      nfaSymbolCcys[nfaSymbolCount]  = result;
      nfaSymbolCount++;
   }

   Print("[NewsFilter] watching ", symbol, " -> ",
         (result == "" ? "NONE (no watched currency derived)" : result));
   return result;
}

//+------------------------------------------------------------------+
//| Window test                                                       |
//+------------------------------------------------------------------+

// ON TIME: TimeCurrent() and MqlCalendarValue.time are both SERVER time, so
// this comparison is internally consistent whatever your broker's offset.
// Your terminal's Experts-tab log timestamps are LOCAL time, a different
// clock. Convert before concluding a window fired at the wrong moment.
//
// Replay events are kept sorted by timestamp. Search only the relevant time
// slice instead of scanning the entire multi-year CSV on every tick. A full
// five-year M1/tick test can otherwise spend most of its time doing repeated
// string comparisons against events that are nowhere near the current bar.
int NFA_FirstEventAtOrAfter(const datetime target)
{
   int low = 0;
   int high = ArraySize(nfaEvents);
   while (low < high)
   {
      int middle = low + (high - low) / 2;
      if (nfaEvents[middle].time < target)
         low = middle + 1;
      else
         high = middle;
   }
   return low;
}

bool NFA_WindowActive(const string symbol, const int pre_seconds,
                      const int post_seconds, string &event_desc)
{
   string currencies = NFA_SymbolCurrencies(symbol);
   if (currencies == "")
      return false;

   datetime now = TimeCurrent();
   datetime from = now - (datetime)MathMax(0, pre_seconds);
   datetime to = (post_seconds < 0 ? now : now + (datetime)post_seconds);
   int first = NFA_FirstEventAtOrAfter(from);

   for (int i = first; i < ArraySize(nfaEvents); i++)
   {
      datetime event_time = nfaEvents[i].time;
      if (event_time > to)
         break;

      // A negative post_seconds is the flatten convention: [T - lead, T),
      // so an event exactly at the current timestamp is already too late.
      if (post_seconds < 0 && event_time <= now)
         continue;
      if (!NFA_ListContains(currencies, nfaEvents[i].currency))
         continue;

      event_desc = nfaEvents[i].currency + " " + nfaEvents[i].name + " @ "
                 + TimeToString(event_time, TIME_DATE|TIME_MINUTES);
      return true;
   }
   return false;
}

bool NFA_FlattenActive(const string symbol, string &event_desc)
{
   if (!NFA_UseNewsFilter || !NFA_FlattenPositions || nfaStale)
      return false;

   int lead = (int)MathMin(NFA_FlattenLeadMinutes, NFA_BlockMinutesBefore);
   return NFA_WindowActive(symbol, lead * 60, -1, event_desc);
}

bool NFA_CancelActive(const string symbol, string &event_desc)
{
   if (!NFA_UseNewsFilter || !NFA_CancelPendings || nfaStale)
      return false;

   return NFA_WindowActive(symbol, NFA_BlockMinutesBefore * 60,
                           NFA_BlockMinutesAfter * 60, event_desc);
}

//+------------------------------------------------------------------+
//| Public API                                                        |
//+------------------------------------------------------------------+

// Call once from OnInit(). A strict replay failure is returned to the EA so
// the tester cannot silently run with missing or malformed calendar data.
bool NFA_Init()
{
   nfaSymbolCount   = 0;
   nfaStale         = true;
   nfaReplayLoaded  = false;
   nfaReplayWarned  = false;
   nfaResolvedSource = NFA_CALENDAR_LIVE;
   nfaNextRefresh   = 0;
   nfaLastWarnTime  = 0;
   nfaLastBlockLog  = 0;
   nfaLastCloseFail = 0;
   nfaCoverageFrom  = 0;
   nfaCoverageTo    = 0;
   ArrayResize(nfaEvents, 0);

   if (!NFA_UseNewsFilter)
      return true;

   if (NFA_BlockMinutesBefore < 0 || NFA_BlockMinutesAfter < 0 ||
       NFA_FlattenLeadMinutes < 0)
   {
      Print("[NewsFilter] invalid negative window input");
      return false;
   }

   nfaResolvedSource = NFA_ResolveCalendarSource();

   if (NFA_UsingCsvReplay())
   {
      if (!NFA_LoadReplayCsv())
         return false;
   }
   else
   {
      NFA_Refresh();
   }

   Print("[NewsFilter] enabled: source=",
         NFA_CalendarSourceLabel(nfaResolvedSource),
         " (input=", NFA_CalendarSourceLabel(NFA_CalendarSource), ")",
         ", block -", NFA_BlockMinutesBefore, "m/+", NFA_BlockMinutesAfter,
         "m, flatten=", (NFA_FlattenPositions ? "on" : "off"),
         " (lead ", NFA_FlattenLeadMinutes, "m), cancelPendings=",
         (NFA_CancelPendings ? "on" : "off"),
         ", onOutage=", (NFA_FailClosed ? "BLOCK" : "trade"));

   if (NFA_FlattenPositions && NFA_FlattenLeadMinutes > NFA_BlockMinutesBefore)
      Print("[NewsFilter] WARNING: FlattenLeadMinutes (", NFA_FlattenLeadMinutes,
            ") exceeds BlockMinutesBefore (", NFA_BlockMinutesBefore,
            ") - clamped to the block window to avoid a close/re-enter loop");
   return true;
}

// The entry gate. Call this at EVERY point your EA sends an entry order.
// One missed call site leaves that path unprotected, and it will not be
// obvious from the logs that it happened.
bool NFA_EntryAllowed(const string symbol)
{
   if (!NFA_UseNewsFilter)
      return true;

   NFA_Refresh();

   if (!NFA_ReplayTimeCovered())
      return !NFA_CsvStrict && !NFA_FailClosed;

   if (nfaStale)
   {
      NFA_Warn("EntryAllowed");
      return !NFA_FailClosed;
   }

   string event_desc = "";
   if (!NFA_WindowActive(symbol, NFA_BlockMinutesBefore * 60,
                         NFA_BlockMinutesAfter * 60, event_desc))
      return true;

   if (NFA_LogBlocks && TimeCurrent() - nfaLastBlockLog >= NFA_LOG_THROTTLE)
   {
      nfaLastBlockLog = TimeCurrent();
      Print("[NewsFilter] entry blocked ", symbol, ": ", event_desc);
   }
   return false;
}

// Close one position at market. Failures are not retried here: NFA_Manage
// re-runs every tick while the window is open, and that is the retry.
bool NFA_ClosePosition(const ulong ticket, const string event_desc)
{
   if (!PositionSelectByTicket(ticket))
      return true;   // already gone

   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.position     = ticket;
   request.symbol       = symbol;
   request.magic        = (ulong)PositionGetInteger(POSITION_MAGIC);
   request.volume       = PositionGetDouble(POSITION_VOLUME);
   request.type         = (ptype == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   request.price        = (request.type == ORDER_TYPE_SELL
                             ? SymbolInfoDouble(symbol, SYMBOL_BID)
                             : SymbolInfoDouble(symbol, SYMBOL_ASK));
   request.deviation    = (ulong)MathMax(0, NFA_SlippagePoints);
   request.type_filling = NFA_FillingMode(symbol);
   request.comment      = "news_flatten";

   ResetLastError();
   if (!OrderSend(request, result) || !NFA_RetcodeOK(result.retcode))
   {
      // Throttled: the sweep retries every tick, so an unthrottled Print
      // would flood the journal for the whole window on a persistent error.
      if (TimeCurrent() - nfaLastCloseFail >= NFA_LOG_THROTTLE)
      {
         nfaLastCloseFail = TimeCurrent();
         Print("[NewsFilter] flatten close FAILED ticket=", ticket, " ", symbol,
               " retcode=", result.retcode, " (retrying next tick): ", event_desc);
      }
      return false;
   }

   Print("[NewsFilter] flattened ticket=", ticket, " ", symbol, ": ", event_desc);
   return true;
}

// The action layer. Call this every tick from OnTick(), passing YOUR EA's
// magic number. Only positions and orders carrying that magic are touched,
// so another EA's trades and your manual trades are always safe.
//
// Pass 0 to act on every position in the account. Do that only if this EA
// is genuinely the only thing trading it.
void NFA_Manage(const ulong magic)
{
   if (!NFA_UseNewsFilter)
      return;

   NFA_Refresh();

   // Never act on positions with a stale cache. Blocking an entry on bad
   // data costs an opportunity; closing a position on bad data costs money.
   if (nfaStale)
      return;

   if (!NFA_ReplayTimeCovered())
      return;

   if (NFA_FlattenPositions)
   {
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if (ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if (magic != 0 && (ulong)PositionGetInteger(POSITION_MAGIC) != magic)
            continue;

         string symbol = PositionGetString(POSITION_SYMBOL);
         string event_desc = "";
         if (!NFA_FlattenActive(symbol, event_desc))
            continue;

         NFA_ClosePosition(ticket, event_desc);
      }
   }

   if (NFA_CancelPendings)
   {
      for (int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if (ticket == 0 || !OrderSelect(ticket))
            continue;
         if (magic != 0 && (ulong)OrderGetInteger(ORDER_MAGIC) != magic)
            continue;

         ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_SELL)
            continue;   // pending orders only

         string symbol = OrderGetString(ORDER_SYMBOL);
         string event_desc = "";
         if (!NFA_CancelActive(symbol, event_desc))
            continue;

         MqlTradeRequest request;
         MqlTradeResult  result;
         ZeroMemory(request);
         ZeroMemory(result);
         request.action = TRADE_ACTION_REMOVE;
         request.order  = ticket;

         ResetLastError();
         if (!OrderSend(request, result) || !NFA_RetcodeOK(result.retcode))
            Print("[NewsFilter] failed to cancel pending ", ticket, " ", symbol,
                  " retcode=", result.retcode, " (retrying next tick): ", event_desc);
         else
            Print("[NewsFilter] cancelled pending ", ticket, " ", symbol, ": ", event_desc);
      }
   }
}

// Read-only helpers, handy for your own status printouts.
bool NFA_IsStale()    { return nfaStale; }
int  NFA_EventCount() { return ArraySize(nfaEvents); }

#endif
