import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'crop.dart';
import 'engine.dart';
import 'photo.dart';
import 'widgets.dart';

/// A layout: one normalised cell per photo, in order.
typedef Template = (String name, List<Rect> cells);

/// Layouts for [n] photos (2…9), the plainest first.
List<Template> templatesFor(int n) {
  List<Rect> cols(int k, [Rect area = const Rect.fromLTWH(0, 0, 1, 1)]) =>
      [for (var i = 0; i < k; i++) Rect.fromLTWH(area.left + area.width * i / k, area.top, area.width / k, area.height)];
  List<Rect> rows(int k, [Rect area = const Rect.fromLTWH(0, 0, 1, 1)]) =>
      [for (var i = 0; i < k; i++) Rect.fromLTWH(area.left, area.top + area.height * i / k, area.width, area.height / k)];
  List<Rect> grid(int k) {
    final c = math.sqrt(k).ceil(), r = (k / c).ceil();
    return [
      for (var i = 0; i < k; i++)
        // The last row's cells widen to fill it.
        () {
          final row = i ~/ c, inRow = row == r - 1 ? k - c * (r - 1) : c;
          return Rect.fromLTWH((i % c) / inRow, row / r, 1 / inRow, 1 / r);
        }(),
    ];
  }

  return switch (n) {
    2 => [('左右', cols(2)), ('上下', rows(2))],
    3 => [
        ('三列', cols(3)),
        ('三行', rows(3)),
        ('左大', [const Rect.fromLTWH(0, 0, 0.5, 1), ...rows(2, const Rect.fromLTWH(0.5, 0, 0.5, 1))]),
        ('上大', [const Rect.fromLTWH(0, 0, 1, 0.5), ...cols(2, const Rect.fromLTWH(0, 0.5, 1, 0.5))]),
      ],
    4 => [
        ('四宫格', grid(4)),
        ('左大', [const Rect.fromLTWH(0, 0, 2 / 3, 1), ...rows(3, const Rect.fromLTWH(2 / 3, 0, 1 / 3, 1))]),
        ('上大', [const Rect.fromLTWH(0, 0, 1, 2 / 3), ...cols(3, const Rect.fromLTWH(0, 2 / 3, 1, 1 / 3))]),
        ('四列', cols(4)),
      ],
    _ => [
        ('网格', grid(n)),
        ('上大', [const Rect.fromLTWH(0, 0, 1, 0.5), ...() {
          final rest = grid(n - 1);
          return [for (final r in rest) Rect.fromLTWH(r.left, 0.5 + r.top / 2, r.width, r.height / 2)];
        }()]),
      ],
  };
}

/// Several photos as one picture. Each photo keeps its own film and crop.
class CollageScreen extends StatefulWidget {
  final List<Photo> photos;
  const CollageScreen({super.key, required this.photos});

  @override
  State<CollageScreen> createState() => _CollageScreenState();
}

enum _Tab { layout, border, ratio }

class _CollageScreenState extends State<CollageScreen> {
  late final order = [...widget.photos];
  int template = 0;
  double spacing = 8; // in points of the preview's long edge, scaled on export
  double radius = 0;
  Color background = Colors.white;
  double ratio = 1;
  int? picked; // a cell tapped to swap with the next one tapped
  _Tab tab = _Tab.layout;

  static const backgrounds = [Colors.white, Color(0xFFF1EADF), Colors.black, Color(0xFF2C2C2E)];
  static const ratios = {'1:1': 1.0, '4:5': 0.8, '3:4': 0.75, '9:16': 9 / 16, '16:9': 16 / 9};

