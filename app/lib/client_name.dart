// What the native apps call themselves when logging in, for the list of
// sessions: the device's name where it has a useful one, and its system.
// The web app's is in client_name_web.dart.

import 'dart:io';

String clientName() {
  final system = switch (Platform.operatingSystem) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    final other => other,
  };
  // Phones mostly answer "localhost", which tells nothing.
  final host = Platform.localHostname;
  return host.isEmpty || host == 'localhost'
      ? 'WtF on $system'
      : 'WtF on $host ($system)';
}
