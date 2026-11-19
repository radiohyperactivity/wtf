// The phone as a remote camera (2026-11-19-remote-camera.md). On a phone,
// the app can be the camera for another session of the account, on a
// desktop: it then shows only the camera screen, asks the server what that
// session has open, and uploads photos for it. Every other app listens to
// the server's events, says what it has open while it has a camera, and
// loads its screen again when the camera changes something.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'api/models.dart';
import 'session.dart';
import 'widgets/common.dart';
import 'widgets/files.dart';

/// How long to wait before connecting again after the stream failed, the
/// first time, the second, and so on.
const _retryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// How often the camera asks what the photo would be for, while it is in
/// the foreground (decision 17).
const cameraPoll = Duration(seconds: 3);

/// The forms for a new item, stock row or location, not saved yet
/// (decision 6).
final _newForm = RegExp(r'^/(items|stock|locations)/new$');

/// An item, stock row or location, shown or edited (decision 5).
final _openOne = RegExp(r'^/(items|stock|locations)/([^/]+)(?:/edit)?$');

/// The type of target of each of those paths.
const _types = {'items': 'item', 'stock': 'stock', 'locations': 'location'};

/// A photo taken or chosen on the camera, and how sending it went.
class CameraShot {
  CameraShot(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
  bool sending = false;

  /// What it went to, once sent.
  CameraTarget? sentTo;

  /// Why it wasn't sent; it can be sent again (decision 18).
  String? error;
}

class Camera extends ChangeNotifier {
  /// [closesInBackground]: phones close the stream while the app is in the
  /// background, and open it again when it comes back; the camera asks
  /// only in the foreground.
  Camera({required this.session, bool? closesInBackground}) {
    _restore().whenComplete(() {
      _restored = true;
      _update();
    });
    session.addListener(_sessionChanged);
    if (closesInBackground ??
        !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS)) {
      _lifecycle = AppLifecycleListener(onPause: _paused, onResume: _resumed);
    }
    _sessionChanged();
  }

  final Session session;

  /// For messages from here, outside any screen.
  final messenger = GlobalKey<ScaffoldMessengerState>();

  // --- This app as a camera ---

  /// The session this app is the camera for; null when it is none.
  CameraPairing? pairing;

  /// What a photo would be for; null until known.
  CameraTarget? target;

  /// The server didn't answer the last time it was asked.
  bool unreachable = false;

  /// The last photo taken or chosen.
  CameraShot? shot;

  // --- This app with a camera ---

  /// What the app that is this one's camera calls itself; null when it has
  /// none (decision 9).
  String? cameraClient;

  bool _restored = false; // the stored camera has been read
  AppLifecycleListener? _lifecycle;
  ApiClient? _client; // the client of the logged-in session
  GoRouter? _router;
  StreamSubscription<ServerEvent>? _events;
  Timer? _retry;
  Timer? _poll;
  int _attempt = 0;
  int _generation = 0; // a connection newer than this one ends it
  bool _foreground = true;
  bool _disposed = false;

  /// The item, stock row or location the screen on top shows, as it said:
  /// its path ("/items/1B2C") and what it is.
  (String, CameraTarget)? _shown;
  CameraTarget _here = CameraTarget.none;
  CameraTarget? _sent; // what the server was told last

  Future<void> _restore() async {
    final stored = await session.storage.readCamera();
    if (stored == null) return;
    try {
      pairing = CameraPairing.fromJson(jsonDecode(stored) as Json);
      notifyListeners();
    } catch (_) {
      await session.storage.writeCamera(null);
    }
  }

  /// Follows the routes of [router], to say what this app has open.
  void attach(GoRouter router) {
    _router = router;
    router.routerDelegate.addListener(_routeChanged);
  }

  /// Makes this app the camera for the session [id] (decision 1), and
  /// remembers it.
  Future<void> start(String id) async {
    final client = session.client;
    pairing = await client.cameraFor(id);
    target = null;
    shot = null;
    unreachable = false;
    await session.storage.writeCamera(jsonEncode(pairing!.toJson()));
    notifyListeners();
    _update();
  }

