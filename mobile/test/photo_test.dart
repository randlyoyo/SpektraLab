import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spektralab_mobile/photo.dart';
import 'package:spektralab_mobile/stocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(Stock.load);

  test('sync copies only the chosen groups', () {
    const from = Settings(film: 'fujifilm_velvia_100', paper: 'kodak_2383', exposure: 1.5, grain: false);
    const to = Settings(exposure: -1, halation: false);
    final s = to.syncedFrom(from, {Group.film, Group.effects});
    expect(s.film, 'fujifilm_velvia_100');
    expect(s.paper, to.paper);
    expect(s.exposure, -1);
    expect((s.grain, s.halation), (false, true));
  });

  test('a slide film is scanned, and edits mark a photo edited', () {
    expect(const Settings(film: 'fujifilm_velvia_100').params['scan_film'], true);
    expect(const Settings().params['scan_film'], false);
    final p = Photo('a', Uint8List(0));
    expect(p.edited, false);
    p.settings = p.settings.copyWith(exposure: 0.3);
    expect(p.edited, true);
  });
}
