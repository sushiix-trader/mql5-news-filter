//+------------------------------------------------------------------+
//|                                                CalendarCache.mqh |
//|                             Copyright 2022-2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#ifdef LOGGING
 #include <MQL5Book/PRTF.mqh>
 #define LOG PRTF
#else
 #define LOG
#endif
#include "Defines.mqh"
#include "QuickSortStructTRef.mqh"

//+------------------------------------------------------------------+
//| Helper struct with indexed storage of strings                    |
//+------------------------------------------------------------------+
template<typename T>
struct StringRef
{
   static string cache[];
   int index;
   StringRef(): index(-1) { }
   
   void operator=(const string s)
   {
      if(index == -1)
      {
         PUSH(cache, s);
         index = ArraySize(cache) - 1;
      }
      else
      {
         cache[index] = s;
      }
   }
   
   string operator[](int x = 0) const
   {
      if(index != -1)
      {
         return cache[index];
      }
      return NULL;
   }
   
   static bool save(const int handle)
   {
      FileWriteInteger(handle, ArraySize(cache));
      for(int i = 0; i < ArraySize(cache); ++i)
      {
         FileWriteInteger(handle, StringLen(cache[i]));
         FileWriteString(handle, cache[i]);
      }
      return true;
   }

   static bool load(const int handle)
   {
      const int n = FileReadInteger(handle);
      for(int i = 0; i < n; ++i)
      {
         PUSH(cache, FileReadString(handle, FileReadInteger(handle)));
      }
      return true;
   }
};

template<typename T>
static string StringRef::cache[];

//+------------------------------------------------------------------+
//| Main class for calendar cache                                    |
//+------------------------------------------------------------------+
class CalendarCache
{
   string context;
   datetime from, to;
   datetime t;
   ulong eventId;
   MqlCalendarValue values[];
   MqlCalendarEvent events[];
   MqlCalendarCountry countries[];

   // indices of values by event_id, country, currency, time - ArraySort()-ed
   ulong value2event[][2];    // [0] - event_id, [1] - value_id
   ulong value2country[][2];  // [0] - country_id, [1] - value_id
   ulong value2currency[][2]; // [0] - currency ushort[4]<->long, [1] - value_id
   ulong value2time[][2];     // [0] - time, [1] - value_id
   
   // mapping of ids into indices in MqlCalendar-arrays
   int id4country[];
   int id4event[];
   int id4value[];
   
   int collisions;
   int worse;
   int collided;
   
   bool wantSort;
   int tzoffset;
   int version;
   int failure_error;
   
   //+------------------------------------------------------------------+
   //| Identificator hash support                                       |
   //+------------------------------------------------------------------+
   
   static int size2prime(const int size)
   {
      static int primes[] =
      {
        17, 53, 97, 193, 389,
        769, 1543, 3079, 6151,
        12289, 24593, 49157, 98317,
        196613, 393241, 786433, 1572869,
        3145739, 6291469, 12582917, 25165843,
        50331653, 100663319, 201326611, 402653189,
        805306457, 1610612741
      };

      const int pmax = ArraySize(primes);
      for(int p = 0; p < pmax; ++p)
      {
         if(primes[p] >= 2 * size)
         {
            return primes[p];
         }
      }
      return size;
   }
   
   int place(const ulong id, const int index, int &array[])
   {
      const int n = ArraySize(array);
      int p = (int)((MathSwap(id) ^ 0xEFCDAB8967452301) % n); // hash-function
      int attempt = 0;
      while(array[p] != -1)
      {
         if(++attempt > n)
         {
            return -1; // not added
         }
         #ifdef DEBUG_LOG
         Print("Collision ", attempt, ": ", id, "=", index, " / ", array[p]);
         #endif
         // Linear probing guarantees that every slot is eventually checked.
         // The original triangular probe could revisit a subset of slots and
         // reject valid calendar data even when the table still had space.
         p = (p + 1) % n;
      }
      collisions += attempt;
      worse = fmax(worse, attempt);
      if(attempt) collided++;
      array[p] = index;
      return p;
   }
   