  /// This app is no camera any more (decision 2).
  Future<void> stop() async {
    _forget(null);
    try {
      await _client?.cameraStop();
    } on ApiProblem {
      // The camera ends by itself once the phone stays away for 12 hours.
    }
  }

  void _forget(String? message) {
    pairing = null;
    target = null;
    shot = null;
    notifyListeners();
    session.storage.writeCamera(null);
    if (message != null) {
      messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    }
    _update();
  }

  /// What the phone says when no photo can be taken for [target]
  /// (decisions 6 and 7); null when one can.
  static String? notReady(CameraTarget target) => target.ready
      ? null
      : target.waiting != null
      ? 'Save the ${CameraTarget.kind(target.waiting)} on the PC first'
      : 'Open an item on the PC';

  /// Asks the server what a photo would be for.
  Future<void> refresh() async {
    final client = _client;
    final p = pairing;
    if (client == null || p == null) return;
    try {
      final now = await client.cameraTarget(p.session);
      if (!identical(p, pairing)) return;
      if (now != target || unreachable) {
        target = now;
        unreachable = false;
        notifyListeners();
      }
    } on ApiProblem catch (e) {
      if (!identical(p, pairing)) return;
      _problem(e);
    }
  }

  void _problem(ApiProblem e) {
    switch (e.status) {
      case 401:
        session.ended();
      case 400 || 404:
        _forget(
          "${pairing?.label ?? 'The other session'} isn't logged in "
          'any more: no longer its camera.',
        );
      case 0:
        if (!unreachable) {
          unreachable = true;
          notifyListeners();
        }
    }
  }

  /// Takes a photo with the camera, and sends it.
  Future<void> takePhoto() async {
    final picked = await takeCameraPhoto();
    if (picked != null) await _take(picked);
  }

  /// Chooses a photo on the device, and sends it.
  Future<void> choosePhoto() async {
    final picked = await pickUploadFile(image: true);
    if (picked != null) await _take(picked);
  }

  Future<void> _take(PickedFile picked) async {
    shot = CameraShot(picked.$1, Uint8List.fromList(await picked.$2()));
    notifyListeners();
    await send();
  }

