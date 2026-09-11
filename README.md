# pushapp-blocker
App that blocks your distraction apps until you do your daily push up rep. It will cheer you up during your rep and counts for you. 

The app is in swift language using SwiftUI and SwiftData when possible. 

## Daily lock state

The app shares one `BlockedAppsStore` through the SwiftUI environment. Its
read-only `isLocked` state controls shields for the selected apps, categories,
and websites. The future workout completion flow should call
`try completeDailyWorkout()` on that shared store after a successful workout.
This removes the shields without clearing the selection and saves the completion
date in shared App Group UserDefaults so the unlock survives app restarts.
If registering the daily schedule fails, the method throws and does not grant a
new unlock. The caller should display that error and allow a retry.

An unlock lasts for the current calendar day in the device's local time zone.
The state refreshes on launch, foreground activation, and significant time changes
(including midnight). The camera currently does not verify or complete workouts.

`DailyResetMonitor` is an embedded Device Activity extension with a repeating
midnight-to-midnight schedule. iOS invokes it when the device is used after the
daily boundary, even if PushApp Blocker is closed. It reads the saved selection
and workout date, then reapplies shields if no workout was completed that day.
Both interval callbacks check the date; neither blindly unlocks apps or overwrites
a workout completed before a delayed callback. The app and extension use the same
named Managed Settings store so either can update the shields.

### Daily reset setup and verification

- Both the app and `DailyResetMonitor` targets need the same signing team,
  **Family Controls**, and the App Group `group.com.stepkurniawan.pushapp-blocker`.
  The project includes these settings; Xcode must provision the App Group and both
  targets for your Apple Developer account. If you change the group identifier,
  update both entitlement files and `Shared/DailyBlocking.swift` together.
- Distribution requires Family Controls entitlement approval for both bundle IDs.
- On a physical iPhone, grant Screen Time access using **Blocked Apps > Edit**
  and select a game. Confirm it is blocked, then call `try completeDailyWorkout()`
  on the shared store through the debugger or the future workout flow. Confirm
  the game unlocks, close PushApp Blocker, and use the device after local midnight.
  Open the game directly: it should be shielded without reopening PushApp Blocker.
  Repeat after skipping several days and after completing another workout.
- Unit tests cover shared date/selection reads, skipped days, delayed callbacks,
  daylight-saving boundaries, migration, and scheduling failures. Actual iOS
  callback delivery and Screen Time shields require physical-device verification.

Apple documents delivery on device use, not a guaranteed wall-clock execution
exactly at midnight: [DeviceActivityCenter](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter).

## Run the app

### Prerequisites

- Install Xcode. Install an iOS Simulator runtime if you want to use a simulator.
- To run on a physical iPhone or iPad, connect it to the Mac by USB, unlock it,
  trust the Mac, and enable **Developer Mode** on the device. The device must be
  paired with Xcode before it can be used from VS Code.

### Enable Developer Mode on an iPhone

The **Developer Mode** setting may not appear until the iPhone has started pairing
with Xcode.

1. Connect the iPhone to the Mac with a USB cable and unlock it.
2. If the iPhone asks whether to trust the computer, tap **Trust** and enter the
   iPhone passcode.
3. Open Xcode and select **Window > Devices and Simulators**.
4. Select the iPhone and follow any pairing prompts shown by Xcode or the iPhone.
5. On the iPhone, open **Settings > Privacy & Security**.
6. Scroll down to the **Security** section and tap **Developer Mode**.
7. Turn on **Developer Mode**, then tap **Restart** when prompted.
8. After the iPhone restarts, unlock it and confirm the Developer Mode prompt by
   tapping **Turn On** (or **Enable**, depending on the iOS version).
9. Enter the iPhone passcode to finish enabling Developer Mode.

If **Developer Mode** is missing from **Privacy & Security**, keep the iPhone
connected and unlocked, confirm that it appears in Xcode's **Devices and
Simulators** window, and then reopen Settings on the iPhone.

### Xcode

1. Open `pushapp-blocker.xcodeproj` in Xcode.
2. Select the `pushapp-blocker` project in the Project navigator, select the
   `pushapp-blocker` target, and open **Signing & Capabilities**.
3. Enable **Automatically manage signing** and select your Apple Developer team.
   If Xcode reports that the bundle identifier is unavailable, replace it with a
   unique identifier for your account.
4. In Xcode's toolbar, select the `pushapp-blocker` scheme, then select your
   connected device from the run-destination menu. To use a simulator instead,
   select one of the listed iPhone simulators.
5. Press `Cmd+R` or click **Run** to build, install, and launch the app.

If the device does not appear, open **Window > Devices and Simulators** in Xcode
and finish pairing it. Keep the device unlocked during the first build and accept
any trust or developer prompts that appear.

### VS Code with SweetPad

Before using a physical device in SweetPad, complete the Xcode signing and device
pairing steps above at least once.

1. Install the SweetPad extension and open the repository root in VS Code (the
   folder containing `pushapp-blocker.xcodeproj`).
2. Open the SweetPad view from the VS Code sidebar.
3. In **Destinations**, select your device under **iOS Devices**. You can also
   press `Cmd+Shift+P`, run **SweetPad: Select destination**, and choose it there.
4. Under **Build**, find the `pushapp-blocker` scheme and click the play button to
   build, install, and launch the app on the selected device.

You can also press `Cmd+Shift+P` and run **SweetPad: Build & Run (Launch)**.

If a newly paired device is missing, run **SweetPad: Refresh devices list**. The
selected destination is remembered for the workspace. Do not commit a physical
device UDID to `.vscode/settings.json`, because it is specific to one developer's
device.

The iOS Simulator does not provide a camera to this app. Selecting **Open Camera**
in the simulator will therefore show the **Camera Unavailable** alert. Test camera
functionality on a physical iPhone.
