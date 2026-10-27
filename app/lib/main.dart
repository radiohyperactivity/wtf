import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'app.dart';
import 'session.dart';

Future<void> main() async {
  // URLs like /items/1B2C instead of /#/items/1B2C (wtfd answers them with
  // index.html).
  usePathUrlStrategy();
  // Screens opened on top of others (context.push) show their own URL too,
  // so every screen can be bookmarked and reloaded.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session(
    storage: DeviceStorage(),
    webOrigin: kIsWeb ? Uri.parse(Uri.base.origin) : null,
  );
  await session.restore();
  runApp(WtfApp(session: session));
}
