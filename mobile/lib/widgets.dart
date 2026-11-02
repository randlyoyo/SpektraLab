import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'stocks.dart';

// iOS dark system colours, with safelight amber as the app's tint.
const kBackground = Color(0xFF000000);
const kSecondary = Color(0xFF1C1C1E); // secondarySystemBackground
const kTertiary = Color(0xFF2C2C2E); // tertiarySystemBackground
const kSeparator = Color(0xFF38383A);
const kLabel = Color(0xFFFFFFFF);
const kSecondaryLabel = Color(0xFF8E8E93);
const kFill = Color(0x3D767680); // tertiarySystemFill
const kTint = Color(0xFFE3A341);

/// Liquid Glass: a blurred, faintly lit capsule floating over the photo.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  const Glass({super.key, required this.child, this.padding = EdgeInsets.zero, this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.07)],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 0.6),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A round glass button with an SF-style icon, or a capsule with a label.
class GlassButton extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final VoidCallback? onPressed;
  const GlassButton({super.key, this.icon, this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null ? kSecondaryLabel : kLabel;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      onPressed: onPressed,
      child: Glass(
        child: SizedBox(
          height: 44,
          width: label == null ? 44 : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 16),
            child: Center(
              child: label == null
                  ? Icon(icon, size: 20, color: color)
                  : Text(label!, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}

/// UISegmentedControl, dark.
class Segmented<T extends Object> extends StatelessWidget {
  final Map<T, String> items;
  final T value;
  final ValueChanged<T> onChanged;
  final bool small;
  const Segmented({super.key, required this.items, required this.value, required this.onChanged, this.small = false});

  @override
  Widget build(BuildContext context) {
    return CupertinoSlidingSegmentedControl<T>(
      groupValue: value,
      backgroundColor: kFill,
      thumbColor: const Color(0xFF636366),
      padding: const EdgeInsets.all(2),
      onValueChanged: (v) => onChanged(v!),
      children: {
        for (final e in items.entries)
          e.key: Padding(
            padding: EdgeInsets.symmetric(vertical: small ? 4 : 6),
            child: Text(e.value, style: TextStyle(fontSize: small ? 12 : 13, color: kLabel, fontWeight: FontWeight.w500)),
          ),
      },
    );
  }
}

/// A film box or a paper packet: the cover photo where the Mac app has one,
/// otherwise a card in the brand's colour.
class StockCard extends StatelessWidget {
  final Stock stock;
  final bool selected;
  final VoidCallback onTap;
  const StockCard({super.key, required this.stock, required this.selected, required this.onTap});

  static const _brandColors = {
    'Kodak': Color(0xFFE9B10A),
    'Fujifilm': Color(0xFF2F8F5B),
    'CineStill': Color(0xFFB8322A),
  };

  @override
  Widget build(BuildContext context) {
    final paper = !stock.isFilm;
    final base = paper ? const Color(0xFFEDE6DA) : _brandColors[stock.brand] ?? const Color(0xFF55555C);
    final ink = paper || base.computeLuminance() > 0.4 ? Colors.black87 : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 88,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 88,
            height: 92,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? kTint : Colors.transparent, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: stock.cover != null
                  ? Image.asset('assets/covers/${stock.cover}', fit: BoxFit.cover)
                  : Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [base, Color.lerp(base, Colors.black, paper ? 0.12 : 0.35)!],
                        ),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(stock.brand.toUpperCase(),
                            style: TextStyle(color: ink.withValues(alpha: 0.7), fontSize: 8, letterSpacing: 1.2)),
                        const Spacer(),
                        Text(stock.shortName,
                            maxLines: 3,
                            style: TextStyle(color: ink, fontSize: 12, fontWeight: FontWeight.w700, height: 1.15)),
                      ]),
                    ),
            ),
          ),
          const SizedBox(height: 5),
          Text(stock.shortName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: selected ? kTint : kLabel)),
          Text(stock.brand, style: const TextStyle(fontSize: 10, color: kSecondaryLabel)),
        ]),
      ),
    );
  }
}

/// An inset grouped section (Settings-app style) without the section chrome.
class Grouped extends StatelessWidget {
  final List<Widget> children;
  const Grouped({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: kTertiary, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Padding(padding: EdgeInsets.only(left: 16), child: Divider(height: 0.5, thickness: 0.5, color: kSeparator)),
          children[i],
        ],
      ]),
    );
  }
}
