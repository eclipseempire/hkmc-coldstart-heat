#!/system/bin/sh
# coldstart.heat - on each start, if outside temp is below threshold_f, apply
# the configured heaters (steering wheel + driver/passenger seats) via the VR
# command channel. Config lives in one-value files written by the UI app.
#
# Verified actuation on-car (NEEV.USA...260507):
#   wheel:      service call com.hkmc.vr 16 i32 1              (on)
#   drv seat:   service call com.hkmc.micom.usm 213 i32 <enum> (setFrontSeatHeatDrvStep)
#   pass seat:  service call com.hkmc.micom.usm 214 i32 <enum> (setFrontSeatHeatAstStep)
#   seat enum:  2=Off 6=Low 7=Med 8=High ; config level 1/2/3 maps to 6/7/8
# Outside temp from logcat: preferred source is the ECO JSON "outTemperature"
# (always deg C, unit-independent of the dash). Fallback is the dashboard temp
# "setOutsideTempUIAdvanced::temp", which is in the DASH DISPLAY UNIT - so if the
# car shows Celsius, set ui_temp_is_c=1 and we convert it (otherwise a Celsius
# reading like 8 is misread as 8F and the heaters fire every start). F=C*9/5+32.
#
# Runs once per boot (mode=background). TEST WHILE PARKED.
export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

TAG=coldstart.heat
STATE=/data/nemesis/state/$TAG
mkdir -p "$STATE" 2>/dev/null
log() { echo "coldstart: $(date 2>/dev/null) $*"; }

cfg() { _f="$STATE/$1"; _d="$2"; if [ -r "$_f" ]; then read -r _v < "$_f" 2>/dev/null; case "$_v" in ''|*[!0-9-]*) echo "$_d";; *) echo "$_v";; esac; else echo "$_d"; fi; }
# map UI level 1/2/3 (Low/Med/High) -> seat enum 6/7/8 ; anything else -> 2 (off)
seat_enum() { case "$1" in 1) echo 6;; 2) echo 7;; 3) echo 8;; *) echo 2;; esac; }

ENABLED=$(cfg enabled 1)
THRESH_F=$(cfg threshold_f 50)
WHEEL=$(cfg wheel 1)          # 0/1
SEAT_DRV=$(cfg seat_drv 0)    # 0..3
SEAT_PASS=$(cfg seat_pass 0)  # 0..3
UI_IS_C=$(cfg ui_temp_is_c 0) # 1 if the dashboard shows Celsius (fallback temp source)
MAX_WAIT=$(cfg max_wait 120)

log "start enabled=$ENABLED threshold_f=$THRESH_F wheel=$WHEEL drv=$SEAT_DRV pass=$SEAT_PASS ui_is_c=$UI_IS_C"
if [ "$ENABLED" != "1" ]; then log "disabled; no action"; exit 0; fi

# wait for the VR service (framework up)
i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
    service check com.hkmc.vr 2>/dev/null | grep -q ': found' && { log "vr ready"; break; }
    sleep 2; i=$((i + 2))
done

# newest valid outside temp -> Fahrenheit
last_match() { _h=$(logcat -d 2>/dev/null | grep "$1"); _l=""; while IFS= read -r _x; do [ -n "$_x" ] && _l=$_x; done <<EOF
$_h
EOF
echo "$_l"; }

TEMP_F=""
i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
    _line=$(last_match '"outTemperature":')
    case "$_line" in *'"outTemperature":'*)
        _c=${_line#*\"outTemperature\":}; _c=${_c%%[!0-9-]*}
        case "$_c" in ''|*[!0-9-]*) ;; *)
            if [ "$_c" -ge -50 ] && [ "$_c" -le 60 ]; then TEMP_F=$(( _c * 9 / 5 + 32 )); log "outTemperature=${_c}C=${TEMP_F}F"; break; fi ;;
        esac ;;
    esac
    _line=$(last_match 'setOutsideTempUIAdvanced::temp =')
    case "$_line" in *'temp = '*)
        _v=${_line#*temp = }; _v=${_v%% *}; _v=${_v%%.*}
        case "$_v" in ''|*[!0-9-]*) ;; *)
            if [ "$UI_IS_C" = "1" ]; then
                # dashboard shows Celsius -> this value is Celsius
                if [ "$_v" -ge -50 ] && [ "$_v" -le 60 ]; then TEMP_F=$(( _v * 9 / 5 + 32 )); log "ui outside=${_v}C=${TEMP_F}F"; break; fi
            else
                if [ "$_v" -ge -58 ] && [ "$_v" -le 140 ]; then TEMP_F=$_v; log "ui outside=${TEMP_F}F"; break; fi
            fi ;;
        esac ;;
    esac
    sleep 3; i=$((i + 3))
done

[ -z "$TEMP_F" ] && { log "no valid outside temp within ${MAX_WAIT}s; no action"; exit 0; }

if [ "$TEMP_F" -ge "$THRESH_F" ]; then
    log "outside ${TEMP_F}F >= ${THRESH_F}F; no action"; exit 0
fi
log "outside ${TEMP_F}F < ${THRESH_F}F -> applying heaters"

if [ "$WHEEL" = "1" ]; then
    service call com.hkmc.vr 16 i32 1 >/dev/null 2>&1; log "wheel on (exit $?)"
fi
if [ "$SEAT_DRV" -gt 0 ] 2>/dev/null; then
    _e=$(seat_enum "$SEAT_DRV")
    service call com.hkmc.micom.usm 213 i32 "$_e" >/dev/null 2>&1; log "drv seat lvl$SEAT_DRV->enum$_e (exit $?)"
fi
if [ "$SEAT_PASS" -gt 0 ] 2>/dev/null; then
    _e=$(seat_enum "$SEAT_PASS")
    service call com.hkmc.micom.usm 214 i32 "$_e" >/dev/null 2>&1; log "pass seat lvl$SEAT_PASS->enum$_e (exit $?)"
fi
log "done"
exit 0
