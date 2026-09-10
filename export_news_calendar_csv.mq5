//+------------------------------------------------------------------+
//| export_news_calendar_csv.mq5                                     |
//| Package: util/news-filter/                                       |
//| Export MT5 economic-calendar values for deterministic tester use. |
//| Cache flow based on MQL5 CodeBase 52977 (CalendarCache).          |
//+------------------------------------------------------------------+
#property copyright "Project local utility"
#property link      "https://www.mql5.com"
#property version   "2.11"
#property strict
#property script_show_inputs
#property description "Writes news_calendar_replay.csv to MQL5\\Files; copy into this package folder too."

#include "MQL5Book/AutoPtr.mqh"
#include "MQL5Book/CalendarCache.mqh"

#define EXPORT_SCHEMA_VERSION 4
#define EXPORTER_VERSION       "2.11"
#define EXPORT_SECONDS_PER_DAY (24 * 60 * 60)
#define EXPORT_META_CURRENCY  "__META__"
#define EXPORT_TIME_BASIS_RAW "mt5_datetime"
#define EXPORT_TIME_BASIS_NYCLOSE "mt5_nyclose"
#define EXPORT_MAX_HISTORY_WINDOW_DAYS 30

enum ENUM_EXPORT_GMT_OFFSET_MODE
{
   EXPORT_GMT_FIXED_PLUS3 = 0,      // MT5 clock - 3h (raw calendar dump)
   EXPORT_GMT_PEPPERSTONE_US_DST = 1 // -3h in US DST, -2h in US standard
};

// Defaults reproduce the five-year USDJPY tester interval used by the project.
// These datetimes are interpreted in the connected terminal's trade-server
// time coordinate, not local PC time or UTC.
input datetime InpFrom             = D'2021.06.30 00:00'; // First calendar time to export
input datetime InpTo               = D'2026.07.01 23:59'; // Last calendar time to export
input string   InpOutputFile       = "news_calendar_replay.csv"; // MQL5\Files output
input string   InpSourceLabel      = "MT5_calendar_scheduled_events_2021_2026_all_currencies"; // Audit label stored in every row
input string   InpCurrencies       = ""; // Comma-separated API currency filters; blank means all currencies
input string   InpCachePrefix      = "news_calendar_cache_v2"; // Prefix for reusable .cal chunks in MQL5\Files
// CodeBase 52977 defaults to a short date scope. Use the same idea here:
// successful ranges are stored as .cal files and reused on later runs.
input int      InpEventChunkDays   = 7; // Per-query history window
input int      InpMaxSplitDepth    = 8; // Maximum bounded split depth for 5400/5401
input bool     InpSkipTimedOutEvents = false; // Opt in to an incomplete export when an event times out
input bool     InpStrictMetadata   = true; // Fail if calendar catalogue metadata is incomplete
// Fusion/Pepperstone charts are NY-close (GMT+3 in US DST, GMT+2 in US standard).
// Raw calendar times behave like fixed GMT+3; enable this so event_time_mt5 matches chart spikes.
input bool     InpAlignMt5ToNycloseServer = true; // Subtract 1h outside US DST (year-varying US rules)
input ENUM_EXPORT_GMT_OFFSET_MODE InpGmtOffsetMode = EXPORT_GMT_PEPPERSTONE_US_DST; // GMT column rule (nyclose align uses US DST offsets)

struct CalendarEventDefinition
{
   ulong  event_id;
   int    importance;
   string country_code;
   string currency;
   string name;
};

struct CalendarQuery
{
   string country_code;
   string currency;
};

struct ExportCalendarEvent
{
   ulong    event_id;
   datetime time;
   int      importance;
   string   currency;
   string   name;
};

CalendarEventDefinition g_event_definitions[];
CalendarQuery           g_queries[];
ExportCalendarEvent      g_events[];
string                   g_currencies[];
ulong                    g_skipped_timeout_event_ids[];

bool RecordSkippedTimeoutEvent(const ulong event_id)
{
   for (int i = 0; i < ArraySize(g_skipped_timeout_event_ids); i++)
   {
      if (g_skipped_timeout_event_ids[i] == event_id)
         return false;
   }

   int count = ArraySize(g_skipped_timeout_event_ids);
   ArrayResize(g_skipped_timeout_event_ids, count + 1);
   g_skipped_timeout_event_ids[count] = event_id;
   return true;
}