   template<typename S>
   int find(const ulong id, const int &array[], const S &structs[])
   {
      const int n = ArraySize(array);
      if(!n) return false;
      int p = (int)((MathSwap(id) ^ 0xEFCDAB8967452301) % n); // hash-function
      int attempt = 0;
      while(array[p] != -1)
      {
         if(structs[array[p]].id == id)
            return array[p];
         if(++attempt >= n)
            return -1; // not found
         p = (p + 1) % n;
      }
      return -1;
   }
   
   //+------------------------------------------------------------------+
   //| Calendar data collecting, hashing and relational binding         |
   //+------------------------------------------------------------------+
   
   bool update()
   {
      string country = NULL, currency = NULL;
      if(StringLen(context) == 3)
      {
         currency = context;
      }
      else if(StringLen(context) == 2)
      {
         country = context;
      }
      
      Print("Reading online calendar base...");
      reset();

      // Calendar API functions return a negative value on failure.  Do not
      // wrap these checks in LOG(): with logging disabled LOG is an empty
      // macro, and !(-1) evaluates to false, incorrectly accepting failure.
      const int value_count = CalendarValueHistory(values, from, to,
         country, currency);
      if(value_count < 0)
         return false;

      const int event_count = currency != NULL ?
         CalendarEventByCurrency(currency, events) :
         CalendarEventByCountry(country, events);
      if(event_count < 0)
         return false;

      const int country_count = CalendarCountries(countries);
      if(country_count < 0)
         return false;

      t = TimeTradeServer();
      return (bool)t;
   }

   bool hash()
   {
      Print("Hashing calendar...");
      
      collisions = 0;
      worse = 0;
      collided = 0;

      const int c = LOG(ArraySize(countries));
      LOG(ArrayResize(id4country, size2prime(c)));
      ArrayInitialize(id4country, -1);
      
      for(int i = 0; i < c; ++i)
      {
         if(place(countries[i].id, i, id4country) == -1)
         {
            failure_error = 4001;
            return false;
         }
      }

      Print("Total collisions: ", collisions, ", worse:", worse,
         ", average: ", (float)collisions / (float)fmax(collided, 1), " in ", collided);
      
      collisions = 0;
      worse = 0;
      collided = 0;

      const int e = LOG(ArraySize(events));
      LOG(ArrayResize(id4event, size2prime(e)));
      ArrayInitialize(id4event, -1);
      
      for(int i = 0; i < e && !IsStopped(); ++i)
      {
         if(place(events[i].id, i, id4event) == -1)
         {
            failure_error = 4001;
            return false;
         }
      }
      
      Print("Total collisions: ", collisions, ", worse:", worse,
         ", average: ", (float)collisions / (float)fmax(collided, 1), " in ", collided);

      collisions = 0;
      worse = 0;
      collided = 0;

      const int v = LOG(ArraySize(values));
      LOG(ArrayResize(id4value, size2prime(v)));
      ArrayInitialize(id4value, -1);
      
      for(int i = 0; i < v && !IsStopped(); ++i)
      {
         if(place(values[i].id, i, id4value) == -1)
         {
            failure_error = 4001;
            return false;
         }
      }
      
      Print("Total collisions: ", collisions, ", worse:", worse,
         ", average: ", (float)collisions / (float)fmax(collided, 1), " in ", collided);
      return true;
   }

   bool bind()
   {
      Print("Binding calendar tables...");
      const int n = ArraySize(values);
      ArrayResize(value2event, n);
      ArrayResize(value2country, n);
      ArrayResize(value2currency, n);
      ArrayResize(value2time, n);
      for(int i = 0; i < n; ++i)
      {
         value2event[i][0] = values[i].event_id;
         value2event[i][1] = values[i].id;
         
         const int e = find(values[i].event_id, id4event, events);
         if(e == -1)
         {
            failure_error = 4001;
            return false;
         }
         
         value2country[i][0] = events[e].country_id;
         value2country[i][1] = values[i].id;
         
         const int c = find(events[e].country_id, id4country, countries);
         if(c == -1)
         {
            failure_error = 4001;
            return false;
         }
         
         value2currency[i][0] = currencyId(countries[c].currency);
         value2currency[i][1] = values[i].id;

         value2time[i][0] = values[i].time;
         value2time[i][1] = values[i].id;
      }
      ArraySort(value2event);
      ArraySort(value2country);
      ArraySort(value2currency);
      ArraySort(value2time); // should it be already in chronologic order?
      return true;
   }

