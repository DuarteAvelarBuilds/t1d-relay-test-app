# Reviewer's guide: t1d-relay-test-app (Relay Test)

This document is for a reviewer (human or AI) who has this repository but
none of the conversations behind it. It explains what the app is for, how it
works, how it is built and shipped, its rules, and what is known to be weak,
so the reviewer can evaluate it and suggest improvements.

It describes `main` at app version 0.1.0 (2026-11-08), which talks to relay
firmware LTE 0.4.5 / Bluetooth 0.4.3. Where this guide and the code
disagree, the code wins. Please report the mismatch as a finding.

Contents:

1. [What it is and isn't](#1-what-it-is-and-isnt)
2. [The bigger project](#2-the-bigger-project)
3. [Repository map](#3-repository-map)
4. [Architecture](#4-architecture)
5. [Bluetooth protocol it speaks](#5-bluetooth-protocol-it-speaks)
6. [Firmware updates from the phone](#6-firmware-updates-from-the-phone)
7. [Build and release](#7-build-and-release)
8. [Rules: safety, privacy, security](#8-rules-safety-privacy-security)
9. [Testing](#9-testing)
10. [Known issues and weaknesses](#10-known-issues-and-weaknesses)
11. [Open questions](#11-open-questions)
12. [What we'd like from a review](#12-what-wed-like-from-a-review)

---

## 1. What it is and isn't

**Relay Test** is an **engineering-only** iPhone app for checking that the
T1D relay hardware works. It:

- finds the relay over Bluetooth LE and connects (no pairing);
- shows every board sensor live (motion, impact, environment, light,
  battery and charger, LTE signal, G7 selection status, controller
  counters), with the rate asked for, the rate actually arriving, missed
  readings (from sequence gaps) and a small graph;
- lets you turn each sensor on or off and pick a rate, but only rates the
  board can carry (the owner explicitly did **not** want a max-rate stress
  test);
- checks nRF Cloud (Memfault) for the newest firmware for each chip and
  installs it over Bluetooth;
- reconnects by itself after the relay restarts or comes back into range;
- keeps the screen awake while connected.

It is **not** the product's phone app. It shows no glucose, does no dosing,
has no accounts and no secure pairing. The owner's real app (provisioning,
bonded encrypted BLE, handoff with Trio) doesn't exist yet. The owner's
words: "an app to figure out if the whole device is working", "not fancy".

## 2. The bigger project

A small screenless wearable that relays a Dexcom G7 CGM and an Omnipod 5
pump so a person with type 1 diabetes can leave their phone behind during
sports (first case: a teenager at 3-hour football practices). The device
firmware is in `DuarteAvelarBuilds/t1d-relay-firmware`; its `REVIEW.md`
covers the product, hardware and firmware in depth. Read at least its
sections 1-3 and 7 for context.

Facts this app depends on:

- The board (Nordic Thingy:91 today, Thingy:91 X later) has two chips. The
  **Application chip** (nRF9160) has the sensors but no Bluetooth. The **Bluetooth
  chip** (nRF52840) talks to the phone. So every sensor reading crosses a
  115200-baud UART between the chips, about 250 readings a second in total.
- The controller runs an engineering GATT service and mcumgr (SMP)
  over BLE, both **unauthenticated**, meant to be compiled out before real
  use.
- Each chip boots a new image on trial and rolls back unless it confirms
  itself, so an interrupted update is meant to be harmless.

The org also has `DuarteAvelarBuilds/Trio`, an unmodified fork of Trio
built the same way (GitHub Actions, fastlane match, TestFlight). This app
reuses that setup's org secrets and certificate repo.

## 3. Repository map

```
RelayTest/
  RelayTestApp.swift   @main, one WindowGroup
  ContentView.swift    SwiftUI screens: status, relays nearby, connected device,
                       FirmwareSection, sensor rows (toggle, rate menu, graph)
  Relay.swift          CoreBluetooth central: scan, connect, discover, notifications,
                       rate writes, per-sensor counting, auto-reconnect
  Sensors.swift        sensor table (IDs match firmware shared/link/sensors.hpp),
                       value formatting, notification parser (Reading)
  Updater.swift        nRF Cloud release lookup, MCUboot header version read,
                       Controller update (mcumgr/SMP over BLE, minimal CBOR),
                       Application chip update (windowed transfer through the controller)
  Info.plist           Bluetooth usage string, MemfaultProjectKey from build settings
  Assets.xcassets      icon
project.yml            XcodeGen spec (no .xcodeproj in git); iOS 17+, iPhone only
fastlane/Fastfile      identifiers + build lanes (match, build_app, upload_to_testflight)
Gemfile                fastlane
.github/workflows/build.yml   PR: compile check; main / Run workflow: TestFlight
README.md              what you see, one-time setup with exact click paths
```

About 1,100 lines of Swift. No third-party Swift packages.

## 4. Architecture

Deliberately small: two `ObservableObject`s and SwiftUI.

- **`Relay`** (owned by `ContentView` as `@StateObject`): wraps a
  `CBCentralManager` on the **main queue**. All Bluetooth callbacks and all
  state changes happen on the main thread.
  - Scanning uses **no service filter** with duplicates allowed, and keeps
    any peripheral that advertises the service UUID **or** has "T1D" in its
    name. (iOS may not match a UUID that is only in the scan response.)
  - On connect: discover the test service and the SMP service, then their
    characteristics; subscribe to Data, LTE update and SMP; read Info.
  - When Data notifications are on: send every enabled sensor's rate and
    start a 4 Hz timer that publishes counts to the UI (so a 100/s sensor
    doesn't redraw the screen 100 times a second) and reads RSSI. Info is
    re-read every 5 s because the application chip's version and serial arrive a
    little after connecting.
  - Per sensor it keeps raw state (`Live`): last sequence number, received,
    missed (gap in `seq`, ignoring jumps ≥ 1000 as a stream restart),
    arrival times for a 2-second rate window, last values, a 60-point graph.
  - On an unexpected disconnect it calls `connect` again (iOS keeps a
    pending connection open with no timeout). A user's Disconnect stops
    that.
- **`Updater`** (owned by `Relay`): firmware lookup and transfer state, also
  main-thread. It holds weak/optional references to the peripheral and
  characteristics, which `Relay` sets and clears.

## 5. Bluetooth protocol it speaks

Defined by the firmware in `docs/ble-test-service.md`; summary:

| | UUID | Use |
| --- | --- | --- |
| Service | `42800001-C846-48AD-9A69-38EF49048320` | test service |
| Data | `…0002` | notify: `[sensor u8][count u8 or 0xFF=error][seq u16][t_ms u32][count × int32]`, little-endian |
| Control | `…0003` | write: `01 <sensor> <ms u16>` set rate (0 = off), `02` all off, `03` boot the uploaded BT image on trial |
| Info | `…0004` | read: `relay-bt <ver> link <proto> lte <ver> serial <IMEI>` |
| LTE update | `…0005` | write `10 <size u32>`, `11 <offset u32> <≤192 bytes>`, `12`; notify `20 <next offset u32>`, `21 <code i32>` |
| SMP service / char | `8D53DC1D-…` / `DA2E7828-…` | standard mcumgr over BLE |

Sensor IDs: 1 motion, 2 impact, 3 environment, 4 light, 5 battery,
6 LTE signal, 7 G7 status (counts and signal only, never a sensor ID),
8 controller counters. 20+ are reserved for the Thingy:91 X. IDs are
never reused. The table lives in both repos and must be changed in both.

## 6. Firmware updates from the phone

1. **Check**: needs the application chip's serial (IMEI) from Info. Calls
   `GET https://device.memfault.com/api/v0/releases/latest` with
   `Memfault-Project-Key`, `device_serial`, `hardware_version=thingy91`,
   `software_type=bt` or `app`, and `current_version=0.0.0` (so it always
   returns the newest). Then reads the first 32 bytes of each image with an
   HTTP Range request and takes the version from the MCUboot header
   (magic `0x96f3b83d`, version at byte 20), because the BT image is a
   component of a release named after the LTE version.
2. **Update the controller**: download the image, turn all sensor
   streams off, then mcumgr image upload (group 1, command 1) over SMP,
   chunked to the write length, with reassembly on the chip. Each response
   gives the next offset. 5 s with no response resends; after 3 retries it
   stops. When done, write Control `03`; the chip reboots on trial and
   confirms after a minute of talking to the application chip. Takes about 1.5 min.
3. **Update the application chip**: download the image, streams off, write `10`
   (size), then windows of 768 bytes as four 192-byte `11` writes, and wait
   for `20 <offset>`. 3 s with no ack resends the window; after 3 retries it
   stops. The controller relays each write over the UART to the LTE
   chip, which buffers a window and writes it to flash. After the last ack,
   write `12`; the application chip reboots on trial and confirms once on LTE for a
   minute. Takes about 1 min for ~300 KB.

The app does not verify the image itself. It relies on MCUboot's hash and
signature check and on trial boot.

## 7. Build and release

- **No Xcode project in git.** `project.yml` is turned into
  `RelayTest.xcodeproj` with XcodeGen, locally
  (`brew install xcodegen && xcodegen`) and in CI.
- **CI** (`.github/workflows/build.yml`, `macos-26` runners):
  - pull requests: `xcodebuild` for the generic iOS Simulator with signing
    off. Compile check only.
  - push to `main` or **Run workflow**: checks the org secrets reach the
    repo, then `bundle exec fastlane build`.
  - Each change builds once on purpose (the repo was private at first, where
    macOS minutes cost 10x; it is public now, so standard runners are free).
- **fastlane `build` lane**: registers the bundle ID
  `org.duarteavelarbuilds.<TEAMID>.relaytest` if needed, takes the next
  TestFlight build number (and stops with a pointer to the README if the App
  Store Connect app doesn't exist yet), fetches App Store signing with
  **match** from the org's private `Match-Secrets` repo (git basic auth with
  `GH_PAT`), builds Release with manual signing, uploads to TestFlight
  without waiting for processing.
- **Secrets**: org-level `TEAMID`, `GH_PAT`, `MATCH_PASSWORD`,
  `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY` (shared with the
  Trio fork); repo-level `MEMFAULT_PROJECT_KEY` (optional; without it the
  Firmware section says it can't check).
- **Versioning**: `MARKETING_VERSION` 0.1.0 in `project.yml`;
  `CURRENT_PROJECT_VERSION` = latest TestFlight build + 1.
- **Distribution**: TestFlight internal testers only. Builds expire after
  90 days; re-run the workflow for a fresh one.

## 8. Rules: safety, privacy, security

- Engineering only; never used for dosing or real glucose.
- It must never show, log or send the ID of a G7 that isn't the selected one.
  Today the firmware never sends any G7 identifier over this service, only
  state, signal strength and counts.
- The Memfault project key is compiled into the app (Info.plist). It's a
  write-style key that lets a holder query releases and send data to the
  project. TestFlight builds go only to internal testers, but anyone with
  the .ipa can extract it.
- Bluetooth is unauthenticated both ways: the app trusts any peripheral
  that advertises the service UUID or has "T1D" in its name, and the relay
  trusts any phone.

## 9. Testing

- No unit tests and no UI tests. CI only checks it compiles.
- Tested by hand by the owner against the real board over TestFlight:
  connect, live rows, rate changes, charger states, auto-reconnect, both
  update paths.
- Pure, easily testable pieces that have no tests: `Reading(Data)`,
  `Sensors` formatting, `CBOR` encode and `intMap` (which had a real bug
  with Zephyr's indefinite-length maps, fixed in PR #3), `Updater.parseInfo`,
  the MCUboot header parse, the sequence-gap counter.

## 10. Known issues and weaknesses

Found while writing this guide (2026-11-08), not yet triaged with the owner.

### Medium

1. **Write-without-response flow control is ignored.** `smpSend()` and
   `lteSendWindow()` write several packets in a loop with
   `.withoutResponse` and never check `canSendWriteWithoutResponse` or wait
   for `peripheralIsReady(toSendWriteWithoutResponse:)`. iOS can drop such
   writes silently when its queue is full. The retry timers hide this
   (a dropped piece means a 3-5 s stall and a resend), which may explain
   slow or stalled updates.
2. **SMP responses are not matched to requests.** `smpResponse` accepts any
   image-group response and doesn't check the sequence number, so a late
   reply to a resent chunk can be taken as the answer to the current one.
   The offset in the reply keeps it mostly correct, but it can cause an
   extra resend or a skipped retry count.
3. **The final "boot it" write isn't confirmed.** After the last ack the app
   writes `12` (LTE, without response) or Control `03` (BT) and reports
   success. If that write is lost, nothing reboots and the user is told it
   is restarting. A follow-up check of the version after reconnect would
   catch it.
4. **No integrity check of the downloaded image** against the release's
   expected size or hash before sending it. MCUboot will reject a damaged
   image, but only after a full transfer and reboot.
5. **The peripheral filter is loose.** Any device whose name contains "T1D"
   is listed. Harmless in a lab, confusing at a conference booth.

### Low

6. `Relay` and `Updater` do everything on the main thread. Fine at
   ~250 notifications/s on current iPhones, but the UI and the transfer
   compete.
7. `Sensors.all.first(where:)` runs for every notification and every row on
   every publish tick; a dictionary would be simpler.
8. The app duplicates the firmware's sensor table, GATT UUIDs, charger state
   names and update protocol by hand. Nothing checks they stay in sync
   (the firmware's `link` protocol version is shown in Info but not
   checked).
9. Rates are sent as `UInt16` milliseconds, so nothing slower than 65 s can
   be asked for (no option offers that today).
10. `Updater.check()` uses `current_version=0.0.0` to always get the newest
    release, so it can't use Memfault cohorts or staged rollouts the normal
    way.

## 11. Open questions

- Should this app grow into the owner's real app, or stay a separate tool
  once the real app exists? (Not decided. The real app needs bonded LESC
  BLE, provisioning, and a handoff with Trio.)
- Should firmware updates move to Nordic's iOS DFU / mcumgr library instead
  of the hand-written SMP and CBOR code?
- How should the Thingy:91 X be supported: same app, sensors 20+, chosen by
  what the Info string reports?

## 12. What we'd like from a review

1. Robustness of the two firmware update paths (flow control, retries,
   timeouts, what the user is told, what happens on disconnect mid-update).
2. CoreBluetooth correctness: state restoration, reconnect behaviour,
   background use, MTU and write-type choices.
3. Whether the build/release pipeline is sound and cheap (secrets handling,
   match in readonly vs write mode, runner choice).
4. Which small tests are worth adding first.
5. Anything that would be a problem if parts of this code were reused in the
   real, safety-relevant app.

Please separate "fix now" from "nice to have", and say what you checked
versus what you inferred.
