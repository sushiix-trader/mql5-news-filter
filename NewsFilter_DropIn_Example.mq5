//+------------------------------------------------------------------+
//| NewsFilter_DropIn_Example.mq5                                    |
//| Minimal skeleton showing how to wire util/news-filter into an EA |
//+------------------------------------------------------------------+
#property copyright "Project local utility"
#property version   "1.00"
#property strict
#property description "Example only — not a trading strategy."
#property tester_file "news_calendar_replay.csv"

#include "NewsFilter_Advanced.mqh"

input ulong InpMagic = 900001;

int OnInit()
{
   // Fail closed on bad/missing CSV when NFA_UseNewsFilter + CSV path is on.
   if(!NFA_Init())
      return INIT_PARAMETERS_INCORRECT;
   return INIT_SUCCEEDED;
}

void OnTick()
{
   // Action layer: run every tick, outside any "new bar only" guard.
   NFA_Manage(InpMagic);

   // Decision layer: skip your entry path when a high-impact window is open.
   if(!NFA_EntryAllowed(_Symbol))
      return;

   // ... your existing entry logic here ...
}