bool WasSkippedTimeoutEvent(const ulong event_id)
{
   for (int i = 0; i < ArraySize(g_skipped_timeout_event_ids); i++)
   {
      if (g_skipped_timeout_event_ids[i] == event_id)
         return true;
   }
   return false;
}

bool CurrencyAlreadyListed(const string currency)
{
   for (int i = 0; i < ArraySize(g_currencies); i++)
   {
      if (g_currencies[i] == currency)
         return true;
   }
   return false;
}

bool BuildCurrencyList(string &reason)
{
   ArrayResize(g_currencies, 0);

   string raw = InpCurrencies;
   StringTrimLeft(raw);
   StringTrimRight(raw);
   if (raw == "")
      return true;

   string parts[];
   int count = StringSplit(raw, StringGetCharacter(",", 0), parts);
   if (count <= 0)
   {
      reason = "InpCurrencies must be blank or a comma-separated list";
      return false;
   }

   for (int i = 0; i < count; i++)
   {
      string currency = parts[i];
      StringTrimLeft(currency);
      StringTrimRight(currency);
      StringToUpper(currency);

      if (currency == "")
         continue;
      if (StringLen(currency) != 3)
      {
         reason = StringFormat("invalid calendar currency '%s'", currency);
         return false;
      }
      if (CurrencyAlreadyListed(currency))
         continue;

      int next = ArraySize(g_currencies);
      ArrayResize(g_currencies, next + 1);
      g_currencies[next] = currency;
   }

   if (StringLen(raw) > 0 && ArraySize(g_currencies) == 0)
   {
      reason = "InpCurrencies did not contain a currency code";
      return false;
   }
   return true;
}

bool AppendQuery(const string country_code,
                 const string currency,
                 string &reason)
{
   if (country_code == "" && currency == "")
   {
      reason = "calendar query has neither a country nor currency filter";
      return false;
   }

   for (int i = 0; i < ArraySize(g_queries); i++)
   {
      if (g_queries[i].country_code == country_code &&
          g_queries[i].currency == currency)
         return true;
   }

   CalendarQuery query;
   query.country_code = country_code;
   query.currency = currency;
   int count = ArraySize(g_queries);
   ArrayResize(g_queries, count + 1);
   g_queries[count] = query;
   return true;
}

bool AppendEventDefinition(const MqlCalendarEvent &definition,
                           const string country_code,
                           const string currency,
                           int &unresolved,
                           string &reason)
{
   if (definition.id == 0 || currency == "")
   {
      unresolved++;
      if (InpStrictMetadata)
      {
         reason = StringFormat("incomplete calendar definition event_id=%I64u currency=%s name='%s'",
                               definition.id, currency, definition.name);
         return false;
      }
      return true;
   }

   string event_name = definition.name;
   if (event_name == "")
      event_name = definition.event_code;
   if (event_name == "")
      event_name = StringFormat("event_%I64u", definition.id);

   for (int i = 0; i < ArraySize(g_event_definitions); i++)
   {
      if (g_event_definitions[i].event_id != definition.id)
         continue;

      if (g_event_definitions[i].importance != (int)definition.importance ||
          (g_event_definitions[i].country_code != "" && country_code != "" &&
           g_event_definitions[i].country_code != country_code) ||
          g_event_definitions[i].currency != currency ||
          g_event_definitions[i].name != event_name)
      {
         reason = StringFormat("conflicting calendar definition event_id=%I64u",
                               definition.id);
         return false;
      }
      if (g_event_definitions[i].country_code == "" && country_code != "")
         g_event_definitions[i].country_code = country_code;
      return true;
   }

   CalendarEventDefinition candidate;
   candidate.event_id = definition.id;
   candidate.importance = (int)definition.importance;
   candidate.country_code = country_code;
   candidate.currency = currency;
   candidate.name = event_name;

   int count = ArraySize(g_event_definitions);
   ArrayResize(g_event_definitions, count + 1);
   g_event_definitions[count] = candidate;
   return true;
}

