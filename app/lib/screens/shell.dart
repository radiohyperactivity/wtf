// The navigation around the screens: a bar at the bottom on narrow screens
// (phones), a rail on the left on wider ones.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../camera.dart';
import '../session.dart';
import '../widgets/common.dart';

class _Destination {
  const _Destination(this.path, this.label, this.icon, this.selectedIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _items = _Destination(
  '/',
  'Items',
  Icons.inventory_2_outlined,
  Icons.inventory_2,
);
const _locations = _Destination(
  '/locations',
  'Locations',
  Icons.place_outlined,
  Icons.place,
);
const _admin = _Destination(
  '/admin',
  'Admin',
  Icons.admin_panel_settings_outlined,
  Icons.admin_panel_settings,
);
const _me = _Destination('/me', 'Account', Icons.person_outline, Icons.person);

/// The screens under Admin: setting up classes and accounts.
final _underAdmin = RegExp(r'^/(classes|accounts)(/|$)');

/// Whether the screen at [path] is for admins only (ACCOUNTS.md): Admin and
/// what is under it, and making and changing locations. The router sends
/// others to Items.
bool adminOnly(String path) =>
    path == '/admin' ||
    _underAdmin.hasMatch(path) ||
    path == '/locations/new' ||
    RegExp(r'^/locations/[^/]+/edit$').hasMatch(path);

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  /// The destination a screen belongs to: locations to their tree, classes
  /// and accounts to Admin, everything else (items, stock, search results)
  /// to Items.
  int _selected(List<_Destination> destinations) {
    var path = location;
    if (_underAdmin.hasMatch(path)) path = '/admin';
    final i = destinations.lastIndexWhere(
      (d) => path == d.path || d.path != '/' && path.startsWith('${d.path}/'),
    );
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    // Admin only for admins: users and viewers keep the inventory, they
    // don't set it up.
    final destinations = [
      _items,
      _locations,
      if (context.watch<Session>().isAdmin) _admin,
      _me,
    ];
    final selected = _selected(destinations);
    void select(int i) => context.go(destinations[i].path);
    // While another session is this one's camera, a bar under the screen
    // says so.
    final camera = context.watch<Camera>().cameraClient;
    // When the server's API revision and the app's differ, a bar above the
    // screen says so, until it is confirmed.
    final session = context.watch<Session>();
    final revisions = session.revisionWarning;
    final body = camera == null && !revisions
        ? child
        : Column(
            children: [
              if (revisions) _RevisionBar(session.serverRevision!),
              // Under the bar, the screen leaves no room for the status bar:
              // the bar does.
              Expanded(
                child: revisions
                    ? MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        child: child,
                      )
                    : child,
              ),
              ?(camera == null ? null : _CameraBar(camera)),
            ],
          );
    if (MediaQuery.sizeOf(context).width < compactWidth) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: select,
          destinations: [
            for (final d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selected,
            onDestinationSelected: select,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// "Camera: WtF on iPhone" (decision 9): photos taken there go to what this
/// app has open.
class _CameraBar extends StatelessWidget {
  const _CameraBar(this.client);

  final String client;

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    return Material(
      color: colours.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.photo_camera_outlined,
              size: 20,
              color: colours.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Camera: ${client.isEmpty ? 'another session' : client}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colours.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The server's API and the app's are of different revisions (decision
/// 104): which side to update, until OK confirms it.
class _RevisionBar extends StatelessWidget {
  const _RevisionBar(this.server);

  /// The server's revision.
  final int server;

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    final text = server < apiRevision
        ? "The server's API is older than this app's (revision $server, the "
              "app's $apiRevision): what the app has that the server lacks "
              "won't work. Update the server (wtfd)."
        : "The server's API is newer than this app's (revision $server, the "
              "app's $apiRevision): the app works, without what the server "
              "has added since. Update the app.";
    return Material(
      color: colours.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                Icons.sync_problem_outlined,
                size: 20,
                color: colours.onTertiaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: colours.onTertiaryContainer),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => context.read<Session>().confirmRevisions(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
