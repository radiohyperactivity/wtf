// What was used and made last in this session, for the forms' defaults. It
// is kept in memory only: a new session, or a new start of the app, begins
// with none. The server isn't asked what is new; classes and locations made
// elsewhere (another device, the CLI) aren't counted.

/// The class of the last item added and the last class made, the location
/// stock was last added to and the last location made, and the unit last
/// given to an item of each class.
class Recent {
  // Each choice is numbered in the order it was made: the default is the
  // later of the two.
  int _count = 0;
  _Choice? _itemClass;
  _Choice? _newClass;
  _Choice? _stockLocation;
  _Choice? _newLocation;
  final Map<String, String> _units = {};

  /// An item was added in class [id], with stock counted in [unit] (null:
  /// pieces).
  void itemAdded(String classId, String? unit) {
    _itemClass = _Choice(classId, ++_count);
    if (unit == null) {
      _units.remove(classId);
    } else {
      _units[classId] = unit;
    }
  }

  void classMade(String id) => _newClass = _Choice(id, ++_count);

  void stockAdded(String locationId) =>
      _stockLocation = _Choice(locationId, ++_count);

  void locationMade(String id) => _newLocation = _Choice(id, ++_count);

  /// The class for a new item: the last class made, if it was made after
  /// the last item was added, else that item's class. [usable] says whether
  /// a class is still there and may hold items; when the later one isn't,
  /// the other is tried.
  String? itemClass(bool Function(String id) usable) =>
      _latest(_newClass, _itemClass, usable);

  /// The location for new stock, as [itemClass] is chosen.
  String? stockLocation(bool Function(String id) usable) =>
      _latest(_newLocation, _stockLocation, usable);

  /// The unit last given to an item of class [classId]; null for none, or
  /// pieces.
  String? unit(String classId) => _units[classId];

  static String? _latest(
    _Choice? a,
    _Choice? b,
    bool Function(String id) usable,
  ) {
    final both = [?a, ?b]..sort((x, y) => y.order.compareTo(x.order));
    for (final c in both) {
      if (usable(c.id)) return c.id;
    }
    return null;
  }
}

class _Choice {
  const _Choice(this.id, this.order);

  final String id;
  final int order;
}
