import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class Print {
  final Uint8List image;
  final Uint8List? original; // only on a fresh decode
  final String info;
  Print(this.image, this.original, this.info);
}

/// The film engine. On iPhone: ios/Runner/AppDelegate.swift over a method
/// channel. Anywhere else (the Chrome design preview) a stand-in that shows
/// the picked photos unprocessed, so layout can be designed without a phone.
class Engine {
  static const _channel = MethodChannel('spektralab/engine');
  static final bool isPreview = kIsWeb || defaultTargetPlatform != TargetPlatform.iOS;

  static Print _print(Map m) => Print(
        m['print'],
        m['original'],
        '${m['width']}×${m['height']} · ${(m['ms'] as num).round()} ms',
      );

  static final _previewPhotos = <String, Uint8List>{};
  static String? _previewOpen;

  /// Pick photos from the library: (id, thumbnail) each, in picking order.
  static Future<List<(String, Uint8List)>> pick() async {
    if (isPreview) {
      final files = await openFiles(acceptedTypeGroups: [
        const XTypeGroup(label: 'images', extensions: ['jpg', 'jpeg', 'png', 'webp']),
      ]);
      return [
        for (final f in files)
          await f.readAsBytes().then((b) {
            final id = '${f.name}#${_previewPhotos.length}';
            _previewPhotos[id] = b;
            return (id, b);
          }),
      ];
    }
    final m = await _channel.invokeMethod<Map>('pick');
    return [for (final p in m?['photos'] ?? []) (p['id'] as String, p['thumb'] as Uint8List)];
  }

  /// Make photo [id] the engine's session and print it with [params].
  static Future<Print> open(String id, Map<String, Object> params) async {
    if (isPreview) {
      final fresh = _previewOpen != id;
      _previewOpen = id;
      await Future.delayed(Duration(milliseconds: fresh ? 900 : 700));
      final b = _previewPhotos[id]!;
      return Print(b, fresh ? b : null, 'preview · no engine');
    }
    return _print((await _channel.invokeMethod<Map>('open', {'id': id, 'params': params}))!);
  }

  /// Re-print the open photo. [film] false reuses the cached negative: only
  /// the paper changed.
  static Future<Print> render(Map<String, Object> params, {required bool film}) async {
    if (isPreview) {
      await Future.delayed(Duration(milliseconds: film ? 700 : 250));
      return Print(_previewPhotos[_previewOpen]!, null, 'preview · no engine');
    }
    return _print((await _channel.invokeMethod<Map>('render', {'params': params, 'film': film}))!);
  }

  /// Save the last print to Photos.
  static Future<void> save() async {
    if (isPreview) return Future.delayed(const Duration(milliseconds: 300));
    await _channel.invokeMethod('save');
  }

  static Future<void> remove(String id) async {
    if (isPreview) {
      _previewPhotos.remove(id);
      return;
    }
    await _channel.invokeMethod('remove', {'id': id});
  }
}
