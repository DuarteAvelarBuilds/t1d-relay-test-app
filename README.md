# Relay Test (engineering only)

An iPhone app to check the T1D relay hardware works: it connects to the relay
over Bluetooth and shows every sensor live, with how many updates per second
actually arrive and how many were missed.

Not for real use. It's for testing the board, nothing more.

Needs relay firmware 0.4.0 or later on both chips
(`DuarteAvelarBuilds/t1d-relay-firmware`). The Bluetooth service it talks to
is described in that repo's `docs/ble-test-service.md`.

## What you see

- **Relays nearby**: tap one to connect.
- One row per sensor: the latest value, a small graph (motion, impact,
  temperature, light, LTE signal), the rate you asked for, the rate actually
  arriving, and any missed readings.
- The dot is green while updates arrive on time and orange when they're late.
- The switch turns a sensor off. "Asked: ..." changes its rate; the menu
  only offers rates the board can handle.
- The screen stays on while connected.

| Sensor | Starts at | Fastest offered |
| --- | --- | --- |
| Motion (low-g accelerometer) | 10/s | 100/s |
| Impact (high-g, biggest hit since the last reading) | 10/s | 100/s |
| Environment (temperature, humidity, pressure, air) | 1/s | 5/s |
| Light | 2/s | 8/s |
| Battery | every 5 s | 1/s |
| LTE signal | every 2 s | 1/s |
| G7 pairing status | 1/s | 1/s |
| Bluetooth chip counters | 1/s | 1/s |

All sensors share a wire between the board's two chips that carries about
250 readings a second in total.

## One-time setup

1. **Repo**: done (this one).
2. **Secrets**: the build uses the same org secrets as the Trio fork. Open
   https://github.com/organizations/DuarteAvelarBuilds/settings/secrets/actions .
   Each secret shows its repository access under its name. If one says
   "Private repositories" or lists specific repos, click the pencil next to
   it, choose **All repositories** (or add `t1d-relay-test-app`), and
   **Save changes**.
3. **Run the build once**: open
   https://github.com/DuarteAvelarBuilds/t1d-relay-test-app/actions/workflows/build.yml ,
   click **Run workflow** (right side), then the green **Run workflow**.
   The first run registers the app's identifier with Apple and then stops,
   saying the app doesn't exist yet in App Store Connect. That's expected.
4. **Create the app in App Store Connect**: open
   https://appstoreconnect.apple.com/apps , click the blue **+** then
   **New App**. Tick **iOS**. Name: `T1D Relay Test` (if it's taken, add
   your initials). Primary language: English (U.S.). Bundle ID: pick
   **T1D Relay Test** (`org.duarteavelarbuilds.<team>.relaytest`). SKU:
   `relaytest`. User Access: Full Access. Click **Create**.
5. **Run the build again** (step 3). About 10 to 15 minutes later the build
   appears in TestFlight.
6. **Install**: in App Store Connect open the app, then **TestFlight** at the
   top, then **Internal Testing** on the left. Click **+** to make a group,
   add yourself, and add the build. Install it from the TestFlight app on
   your iPhone.

After that, every change merged to `main` builds and goes to TestFlight by
itself. TestFlight builds expire after 90 days; run the workflow again to
get a fresh one.

## How it's built

- `RelayTest/`: the app (SwiftUI and CoreBluetooth, iOS 17 or later).
  - `Sensors.swift`: the sensor list (numbers match the firmware's
    `shared/link/sensors.hpp`) and how each value is shown.
  - `Relay.swift`: scanning, connecting, rates, and counting what arrives.
  - `ContentView.swift`: the screens.
- `project.yml`: the Xcode project, generated with XcodeGen. To open it on a
  Mac: `brew install xcodegen && xcodegen && open RelayTest.xcodeproj`.
- `fastlane/Fastfile` and `.github/workflows/build.yml`: pull requests only
  check it compiles; `main` and **Run workflow** sign it with the
  certificates in `DuarteAvelarBuilds/Match-Secrets` and upload to
  TestFlight. Each change builds once, because macOS minutes count 10x on a
  private repo.

Adding the Thingy:91 X sensors later: give each a new number (20 and up) in
the firmware's `shared/link/sensors.hpp` and add a matching entry to
`Sensors.swift`.