bool AppendDefinitionsForCurrency(const string currency,
                                  int &unresolved,
                                  string &reason)
{
   MqlCalendarEvent definitions[];
   ResetLastError();
   int count = CalendarEventByCurrency(currency, definitions);
   int error = GetLastError();
   if (count < 0 || error == 5400 || error == 5401)
   {
      reason = StringFormat("CalendarEventByCurrency failed currency=%s error=%d",
                            currency, error);
      return false;
   }

   for (int i = 0; i < count; i++)
   {
      if (!AppendEventDefinition(definitions[i], "", currency,
                                 unresolved, reason))
         return false;
   }
   return true;
}

bool AppendDefinitionsForCountry(const MqlCalendarCountry &country,
                                 int &unresolved,
                                 string &reason)
{
   if (country.code == "" || country.currency == "")
   {
      unresolved++;
      if (InpStrictMetadata)
      {
         reason = StringFormat("incomplete calendar country code='%s' currency='%s'",
                               country.code, country.currency);
         return false;
      }
      return true;
   }

   MqlCalendarEvent definitions[];
   ResetLastError();
   int count = CalendarEventByCountry(country.code, definitions);
   int error = GetLastError();
   if (count < 0 || error == 5400 || error == 5401)
   {
      reason = StringFormat("CalendarEventByCountry failed country=%s currency=%s error=%d",
                            country.code, country.currency, error);
      return false;
   }

   for (int i = 0; i < count; i++)
   {
      if (!AppendEventDefinition(definitions[i], country.code,
                                 country.currency,
                                 unresolved, reason))
         return false;
   }
   return true;
}

bool BuildCalendarCatalogue(int &unresolved, string &reason)
{
   ArrayResize(g_event_definitions, 0);
   ArrayResize(g_queries, 0);
   unresolved = 0;

   // Explicit currencies use the same currency context supported by the
   // CodeBase CalendarCache. Blank input keeps the complete country catalogue.
   if (ArraySize(g_currencies) > 0)
   {
      for (int i = 0; i < ArraySize(g_currencies); i++)
      {
         if (!AppendDefinitionsForCurrency(g_currencies[i], unresolved, reason))
            return false;
         if (!AppendQuery("", g_currencies[i], reason))
            return false;
      }
   }
   else
   {
      MqlCalendarCountry countries[];
      ResetLastError();
      int country_count = CalendarCountries(countries);
      int error = GetLastError();
      if (country_count < 0 || error == 5400 || error == 5401)
      {
         reason = StringFormat("CalendarCountries failed error=%d", error);
         return false;
      }
      if (country_count == 0)
      {
         reason = "CalendarCountries returned no countries";
         return false;
      }

      for (int i = 0; i < country_count; i++)
      {
         if (!AppendDefinitionsForCountry(countries[i], unresolved, reason))
            return false;

         // Worldwide/ALL-style catalogue rows are not real currency filters.
         // Keep those as country queries so they are not lost from an
         // all-currency export; normal countries use currency contexts.
         if (countries[i].currency != "" && countries[i].currency != "ALL")
         {
            if (!AppendQuery("", countries[i].currency, reason))
               return false;
         }
         else if (!AppendQuery(countries[i].code, "", reason))
         {
            return false;
         }
      }
   }

   if (ArraySize(g_event_definitions) == 0)
   {
      reason = "calendar catalogue returned no usable event definitions";
      return false;
   }
   if (ArraySize(g_queries) == 0)
   {
      reason = "calendar catalogue returned no usable history queries";
      return false;
   }
   return true;
}

int FindEventDefinition(const ulong event_id)
{
   for (int i = 0; i < ArraySize(g_event_definitions); i++)
   {
      if (g_event_definitions[i].event_id == event_id)
         return i;
   }
   return -1;
}