   void reset()
   {
      ArrayFree(values);
      ArrayFree(events);
      ArrayFree(countries);
      ArrayFree(value2country);
      ArrayFree(value2currency);
      ArrayFree(value2event);
      ArrayFree(value2time);
      ArrayFree(id4country);
      ArrayFree(id4event);
      ArrayFree(id4value);
   }

public:
   const static string CALENDAR_CACHE_HEADER;
   
   //+------------------------------------------------------------------+
   //| Public interface                                                 |
   //+------------------------------------------------------------------+

   CalendarCache(const string _context = NULL,
      const datetime _from = 0, const datetime _to = 0, const bool _sort = true):
      context(_context), from(_from), to(_to), t(0), eventId(0),
      wantSort(_sort), failure_error(0)
   {
      tzoffset = (int)(TimeGMT() - TimeTradeServer());
      version = 1;
      if(from > to) // context is a filename 'flag'
      {
         if(!StringLen(_context)) return;
         if(!load(_context))
         {
            load(_context, FILE_COMMON);
         }
      }
      else
      {
         if(!update() || !hash() || !bind())
         {
            if(failure_error == 0)
               failure_error = GetLastError();
            t = 0;
         }
      }
   }
   
   string getContext() const
   {
      return context;
   }
   
   datetime getFrom() const
   {
      return from;
   }

   datetime getTo() const
   {
      return to;
   }
   
   bool isLoaded() const
   {
      return t != 0;
   }

   int getError() const
   {
      return failure_error;
   }
   
   static ulong currencyId(const string s)
   {
      union CRNC4
      {
         ushort word[4];
         ulong ul;
      } v;

      StringToShortArray(s, v.word);
      return v.ul;
   }
   
   template<typename T1,typename T2>
   void static store(T1 &array[], T2 &origin[])
   {
      ArrayResize(array, ArraySize(origin));
      for(int i = 0; i < ArraySize(origin); ++i)
      {
         array[i] = origin[i];
      }
   }

   template<typename T1,typename T2>
   void static restore(T1 &array[], T2 &origin[])
   {
      ArrayResize(array, ArraySize(origin));
      for(int i = 0; i < ArraySize(origin); ++i)
      {
         array[i] = origin[i][];
      }
   }
   
   struct MqlCalendarCountryRef
   {
      ulong id;
      StringRef<MqlCalendarCountry> name;
      StringRef<MqlCalendarCountry> code;
      StringRef<MqlCalendarCountry> currency;
      StringRef<MqlCalendarCountry> currency_symbol;
      StringRef<MqlCalendarCountry> url_name;
      
      void operator=(const MqlCalendarCountry &c)
      {
         id = c.id;
         name = c.name;
         code = c.code;
         currency = c.currency;
         currency_symbol = c.currency_symbol;
         url_name = c.url_name;
      }
      
      MqlCalendarCountry operator[](int x = 0) const
      {
         MqlCalendarCountry r;
         r.id = id;
         r.name = name[];
         r.code = code[];
         r.currency = currency[];
         r.currency_symbol = currency_symbol[];
         r.url_name = url_name[];
         return r;
      }
   };
   
   struct MqlCalendarEventRef
   {
      ulong                           id;
      ENUM_CALENDAR_EVENT_TYPE        type;
      ENUM_CALENDAR_EVENT_SECTOR      sector;
      ENUM_CALENDAR_EVENT_FREQUENCY   frequency;
      ENUM_CALENDAR_EVENT_TIMEMODE    time_mode;
      ulong                           country_id;
      ENUM_CALENDAR_EVENT_UNIT        unit;
      ENUM_CALENDAR_EVENT_IMPORTANCE  importance;
      ENUM_CALENDAR_EVENT_MULTIPLIER  multiplier;
      uint                            digits;
      StringRef<MqlCalendarEvent>     source_url;
      StringRef<MqlCalendarEvent>     event_code;
      StringRef<MqlCalendarEvent>     name;
      
