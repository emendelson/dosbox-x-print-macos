#!/bin/bash

RES="$(cd "$(dirname "$0")" && pwd)"

"$RES/gpcl6" -dBATCH -dNOPAUSE -sDEVICE=txtwrite -sOutputFile=pcltemp.txt "$1"

LOC=$( defaults read "Apple Global Domain" AppleLocale )
export LANG="$LOC.UTF-8"

cat pcltemp.txt | pbcopy

rm "$1"

rm pcltemp.txt



