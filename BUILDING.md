# Building WtF

What there is to build, what each part needs, and on which systems it can be built. For setting WtF up, see [README.md](README.md); for the apps' design, [APP.md](APP.md).

| Part | Made with | Built on | Result |
|------|-----------|----------|--------|
| `wtfd`, the server | Go | any system, for every system | one program, with the web app built in |
| `wtf`, the command-line tool | Go | any system, for every system | one program |
| The web app | Flutter | any system | files, built into `wtfd` |
| The Windows app | Flutter | Windows | a folder with `wtf-app.exe` and its libraries |
| The Linux app | Flutter | Linux | a folder, packed as a `.deb` |
| The macOS app | Flutter | macOS | `WtF.app` |
| The iOS app | Flutter | macOS | `Runner.app`, for the simulator or, signed for development, for devices |
| The Android app | Flutter | Windows, Linux or macOS | an `.apk`, signed with its own key |

## Tools

- **Go 1.26 or newer**, the version in `go.mod`.
- **Flutter 3.47.8**, pinned in `app/.fvmrc`. [FVM](https://fvm.app) installs it (`fvm install`, in `app/`) and runs it (`fvm flutter …`); a Flutter of the same version on the PATH does as well.
- **bash**, for the scripts in `scripts/`: on Windows, the one that comes with Git (Git Bash).
- **zip**, for the release's Windows archives.

`flutter doctor` says what else a platform's apps need on the machine at hand.

### Running the scripts on Windows

The scripts are bash scripts. In Git Bash, run them as they are (`scripts/build.sh`). From PowerShell, start them with Git's bash, by its full path:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' scripts/release.sh
```

A plain `bash` in PowerShell is usually `C:\Windows\System32\bash.exe`, WSL's, which runs the script in Linux, without the Windows PATH's Go and Flutter. Git's bash takes the PATH over from PowerShell; `FLUTTER` names Flutter when it isn't on it (`FLUTTER=~/fvm/default/bin/flutter`).

## The server and the command-line tool

```sh
go build ./cmd/wtfd ./cmd/wtf          # here, for this system
go install ./cmd/wtfd ./cmd/wtf        # into ~/go/bin (%USERPROFILE%\go\bin)
```

These have no web app in `wtfd`. Go builds for any system from any system, without anything else installed (`GOOS=linux GOARCH=arm64 go build …`); the programs need no libraries (`CGO_ENABLED=0`).

### With the web app built in

`wtfd` embeds the web app when built with the tag `webapp`, from a copy of the web build in `internal/webapp/dist` (not in git):

```sh
(cd app && flutter build web --release --no-web-resources-cdn)
rm -rf internal/webapp/dist && cp -r app/build/web internal/webapp/dist
go build -tags webapp ./cmd/wtfd
```

`--no-web-resources-cdn` makes Flutter bundle its engine and fonts instead of loading them from Google, which `wtfd`'s Content Security Policy wouldn't allow. The web app makes `wtfd` about 40 MB larger. While working on the web app, `wtfd serve --web-root app/build/web` serves a fresh build without building `wtfd` again.

### The scripts

| Script | Does |
|--------|------|
| `scripts/build.sh` | builds the web app, then `wtf` and `wtfd` (with the web app) for Linux, Windows and macOS, amd64 and arm64, into `dist/<os>-<arch>/`; `NO_WEB_APP=1` leaves the web app out |
| `scripts/release.sh` | runs `build.sh`, and packs each system's `wtf`, `wtfd`, `LICENSE` and a README (`scripts/release-readme.txt`) into `dist/release/`: `.zip` for Windows, `.tar.gz` for Linux and macOS, with the programs executable |
| `scripts/app-build.sh` | runs `flutter build` in `app/` with its arguments (`scripts/app-build.sh windows --release`), stamped with the app's version and the time of the build, which the app shows under Account; the other scripts build the app with it |
| `scripts/windows-server-installer.sh` | after `release.sh`, on Windows: the server's installer, `dist/release/wtf-<version>-windows-setup.exe`, with `wtfd` and `wtf` for x64 and ARM64; see [The server's installer](#the-servers-installer) |
| `scripts/windows-app-installer.sh` | builds the Windows app and its installer, `dist/wtf-app-<version>-windows-x64-setup.exe`; see [Windows](#windows) |
| `scripts/windows-sandbox-test.sh` | after both installers, on Windows: tries them on a clean Windows in Windows Sandbox; see [Trying the installers](#trying-the-installers) |
| `scripts/test.sh` | what CI checks: `gofmt`, `go vet` for every system, and the tests |
| `scripts/ios-signing-setup.sh`, `scripts/ios-device.sh` | sign the iOS app for devices over SSH, build it, and install it; see [iOS](#ios) |
| `scripts/android-signing-setup.sh`, `scripts/android-device.sh` | make the Android app's signing key, build the app, and install it by cable or Wi-Fi; see [Android](#android) |

The version in a release's names is the app's, from `app/pubspec.yaml`. `build.sh` stamps it, and the time of the build, into `wtfd`, which `/api/health` gives and the app shows under Account.

### The server's installer

On Windows, in Git Bash, after `scripts/release.sh`:

```sh
scripts/windows-server-installer.sh
```

It makes `dist/release/wtf-<version>-windows-setup.exe` beside the zips, from `scripts/windows-server-installer.iss`, with [Inno Setup](https://jrsoftware.org/isinfo.php) 6.3 or newer (`ISCC` names its `ISCC.exe` when it isn't where Inno Setup installs it). It takes `wtfd` and `wtf` from `dist/windows-amd64` and `dist/windows-arm64`, and installs the ones for the machine's processor. README.md ("Installing on Windows") says what it does. It isn't signed, so Windows says "Unknown publisher" when it asks for an administrator, and SmartScreen warns about it at first: **More info → Run anyway**.

**Without a window,** for scripts: `/VERYSILENT /SUPPRESSMSGBOXES /LOG=setup.log`, with the answers as parameters (`/database=new|existing`, `/dbhost=`, `/account=`, `/listen=local|network`, `/firewall=yes|no`, and the others the top of `ApplyParameters` in the `.iss` lists) and the passwords in the environment variables `wtfd` reads (`WTFD_ADMIN_DATABASE_PASSWORD` for a new database; `WTFD_DBA_DATABASE_PASSWORD` and `WTFD_API_DATABASE_PASSWORD` for one there already). Nothing is tried before installing; the log ends with "WtF is set up." or says what failed. Without parameters, an upgrade keeps its settings, as it does with the pages.

### Trying the installers

```sh
scripts/windows-sandbox-test.sh [--start-app]
```

runs both installers on a clean Windows, in [Windows Sandbox](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/), which is thrown away afterwards. In the sandbox, `scripts/windows-sandbox-test.ps1` installs and uninstalls the app (and with `--start-app` starts it, to see that it opens), runs a PostgreSQL of its own, and installs the server without a window: a first install with a new database, an upgrade, uninstalling, an existing database with an account and one without, and a wrong password; after each, it checks the service, `/api/health`, the settings, the firewall rule, the PATH and the access to `pgpass.conf`. It prints what it found, and leaves it, with the installers' logs, in `dist/sandbox-test/`. PostgreSQL's programs are downloaded once, into `local/sandbox/`. It doesn't try the pages, only what the installers do, and only on x64.

Windows Sandbox must be turned on once, in an administrator's PowerShell, and Windows restarted:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
```

## The apps

All are built in `app/`, with `flutter build <platform> --release` (or `fvm flutter …`). `scripts/app-build.sh <platform> --release` does the same, and stamps the build with the app's version (`app/pubspec.yaml`) and the time, which the app shows under Account; a build without it says it is a development build. A platform's app can only be built on that platform, except Android's; and only for the machine's own processor, except macOS's, which is built for both Apple silicon and Intel.

### Web

```sh
flutter build web --release --no-web-resources-cdn
```

Into `app/build/web`; see above for building it into `wtfd`.

### Windows

Needs Visual Studio (2022 or newer, the Community edition does) with the "Desktop development with C++" workload.

```sh
flutter build windows --release
```

Into `app\build\windows\x64\runner\Release`: `wtf-app.exe` with the libraries and the `data` folder beside it, which go along wherever it goes. The app's program is `wtf-app`, on Linux too, so that it never clashes with `wtf`, the command-line tool; people see it as "WtF". A build folder from before that name (`wtf`) makes CMake fail with "No target "wtf"": remove `build\windows` (or `build/linux`) once, and build again. The app for Windows on ARM can only be built on Windows on ARM.

`scripts/windows-app-installer.sh`, in Git Bash, builds the app and an installer of it with [Inno Setup](https://jrsoftware.org/isinfo.php) 6.3 or newer (`ISCC` names its `ISCC.exe` when it isn't where Inno Setup installs it), from `scripts/windows-app-installer.iss`: `dist/wtf-app-<version>-windows-x64-setup.exe`. The installer is one file. It installs for the current user, without administrator rights, into `%LOCALAPPDATA%\Programs\WtF` (or for everyone, into Program Files, if chosen), with a Start menu entry and an uninstaller under Settings → Apps; a new version installs over the old one, and the app's settings stay. It includes the Microsoft C++ runtime from Visual Studio, so the app starts on a PC without it. The installer isn't signed, so Windows SmartScreen warns about it at first: **More info → Run anyway**.

### Android

Needs the Android SDK, with the NDK version Flutter asks for: the newer command-line tools don't let Gradle install it by itself, so install it with `sdkmanager` or `android sdk install ndk/<version>`.

```sh
flutter build apk --release
```

Into `app/build/app/outputs/flutter-apk/app-release.apk`, for Android 7.0 (API 24) and later.

**Signing:** release builds are signed with the app's own key when Gradle finds it: `local/android/key.properties` (not in git), or the file `WTF_ANDROID_KEY_PROPERTIES` names, with the keystore beside it. `scripts/android-signing-setup.sh` makes them once, with a random password that nothing prints; it needs `keytool`, from a JDK (Android Studio's is found). Back that folder up: Android only updates an app with one signed by the same key, on devices and on Google Play. Without the key, the build is signed with the debug key of the machine at hand, which is fine for trying it out.

**On a device:**

```sh
scripts/android-device.sh                    # a release build only
scripts/android-device.sh <serial number>    # and install it on the device
```

The device is named by its serial number (`adb devices -l`, or Settings, About phone), and found by cable or over Wi-Fi. For Wi-Fi, turn on Developer options and, in them, **Wireless debugging** (Android 11 and later); pair the computer once with **Pair device with pairing code**, which shows an address and a code for `adb pair <address> <code>`. After that the script finds the device on the network by itself, as long as wireless debugging is on (Android turns it off after a restart, and on another network). The script installs, keeping the app's data, and doesn't start the app. An app signed with another key (the debug key, say) has to be uninstalled first, which loses its login.

On Windows, Kotlin's incremental compilation is off (`kotlin.incremental=false` in `app/android/gradle.properties`): its caches fail when the project and Flutter's package cache are on different drives.

### Linux

Needs what `flutter doctor` lists for Linux (clang, CMake, Ninja, pkg-config and GTK 3's headers), and `libsecret-1-dev`, which keeps the login.

```sh
flutter build linux --release
scripts/build-deb.sh
```

The first builds into `app/build/linux/x64/release/bundle`. The second builds that too, and packs it as `dist/wtf-app_<version>_<arch>.deb`, for Debian, Ubuntu and their relatives: the app goes in `/opt/wtf` (the program is `/opt/wtf/wtf-app`), with a launcher entry and an icon. Package and program are called `wtf-app`, as `wtf` is the command-line tool.

### macOS

Needs Xcode. The plugins come through Swift Package Manager; CocoaPods may still be wanted by Flutter's tooling.

```sh
flutter build macos --release
```

Into `app/build/macos/Build/Products/Release/WtF.app`, for Apple silicon and Intel both. To pack it, use `ditto -c -k --keepParent WtF.app WtF.zip`, which keeps the links inside the app that other zip tools may break.

### iOS

Needs Xcode. For the simulator:

```sh
flutter build ios --simulator --debug
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted io.bbj.wtf
```

For real iPhones and iPads, the app is signed for development with the team in the Xcode project (`DEVELOPMENT_TEAM`, an Apple Developer Program membership), and Xcode's automatic signing. To set a Mac up:

1. Sign Xcode in to the membership's Apple Account (Settings, Accounts).
2. Connect the device with a cable once, trust the Mac on it, and turn on Developer Mode on it (Settings, Privacy & Security).
3. Open `app/ios/Runner.xcworkspace`, and in the Runner target's Signing & Capabilities let Xcode make the certificate and the profile; it registers the device as well. If it says the account already has a certificate whose key isn't on this Mac, revoke it there and it makes a new one.
4. Run `scripts/ios-signing-setup.sh` in Terminal on the Mac, once (and again when Xcode makes a new certificate, about once a year).

Then, also over SSH:

```sh
scripts/ios-device.sh                 # a release build, into build/ios/iphoneos/Runner.app
scripts/ios-device.sh <device>        # and install it on the device
```

The device is its identifier or name from `xcrun devicectl list devices`. Once paired by cable, Xcode also reaches it over Wi-Fi, without the cable, when it is awake and on the same network as the Mac: `xcrun devicectl list devices` shows it as connected, and `xcrun devicectl device info details --device <device>` gives its transport as `localNetwork` rather than `wired`. Xcode 27 manages devices in DeviceHub (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`), which also shows the simulator; there is no Devices and Simulators window any more. The script installs the app and doesn't start it. A debug build on a device only starts from the debugger, hence the release build.

Over SSH, the login keychain stays locked even when it is unlocked on the Mac's screen, and codesign fails with `errSecInternalComponent`. So `ios-signing-setup.sh` moves the certificate and its key to a keychain of their own, `wtf-signing`, with a random password kept in `~/.config/wtf/signing-keychain-password`, and `ios-device.sh` unlocks it before building. That keychain is locked again after a restart; a build from Xcode before any `ios-device.sh` asks for its password, the one in that file.

TestFlight and the App Store are still to come.

## Tests

```sh
go test ./...                 # the server and the command-line tool
scripts/test.sh               # the same, as CI runs it
(cd app && flutter test)      # the apps
```

The integration tests need a test database: see "Tests" in [README.md](README.md#tests).
