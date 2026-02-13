# Testing the Drowsiness Guide App on Android Emulator

This guide walks through setting up Android Studio, creating an emulator, and running the Flutter app from VS Code (or Cursor) for testing.

---

## Prerequisites

- **Flutter** installed and on your PATH ([flutter.dev](https://flutter.dev))
- **VS Code** or **Cursor** with the Flutter extension installed
- **Android Studio** (for SDK and emulator only; you can use VS Code/Cursor to run the app)

---

## Part 1: Install Android Studio & SDK

1. Download and install [Android Studio](https://developer.android.com/studio).
2. Open Android Studio and complete the setup wizard if it’s your first run.
3. In Android Studio:
   - Go to **More Actions** → **SDK Manager** (or **Tools** → **SDK Manager**).
   - On the **SDK Platforms** tab, ensure at least one Android version is installed (e.g. **Android 14** or **API 34**). Install one if needed.
   - Switch to the **SDK Tools** tab.
   - Check **Android SDK Command-line Tools (latest)**.
   - Click **Apply** / **OK** and wait for the install to finish.

---

## Part 2: Install Android SDK Licenses

1. Open a terminal **in your project** (e.g. in VS Code/Cursor: **Terminal** → **New Terminal**, or `` Ctrl+` ``).
2. Go to the project root:
   ```bash
   cd path/to/drowsiness_guide
   ```
3. Run:
   ```bash
   flutter doctor --android-licenses
   ```
4. When prompted for each license, type `y` and press Enter until all are accepted.

---

## Part 3: Verify Flutter Setup

1. In the same terminal, run:
   ```bash
   flutter doctor
   ```
2. You want to see something like:
   ```text
   [✓] Flutter (Channel stable, ...)
   [✓] Android toolchain - develop for Android devices (Android SDK version 36.x.x)
   [✓] Android Studio
   [✓] VS Code (or Cursor)
   ```
3. If **Android toolchain** still shows issues:
   - **cmdline-tools missing**: Install them in Android Studio (SDK Manager → SDK Tools) as in Part 1.
   - **License status unknown**: Run `flutter doctor --android-licenses` again (Part 2).

---

## Part 4: Create an Android Virtual Device (Emulator)

1. In Android Studio, go to **More Actions** → **Virtual Device Manager** (or **Tools** → **Device Manager**).
2. Click **Create Device** (or **Create Virtual Device**).
3. Choose a phone (e.g. **Pixel 6**) → **Next**.
4. Select a system image (e.g. **API 34**). If needed, click **Download** next to it, then **Next**.
5. Name the AVD if you like → **Finish**.

Your emulator is now listed in the Device Manager.

---

## Part 5: Run the App from VS Code / Cursor

### Start the emulator

- **From Android Studio**: In **Device Manager**, click the **Play** button next to your AVD (e.g. Pixel 6).
- **From terminal** (optional):
  ```bash
  flutter emulators
  flutter emulators --launch <emulator_id>
  ```

Wait until the emulator is fully booted (you see the home screen).

### Run the Flutter app

1. Open the project in **VS Code** or **Cursor** (e.g. open the `drowsiness_guide` folder).
2. Select the **device**:
   - In the status bar at the bottom, click the device name (it might say "Chrome" or "No device").
   - Choose your **Android emulator** (e.g. `Pixel 6 API 34` or `emulator-5554`).  
     Do **not** select Chrome if you want to test on Android.
3. Start the app:
   - Press **F5** to run with debugging, or  
   - Open the terminal (`` Ctrl+` ``) and run:
     ```bash
     flutter run
     ```
     Flutter will use the currently selected device.

The app will build and launch on the emulator. Use the app as normal (e.g. tap **DROWSINESS DETECTED** to open the gas stations page).

### Run from terminal only (no device selector)

```bash
flutter devices
flutter run -d <device_id>
```

Example: `flutter run -d emulator-5554`.

---

## Troubleshooting

| Problem | What to do |
|--------|------------|
| **Android toolchain – cmdline-tools missing** | Android Studio → SDK Manager → SDK Tools → enable **Android SDK Command-line Tools** → Apply. |
| **Android license status unknown** | Run `flutter doctor --android-licenses` and accept all licenses. |
| **No devices found** | Start the emulator from Android Studio (Device Manager → Play). Wait for it to boot, then run `flutter devices`. |
| **App runs in Chrome instead of emulator** | In VS Code/Cursor, use the device selector in the status bar and pick the Android emulator, then run again. |
| **Build errors** | Run `flutter clean` then `flutter pub get`, then `flutter run` again. |

---

## Quick reference

- **Check setup:** `flutter doctor`
- **Accept Android licenses:** `flutter doctor --android-licenses`
- **List devices:** `flutter devices`
- **List emulators:** `flutter emulators`
- **Run on default device:** `flutter run`
- **Run on specific device:** `flutter run -d <device_id>`

---

*This app is intended to be tested on Android (and iOS). Running in Chrome may cause CORS issues with the Google Places API; use the Android emulator or a physical device for full functionality.*