  /// Sends the last photo, again after it failed (decision 18). The server
  /// puts it on what the desktop has open as it arrives (decision 12).
  Future<void> send() async {
    final s = shot;
    final client = _client;
    final p = pairing;
    if (s == null || client == null || p == null || s.sending) return;
    s
      ..sending = true
      ..error = null;
    notifyListeners();
    try {
      final to = await client.cameraPhoto(
        p.session,
        name: s.name,
        bytes: s.bytes,
      );
      s.sentTo = to;
      target = to;
      unreachable = false;
    } on ApiProblem catch (e) {
      if (e.status == 409) {
        // What is open there changed meanwhile: say what is now.
        await refresh();
        s.error = notReady(target ?? CameraTarget.none) ?? errorText(e);
      } else {
        s.error = errorText(e);
        _problem(e);
      }
    } catch (e) {
      s.error = errorText(e);
    } finally {
      s.sending = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Says that the screen for [path] shows [target], an item, stock row or
  /// location; the screens do, once they've loaded it.
  void shows(String path, CameraTarget target) {
    _shown = (path, target);
    _routeChanged();
  }

  void _sessionChanged() {
    final client = session.me == null ? null : session.client;
    if (identical(client, _client)) return;
    _client = client;
    _sent = null;
    if (cameraClient != null) {
      cameraClient = null;
      notifyListeners();
    }
    _update();
  }

  void _paused() {
    _foreground = false;
    _update();
  }

  void _resumed() {
    _foreground = true;
    _attempt = 0;
    _update();
  }

  /// Starts or stops what this app does in its state: as a camera, asking
  /// what a photo would be for; otherwise listening to the event stream;
  /// in the background, neither.
  void _update() {
    // At once, so that a pause and a resume close together each take
    // effect; until the stored camera is read, once it is.
    if (!_restored || _disposed) return;
    final active = _client != null && _foreground;
    if (active && pairing != null) {
      _disconnect();
      if (_poll == null) {
        _poll = Timer.periodic(cameraPoll, (_) => refresh());
        refresh();
      }
    } else {
      _poll?.cancel();
      _poll = null;
      if (active) {
        if (_events == null && _retry == null) _connect();
      } else {
        _disconnect();
      }
    }
  }

  /// Opens the event stream.
  Future<void> _connect() async {
    _disconnect();
    final generation = _generation;
    final client = _client;
    if (client == null) return;
    try {
      final stream = await client.events();
      if (generation != _generation) {
        stream.listen(null).cancel();
        return;
      }
      // The server says at once when this session has a camera.
      _camera(null);
      _events = stream.listen(
        (event) {
          _attempt = 0;
          _handle(event);
        },
        onError: (_) => _retryLater(generation),
        onDone: () => _retryLater(generation),
        cancelOnError: true,
      );
    } on ApiProblem catch (e) {
      if (e.status == 401) {
        session.ended();
        return;
      }
      _retryLater(generation);
    } catch (_) {
      _retryLater(generation);
    }
  }

  void _retryLater(int generation) {
    if (generation != _generation || _disposed) return;
    _events = null;
    final delay = _retryDelays[min(_attempt, _retryDelays.length - 1)];
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }

  void _disconnect() {
    _generation++;
    _events?.cancel();
    _events = null;
    _retry?.cancel();
    _retry = null;
  }

  void _handle(ServerEvent event) {
    switch (event.name) {
      case 'camera':
        // {} when it has none; a camera's app may have no name.
        _camera(
          event.data.containsKey('client')
              ? event.data['client'] as String? ?? ''
              : null,
        );
      case 'changed':
        final path = event.data['path'];
        if (path is String) _client?.noteRemoteChange(path);
      case 'ended':
        session.ended();
    }
  }

  /// This session has a camera, which calls itself [client], or none
  /// (null). With one, the server is told what is open.
  void _camera(String? client) {
    if (client == cameraClient) return;
    cameraClient = client;
    _sent = null;
    notifyListeners();
    _report();
  }

  /// The path of the screen on top, opened by go or by push.
  String _path() {
    final router = _router;
    if (router == null || router.routerDelegate.currentConfiguration.isEmpty) {
      return '';
    }
    return router.state.uri.path;
  }

  /// Works out what is open from the screen on top (decisions 5 to 7).
  void _routeChanged() {
    final path = _path();
    var here = CameraTarget.none;
    if (_newForm.firstMatch(path) case final m?) {
      here = CameraTarget.waiting(_types[m[1]]!);
    } else if (_openOne.firstMatch(path) case final m?) {
      final shown = _shown;
      if (shown != null && shown.$1 == '/${m[1]}/${m[2]}') here = shown.$2;
    }
    if (here != _here) {
      _here = here;
      _report();
    }
  }

  /// Tells the server what is open, while this session has a camera.
  void _report() {
    final client = _client;
    if (client == null || cameraClient == null || pairing != null) return;
    if (_here == _sent) return;
    final here = _sent = _here;
    client.putTarget(here).catchError((_) {
      // Told again with the next change, or when the stream opens again.
      if (_sent == here) _sent = null;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _disconnect();
    _poll?.cancel();
    session.removeListener(_sessionChanged);
    _router?.routerDelegate.removeListener(_routeChanged);
    _lifecycle?.dispose();
    super.dispose();
  }
}

/// Says that this screen shows an item, stock row or location, for the
/// camera of this app's session: the screen at [path] shows [target].
class CameraSubject extends StatefulWidget {
  const CameraSubject({
    super.key,
    required this.path,
    required this.target,
    required this.child,
  });

  final String path;
  final CameraTarget target;
  final Widget child;

  @override
  State<CameraSubject> createState() => _CameraSubjectState();
}

class _CameraSubjectState extends State<CameraSubject> {
  late final Camera _camera = context.read<Camera>();

  @override
  void initState() {
    super.initState();
    _camera.shows(widget.path, widget.target);
  }

  @override
  void didUpdateWidget(CameraSubject old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.target != widget.target) {
      _camera.shows(widget.path, widget.target);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