bool AppendEvent(const ExportCalendarEvent &candidate, string &reason)
{
   for (int i = 0; i < ArraySize(g_events); i++)
   {
      if (g_events[i].event_id != candidate.event_id ||
          g_events[i].time != candidate.time)
         continue;

      if (g_events[i].importance != candidate.importance ||
          g_events[i].currency != candidate.currency ||
          g_events[i].name != candidate.name)
      {
         reason = StringFormat("conflicting duplicate event_id=%I64u time=%I64d",
                               candidate.event_id, (long)candidate.time);
         return false;
      }
      return true;
   }

   int count = ArraySize(g_events);
   int insert_at = count;
   while (insert_at > 0 && g_events[insert_at - 1].time > candidate.time)
      insert_at--;

   ArrayResize(g_events, count + 1);
   for (int i = count; i > insert_at; i--)
      g_events[i] = g_events[i - 1];
   g_events[insert_at] = candidate;
   return true;
}

string ExportTimeBasis()
{
   return InpAlignMt5ToNycloseServer ? EXPORT_TIME_BASIS_NYCLOSE : EXPORT_TIME_BASIS_RAW;
}

string GmtOffsetModeLabel()
{
   if (InpAlignMt5ToNycloseServer)
      return "nyclose_us_dst";
   if (InpGmtOffsetMode == EXPORT_GMT_PEPPERSTONE_US_DST)
      return "pepperstone_us_dst";
   return "fixed_plus3";
}

datetime NthWeekdayOfMonth(const int year, const int month, const int weekday,
                           const int n)
{
   // weekday: 0=Sunday .. 6=Saturday (MqlDateTime.day_of_week)
   MqlDateTime parts;
   ZeroMemory(parts);
   parts.year = year;
   parts.mon = month;
   parts.day = 1;
   parts.hour = 12;
   datetime cursor = StructToTime(parts);
   TimeToStruct(cursor, parts);

   int offset = (weekday - parts.day_of_week + 7) % 7;
   parts.day = 1 + offset + (n - 1) * 7;
   parts.hour = 2;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts);
}

bool IsUsDaylightSavingDate(const datetime value)
{
   // US DST since 2007: 2nd Sunday in March 02:00 -> 1st Sunday in November 02:00.
   // Dates move every year; export coverage starts in 2010 so pre-2007 rules are unused.
   MqlDateTime parts;
   TimeToStruct(value, parts);
   datetime dst_start = NthWeekdayOfMonth(parts.year, 3, 0, 2);
   datetime dst_end = NthWeekdayOfMonth(parts.year, 11, 0, 1);
   return (value >= dst_start && value < dst_end);
}

datetime AlignEventTimeToNycloseServer(const datetime calendar_time)
{
   if (!InpAlignMt5ToNycloseServer || calendar_time <= 0)
      return calendar_time;

   // Raw calendar values on this terminal behave like fixed GMT+3 wall clocks.
   // NY-close brokers (Fusion/Pepperstone) use GMT+3 only during US DST and
   // GMT+2 during US standard time, so chart spikes sit 1h earlier in winter.
   if (IsUsDaylightSavingDate(calendar_time))
      return calendar_time;
   return calendar_time - 3600;
}

int ServerToGmtOffsetHours(const datetime mt5_time)
{
   // After nyclose align, MT5 column is server time: use US DST +3/+2.
   if (InpAlignMt5ToNycloseServer || InpGmtOffsetMode == EXPORT_GMT_PEPPERSTONE_US_DST)
      return IsUsDaylightSavingDate(mt5_time) ? 3 : 2;
   return 3;
}

datetime EventTimeToGmt(const datetime mt5_time)
{
   if (mt5_time <= 0)
      return 0;
   return mt5_time - (datetime)ServerToGmtOffsetHours(mt5_time) * 3600;
}

string FormatEventTimeGmt(const datetime value)
{
   // Human-readable GMT / UTC+0 clock. Do not use live TimeGMTOffset() —
   // historical rows need the configured server→GMT rule, not "now".
   if (value <= 0)
      return "";

   MqlDateTime parts;
   TimeToStruct(value, parts);
   return StringFormat("%04d-%02d-%02d %02d:%02d:%02dZ",
                       parts.year, parts.mon, parts.day,
                       parts.hour, parts.min, parts.sec);
}

void WriteHeader(const int handle)
{
   FileWrite(handle,
             "schema_version", "event_id", "event_time_mt5", "currency",
             "importance", "event_name", "coverage_from_mt5",
             "coverage_to_mt5", "time_basis", "source", "event_time_gmt");
}