      void operator=(const MqlCalendarEvent &e)
      {
         id = e.id;
         type = e.type;
         sector = e.sector;
         frequency = e.frequency;
         time_mode = e.time_mode;
         country_id = e.country_id;
         unit = e.unit;
         importance = e.importance;
         multiplier = e.multiplier;
         digits = e.digits;
         source_url = e.source_url;
         event_code = e.event_code;
         name = e.name;
      }
      
      MqlCalendarEvent operator[](int x = 0) const
      {
         MqlCalendarEvent r;
         r.id = id;
         r.type = type;
         r.sector = sector;
         r.frequency = frequency;
         r.time_mode = time_mode;
         r.country_id = country_id;
         r.unit = unit;
         r.importance = importance;
         r.multiplier = multiplier;
         r.digits = digits;
         r.source_url = source_url[];
         r.event_code = event_code[];
         r.name = name[];
         return r;
      }
   };
   
   bool save(string filename = NULL, const int flags = 0, const int forceTZoffset = INT_MIN)
   {
      if(!t) return false;
      
      MqlDateTime mdt;
      TimeToStruct(t, mdt);
      if(!StringLen(filename) || filename == "*") filename = "calendar-" +
         StringFormat("%04d-%02d-%02d-%02d-%02d.cal",
         mdt.year, mdt.mon, mdt.day, mdt.hour, mdt.min);
      PrintFormat("Saving calendar %s '%s'", (flags ? "common" : "cache"), filename);
      int handle = LOG(FileOpen(filename, FILE_WRITE | FILE_BIN | flags));
      if(handle == INVALID_HANDLE) return false;
      
      FileWriteString(handle, CALENDAR_CACHE_HEADER);
      FileWriteString(handle, context, 4);
      FileWriteLong(handle, from);
      FileWriteLong(handle, to);
      FileWriteLong(handle, t);
      FileWriteInteger(handle, forceTZoffset == INT_MIN ? (int)(TimeGMT() - TimeTradeServer()) : forceTZoffset); // server time zone offset
      const int n = ArraySize(values);
      FileWriteInteger(handle, n);
      if(n > 0)
      {
         FileWriteArray(handle, values);
         Print("First and last records: ", values[0].time, "-", values[n - 1].time);
      }
      
      MqlCalendarEventRef erefs[];
      store(erefs, events);
      FileWriteInteger(handle, ArraySize(erefs));
      FileWriteArray(handle, erefs);
      StringRef<MqlCalendarEvent>::save(handle);
      
      MqlCalendarCountryRef crefs[];
      store(crefs, countries);
      FileWriteInteger(handle, ArraySize(crefs));
      FileWriteArray(handle, crefs);
      StringRef<MqlCalendarCountry>::save(handle);

      FileClose(handle);
      return true;
   }
   
