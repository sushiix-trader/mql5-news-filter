#!/usr/bin/env bash
# Copy the package CSV into MQL5/Files so Strategy Tester / live FileOpen can see it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$(cd "$HERE/../../../../Files" && pwd)/news_calendar_replay.csv"
SRC="$HERE/news_calendar_replay.csv"
if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC — run export_news_calendar_csv.mq5 first." >&2
  exit 1
fi
cp -f "$SRC" "$DEST"
echo "Staged $SRC -> $DEST"