void WriteMetadata(const int handle)
{
   // Meta row stores the GMT / align mode in event_time_gmt for audit.
   FileWrite(handle,
             EXPORT_SCHEMA_VERSION,
             0,
             0,
             EXPORT_META_CURRENCY,
             -1,
             "coverage",
             (long)InpFrom,
             (long)InpTo,
             ExportTimeBasis(),
             InpSourceLabel,
             GmtOffsetModeLabel());
}

void WriteEvent(const int handle, const ExportCalendarEvent &event)
{
   const datetime aligned = AlignEventTimeToNycloseServer(event.time);
   FileWrite(handle,
             EXPORT_SCHEMA_VERSION,
             event.event_id,
             (long)aligned,
             event.currency,
             event.importance,
             event.name,
             (long)InpFrom,
             (long)InpTo,
             ExportTimeBasis(),
             InpSourceLabel,
             FormatEventTimeGmt(EventTimeToGmt(aligned)));
}

string CalendarQueryLabel(const CalendarQuery &query)
{
   if (query.country_code != "")
      return "country=" + query.country_code;
   return "currency=" + query.currency;
}

bool EventDefinitionMatchesQuery(const CalendarEventDefinition &definition,
                                 const CalendarQuery &query)
{
   if (query.country_code != "")
      return definition.country_code == query.country_code;
   return query.currency != "" && definition.currency == query.currency;
}

bool AppendCalendarValues(const CalendarQuery &query,
                          const MqlCalendarValue &values[],
                          const int count,
                          int &values_seen,
                          int &unresolved,
                          string &reason)
{
   for (int i = 0; i < count; i++)
   {
      int definition_index = FindEventDefinition(values[i].event_id);
      if (definition_index < 0)
      {
         unresolved++;
         if (InpStrictMetadata)
         {
            reason = StringFormat("cannot map calendar value event_id=%I64u query=%s",
                                  values[i].event_id,
                                  CalendarQueryLabel(query));
            return false;
         }
         continue;
      }

      if (!EventDefinitionMatchesQuery(g_event_definitions[definition_index],
                                       query))
         continue;

      ExportCalendarEvent candidate;
      candidate.event_id = values[i].event_id;
      candidate.time = values[i].time;
      candidate.importance = g_event_definitions[definition_index].importance;
      candidate.currency = g_event_definitions[definition_index].currency;
      // MT5 FILE_CSV readers do not reliably honor quoted commas in names.
      string event_name = g_event_definitions[definition_index].name;
      StringReplace(event_name, ",", " -");
      while (StringFind(event_name, "  ") >= 0)
         StringReplace(event_name, "  ", " ");
      StringTrimLeft(event_name);
      StringTrimRight(event_name);
      candidate.name = event_name;
      if (!AppendEvent(candidate, reason))
         return false;
      values_seen++;
   }
   return true;
}

bool CollectCalendarEventRange(const CalendarQuery &query,
                               const CalendarEventDefinition &definition,
                               const datetime from,
                               const datetime to,
                               const int depth,
                               int &values_seen,
                               int &unresolved,
                               int &error,
                               string &reason)
{
   if (IsStopped())
   {
      reason = "export stopped while querying calendar events";
      error = 4108;
      return false;
   }

   if (WasSkippedTimeoutEvent(definition.event_id))
   {
      reason = "";
      return true;
   }

   MqlCalendarValue values[];
   ResetLastError();
   int count = CalendarValueHistoryByEvent(definition.event_id,
                                           values, from, to);
   error = GetLastError();
   if (count >= 0)
      return AppendCalendarValues(query, values, count, values_seen,
                                  unresolved, reason);

   if (error == 0)
      error = 4001;

   if (error == 5401 && InpSkipTimedOutEvents)
   {
      RecordSkippedTimeoutEvent(definition.event_id);
      Print("[NewsExport] WARNING: skipping timed-out event event_id=",
            definition.event_id, " name='", definition.name,
            "' for ", TimeToString(from, TIME_DATE|TIME_SECONDS), "..",
            TimeToString(to, TIME_DATE|TIME_SECONDS), " query=",
            CalendarQueryLabel(query), ", skipped_events=",
            ArraySize(g_skipped_timeout_event_ids));
      reason = "";
      return true;
   }

   if ((error == 5400 || error == 5401) &&
       from < to && depth < InpMaxSplitDepth)
   {
      datetime midpoint = from + (to - from) / 2;
      if (midpoint > from && midpoint < to)
      {
         Print("[NewsExport] event history timeout error=", error,
               " event_id=", definition.event_id,
               " for ", TimeToString(from, TIME_DATE|TIME_SECONDS), "..",
               TimeToString(to, TIME_DATE|TIME_SECONDS),
               "; splitting at ",
               TimeToString(midpoint, TIME_DATE|TIME_SECONDS));
         return CollectCalendarEventRange(query, definition, from, midpoint,
                                          depth + 1, values_seen, unresolved,
                                          error, reason) &&
                CollectCalendarEventRange(query, definition, midpoint, to,
                                          depth + 1, values_seen, unresolved,
                                          error, reason);
      }
   }

   reason = StringFormat("CalendarValueHistoryByEvent failed event_id=%I64u name='%s' for %s..%s query=%s error=%d",
                         definition.event_id,
                         definition.name,
                         TimeToString(from, TIME_DATE|TIME_SECONDS),
                         TimeToString(to, TIME_DATE|TIME_SECONDS),
                         CalendarQueryLabel(query),
                         error);
   return false;
}

