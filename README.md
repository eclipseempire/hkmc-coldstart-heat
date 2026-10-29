# HKMC Cold-start Heat

A [NEMESIS](https://github.com/xwtk/hmg_nemesis) package for Hyundai / Kia / Genesis **Gen5W** head units that, **on every start, automatically turns on the heated steering wheel and/or heated seats when it's cold outside** — with an on-screen settings app to configure it.

No more reaching for the seat and wheel buttons on a frosty morning. Start the car, and if the outside temperature is below your threshold, your chosen heaters come on by themselves.

> [!WARNING]
> This is an unofficial community mod, not affiliated with or endorsed by Hyundai, Kia, Genesis, or HKMC. You run it at your own risk. It requires [NEMESIS](https://github.com/xwtk/hmg_nemesis) (root) to already be installed on your head unit. **Test everything while parked.** See [compatibility](#compatibility) — it is confirmed on one vehicle/firmware and may behave differently on others.

## Features

- **Automatic on cold start** — reads the outside-air temperature and turns on the configured heaters when it's below your threshold.
- **Steering wheel + both front seats** — each independently configurable. Seats support **Low / Med / High**.
- **On-screen settings app**, launched from the NEMESIS Manager:
  - Automation on/off
  - Temperature threshold (°F)
  - Steering wheel on/off
  - Driver seat: Off / Low / Med / High
  - Passenger seat: Off / Low / Med / High
  - **Test now** (apply immediately, ignoring temperature) and **All off**
- **No app required to run** — the boot service reads plain config files; the app is just a friendly editor for them.

## Compatibility

- **Head unit:** Android-based **Gen5W** (`S5W_M`) with [NEMESIS](https://github.com/xwtk/hmg_nemesis) installed.
- **Confirmed on:** Hyundai Ioniq, US firmware `NEEV.USA.0000.V015.012.260507`.
- **Elsewhere:** other Gen5W HKMC vehicles may work, but the service transaction codes and the seat-level enum were verified on the firmware above. On a different model/firmware the codes *should* be the same (they come from the shared `automotive` framework), but **verify while parked** before relying on it. If your vehicle has no heated seats, just leave the seat options Off.

## Requirements

- A Gen5W head unit with **NEMESIS already installed** (this package does not install NEMESIS; see the [NEMESIS project](https://github.com/xwtk/hmg_nemesis)).
- A FAT32 / exFAT USB drive for install.

## Install

### Option A — USB (recommended)

1. Download `hkmc-coldstart-heat-USB.zip` from the [latest release](../../releases/latest).
2. Extract it to the **root** of a FAT32/exFAT USB drive. You should have `NEMESIS.data` at the root and `packages/coldstart.heat.zip`.
3. Insert into the **parked** car's USB port and approve the install prompt.

### Option B — CLI (ADB)

```sh
adb push coldstart.heat.zip /data/local/tmp/
adb shell nemesis install /data/local/tmp/coldstart.heat.zip
```

## Using it

Open the NEMESIS Manager → **Packages** → **Cold-start Heat** → **Launch**.

- Set the **temperature threshold** (the heaters come on when the outside temp is *below* this), toggle the **steering wheel**, and pick a level for each **seat**.
- Tap **Save** to store your preferences.
- Tap **Test now** to apply them immediately (ignores temperature) — good for confirming it works.
- Tap **All off** to switch everything back off.

From then on, every time you start the car, the service checks the outside temperature and applies your settings automatically.

## Configuration (advanced)

Settings are one-value files under `/data/nemesis/state/coldstart.heat/`. The app writes these for you, but you can also edit them directly:

```sh
S=/data/nemesis/state/coldstart.heat
nemesis root -c "echo 50 > $S/threshold_f"   # trigger below 50 F
nemesis root -c "echo 1  > $S/wheel"         # steering wheel: 1 on / 0 off
nemesis root -c "echo 3  > $S/seat_drv"      # driver seat:    0 off / 1 low / 2 med / 3 high
nemesis root -c "echo 0  > $S/seat_pass"     # passenger seat: 0 off / 1 low / 2 med / 3 high
nemesis root -c "echo 1  > $S/enabled"       # master on/off
```

Logs: `nemesis log service coldstart.heat/apply`.

## How it works

The head unit has no CAN interface exposed to Android. Vehicle functions are **named binder services** in `system_server`, reachable as root with `service call`. This package calls the same services the factory climate UI and voice assistant use. The verified calls (firmware `260507`):

| Function | Command |
|----------|---------|
| Steering wheel heat on | `service call com.hkmc.vr 16 i32 1` |
| Driver seat heat | `service call com.hkmc.micom.usm 213 i32 <enum>` |
| Passenger seat heat | `service call com.hkmc.micom.usm 214 i32 <enum>` |
| Read driver seat state | `service call com.hkmc.micom.bcm 21` |
| Read passenger seat state | `service call com.hkmc.micom.bcm 23` |

Seat level **enum**: `2` = Off, `6` = Low, `7` = Med, `8` = High.

The outside temperature is read from the telematics log stream (the `"outTemperature"` value, in °C, that the unit already computes for its own display).

The boot service (`package/svc/coldstart.sh`) runs once per start as a NEMESIS `mode=background` service. The settings app (`app/`) is an ordinary-uid Android app that reads and writes the config files through the privileged `nemesis root` channel.

## Build from source

You need a JDK and Android build-tools that still ship `dx` (e.g. `30.0.3`) plus a platform `android.jar`.

```sh
export ANDROID_SDK=/path/to/android-sdk     # must contain build-tools/30.0.3 and platforms/android-30
tools/build_apk.sh                          # compiles + signs app/coldstart.apk
cp app/coldstart.apk package/app/coldstart.apk
tools/make_package.sh                        # builds dist/coldstart.heat.zip + the USB bundle
```

> The build uses the legacy `dx` dexer (not `d8`): it emits DEX `035`, which the KitKat-based Gen5W unit requires, and it avoids a `d8`/`r8` crash seen on very new JDKs. The APK is self-signed; NEMESIS handles installing a non-OEM-signed APK.

## Credits

- Built on [**NEMESIS**](https://github.com/xwtk/hmg_nemesis) by Gor Mirzoyan (xwtk) — the head-unit debugging/execution framework this package runs under.
- Detection pattern inspired by [dibble9012/hkmc-carplay-auto-display](https://github.com/dibble9012/hkmc-carplay-auto-display).

## License

[MIT](LICENSE) — do what you like, no warranty. Contributions welcome; if you confirm it on another Gen5W model/firmware, please open an issue or PR with the details.
