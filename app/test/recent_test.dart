import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/recent.dart';

void main() {
  bool any(String _) => true;

  test('nothing yet: no default', () {
    final r = Recent();
    expect(r.itemClass(any), isNull);
    expect(r.stockLocation(any), isNull);
  });

  test('the class of the last item, unless a class was made since', () {
    final r = Recent()..itemAdded('drills');
    expect(r.itemClass(any), 'drills');
    r.classMade('saws');
    expect(r.itemClass(any), 'saws');
    r.itemAdded('drills');
    expect(r.itemClass(any), 'drills');
  });

  test('the location stock was last added to, or made since', () {
    final r = Recent()..stockAdded('shelf');
    expect(r.stockLocation(any), 'shelf');
    r.locationMade('box');
    expect(r.stockLocation(any), 'box');
    r.stockAdded('shelf');
    expect(r.stockLocation(any), 'shelf');
  });

  test('one that is gone, or a container, gives way to the other', () {
    final r = Recent()
      ..itemAdded('drills')
      ..classMade('tools');
    expect(r.itemClass((id) => id != 'tools'), 'drills');
    expect(r.itemClass((id) => false), isNull);
  });
}
