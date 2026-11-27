// What was used and made last in this session, for the forms' defaults. It
// is kept in memory only: a new session, or a new start of the app, begins
// with none. The server isn't asked what is new; classes and locations made
// elsewhere (another device, the CLI) aren't counted.

/// The class of the last item added and the last class made, and the
/// location stock was last added to and the last location made; and the
/// parents of the last class and location made, for the next one's
/// (decision 122). (Units are the classes' now, decision 110; whether the
/// last new item had stock is on the account, decision 118.)
class Recent {
  // Each choice is numbered in the order it was made: the default is the
  // later of the two.
  int _count = 0;
  _Choice? _itemClass;
  _Choice? _newClass;
  _Choice? _stockLocation;
  _Choice? _newLocation;

  // The parent of the last class and the last location made: null inside
  // for the top level, and null itself while none was made.
  ({String? id})? _classParent;
  ({String? id})? _locationParent;

  /// An item was added in class [classId].
  void itemAdded(String classId) => _itemClass = _Choice(classId, ++_count);

  /// A class [id] was made below [parent] (null: at the top level).
  void classMade(String id, String? parent) {
    _newClass = _Choice(id, ++_count);
    _classParent = (id: parent);
  }

  void stockAdded(String locationId) =>
      _stockLocation = _Choice(locationId, ++_count);

  /// A location [id] was made in [parent] (null: at the top level). A box
  /// made with compartments counts as one location.
  void locationMade(String id, String? parent) {
    _newLocation = _Choice(id, ++_count);
    _locationParent = (id: parent);
  }

  /// The class for a new item: the last class made, if it was made after
  /// the last item was added, else that item's class. [usable] says whether
  /// a class is still there and may hold items; when the later one isn't,
  /// the other is tried.
  String? itemClass(bool Function(String id) usable) =>
      _latest(_newClass, _itemClass, usable);

  /// The location for new stock, as [itemClass] is chosen.
  String? stockLocation(bool Function(String id) usable) =>
      _latest(_newLocation, _stockLocation, usable);

  /// The parent for a new class: the last one made's, so that classes made
  /// one after another are siblings. The top level (null) when none was
  /// made, or when that parent is gone, as [exists] says.
  String? classParent(bool Function(String id) exists) =>
      _parent(_classParent, exists);

  /// The parent for a new location, as [classParent] is chosen.
  String? locationParent(bool Function(String id) exists) =>
      _parent(_locationParent, exists);

  static String? _parent(
    ({String? id})? made,
    bool Function(String id) exists,
  ) {
    final id = made?.id;
    return id != null && exists(id) ? id : null;
  }

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