bool CollectCalendarValuesByEvent(const CalendarQuery &query,
                                  const datetime from,
                                  const datetime to,
                                  int &values_seen,
                                  int &unresolved,
                                  string &reason)
{
   int matched = 0;
   int available = 0;
   for (int i = 0; i < ArraySize(g_event_definitions); i++)
   {
      if (EventDefinitionMatchesQuery(g_event_definitions[i], query))
         available++;
   }

   for (int i = 0; i < ArraySize(g_event_definitions); i++)
   {
      if (!EventDefinitionMatchesQuery(g_event_definitions[i], query))
         continue;

      matched++;
      if (matched == 1 || matched % 25 == 0)
      {
         Print("[NewsExport] event fallback progress=", matched, "/",
               available, ", query=", CalendarQueryLabel(query));
      }
      int error = 0;
      if (!CollectCalendarEventRange(query, g_event_definitions[i],
                                     from, to, 0, values_seen, unresolved,
                                     error, reason))
         return false;
   }

   if (matched == 0)
   {
      reason = "event-by-event fallback found no definitions for query=" +
               CalendarQueryLabel(query);
      return false;
   }
   return true;
}

string CalendarTimeToken(const datetime value)
{
   string token = TimeToString(value, TIME_DATE|TIME_SECONDS);
   StringReplace(token, ".", "");
   StringReplace(token, ":", "");
   StringReplace(token, " ", "_");
   return token;
}

string CalendarCacheContext(const CalendarQuery &query)
{
   if (query.currency != "")
      return query.currency;
   return query.country_code;
}

string CalendarCacheFileName(const CalendarQuery &query,
                             const datetime from,
                             const datetime to)
{
   string query_token = query.currency != ""
                         ? "currency_" + query.currency
                         : "country_" + query.country_code;
   return InpCachePrefix + "_" + query_token + "_" +
          CalendarTimeToken(from) + "_" + CalendarTimeToken(to) + ".cal";
}

