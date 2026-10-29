# Extending this project — methodology & lessons learned

This document is a **starting block for adding new vehicle functions** to the
Cold-start Heat package (ventilated seats, rear seats, mirrors, whatever your
trim exposes) and a record of what was learned reverse-engineering the first
ones. It's written for both humans and AI coding agents — the discovery recipe
is deterministic enough to follow step by step.

> Everything here was derived on a Hyundai Ioniq 5, US firmware
> `NEEV.USA.0000.V015.012.260507`. **Your trim and firmware will differ** — the
> service interface literally contains different methods on different builds
> (see [lesson #2](#2-the-interface-is-trim--firmware-dependent)). Re-derive on
> your own unit. Test everything **parked**.

---

## The big picture

The Gen5W head unit runs Android (KitKat-based). **There is no CAN interface
exposed to Android** — no `can0`, no SocketCAN. Instead, every vehicle function
is a **named binder service** registered in `system_server`, and those services
talk to a micro-controller (the "micom") over a serial link; the micom is what
actually drives the CAN buses.

```
your code (root)                OEM apps (climate UI, voice)
      │                                   │
      └──────────────┬────────────────────┘
                     ▼
       binder service in system_server      e.g. com.hkmc.micom.usm (IUSMService)
                     │                            com.hkmc.vr      (IVRService)
                     ▼                            com.hkmc.micom.bcm (IBCMService)
              MicomD / sendPacket / sendILPacket   (serial to the micom)
                     ▼
                   micom ──► CAN ──► body / climate / BCM
```

So to control something, you call the **same binder service the factory UI
calls**, as root, with `service call`. Root is not permission-gated on these
services, so no OEM signature is needed.

```sh
service call <service-name> <transaction-code> i32 <arg>
```

`service call` writes the interface token for you, so the call passes
`enforceInterface`. A clean result looks like `Result: Parcel(00000000 ...)` —
the first word `0` means no exception.

---

## The discovery recipe

This is the exact process that worked for the wheel and seats. Do it **parked**.

### Step 1 — capture the real command (press the physical button)

The fastest, most reliable signal is to watch what the car does when *you*
operate the factory control. Run a NEMESIS `type=execute` script that clears
logcat, waits while you press the button, then dumps it
(see `research/probe-template/`):

```sh
logcat -c
sleep 25            # press the physical button through its states now
logcat -d -v time > /storage/usb0/capture.txt
```

Then grep the capture for the UI handler, the manager call, and the micom frame:

```
D/SeatHeatVentPopup( ... ): getNextState(DRIVER_HEAT) (2)[OFF] -> (8)[HEAT_HIGH]
D/ClimateManager  ( ... ): ... setSeatDriverState() - 8
D/MicomD          ( ... ): send_data: c => m : ff 92 11 01 11 28 00 03 00 08 4f
```

That one capture tells you: the **method** (`setSeatDriverState`), the
**value/enum** (`8` = HEAT_HIGH), and the **raw micom frame** (command id `0x28`,
value `08`).

### Step 2 — map the enum

States are **enums, not 0..3**. Step the control through every level and record
each value. For front seat heat we got: `2`=Off, `6`=Low, `7`=Med, `8`=High.
Read the state back between presses with the matching getter (below) to confirm.

### Step 3 — find the binder service + transaction code

Pull the framework the services are compiled into and read the AIDL stubs with
the included tool (`tools/dexodex.py`, pure Python, no SDK/Java needed):

```sh
# pull these off the unit (NEMESIS run-script with cp), then off-car:
#   /system/framework/automotive.odex          (AIDL interfaces/stubs)
#   /system/framework/automotive-service.odex  (server impls - shows sendPacket)
#   /system/app/HKMC_*.odex                     (OEM app logic)

python3 tools/dexodex.py automotive.odex              # lists seat/heat/charge codes
python3 tools/dexodex.py --disasm automotive-service.odex \
    'Lcom/hkmc/micom/USMService;' setFrontSeatHeatDrvStep
```

`dexodex.py` extracts `TRANSACTION_*` codes (AIDL constants live in each stub's
`static_values`) and disassembles method bodies far enough to see `invoke`,
`sendPacket`/`sendILPacket`, and `const-string` IL-signal names. That's how we
confirmed `setFrontSeatHeatDrvStep` (code 213) → `sendFrontSeatHeat(0,step)` →
`sendPacket(0x92,0x11,0x1128,…)`, which builds the exact `ff 92 11 01 11 28`
frame the physical button produced.

### Step 4 — verify on-car, carefully

1. Call the **getter** first (read-only) to confirm root reaches the service.
2. Issue **one** write, parked, and confirm with the getter + the on-screen
   indicator (you don't have to wait to feel heat — the state readback and the
   indicator bars confirm it immediately).
3. Only then wire it into the service/app.

### Step 5 — wire it in

- Add the command to `package/svc/coldstart.sh` (a `service call` line, gated on
  a config value).
- Add a config file + a control in `app/src/.../MainActivity.java` (map the UI
  level to the right enum).
- Rebuild: `tools/build_apk.sh` → copy APK to `package/app/` → `tools/make_package.sh`.

---

## Lessons learned (gotchas)

### 1. "Indicator-only" vs actuating calls
Some service methods only update the **on-screen indicator**; a *different*
method actually drives the hardware. The steering wheel is the trap:
`com.hkmc.micom.usm` code **212** (`setSWRC_SteeringwheelWarmerSet`) flips the
indicator but does **not** heat — the real actuator is `com.hkmc.vr` code **16**
(`set_StrgWhlHeated_Cmd_AVN`). Conversely, for **seats** the USM path (code 213)
*does* actuate. Don't assume by service; confirm the method reaches
`sendPacket`/`sendILPacket` (Step 3) and test (Step 4). If a call returns `0`
but nothing physically changes, you've found an indicator-only method.

### 2. The interface is trim- / firmware-dependent
`IUSMService` on this (no-ventilated-seats) build has `setFrontSeatHeatDrvStep`
but **no** `setFrontSeatVent…` method at all. A trim with ventilated seats will
expose additional methods and enum values. **Always dump your own car's
`automotive.odex`** — don't trust another unit's code list.

### 3. Use `dx`, not `d8`, and target DEX 035
The head unit is KitKat/Dalvik. Build the APK with the legacy `dx` dexer
(`--min-sdk-version=19` → DEX `035`). `d8`/`r8` from older build-tools also
crash under very new JDKs (e.g. JDK 27). Sign with **v1** (jar) signing — v2 is
Android 7+.

### 4. NEMESIS installs non-OEM APKs
A self-signed APK normally fails `pm install` while booted
(`INCONSISTENT_CERTIFICATES`); NEMESIS works around this during package install,
so your mod app just needs to be v1-signed with any key.

### 5. Ordinary apps reach root via the NEMESIS channel
The settings app runs as an ordinary uid. It reads/writes `/data/nemesis/state`
and issues `service call`s by exec-ing `/system/xbin/nemesis root -c "…"`. Any
uid may use that channel, so you don't need a system-signed app.

### 6. The micom frame format
`sendPacket`/`sendILPacket` produce frames like
`ff 92 11 01 11 <cmd-id> 00 03 00 <value> <checksum>`. The command id
distinguishes functions (wheel heat `0x27`, driver-seat heat `0x28`). You rarely
need to craft these by hand — prefer the binder `service call` — but they're the
ground truth when confirming which binder method maps to which function.

---

## Verified reference (firmware 260507)

| Function | Call | Values |
|----------|------|--------|
| Steering wheel heat | `service call com.hkmc.vr 16 i32 <v>` | `1` on, `0` off |
| Driver seat heat | `service call com.hkmc.micom.usm 213 i32 <v>` | `2` off, `6` low, `7` med, `8` high |
| Passenger seat heat | `service call com.hkmc.micom.usm 214 i32 <v>` | same enum |
| Charge-port door | `service call com.hkmc.micom.bcm 84 i32 <v>` | `0` open |
| Read drv seat state | `service call com.hkmc.micom.bcm 21` | returns the enum above |
| Read pass seat state | `service call com.hkmc.micom.bcm 23` | |
| Read charge-door state | `service call com.hkmc.micom.bcm 82` | `1` open, `2` closed |

Outside temp: parse `"outTemperature"` (°C) from the telematics `ECO` JSON in
`logcat`. (`getOutTempSnsrVal()` returns `-1`; don't use it.)

---

## Ventilated seats — a concrete starting block

Strong evidence this is the **same actuator with different enum values**:

- The factory popup is a unified **`SeatHeatVent`** state machine. Its states
  (seen as strings in `HKMC_Climate`) include `HEAT_VENT_OFF`, `HEAT_LOW/MID/
  HIGH`, and **`VENT_LOW`, `VENT_MID`, `VENT_HIGH`** — one control cycles through
  all of them, and all go through the same `setSeatDriverState(enum)`.
- Front seat heat already actuates via `com.hkmc.micom.usm` code **213** (driver)
  / **214** (passenger). The vent levels are almost certainly **more enum values
  on the same codes**, not a new service.

**What's known:** heat enums `2`/`6`/`7`/`8` (off/low/med/high).
**What's unknown (needs a vent-equipped car):** the `VENT_LOW/MID/HIGH` enum
values. Capture them with the recipe above — press the physical driver-seat
*vent* button through its levels and read `setSeatDriverState() - <n>` plus the
`service call com.hkmc.micom.usm 213 i32 <n>` readback (`bcm 21`).

Once you have the three vent enums, adding vent is small: a few more config
values and UI options, same `usm 213/214` calls.

**Not this:** `IDATCService.setSmartVentilation` (25) / `setScheduledVentilation`
(27) are **cabin** ventilation (the park-and-cool feature), not seat vent.

Other low-hanging fruit visible in the interfaces: rear seat heat
(`com.hkmc.micom.usm` `setRearSeatHeatLeftStep` 186 / `RightStep` 187).

---

## For AI agents picking this up

1. Work **parked**. Treat every `service call` write as live vehicle control.
2. Don't guess transaction codes against a live service. Derive them from the
   car's own `automotive.odex` with `tools/dexodex.py`, or capture the physical
   button (Step 1). Guessing codes can trigger unrelated functions.
3. Confirm each function in this order: read-only getter → single write parked →
   on-screen/indicator confirmation → wire into the package.
4. Re-derive on the target car; do not assume codes/enums from firmware 260507
   carry over. Verify the method exists in *that* unit's framework.
5. Never commit OEM `.apk`/`.odex` binaries or signing keystores to the repo.

---

## Tools in this repo

- `tools/dexodex.py` — pure-Python Dalvik ODEX reader/disassembler. Lists AIDL
  transaction codes and disassembles method bodies (invokes, `sendPacket`,
  `const-string`). No Android SDK or Java required.
- `tools/build_apk.sh` / `tools/make_package.sh` — build + package.
- `research/probe-template/` — a `type=execute` capture skeleton for Step 1.

## Safety

Unofficial mod; not affiliated with Hyundai/Kia/Genesis/HKMC. You are
responsible for anything you command on your vehicle. Test parked, one function
at a time, with a way to reverse it. If you brick something, that's on you.
