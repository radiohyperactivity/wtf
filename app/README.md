# WtF apps

The Flutter app for every platform. Its design is described in [APP.md](../APP.md).

```sh
fvm flutter pub get              # fetch the packages
fvm flutter run -d windows       # run the Windows app, with hot reload
fvm flutter test                 # run the tests
fvm flutter build web --no-web-resources-cdn   # the web app, for wtfd --web-root
```

The Flutter version is pinned in `.fvmrc`; FVM installs it (`fvm install`).
