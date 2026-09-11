# pushapp-blocker
App that blocks your distraction apps until you do your daily push up rep. It will cheer you up during your rep and counts for you. 

The app is in swift language using SwiftUI and SwiftData when possible. 

## Workout recognition

**Start Workout** opens a live, on-device camera session that recognizes and counts
push-ups. It uses Vision's `VNDetectHumanBodyPoseRequest`, then counts a rep when
the 2D elbow angle decreases and returns to the extended position.

The app intentionally uses 2D pose observations rather than 3D observations:
push-up counting only needs the shoulder-elbow-wrist geometry in the camera image,
and the 2D pipeline better supports the intended side-view setup where the rest of
the body may be cropped out.

The phone should lean securely against a wall with one person in frame. Use a
side view with one shoulder, elbow, and wrist visible; the rest of the body can
be cropped. The green/red readiness icon shows whether the required arm chain is
currently visible. The debug build includes a tracking overlay with angles, frame
rate, and Vision processing time.

Video is processed locally and is not saved. Spoken exercise and repetition
feedback can be muted. The current feature counts a workout session but does not
complete or unlock the daily app-blocking requirement.

The iOS Simulator has no usable camera for Vision testing. Validate placements,
lighting, phone angle, and different users on a physical iPhone. The recognition
engine has deterministic tests for complete and partial reps, speed changes,
tracking gaps, cropped bodies, and false-positive movements.

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
(including midnight). Workout sessions currently do not verify or complete the
daily unlock requirement.

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

The iOS Simulator does not provide a usable camera to this app. Start Workout in
the simulator to inspect the UI; test live pose processing on a physical iPhone.

## Code organization

### Blocked Apps

`BlockedAppsStore.swift` manages selected apps and blocking rules. It saves the
selection, requests Screen Time access, applies restrictions, handles unlocking
after a workout, and sets up the daily reset.

`BlockedAppsView.swift` manages the user interface for selected apps, categories,
websites, lock status, errors, the **Edit** button, and the app picker.

When the view changes `store.selection`, the store saves the selection and updates
blocking. SwiftUI refreshes the view when the store's published state changes.

- **Appearance, text, or buttons:** [`BlockedAppsView.swift`](pushapp-blocker/Features/BlockedApps/BlockedAppsView.swift)
- **Saving selections or blocking/unlocking behavior:** [`BlockedAppsStore.swift`](pushapp-blocker/Features/BlockedApps/BlockedAppsStore.swift)

### Shared daily blocking logic

[`DailyBlocking.swift`](Shared/DailyBlocking.swift) contains the blocking logic
used by both the main app and the `DailyResetMonitor` extension. Xcode includes
this source in both targets so they share one implementation.

- **Main app:** saves selected apps, records workout completion, starts daily
  monitoring, and updates restrictions.
- **Monitor extension:** refreshes restrictions at daily schedule boundaries,
  independently of the app's UI.

[`AppSettings.swift`](Shared/AppSettings.swift) contains the App Group identifier
used by both targets. It must match both targets' entitlements.

`DailyBlocking.swift` also owns the blocking storage keys, monitoring schedule,
named settings store, saved-data migration helpers, daily completion check, and
restriction updates for apps, categories, and web domains. Storage key changes
require a data migration.

The `Shared` folder shares source code; the App Group's `UserDefaults` shares
saved data between the app and extension. The folder name is a convention, not
an Apple requirement.

### Workout feature

The Workout feature uses the iPhone's front camera and Vision body-pose tracking
to recognize push-ups, count repetitions, and provide spoken and on-screen
feedback.

- [`WorkoutView.swift`](pushapp-blocker/Features/Workout/WorkoutView.swift)
  displays setup instructions, the live camera preview, repetition totals,
  tracking status, optional diagnostics, and the completed
  session summary. It also pauses and resumes with the app's scene phase.
- [`WorkoutSessionModel.swift`](pushapp-blocker/Features/Workout/WorkoutSessionModel.swift)
  coordinates the session lifecycle, totals, camera state, orientation, speech
  feedback, and published view state.
- [`WorkoutCamera.swift`](pushapp-blocker/Features/Workout/WorkoutCamera.swift)
  owns camera permission, capture, Vision processing, interruptions, runtime
  errors, device rotation, and `PoseFrame` delivery.
- [`WorkoutPose.swift`](pushapp-blocker/Features/Workout/WorkoutPose.swift)
  defines the push-up arm-joint mapping, pose data, angle thresholds, and
  visibility checks.
- [`WorkoutRecognitionEngine.swift`](pushapp-blocker/Features/Workout/WorkoutRecognitionEngine.swift)
  is the pure temporal push-up classifier. It uses stabilized elbow angles,
  detects a stable down-then-up cycle, and reports tracking status and
  repetitions.

The view starts the session model, which starts the camera. The camera emits
events and valid frames; the model passes frames to the recognition engine, then
updates totals and optionally triggers `WorkoutSpeech`. The recognition engine
has no camera, Vision, speech, persistence, or blocking dependencies.

For changes, use the view for layout and controls, the session model for
lifecycle and camera-event handling, the camera for capture and Vision behavior,
the pose model for exercises and thresholds, and the recognition engine for
repetition detection and tracking states.
