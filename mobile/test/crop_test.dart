import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spektralab_mobile/collage.dart';
import 'package:spektralab_mobile/crop.dart';

void main() {
  test('a preset ratio fits the largest centred rect', () {
    // 1:1 in a 3:2 photo: full height, two thirds of the width.
    final r = Crop.fit(1, 1.5);
    expect(r.width, closeTo(2 / 3, 1e-9));
    expect(r.height, 1);
    expect(r.left, closeTo(1 / 6, 1e-9));
    // The result has the chosen ratio.
    expect(const Crop().copyWith(rect: r).aspect(1.5), closeTo(1, 1e-9));
    // A quarter turn swaps the sides.
    expect(const Crop(turns: 1).turnedAspect(1.5), closeTo(2 / 3, 1e-9));
  });

  test('every template has one cell per photo, inside the frame', () {
    for (var n = 2; n <= 9; n++) {
      for (final (name, cells) in templatesFor(n)) {
        expect(cells.length, n, reason: '$n $name');
        for (final c in cells) {
          expect(const Rect.fromLTWH(0, 0, 1, 1).inflate(1e-9).contains(c.topLeft), true, reason: '$n $name');
          expect(c.right <= 1 + 1e-9 && c.bottom <= 1 + 1e-9, true, reason: '$n $name');
        }
      }
    }
  });
}
