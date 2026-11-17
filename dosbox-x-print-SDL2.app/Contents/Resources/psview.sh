#!/bin/bash

RES="$(cd "$(dirname "$0")" && pwd)"

NOW=$(date '+%F_%H:%M:%S')

# osascript -e ' tell application "System Events" to display dialog "path is:'"$FULLPATH"' " buttons {"OK"}'

"$RES/gs" -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="temporary-$NOW.pdf" "$1" 

sleep 1

rm "$1"

open "temporary-$NOW.pdf"
sleep 1
rm "temporary-$NOW.pdf"

