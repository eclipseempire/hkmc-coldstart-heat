#!/bin/bash
# Off-car test of package/svc/coldstart.sh under mksh: fake service/logcat/sleep, state in a temp dir.
#   tools/test_coldstart.sh [script]
SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)/package/svc/coldstart.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/service" <<'E2'
#!/bin/sh
case "$1" in check) echo "Service $2: found" ;; call) shift; echo "$*" >> "$T/sent" ;; esac
E2
cat > "$T/bin/logcat" <<'E2'
#!/bin/sh
[ -f "$T/tempc" ] && echo "11-10 07:00:00.000 I/x: {\"outTemperature\":$(cat $T/tempc),\"a\":1}"
exit 0
E2
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
export T
sed -e "s#^export PATH=.*#export PATH=$T/bin:/usr/bin:/bin#" -e "s#^STATE=.*#STATE=$T/state#" "$SRC" > "$T/cs.sh"
pass=0 fail=0
sc() {  # sc <name> <state k=v,...> <tempC or -> <expected sends>
    rm -f "$T/sent" "$T/tempc" "$T"/state/*
    for kv in ${2//,/ }; do echo "${kv#*=}" > "$T/state/${kv%%=*}"; done
    [ "$3" != - ] && echo "$3" > "$T/tempc"
    mksh "$T/cs.sh" > "$T/log" 2>&1
    got=$(cat "$T/sent" 2>/dev/null)
    if [ "$got" = "$4" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo " want: ${4//$'\n'/ | }"; echo " got:  ${got//$'\n'/ | }"; cat "$T/log"; fi
}
W="com.hkmc.vr 16 i32 1"; D7="com.hkmc.micom.usm 213 i32 7"
sc "defaults, cold (4C=39F): wheel"                 ""                                  4  "$W"
sc "defaults, warm (20C=68F): nothing"              ""                                  20 ""
sc "cold, wheel + driver med"                       "seat_drv=2"                        4  "$W"$'\n'"$D7"
sc "wheel 135, warm 25C=77F: wheel only"            "wheel_threshold_f=135,seat_drv=2"  25 "$W"
sc "wheel 135, cold: wheel + seat"                  "wheel_threshold_f=135,seat_drv=2"  4  "$W"$'\n'"$D7"
sc "wheel 135, 58C=136F: not below 135"             "wheel_threshold_f=135"             58 ""
sc "wheel 140 = always, no temp at all: wheel"      "wheel_threshold_f=140"             -  "$W"
sc "wheel 140, seat, no temp: wheel only"           "wheel_threshold_f=140,seat_drv=2"  -  "$W"
sc "wheel 140, seat, cold: wheel once + seat"       "wheel_threshold_f=140,seat_drv=2"  4  "$W"$'\n'"$D7"
sc "wheel 140 but wheel off: nothing when warm"     "wheel_threshold_f=140,wheel=0"     25 ""
sc "wheel threshold 20F below seats 50F, 4C=39F"    "wheel_threshold_f=20,seat_drv=2"   4  "$D7"
sc "disabled: nothing"                              "enabled=0,wheel_threshold_f=140"   4  ""
sc "no temp, threshold-based: nothing"              "wheel_threshold_f=135"             -  ""
echo "$pass passed, $fail failed"
