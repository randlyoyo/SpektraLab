import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'widgets.dart';

/// Post-print geometry, applied in this order: quarter turns, flips,
/// straighten (zoomed to fill), then the crop rectangle. Like the Mac app,
/// it stays with its photo and is never synced.
@immutable
class Crop {
  final int turns; // clockwise quarter turns
  final bool flipH, flipV;
  final double straighten; // degrees, -45…45
  final Rect rect; // normalised to the turned, flipped, straightened image
  final String ratio; // a key of [ratios]

  const Crop({
    this.turns = 0,
    this.flipH = false,
    this.flipV = false,
    this.straighten = 0,
    this.rect = const Rect.fromLTWH(0, 0, 1, 1),
    this.ratio = 'free',
  });

  Crop copyWith({int? turns, bool? flipH, bool? flipV, double? straighten, Rect? rect, String? ratio}) => Crop(
        turns: turns ?? this.turns,
        flipH: flipH ?? this.flipH,
        flipV: flipV ?? this.flipV,
        straighten: straighten ?? this.straighten,
        rect: rect ?? this.rect,
        ratio: ratio ?? this.ratio,
      );

  /// Width over height of the photo after the quarter turns.
  double turnedAspect(double aspect) => turns.isOdd ? 1 / aspect : aspect;

  /// Width over height of the result.
  double aspect(double imageAspect) => turnedAspect(imageAspect) * rect.width / rect.height;

  /// Preset ratios, width:height of the result. null: free; 0: the photo's own.
  static const ratios = <String, (String, double?)>{
    'free': ('自由', null),
    'original': ('原始', 0),
    '1:1': ('1:1', 1),
    '4:5': ('4:5', 4 / 5),
    '3:4': ('3:4', 3 / 4),
    '2:3': ('2:3', 2 / 3),
    '9:16': ('9:16', 9 / 16),
    '16:9': ('16:9', 16 / 9),
    'xpan': ('65:24', 65 / 24),
  };

  /// The largest centred rectangle of [ratio] (result width:height) in an
  /// image of [aspect] (after turns).
  static Rect fit(double ratio, double aspect) {
    final w = math.min(1.0, ratio / aspect);
    final h = math.min(1.0, aspect / ratio);
    return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
  }

  @override
  bool operator ==(Object other) =>
      other is Crop &&
      other.turns % 4 == turns % 4 &&
      other.flipH == flipH &&
      other.flipV == flipV &&
      other.straighten == straighten &&
      other.rect == rect &&
      other.ratio == ratio;

  @override
  int get hashCode => Object.hash(turns % 4, flipH, flipV, straighten, rect, ratio);
}

/// The photo turned, flipped and straightened, filling a box of
/// `crop.turnedAspect(aspect)`. Straightening zooms in so no corner shows.
class Turned extends StatelessWidget {
  final Uint8List image;
  final double aspect;
  final Crop crop;
  const Turned({super.key, required this.image, required this.aspect, required this.crop});

  @override
  Widget build(BuildContext context) {
    final a = crop.straighten * math.pi / 180;
    final r = crop.turnedAspect(aspect);
    final cover = math.max(math.cos(a.abs()) + math.sin(a.abs()) / r, math.cos(a.abs()) + math.sin(a.abs()) * r);
    return ClipRect(
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.rotationZ(a)..scaleByDouble(cover, cover, 1, 1),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(crop.flipH ? -1 : 1, crop.flipV ? -1 : 1, 1),
          child: RotatedBox(
            quarterTurns: crop.turns,
            child: Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}

/// The photo as cropped, fitted to the space it is given.
class Cropped extends StatelessWidget {
  final Uint8List image;
  final double aspect;
  final Crop crop;
  const Cropped({super.key, required this.image, required this.aspect, required this.crop});

  @override
  Widget build(BuildContext context) {
    final rect = crop.rect;
    return Center(
      child: AspectRatio(
        aspectRatio: crop.aspect(aspect),
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth / rect.width, h = box.maxHeight / rect.height;
          return ClipRect(
            child: Stack(clipBehavior: Clip.hardEdge, children: [
              Positioned(
                left: -rect.left * w,
                top: -rect.top * h,
                width: w,
                height: h,
                child: Turned(image: image, aspect: aspect, crop: crop),
              ),
            ]),
          );
        }),
      ),
    );
  }
}

/// The whole photo with the crop rectangle over it: drag inside to move it,
/// drag a corner to resize it (keeping the ratio when one is chosen).
class CropEditor extends StatefulWidget {
  final Uint8List image;
  final double aspect;
  final Crop crop;
  final ValueChanged<Crop> onChanged;
  const CropEditor({super.key, required this.image, required this.aspect, required this.crop, required this.onChanged});

  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  int? corner; // 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left; null moves the rect