   bool load(const string filename, const int flags = 0)
   {
      if(!StringLen(filename)) return false;
      PrintFormat("Loading calendar %s '%s'", (flags ? "common" : "cache"), filename);
      t = 0;
      int handle = LOG(FileOpen(filename, FILE_READ | FILE_BIN | flags));
      if(handle == INVALID_HANDLE) return false;
      
      version = 1;
      string header = FileReadString(handle, StringLen(CALENDAR_CACHE_HEADER));
      if(StringReplace(header, "\r\nv.1.0\r\n", "\r\nv.1.1\r\n") == 1) version = 0;
      if(header != CALENDAR_CACHE_HEADER) return false;
      
      reset();
      ResetLastError();
      
      context = FileReadString(handle, 4);
      if(!StringLen(context)) context = NULL;
      from = (datetime)FileReadLong(handle);
      to = (datetime)FileReadLong(handle);
      t = (datetime)FileReadLong(handle);
      Print("Calendar cache interval: ", from, "-", to);
      Print("Calendar cache saved at: ", t);
      if(version > 0)
      {
         tzoffset = FileReadInteger(handle);
         Print("Calendar cache saved with time zone offset: ", tzoffset);
      }
      int n = FileReadInteger(handle);
      if(n > 0)
      {
         FileReadArray(handle, values, 0, n);
         Print("First and last records: ", values[0].time, "-", values[n - 1].time);
      }
      
      MqlCalendarEventRef erefs[];
      n = FileReadInteger(handle);
      FileReadArray(handle, erefs, 0, n);
      StringRef<MqlCalendarEvent>::load(handle);
      restore(events, erefs);
      
      MqlCalendarCountryRef crefs[];
      n = FileReadInteger(handle);
      FileReadArray(handle, crefs, 0, n);
      StringRef<MqlCalendarCountry>::load(handle);
      restore(countries, crefs);

      FileClose(handle);
      
      if(_LastError) Print("Error in load: ", _LastError);
      
      const bool result = hash() && bind();
      if(!result) t = 0;
      return result;
   }
   
   int getTZOffset() const
   {
      return tzoffset;
   }
   
   int getVersion() const
   {
      return version;
   }
   
   #ifdef TZDST_NOW_SCAN // TimeServerDST.mqh is included
   // XAUUSD or EURUSD are preferred symbols
   int adjustTZonHistory(const string symbol, const bool log = false)
   {
      if(MQLInfoInteger(MQL_TESTER)) return 0;
      
      TimeServerGMTOffsetHistory(0, 1, 0.0, symbol); // build cache of TZ/DST changes on history of the symbol's chart
      const int savedOffset = TimeServerGMTOffsetHistory(t, 1, 0.0, symbol);

      const int n = ArraySize(values);
      int c = 0, e = 0;
      int prevLog = 0;
      bool fixstart = false;
      for(int i = 0; i < n; ++i)
      {
         // NB1: events can be retrieved from the calendar in non-strict chronological order!
         
         // NB2: normally we should only adjust times for events of CALENDAR_TIMEMODE_DATETIME,
         // to speedup the process we can probably eliminate lookup of event structures
         // and deduce the mode from the record itself, but this is questionable
         if(values[i].time % (60 * 60 * 24) == 0 && values[i].period == 0) continue;
         
         const int historicOffset = TimeServerGMTOffsetHistory(values[i].time, 1, 0.0, symbol);
         if(historicOffset != INT_MIN) // data obtained (can be missing for dates before range of bars on the chart)
         {
            if(log && !fixstart)
            {
               Print("Time fix-up started at ", values[i].time);
               fixstart = true;
            }
            int diff = 0;
            if(historicOffset != savedOffset)
            {
               diff = historicOffset - savedOffset;
            }
            
            if(diff)
            {
               if(log && (prevLog != diff))
               {
                  PrintFormat("%s: %lld %+d diff=%d", (string)values[i].time, values[i].id, historicOffset, diff);
                  prevLog = diff;
               }
               #ifdef WARN_ON_FIX_ON_FIX
               if(!!((long)(values[i].period) & 0x3F)) // already adjusted time indicates misuse of the lib
               {
                  /*
                  if(log) // bulk output for debugging only
                  {
                     PrintFormat("Re-adjustement: %lld %s", values[i].id, (string)values[i].time);
                  }
                  */
                  e++;
               }
               #endif
               values[i].time = values[i].time - diff;
               #ifdef WARN_ON_FIX_ON_FIX
               values[i].period += 1; // count corrections as number of seconds (don't have other field?)
               #endif
               c++;
            }
            else
            {
               if(log && prevLog)
               {
                  PrintFormat("%s: %lld %+d OK", (string)values[i].time, values[i].id, historicOffset);
                  prevLog = 0;
               }
            }
         }
      }
      if(log && c && e)
      {
         PrintFormat("WARNING: %d adjusted records were modified twice or more times (call adjustTZonHistory only once)", e);
      }
      bind(); // re-index
      return c;
   }
   #endif
   