bool ReadOrBuildCalendarCache(const CalendarQuery &query,
                              const datetime from,
                              const datetime to,
                              MqlCalendarValue &values[],
                              int &count,
                              int &error,
                              string &reason)
{
   ArrayFree(values);
   count = -1;
   error = 0;

   const string context = CalendarCacheContext(query);
   const string cache_file = CalendarCacheFileName(query, from, to);

   // A .cal file is the durable part of the CodeBase 52977 approach. It
   // contains values plus the event/country tables needed to query them.
   if (InpCachePrefix != "" && FileIsExist(cache_file))
   {
      AutoPtr<CalendarCache> cache;
      cache = new CalendarCache(cache_file, (datetime)1, (datetime)0, false);
      if (cache[].isLoaded() &&
          cache[].getContext() == context &&
          cache[].getFrom() == from &&
          cache[].getTo() == to)
      {
         ResetLastError();
         count = cache[].calendarValueHistory(values, from, to,
                                              query.country_code,
                                              query.currency);
         error = GetLastError();
         if (count >= 0)
         {
            Print("[NewsExport] cache hit file=", cache_file,
                  ", query=", CalendarQueryLabel(query),
                  ", values=", count);
            return true;
         }

         Print("[NewsExport] cache read failed file=", cache_file,
               ", error=", error, "; rebuilding online");
      }
      else
      {
         Print("[NewsExport] cache metadata mismatch file=", cache_file,
               "; rebuilding online");
      }
   }

   // Cache miss: make one short, explicitly scoped online request. This is
   // the same CalendarCache constructor used by CodeBase 52977.
   ResetLastError();
   AutoPtr<CalendarCache> cache;
   cache = new CalendarCache(context, from, to, false);
   error = cache[].getError();
   if (error == 0)
      error = GetLastError();
   if (!cache[].isLoaded())
   {
      reason = StringFormat("CalendarCache online build failed for %s..%s query=%s error=%d",
                            TimeToString(from, TIME_DATE|TIME_SECONDS),
                            TimeToString(to, TIME_DATE|TIME_SECONDS),
                            CalendarQueryLabel(query), error);
      return false;
   }

   if (InpCachePrefix != "")
   {
      ResetLastError();
      if (cache[].save(cache_file))
      {
         Print("[NewsExport] cache saved file=", cache_file);
      }
      else
      {
         Print("[NewsExport] cache save failed file=", cache_file,
               ", error=", GetLastError(),
               "; continuing with in-memory values");
      }
   }

   ResetLastError();
   count = cache[].calendarValueHistory(values, from, to,
                                        query.country_code,
                                        query.currency);
   error = GetLastError();
   if (count < 0)
   {
      reason = StringFormat("CalendarCache query failed for %s..%s query=%s error=%d",
                            TimeToString(from, TIME_DATE|TIME_SECONDS),
                            TimeToString(to, TIME_DATE|TIME_SECONDS),
                            CalendarQueryLabel(query), error);
      return false;
   }

   Print("[NewsExport] cache online fill file=", cache_file,
         ", query=", CalendarQueryLabel(query),
         ", values=", count);
   return true;
}

bool CollectCalendarCacheRange(const CalendarQuery &query,
                               const datetime from,
                               const datetime to,
                               const int depth,
                               int &values_seen,
                               int &unresolved,
                               string &reason)
{
   MqlCalendarValue values[];
   int count = -1;
   int error = 0;

   if (!ReadOrBuildCalendarCache(query, from, to, values, count,
                                 error, reason))
   {
      // The aggregate currency/country request can time out even for a small
      // range. Query each matching event separately before giving up; one
      // problematic event must not prevent the rest of the range exporting.
      if (error == 5400 || error == 5401)
      {
         Print("[NewsExport] aggregate history error=", error,
               " for ", CalendarQueryLabel(query), " ",
               TimeToString(from, TIME_DATE|TIME_SECONDS), "..",
               TimeToString(to, TIME_DATE|TIME_SECONDS),
               "; using event-by-event fallback");
         int values_before = values_seen;
         if (CollectCalendarValuesByEvent(query, from, to, values_seen,
                                          unresolved, reason))
         {
            Print("[NewsExport] event-by-event fallback complete query=",
                  CalendarQueryLabel(query), ", values=",
                  values_seen - values_before);
            return true;
         }
      }
      return false;
   }

   return AppendCalendarValues(query, values, count, values_seen,
                               unresolved, reason);
}

bool CollectCalendarHistory(const CalendarQuery &query,
                            int &values_seen,
                            int &unresolved,
                            string &reason)
{
   datetime cursor = InpFrom;
   while (cursor <= InpTo)
   {
      datetime chunk_to = InpTo;
      if (InpEventChunkDays > 0)
      {
         chunk_to = cursor + (datetime)InpEventChunkDays * EXPORT_SECONDS_PER_DAY;
         if (chunk_to > InpTo)
            chunk_to = InpTo;
      }

      if (!CollectCalendarCacheRange(query, cursor, chunk_to, 0,
                                     values_seen, unresolved, reason))
         return false;

      if (chunk_to == InpTo)
         break;

      // CalendarValueHistory treats the right boundary as exclusive. Start
      // the next chunk at that boundary so no calendar second is skipped.
      cursor = chunk_to;
      Sleep(25);
   }
   return true;
}

