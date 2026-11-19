#!/bin/bash

RES="$(cd "$(dirname "$0")" && pwd)"

# test for available printers
PTRS=$( lpstat -p | grep -c "enabled")
if [ ! "$PTRS" -gt 0 ]; then
	message="No printers available."
	osascript -e "tell app \"System Events\" to display dialog \"$message\" buttons {\"OK\"} with title \"DOSBox-X Printing\""
	exit
fi

"$RES/gs" -sBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile=select.pdf "$1"

rm "$1"

DIR="$PWD"
PDF=("$DIR/select.pdf")

source "$RES/selectprint.sh" "$PDF"
exit