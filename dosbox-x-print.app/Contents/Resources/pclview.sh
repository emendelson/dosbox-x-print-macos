#!/bin/bash

RES="$(cd "$(dirname "$0")" && pwd)"

## TODO: add this to PJL string
LOC=$( defaults read "Apple Global Domain" AppleLocale )
PAPER="A4"
if [ $LOC = "en_US" ] || [ $LOC = "en_CA" ] ; then
 PAPER="LETTER"
fi
# PJLPAPER="@PJL SET PAPER=$PAPER"

NOW=$(date '+%F_%H:%M:%S')
FULLPATH="$HOME/Desktop/$NOW.pdf"

"$RES/gpcl6" -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="temporary-$NOW.pdf" "$1" 

sleep 1

rm "$1"

open "temporary-$NOW.pdf"
sleep 1
rm "temporary-$NOW.pdf"