  @override
  Widget build(BuildContext context) {
    final templates = templatesFor(order.length);
    final cells = templates[template.clamp(0, templates.length - 1)].$2;
    return Scaffold(
      backgroundColor: kBackground,
      body: Column(children: [
        SafeArea(
          bottom: false,
          child: SizedBox(
            height: 52,
            child: Row(children: [
              CupertinoButton(child: const Text('取消'), onPressed: () => Navigator.pop(context)),
              const Expanded(
                child: Text('拼图',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kLabel, fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              CupertinoButton(
                onPressed: () async {
                  await Engine.save();
                  if (!context.mounted) return;
                  Navigator.pop(context, '已保存拼图${Engine.isPreview ? '（预览模式，未真正保存）' : ''}');
                },
                child: const Text('导出', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: AspectRatio(
                aspectRatio: ratio,
                child: Container(
                  color: background,
                  padding: EdgeInsets.all(spacing / 2),
                  child: LayoutBuilder(builder: (context, box) {
                    return Stack(children: [
                      for (var i = 0; i < cells.length; i++) _cell(i, cells[i], box.biggest),
                    ]);
                  }),
                ),
              ),
            ),
          ),
        ),
        Text(picked == null ? '点一格，再点另一格可以交换位置' : '再点一格和它交换',
            style: const TextStyle(color: kSecondaryLabel, fontSize: 12)),
        const SizedBox(height: 8),
        Container(
          decoration: const BoxDecoration(color: kSecondary, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: Segmented<_Tab>(
                  items: const {_Tab.layout: '布局', _Tab.border: '边框', _Tab.ratio: '比例'},
                  value: tab,
                  onChanged: (v) => setState(() => tab = v),
                ),
              ),
            ),
            SizedBox(
              height: 120,
              child: switch (tab) {
                _Tab.layout => _layouts(templates),
                _Tab.border => _border(),
                _Tab.ratio => _ratios(),
              },
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _cell(int i, Rect cell, Size size) {
    final p = order[i];
    final r = Rect.fromLTWH(cell.left * size.width, cell.top * size.height, cell.width * size.width,
            cell.height * size.height)
        .deflate(spacing / 2);
    final image = p.print ?? p.thumb;
    return Positioned.fromRect(
      rect: r,
      child: GestureDetector(
        onTap: () => setState(() {
          if (picked == null) {
            picked = i;
          } else {
            final t = order[i];
            order[i] = order[picked!];
            order[picked!] = t;
            picked = null;
          }
        }),
        child: Container(
          foregroundDecoration: picked == i
              ? BoxDecoration(border: Border.all(color: kTint, width: 3), borderRadius: BorderRadius.circular(radius))
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            // Each photo as cropped, filling its cell.
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 1000,
                height: 1000 / p.crop.aspect(p.aspect),
                child: Cropped(image: image, aspect: p.aspect, crop: p.crop),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _layouts(List<Template> templates) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: templates.length,
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (_, i) => GestureDetector(
        onTap: () => setState(() => template = i),
        child: Column(children: [
          Container(
            width: 64,
            height: 64,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: kTertiary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: template == i ? kTint : Colors.transparent, width: 2),
            ),
            child: LayoutBuilder(
              builder: (_, box) => Stack(children: [
                for (final c in templates[i].$2)
                  Positioned(
                    left: c.left * box.maxWidth,
                    top: c.top * box.maxHeight,
                    width: c.width * box.maxWidth,
                    height: c.height * box.maxHeight,
                    child: Container(
                      margin: const EdgeInsets.all(1.5),
                      decoration: BoxDecoration(color: kSecondaryLabel, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          Text(templates[i].$1, style: TextStyle(fontSize: 11, color: template == i ? kTint : kLabel)),
        ]),
      ),
    );
  }

  Widget _border() {
    Widget slider(String label, double value, double max, ValueChanged<double> onChanged) => Row(children: [
          SizedBox(width: 40, child: Text(label, style: const TextStyle(color: kLabel, fontSize: 14))),
          Expanded(child: CupertinoSlider(value: value, max: max, activeColor: kTint, onChanged: onChanged)),
        ]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        slider('间距', spacing, 24, (v) => setState(() => spacing = v)),
        slider('圆角', radius, 24, (v) => setState(() => radius = v)),
        Row(children: [
          const SizedBox(width: 40, child: Text('底色', style: TextStyle(color: kLabel, fontSize: 14))),
          for (final c in backgrounds)
            GestureDetector(
              onTap: () => setState(() => background = c),
              child: Container(
                margin: const EdgeInsets.only(left: 12),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: background == c ? kTint : kSeparator, width: background == c ? 2.5 : 1),
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  Widget _ratios() {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        for (final e in ratios.entries)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: () => setState(() => ratio = e.value),
              child: Column(children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: e.value,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: ratio == e.value ? kTint : kSecondaryLabel, width: 2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(e.key, style: TextStyle(fontSize: 12, color: ratio == e.value ? kTint : kLabel)),
              ]),
            ),
          ),
      ],
    );
  }
}