void PrintFailure(const string reason)
{
   Print("[NewsExport] ", reason,
         "; no output file was changed; successful cache chunks remain under MQL5\\Files\\",
         InpCachePrefix, "_*.cal");
}

void OnStart()
{
   if (InpFrom <= 0 || InpTo <= InpFrom || InpOutputFile == "" ||
       InpSourceLabel == "" || InpEventChunkDays < 1 ||
       InpEventChunkDays > EXPORT_MAX_HISTORY_WINDOW_DAYS ||
       InpMaxSplitDepth < 0 || InpMaxSplitDepth > 12)
   {
      PrintFailure("invalid inputs: from/to/output/source/cache/chunk settings");
      return;
   }

   string reason = "";
   if (!BuildCurrencyList(reason))
   {
      PrintFailure(reason);
      return;
   }

   Print("[NewsExport] version=", EXPORTER_VERSION,
         ", starting coverage=",
         TimeToString(InpFrom, TIME_DATE|TIME_SECONDS), "..",
         TimeToString(InpTo, TIME_DATE|TIME_SECONDS),
         ", currencies=", InpCurrencies == "" ? "ALL" : InpCurrencies,
         ", history_chunk_days=", InpEventChunkDays,
         ", max_split_depth=", InpMaxSplitDepth,
         ", cache_prefix=", InpCachePrefix == "" ? "DISABLED" : InpCachePrefix,
         ", align_nyclose=", InpAlignMt5ToNycloseServer ? "true" : "false",
         ", gmt_offset_mode=", GmtOffsetModeLabel());

   int unresolved = 0;
   if (!BuildCalendarCatalogue(unresolved, reason))
   {
      PrintFailure(reason);
      return;
   }

   Print("[NewsExport] loaded ", ArraySize(g_event_definitions),
         " event definition(s) and ", ArraySize(g_queries),
         " history quer", ArraySize(g_queries) == 1 ? "y" : "ies",
         ", unresolved=", unresolved,
         ", currencies=", InpCurrencies == "" ? "ALL" : InpCurrencies);

   ArrayResize(g_events, 0);
   ArrayResize(g_skipped_timeout_event_ids, 0);
   int values_seen = 0;
   int query_count = ArraySize(g_queries);
   for (int i = 0; i < query_count; i++)
   {
      reason = "";
      if (!CollectCalendarHistory(g_queries[i], values_seen, unresolved,
                                  reason))
      {
         PrintFailure(reason);
         return;
      }

      Print("[NewsExport] query progress=", i + 1, "/", query_count,
            ", values_seen=", values_seen,
            ", unique_events=", ArraySize(g_events));
   }

   ResetLastError();
   int handle = FileOpen(InpOutputFile,
                         FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_REWRITE,
                         ',');
   if (handle == INVALID_HANDLE)
   {
      Print("[NewsExport] cannot open ", InpOutputFile,
            " for writing, error=", GetLastError());
      return;
   }

   WriteHeader(handle);
   WriteMetadata(handle);
   for (int i = 0; i < ArraySize(g_events); i++)
      WriteEvent(handle, g_events[i]);
   FileFlush(handle);
   FileClose(handle);

   Print("[NewsExport] wrote ", ArraySize(g_events),
         " unique event(s), values_seen=", values_seen,
         ", unresolved=", unresolved,
         ", skipped_timeout_events=", ArraySize(g_skipped_timeout_event_ids),
         ", coverage=", TimeToString(InpFrom, TIME_DATE|TIME_SECONDS), "..",
         TimeToString(InpTo, TIME_DATE|TIME_SECONDS),
         ", currencies=", InpCurrencies == "" ? "ALL" : InpCurrencies,
         ", history_chunk_days=", InpEventChunkDays,
         ", cache_prefix=", InpCachePrefix == "" ? "DISABLED" : InpCachePrefix,
         ", file=MQL5\\Files\\", InpOutputFile);
}
//+------------------------------------------------------------------+
