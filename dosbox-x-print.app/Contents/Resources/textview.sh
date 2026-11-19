#!/bin/bash

# convert text file to arbitrarily-named PDF on desktop; open; then delete when closed

RES="$(cd "$(dirname "$0")" && pwd)"

# echo "$MYDIR">~/Desktop/x.txt

LOC=$( defaults read "Apple Global Domain" AppleLocale )
PAPER="a4"
if [ $LOC = "en_US" ] || [ $LOC = "en_CA" ] ; then
   PAPER="us"
fi

NOW=$( date '+%F_%H:%M:%S' )

"$RES/nenscript" -p temp.ps -fCourier9 -B -T $PAPER "$1"
"$RES/gs" -sBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="temporary-$NOW.pdf" temp.ps

sleep 1

rm temp.ps
rm "$1"

open "temporary-$NOW.pdf"
sleep 1
rm "temporary-$NOW.pdf"