  @override
  Widget build(BuildContext context) {
    final c = widget.crop;
    final turned = c.turnedAspect(widget.aspect);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 64, 24, 24),
      child: Center(
        child: AspectRatio(
          aspectRatio: turned,
          child: LayoutBuilder(builder: (context, box) {
            final size = box.biggest;
            final r = Rect.fromLTWH(c.rect.left * size.width, c.rect.top * size.height,
                c.rect.width * size.width, c.rect.height * size.height);
            return GestureDetector(
              onPanStart: (d) {
                final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
                corner = null;
                for (var i = 0; i < 4; i++) {
                  if ((corners[i] - d.localPosition).distance < 32) corner = i;
                }
              },
              onPanUpdate: (d) => widget.onChanged(c.copyWith(rect: _drag(c, d.delta, size, turned))),
              child: Stack(fit: StackFit.expand, children: [
                Turned(image: widget.image, aspect: widget.aspect, crop: c),
                CustomPaint(painter: _CropPainter(r)),
              ]),
            );
          }),
        ),
      ),
    );
  }

  Rect _drag(Crop c, Offset delta, Size size, double turned) {
    final d = Offset(delta.dx / size.width, delta.dy / size.height);
    final rect = c.rect;
    if (corner == null) {
      final dx = d.dx.clamp(-rect.left, 1 - rect.right), dy = d.dy.clamp(-rect.top, 1 - rect.bottom);
      return rect.shift(Offset(dx, dy));
    }
    const minSide = 0.1;
    // The corner opposite the dragged one stays put.
    final anchor = [rect.bottomRight, rect.bottomLeft, rect.topLeft, rect.topRight][corner!];
    final moving = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft][corner!] + d;
    var w = (moving.dx - anchor.dx).abs().clamp(minSide, 1.0);
    var h = (moving.dy - anchor.dy).abs().clamp(minSide, 1.0);
    final ratio = Crop.ratios[c.ratio]!.$2;
    if (ratio != null) {
      final target = ratio == 0 ? 1.0 : ratio / turned; // normalised width / height
      h = w / target;
    }
    final left = corner == 0 || corner == 3 ? anchor.dx - w : anchor.dx;
    final top = corner == 0 || corner == 1 ? anchor.dy - h : anchor.dy;
    final next = Rect.fromLTWH(left, top, w, h);
    // Refuse a drag that would leave the image rather than distort the ratio.
    return next.left < -1e-6 || next.top < -1e-6 || next.right > 1 + 1e-6 || next.bottom > 1 + 1e-6 ? rect : next;
  }
}

class _CropPainter extends CustomPainter {
  final Rect r;
  _CropPainter(this.r);

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(r)),
      dim,
    );
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(r.left + r.width * i / 3, r.top), Offset(r.left + r.width * i / 3, r.bottom), line);
      canvas.drawLine(Offset(r.left, r.top + r.height * i / 3), Offset(r.right, r.top + r.height * i / 3), line);
    }
    canvas.drawRect(r, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
    final handle = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const l = 18.0;
    for (final (p, sx, sy) in [(r.topLeft, 1, 1), (r.topRight, -1, 1), (r.bottomRight, -1, -1), (r.bottomLeft, 1, -1)]) {
      canvas.drawLine(p, p + Offset(l * sx, 0), handle);
      canvas.drawLine(p, p + Offset(0, l * sy), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.r != r;
}

/// The panel's 裁剪 tab: ratio presets, turn and flip, straighten.
class CropPane extends StatelessWidget {
  final Crop crop;
  final double aspect;
  final ValueChanged<Crop> onChanged;
  const CropPane({super.key, required this.crop, required this.aspect, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final turned = crop.turnedAspect(aspect);
    void ratio(String key) {
      final r = Crop.ratios[key]!.$2;
      onChanged(crop.copyWith(ratio: key, rect: r == null ? crop.rect : Crop.fit(r == 0 ? turned : r, turned)));
    }

    Widget tool(Widget icon, String label, VoidCallback onTap) => CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(60, 48),
          onPressed: onTap,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconTheme(data: const IconThemeData(size: 22, color: kLabel), child: icon),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 10, color: kSecondaryLabel)),
          ]),
        );

    return Column(children: [
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final e in Crop.ratios.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 30),
                  color: crop.ratio == e.key ? kTint : kTertiary,
                  borderRadius: BorderRadius.circular(15),
                  onPressed: () => ratio(e.key),
                  child: Text(e.value.$1,
                      style: TextStyle(fontSize: 13, color: crop.ratio == e.key ? Colors.black : kLabel)),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        // A quarter turn swaps the image's sides; the crop starts over at the ratio.
        tool(const Icon(CupertinoIcons.rotate_right), '旋转', () {
          final next = crop.copyWith(turns: (crop.turns + 1) % 4);
          final r = Crop.ratios[crop.ratio]!.$2;
          final t = next.turnedAspect(aspect);
          onChanged(next.copyWith(rect: r == null ? const Rect.fromLTWH(0, 0, 1, 1) : Crop.fit(r == 0 ? t : r, t)));
        }),
        tool(const Icon(Icons.flip), '水平翻转', () => onChanged(crop.copyWith(flipH: !crop.flipH))),
        tool(const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)), '垂直翻转',
            () => onChanged(crop.copyWith(flipV: !crop.flipV))),
        tool(const Icon(CupertinoIcons.arrow_counterclockwise), '复原', () => onChanged(const Crop())),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(children: [
          const Text('拉直', style: TextStyle(color: kLabel, fontSize: 14)),
          Expanded(
            child: CupertinoSlider(
              value: crop.straighten,
              min: -45,
              max: 45,
              divisions: 180,
              activeColor: kTint,
              onChanged: (v) => onChanged(crop.copyWith(straighten: v)),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${crop.straighten.toStringAsFixed(1)}°',
                textAlign: TextAlign.right,
                style: const TextStyle(color: kSecondaryLabel, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ]),
      ),
    ]);
  }
}
