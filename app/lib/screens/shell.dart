// The navigation around the screens: a bar at the bottom on narrow screens
// (phones), a rail on the left on wider ones.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../session.dart';

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
const _me = _Destination('/me', 'Me', Icons.person_outline, Icons.person);

/// The screens under Admin: setting up classes, attributes, units and
/// accounts.
final _underAdmin = RegExp(r'^/(classes|attributes|accounts|units)(/|$)');

/// Whether the screen at [path] is for admins only (ACCOUNTS.md): Admin and
/// what is under it, making and changing locations, and the history of
/// anything but items and stock rows. The router sends others to Items.
bool adminOnly(String path) {
  if (path == '/admin' || _underAdmin.hasMatch(path)) return true;
  if (path == '/locations/new' ||
      RegExp(r'^/locations/[^/]+/edit$').hasMatch(path)) {
    return true;
  }
  return path.startsWith('/history/') &&
      !RegExp(r'^/history/(items|stock)/').hasMatch(path);
}

/// Below this width (logical pixels) the navigation is a bottom bar.
const compactWidth = 600.0;

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  /// The destination a screen belongs to: locations (and their history) to
  /// their tree, classes, attributes, units and accounts (and their history)
  /// to Admin, everything else (items, stock, search results) to Items.
  int _selected(List<_Destination> destinations) {
    var path = location.startsWith('/history/')
        ? location.substring('/history'.length)
        : location;
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
    if (MediaQuery.sizeOf(context).width < compactWidth) {
      return Scaffold(
        body: child,
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
          Expanded(child: child),
        ],
      ),
    );
  }
}
