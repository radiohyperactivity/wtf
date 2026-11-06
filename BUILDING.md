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
| The iOS app | Flutter | macOS | for the simulator, so far |
| The Android app | Flutter | Windows, Linux or macOS | an `.apk` |

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
| `scripts/test.sh` | what CI checks: `gofmt`, `go vet` for every system, and the tests |

The version in a release's names is the app's, from `app/pubspec.yaml`.

## The apps

All are built in `app/`, with `flutter build <platform> --release` (or `fvm flutter …`). A platform's app can only be built on that platform, except Android's; and only for the machine's own processor, except macOS's, which is built for both Apple silicon and Intel.

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

### Android

Needs the Android SDK, with the NDK version Flutter asks for: the newer command-line tools don't let Gradle install it by itself, so install it with `sdkmanager` or `android sdk install ndk/<version>`.

```sh
flutter build apk --release
```

Into `app/build/app/outputs/flutter-apk/app-release.apk`, for Android 7.0 (API 24) and later. It is **signed with Flutter's debug key**, which is fine for installing directly, but not for Google Play; a signing key of its own is still to come.

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

Needs Xcode. So far only for the simulator:

```sh
flutter build ios --simulator --debug
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted io.bbj.wtf
```

A build for real iPhones and iPads, and TestFlight, need an Apple Developer Program membership and signing, which are still to come.

## Tests

```sh
go test ./...                 # the server and the command-line tool
scripts/test.sh               # the same, as CI runs it
(cd app && flutter test)      # the apps
```

The integration tests need a test database: see "Tests" in [README.md](README.md#tests).