   //+------------------------------------------------------------------+
   //| Methods to emulate standard calendar API                         |
   //+------------------------------------------------------------------+

   bool calendarCountryById(ulong country_id, MqlCalendarCountry &cnt)
   {
      const int index = find(country_id, id4country, countries);
      if(index == -1) return false;
      
      cnt = countries[index];
      return true;
   }
   
   bool calendarEventById(ulong event_id, MqlCalendarEvent &event)
   {
      const int index = find(event_id, id4event, events);
      if(index == -1) return false;
      
      event = events[index];
      return true;
   }
   
   static int ArrayBlowerBound(const ulong &array[][2], const ulong value, const int index)
   {
      if(index >= ArrayRange(array, 0)) return false;
      if(array[index][0] != value) return index; // no exact match
      for(int i = index - 1; i >= 0; --i)
      {
         if(array[i][0] != value) return i + 1;
      }
      return 0;
   }
   
   int calendarValueHistoryByEvent(ulong event_id, MqlCalendarValue &temp[],
      datetime _from, datetime _to = 0)
   {
      if(_to == 0) _to = LONG_MAX;
      ArrayFree(temp);
      
      const int index = ArrayBsearch(value2event, event_id);
      if(index < 0 || index >= ArrayRange(value2event, 0)) return 0;
      int i = ArrayBlowerBound(value2event, event_id, index);
      
      while(value2event[i][0] == event_id)
      {
         const ulong value_id = value2event[i][1];
         const int p = find(value_id, id4value, values);
         if(p != -1 && values[p].time >= _from && values[p].time < _to)
         {
            PUSH(temp, values[p]);
         }
         i++;
      }

      if(wantSort && ArraySize(temp) > 0)
      {
         SORT_STRUCT_REF(MqlCalendarValue, temp, time);
      }

      return ArraySize(temp);
   }
   
   int calendarValueHistory(MqlCalendarValue &temp[],
      datetime _from, datetime _to = 0,
      const string _code = NULL, const string _coin = NULL)
   {
      if(_to == 0) _to = LONG_MAX;
      ArrayFree(temp);
      
      ulong country_id = 0;
      ulong currency_id = StringLen(_coin) ? currencyId(_coin) : 0;
      
      if(StringLen(_code))
      {
         for(int i = 0; i < ArraySize(countries); ++i)
         {
            if(countries[i].code == _code)
            {
               country_id = countries[i].id;
               break;
            }
         }
      }

      // NB1: country and currency are considered more narrow filters than time,
      // hence try to apply them in first place. This is debatable.
      // NB2: if we manage to load actual times of changes into the cache,
      // then selection by from/to should be applied to these times,
      // instead of values[p].time
      
      if(country_id)
      {
         const int index = ArrayBsearch(value2country, country_id);
         if(index < 0 || index >= ArrayRange(value2country, 0)) return 0;
         if(value2country[index][0] != country_id) return 0;
         
         int i = ArrayBlowerBound(value2country, country_id, index);
         while(i < ArrayRange(value2country, 0) && value2country[i][0] == country_id)
         {
            const ulong value_id = value2country[i][1];
            const int p = find(value_id, id4value, values);
            if(p != -1 && values[p].time >= _from && values[p].time < _to)
            {
               PUSH(temp, values[p]);
            }
            i++;
         }
      }
      else if(currency_id)
      {
         const int index = ArrayBsearch(value2currency, currency_id);
         if(index < 0 || index >= ArrayRange(value2currency, 0)) return 0;
         if(value2currency[index][0] != currency_id) return 0;
         
         int i = ArrayBlowerBound(value2currency, currency_id, index);
         while(i < ArrayRange(value2currency, 0) && value2currency[i][0] == currency_id)
         {
            const ulong value_id = value2currency[i][1];
            const int p = find(value_id, id4value, values);
            if(p != -1 && values[p].time >= _from && values[p].time < _to)
            {
               PUSH(temp, values[p]);
            }
            i++;
         }
      }
      else if(_from) // no filters, only start and end time (optional)
      {
         const int index = ArrayBsearch(value2time, _from);
         if(index < 0 || index >= ArrayRange(value2time, 0)) return 0;
         
         int i = ArrayBlowerBound(value2time, value2time[index][0], index);
         while(i < ArrayRange(value2time, 0) && value2time[i][0] < (ulong)_from) ++i;
         
         if(i >= ArrayRange(value2time, 0)) return 0;
         
         for(int j = i; j < ArrayRange(value2time, 0) && value2time[j][0] < (ulong)_to; ++j)
         {
            const int p = find(value2time[j][1], id4value, values);
            if(p != -1)
            {
               PUSH(temp, values[p]);
            }
         }
      }
      else if(_to < D'3000.12.31') // no filters, only end time
      {
         const int index = ArrayBsearch(value2time, _to);
         if(index < 0 || index >= ArrayRange(value2time, 0)) return 0;

         int i = ArrayBlowerBound(value2time, value2time[index][0], index);
         while(i > 0 && value2time[i][0] >= (ulong)_to) --i;
         
         for(int j = 0; j <= i; ++j)
         {
            const int p = find(value2time[j][1], id4value, values);
            if(p != -1)
            {
               PUSH(temp, values[p]);
            }
         }
      }
      else
      {
         ArrayCopy(temp, values);
      }
      
      if(wantSort && ArraySize(temp) > 0)
      {
         SORT_STRUCT_REF(MqlCalendarValue, temp, time);
      }
      
      return ArraySize(temp);
   }
   
