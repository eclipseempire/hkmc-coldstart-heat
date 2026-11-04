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
# (always deg C). Fallback is the dashboard temp line
# "setOutsideTempUIAdvanced::temp = X / tempunit = Y". tempunit gives BOTH the
# unit and validity: 2=Fahrenheit, 1=Celsius, -1/0=NOT READY (early-boot
# sentinel, temp reads -1.0). We reject the sentinel and keep waiting - reading
# -1 as -1F is what made the heaters fire on warm mornings. If a firmware omits
# tempunit we fall back to the ui_temp_is_c config. F=C*9/5+32.
#
# Runs once per boot (mode=background). TEST WHILE PARKED.
#
# Optional diagnostics: with diag=1 (default 0), every start also appends a
# timestamped record to diag.log (what temp was read, from which source, and
# the fire/no-fire decision) and copies it to a plugged-in USB stick. Off by
# default and zero-overhead when off; turn it on from the app only to capture
# a log. Read it with: nemesis root -c "cat /data/nemesis/state/coldstart.heat/diag.log"
export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

TAG=coldstart.heat
STATE=/data/nemesis/state/$TAG
DIAG=$STATE/diag.log
mkdir -p "$STATE" 2>/dev/null
D() { :; }               # diagnostic logger: no-op unless diag=1 (redefined below)
_copy_usb() { :; }       # copy diag.log to a plugged USB: no-op unless diag=1
log() { echo "coldstart: $(date 2>/dev/null) $*"; D "$*"; }

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
DIAG_ON=$(cfg diag 0)         # 1 = append a persistent timestamped record to diag.log

# enable persistent diagnostics only when asked
if [ "$DIAG_ON" = "1" ]; then
    _sz=$(wc -c < "$DIAG" 2>/dev/null || echo 0); case "$_sz" in ''|*[!0-9]*) _sz=0;; esac
    [ "$_sz" -gt 262144 ] && mv "$DIAG" "$DIAG.1" 2>/dev/null   # rotate past ~256 KB
    D() { echo "$*" >> "$DIAG" 2>/dev/null; sync 2>/dev/null; }
    _copy_usb() { for _u in /storage/usb0 /storage/usb1 /mnt/media_rw/usb0 /mnt/usbhost0; do [ -d "$_u" ] && cp "$DIAG" "$_u/coldstart-diag.log" 2>/dev/null && { D "(copied diag.log to $_u)"; return; }; done; }
    D "================================================================"
    D "RUN wall=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)s"
fi

log "start enabled=$ENABLED threshold_f=$THRESH_F wheel=$WHEEL drv=$SEAT_DRV pass=$SEAT_PASS ui_is_c=$UI_IS_C diag=$DIAG_ON"
if [ "$ENABLED" != "1" ]; then log "disabled; no action"; _copy_usb; exit 0; fi

# wait for the VR service (framework up)
i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
    service check com.hkmc.vr 2>/dev/null | grep -q ': found' && { log "vr ready"; break; }
    sleep 2; i=$((i + 2))
done

# newest matching line from the live log, with timestamp.
# tail-free on purpose: this head unit's shell has no `tail`.
last_match() { _h=$(logcat -d -v time 2>/dev/null | grep "$1"); _l=""; while IFS= read -r _x; do [ -n "$_x" ] && _l=$_x; done <<EOF
$_h
EOF
echo "$_l"; }

# diagnostics: record the newest line from each source (with its timestamp)
if [ "$DIAG_ON" = "1" ]; then
    D "newest raw outTemperature:  $(last_match '"outTemperature":')"
    D "newest dashboard temp line: $(last_match 'setOutsideTempUIAdvanced::temp =')"
fi

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
        _u=x; case "$_line" in *'tempunit = '*) _u=${_line##*tempunit = }; _u=${_u%% *}; _u=${_u%%.*};; esac
        case "$_u" in ''|*[!0-9-]*) _u=x;; esac
        case "$_v" in ''|*[!0-9-]*) _v=x;; esac
        if [ "$_v" = "x" ]; then
            :                                           # unparseable; keep waiting
        elif [ "$_u" = "1" ]; then                      # tempunit 1 = Celsius
            if [ "$_v" -ge -45 ] && [ "$_v" -le 60 ]; then TEMP_F=$(( _v * 9 / 5 + 32 )); log "ui outside=${_v}C=${TEMP_F}F (unit=C)"; break; fi
        elif [ "$_u" = "2" ]; then                      # tempunit 2 = Fahrenheit
            if [ "$_v" != "-1" ] && [ "$_v" -ge -50 ] && [ "$_v" -le 140 ]; then TEMP_F=$_v; log "ui outside=${TEMP_F}F (unit=F)"; break; fi
        elif [ "$_u" = "x" ]; then                      # no tempunit tag: use the configured unit, but never the -1 sentinel
            if [ "$_v" = "-1" ]; then log "ui temp not ready (-1); waiting"
            elif [ "$UI_IS_C" = "1" ]; then
                if [ "$_v" -ge -45 ] && [ "$_v" -le 60 ]; then TEMP_F=$(( _v * 9 / 5 + 32 )); log "ui outside=${_v}C=${TEMP_F}F (cfg C)"; break; fi
            else
                if [ "$_v" -ge -50 ] && [ "$_v" -le 140 ]; then TEMP_F=$_v; log "ui outside=${TEMP_F}F (cfg F)"; break; fi
            fi
        else                                            # tempunit present but not 1/2 (e.g. -1, 0) = not ready
            log "ui temp not ready (temp=$_v unit=$_u); waiting"
        fi ;;
    esac
    sleep 3; i=$((i + 3))
done

[ -z "$TEMP_F" ] && { log "no valid outside temp within ${MAX_WAIT}s; no action"; _copy_usb; exit 0; }

if [ "$TEMP_F" -ge "$THRESH_F" ]; then
    log "outside ${TEMP_F}F >= ${THRESH_F}F; no action"; _copy_usb; exit 0
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
_copy_usb
exit 0
