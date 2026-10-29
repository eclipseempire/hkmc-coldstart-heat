#!/system/bin/sh
# Capture-probe template (Step 1 of EXTENDING.md). Clears logcat, waits while
# you operate a FACTORY control, then dumps the log so you can see the exact
# ClimateManager/Manager call + the MicomD frame it produced. Read-only.
#
# Put this + NEMESIS.data at the root of a USB drive, insert PARKED, approve.
# During the wait window, press the physical button through its states.
#
# Edit GREP to match what you're hunting (seat/vent/mirror/etc.).
export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin:$PATH
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

U=/storage/usb0; [ -d "$U" ] || U=/data/nemesis
OUT=$U/CAPTURE.txt
RAW=$U/capture-logcat.txt
GREP='seat|heat|vent|warm|SeatHeatVent|ClimateManager|MicomD|send_data|sendILPacket|sendPacket|setSeat|getNextState'
WAIT=25

echo "capture $(date 2>/dev/null)" > "$OUT"
sleep 3
echo "clearing log; operate the control now for ~${WAIT}s" >> "$OUT"; sync 2>/dev/null
logcat -c 2>/dev/null
sleep "$WAIT"
logcat -d -v time > "$RAW" 2>/dev/null
sync 2>/dev/null
grep -iE "$GREP" "$RAW" 2>/dev/null >> "$OUT" 2>/dev/null
echo "done -> $OUT (+ full log $RAW)" >> "$OUT"; sync 2>/dev/null
exit 0