   int calendarValueLast(ulong &change, MqlCalendarValue &result[],
      const string code = NULL, const string currency = NULL)
   {
      /*

      straightforward equivalent is shown in this comment, but
      it's too slow for requests on short latest periods of time
      
         const int n = change ? calendarValueHistory(result,
            change, TimeTradeServer(), code, currency) : 0;
         change = TimeTradeServer();
         return n;
      */
      
      if(!change)
      {
         change = TimeTradeServer();
         return 0;
      }
      
      ulong country_id = 0;
      ulong currency_id = StringLen(currency) ? currencyId(currency) : 0;
      
      if(StringLen(code))
      {
         for(int i = 0; i < ArraySize(countries); ++i)
         {
            if(countries[i].code == code)
            {
               country_id = countries[i].id;
               break;
            }
         }
      }
      
      const ulong past = change;
      const int index = ArrayBsearch(value2time, past);
      if(index < 0 || index >= ArrayRange(value2time, 0)) return 0;
      
      int i = ArrayBlowerBound(value2time, value2time[index][0], index);
      while(i < ArrayRange(value2time, 0) && value2time[i][0] <= (ulong)past) ++i;
      
      if(i >= ArrayRange(value2time, 0)) return 0;
      
      for(int j = i; j < ArrayRange(value2time, 0) && value2time[j][0] <= (ulong)TimeTradeServer(); ++j)
      {
         const int p = find(value2time[j][1], id4value, values);
         if(p != -1)
         {
            change = TimeTradeServer();
            if(country_id != 0 || currency_id != 0)
            {
               const int q = find(values[p].event_id, id4event, events);
               if(country_id != 0 && country_id != events[q].country_id) continue;
               if(currency_id != 0)
               {
                  const int m = find(events[q].country_id, id4country, countries);
                  if(countries[m].currency != currency) continue;
               }
            }
            
            if(!eventId || eventId == values[p].event_id)
            {
               PUSH(result, values[p]);
            }
         }
      }
      
      return ArraySize(result);
   }
   
   int calendarValueLastByEvent(ulong event_id, ulong &change,
      MqlCalendarValue &result[])
   {
      eventId = event_id; // enable internal filtering by event id for the next call
      const int n = calendarValueLast(change, result);
      change = TimeTradeServer();
      eventId = 0;
      return n;
   }
};

const static string CalendarCache::CALENDAR_CACHE_HEADER = "MQL5 Calendar Cache\r\nv.1.1\r\n";
//+------------------------------------------------------------------+
#undef LOG
