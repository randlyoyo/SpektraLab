import 'dart:convert';

import 'package:flutter/services.dart';

/// One film or paper from the Mac app's `Resources/StockCatalog.json`
/// (copied to assets/; re-copy when the Mac catalog changes).
class Stock {
  final String id, name, stage, use;
  final String? type, cover;
  final bool monochrome;

  Stock.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        stage = j['stage'],
        use = j['use'],
        type = j['type'],
        cover = j['cover'],
        monochrome = j['monochrome'] ?? false;

  bool get isFilm => stage == 'filming';
  bool get isPositive => type == 'positive';
  bool get isCine => use == 'cine';

  String get brand => name.split(' ').first;

  /// The name without the brand: "Portra 400", "Vision3 250D".
  String get shortName => name.substring(brand.length).trim();

  static late final List<Stock> all;

  static Future<void> load() async {
    final j = jsonDecode(await rootBundle.loadString('assets/StockCatalog.json'));
    // Black and white is behind a feature flag on the Mac too.
    all = [for (final s in j['stocks']) Stock.fromJson(s)].where((s) => !s.monochrome).toList();
  }

  static List<Stock> get films => all.where((s) => s.isFilm).toList();
  static List<Stock> get papers => all.where((s) => !s.isFilm).toList();
  static Stock byId(String id) => all.firstWhere((s) => s.id == id);
}
