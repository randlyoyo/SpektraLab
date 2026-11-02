import 'package:device_preview/device_preview.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'collage.dart';
import 'crop.dart';
import 'engine.dart';
import 'photo.dart';
import 'stocks.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Stock.load();
  runApp(DevicePreview(
    enabled: Engine.isPreview,
    defaultDevice: Devices.ios.iPhone16Pro,
    builder: (_) => const App(),
  ));
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpektraLab Mobile',
      debugShowCheckedModeBanner: false,
      locale: DevicePreview.locale(context),
      builder: DevicePreview.appBuilder,
      theme: ThemeData(
        brightness: Brightness.dark,
        platform: TargetPlatform.iOS, // iOS scrolling, transitions and system font
        scaffoldBackgroundColor: kBackground,
        colorScheme: const ColorScheme.dark(primary: kTint, surface: kSecondary),
        cupertinoOverrideTheme: const CupertinoThemeData(brightness: Brightness.dark, primaryColor: kTint),
      ),
      home: const Editor(),
    );
  }
}

enum Pane { film, paper, adjust, crop }

class Editor extends StatefulWidget {
  const Editor({super.key});

  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  final photos = <Photo>[];
  Photo? current;

  bool selecting = false;
  final selected = <String>{}; // besides [current], which is always included
  Settings? clipboard;

  Pane pane = Pane.film;
  String filmGroup = 'all';
  bool showOriginal = false; // the 原图 button

  // One engine, one open photo; edits made while it works are coalesced.
  bool busy = false;
  String? openId;
  Photo? pending;
  bool pendingFilm = false;

  /// The photos an edit applies to.
  List<Photo> get targets =>
      selecting ? photos.where((p) => p == current || selected.contains(p.id)).toList() : [?current];

  // --- engine -------------------------------------------------------------

  void _request(Photo p, {bool film = true}) {
    if (busy) {
      pendingFilm = pendingFilm || film || pending != p;
      pending = p;
      return;
    }
    _develop(p, film);
  }

  Future<void> _develop(Photo p, bool film) async {
    setState(() => busy = true);
    final s = p.settings;
    try {
      final r = p.id == openId ? await Engine.render(s.params, film: film) : await Engine.open(p.id, s.params);
      openId = p.id;
      final img = await decodeImageFromList(r.image);
      p.aspect = img.width / img.height;
      p
        ..print = r.image
        ..original = r.original ?? p.original
        ..status = r.info
        ..printed = s;
    } on PlatformException catch (e) {
      p.status = e.message ?? e.code;
    }
    if (!mounted) return;
    setState(() => busy = false);
    final next = pending;
    if (next != null) {
      pending = null;
      final f = pendingFilm;
      pendingFilm = false;
      _develop(next, f);
    }
  }

  /// Apply an edit to every target photo; print the current one.
  void _edit(Settings Function(Settings) change, {required bool film}) {
    for (final p in targets) {
      p.settings = change(p.settings);
    }
    setState(() {});
    if (current != null) _request(current!, film: film);
  }

  // --- library ------------------------------------------------------------

  Future<void> _import() async {
    final picked = await Engine.pick();
    if (picked.isEmpty) return;
    setState(() => photos.addAll([for (final (id, thumb) in picked) Photo(id, thumb)]));
    if (current == null) _show(photos.first);
  }

  void _show(Photo p) {
    setState(() => current = p);
    if (p.print == null || p.stale || openId != p.id) _request(p);
  }

  void _tapThumb(Photo p) {
    if (!selecting) return _show(p);
    if (p == current) return;
    setState(() => selected.contains(p.id) ? selected.remove(p.id) : selected.add(p.id));
  }

  void _toggleSelecting() => setState(() {
        selecting = !selecting;
        selected.clear();
      });

  void _selectAll() => setState(() {
        final all = photos.where((p) => p != current).map((p) => p.id);
        selected.length == all.length ? selected.clear() : selected.addAll(all);
      });

  Future<void> _thumbMenu(Photo p) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx, 'copy'), child: const Text('拷贝设置')),
          if (clipboard != null)
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx, 'paste'), child: const Text('粘贴设置')),
          CupertinoActionSheetAction(
              isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, 'remove'), child: const Text('移除照片')),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
      ),
    );
    switch (action) {
      case 'copy':
        clipboard = p.settings;
        _toast('已拷贝设置');
      case 'paste':
        setState(() => p.settings = clipboard!);
        if (p == current) _request(p);
        _toast('已粘贴设置');
      case 'remove':
        await Engine.remove(p.id);
        setState(() {
          photos.remove(p);
          selected.remove(p.id);
          if (openId == p.id) openId = null;
        });
        if (p == current) {
          current = null;
          if (photos.isNotEmpty) _show(photos.first);
        }
    }
  }

  // --- batch --------------------------------------------------------------

  Future<void> _syncSheet() async {
    final from = current!;
    final to = photos.where((p) => selected.contains(p.id)).toList();
    final groups = Group.values.toSet();
    await showCupertinoModalPopup(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: const BoxDecoration(
            color: kSecondary,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Material(
              type: MaterialType.transparency,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 14),
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(color: kSeparator, borderRadius: BorderRadius.circular(3)),
                ),
                const Text('同步设置', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: kLabel)),
                const SizedBox(height: 4),
                Text('把当前照片的设置应用到另外 ${to.length} 张',
                    style: const TextStyle(fontSize: 13, color: kSecondaryLabel)),
                CupertinoListSection.insetGrouped(
                  backgroundColor: Colors.transparent,
                  decoration: BoxDecoration(color: kTertiary, borderRadius: BorderRadius.circular(12)),
                  separatorColor: kSeparator,
                  children: [
                    for (final g in Group.values)
                      CupertinoListTile(
                        title: Text(g.label, style: const TextStyle(color: kLabel)),
                        trailing: CupertinoSwitch(
                          value: groups.contains(g),
                          activeTrackColor: kTint,
                          onChanged: (v) => setSheet(() => v ? groups.add(g) : groups.remove(g)),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: CupertinoButton.filled(
                      borderRadius: BorderRadius.circular(14),
                      onPressed: groups.isEmpty
                          ? null
                          : () {
                              for (final p in to) {
                                p.settings = p.settings.syncedFrom(from.settings, groups);
                              }
                              Navigator.pop(ctx);
                              setState(() {});
                              _toast('已同步到 ${to.length} 张照片，打开时冲印');
                            },
                      child: Text('同步到 ${to.length} 张', style: const TextStyle(color: Colors.black)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// Print each photo at full size with its own settings and save it.
  Future<void> _export(List<Photo> list) async {
    if (busy) return _toast('正在冲印，请稍候');
    setState(() => busy = true);
    final done = ValueNotifier(0);
    var stop = false;
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('正在导出到相册'),
        content: ValueListenableBuilder(
          valueListenable: done,
          builder: (_, n, __) => Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(children: [
              const CupertinoActivityIndicator(),
              const SizedBox(height: 8),
              Text('$n / ${list.length}'),
            ]),
          ),
        ),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => stop = true, child: const Text('停止')),
        ],
      ),
    );
    var saved = 0, failed = 0;
    for (final p in list) {
      if (stop) break;
      try {
        final r = await Engine.open(p.id, p.settings.params);
        openId = p.id;
        p
          ..print = r.image
          ..original = r.original ?? p.original
          ..printed = p.settings
          ..status = r.info;
        await Engine.save();
        saved++;
      } on PlatformException {
        failed++;
      }
      done.value++;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    setState(() => busy = false);
    _toast('已保存 $saved 张${failed > 0 ? '，$failed 张失败' : ''}${Engine.isPreview ? '（预览模式，未真正保存）' : ''}');
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text, style: const TextStyle(color: kLabel)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: kTertiary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 2),
      ));

  // --- layout -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            _canvas(),
            Positioned(left: 12, right: 12, top: MediaQuery.paddingOf(context).top + 4, child: _topBar()),
          ]),
        ),
        if (photos.isNotEmpty) _filmstrip(),
        _panel(),
      ]),
    );
  }

  Widget _topBar() {
    final s = current?.settings;
    final film = s == null ? null : Stock.byId(s.film);
    return Row(children: [
      selecting
          ? GlassButton(label: '全选', onPressed: photos.length > 1 ? _selectAll : null)
          : GlassButton(icon: CupertinoIcons.plus, onPressed: busy ? null : _import),
      const SizedBox(width: 8),
      Expanded(
        child: film == null
            ? const SizedBox()
            : Center(
                child: Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(film.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kLabel)),
                    Text(film.isPositive ? '反转片 · 直接扫描' : Stock.byId(s!.paper).name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: kSecondaryLabel)),
                  ]),
                ),
              ),
      ),
      const SizedBox(width: 8),
      if (photos.length > 1) ...[
        GlassButton(label: selecting ? '完成' : '选择', onPressed: _toggleSelecting),
        const SizedBox(width: 8),
      ],
      if (!selecting)
        GlassButton(
          icon: CupertinoIcons.square_arrow_up,
          onPressed: current?.print == null || busy ? null : () => _export([current!]),
        ),
    ]);
  }

  Widget _canvas() {
    final p = current;
    if (p == null) {
      return Center(
        child: CupertinoButton(
          onPressed: _import,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(shape: BoxShape.circle, color: kTint.withValues(alpha: 0.12)),
              child: const Icon(CupertinoIcons.photo_on_rectangle, color: kTint, size: 34),
            ),
            const SizedBox(height: 16),
            const Text('导入照片', style: TextStyle(color: kLabel, fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('可以一次选多张 · RAW / ProRAW / HEIC / JPEG',
                style: TextStyle(color: kSecondaryLabel, fontSize: 13)),
          ]),
        ),
      );
    }
    final print = p.print, original = p.original;
    if (print == null) return const Center(child: CupertinoActivityIndicator(radius: 14));
    final shown = showOriginal && original != null ? original : print;
    final top = MediaQuery.paddingOf(context).top + 60;

    return Stack(fit: StackFit.expand, children: [
      if (pane == Pane.crop)
        CropEditor(
          image: shown,
          aspect: p.aspect,
          crop: p.crop,
          onChanged: (c) => setState(() => p.crop = c),
        )
      else
        // Tap for full screen.
        GestureDetector(
        onTap: () => Navigator.of(context).push(PageRouteBuilder(
          opaque: true,
          pageBuilder: (_, __, ___) => _Fullscreen(Cropped(image: shown, aspect: p.aspect, crop: p.crop)),
          transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        )),
        child: InteractiveViewer(
          maxScale: 6,
          child: Cropped(image: shown, aspect: p.aspect, crop: p.crop),
        ),
      ),
      if (showOriginal && original != null) Positioned(left: 12, top: top, child: _chip('原图', highlight: true)),
      Positioned(left: 12, bottom: 10, child: _originalButton(enabled: original != null)),
      Positioned(
        right: 12,
        bottom: 10,
        child: busy ? _chip('冲印中', spinner: true) : _chip(p.status),
      ),
    ]);
  }

  /// Switches between the print and the original.
  Widget _originalButton({required bool enabled}) {
    return Glass(
      radius: 17,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 34),
        onPressed: enabled ? () => setState(() => showOriginal = !showOriginal) : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(showOriginal ? CupertinoIcons.eye_fill : CupertinoIcons.eye,
              size: 15, color: showOriginal ? kTint : kLabel),
          const SizedBox(width: 5),
          Text('原图', style: TextStyle(fontSize: 12, color: showOriginal ? kTint : kLabel)),
        ]),
      ),
    );
  }

  Widget _chip(String text, {bool highlight = false, bool spinner = false}) {
    if (text.isEmpty) return const SizedBox();
    return Glass(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (spinner) ...[const CupertinoActivityIndicator(radius: 6), const SizedBox(width: 6)],
        Text(text, style: TextStyle(fontSize: 11, color: highlight ? kTint : kLabel)),
      ]),
    );
  }

  Widget _filmstrip() {
    return Container(
      color: kBackground,
      height: 68,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final p = photos[i];
          final isCurrent = p == current;
          final isSelected = isCurrent || selected.contains(p.id);
          return GestureDetector(
            onTap: () => _tapThumb(p),
            onLongPress: () => _thumbMenu(p),
            child: Stack(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 52,
                height: 52,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: isCurrent ? kTint : Colors.transparent, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Opacity(
                    opacity: selecting && !isSelected ? 0.45 : 1,
                    child: Image.memory(p.thumb, fit: BoxFit.cover, cacheWidth: 160),
                  ),
                ),
              ),
              if (selecting)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Icon(
                    isSelected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                    size: 18,
                    color: isSelected ? kTint : Colors.white70,
                  ),
                )
              else if (p.edited)
                Positioned(
                  right: 5,
                  top: 5,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(color: kTint, shape: BoxShape.circle),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }

  Widget _panel() {
    return Container(
      decoration: const BoxDecoration(
        color: kSecondary,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (selecting) _selectBar(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: Segmented<Pane>(
              items: const {Pane.film: '胶片', Pane.paper: '相纸', Pane.adjust: '调整', Pane.crop: '裁剪'},
              value: pane,
              onChanged: (v) => setState(() => pane = v),
            ),
          ),
        ),
        SizedBox(
          height: 186,
          child: IgnorePointer(
            ignoring: current == null,
            child: Opacity(
              opacity: current == null ? 0.4 : 1,
              child: switch (pane) {
                Pane.film => _filmPane(),
                Pane.paper => _paperPane(),
                Pane.adjust => _adjustPane(),
                Pane.crop => CropPane(
                    crop: current?.crop ?? const Crop(),
                    aspect: current?.aspect ?? 1.5,
                    onChanged: (c) => setState(() => current!.crop = c),
                  ),
              },
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _collage() async {
    final done = await Navigator.of(context).push<String>(
      CupertinoPageRoute(fullscreenDialog: true, builder: (_) => CollageScreen(photos: targets)),
    );
    if (done != null) _toast(done);
  }

  Widget _selectBar() {
    final n = selected.length + 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
      child: Row(children: [
        Expanded(
          child: Text('已选 $n 张',
              style: const TextStyle(fontSize: 13, color: kSecondaryLabel)),
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: selected.isEmpty ? null : _syncSheet,
          child: const Text('同步', style: TextStyle(fontSize: 15)),
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: n < 2 || n > 9 || busy ? null : _collage,
          child: const Text('拼图', style: TextStyle(fontSize: 15)),
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: busy ? null : () => _export(targets),
          child: Text('导出 $n 张', style: const TextStyle(fontSize: 15)),
        ),
      ]),
    );
  }

  Settings get _s => current?.settings ?? const Settings();

  Widget _filmPane() {
    final groups = <String, (String, bool Function(Stock))>{
      'all': ('全部', (s) => true),
      'neg': ('负片', (s) => !s.isPositive && !s.isCine),
      'pos': ('反转片', (s) => s.isPositive),
      'cine': ('电影卷', (s) => s.isCine),
    };
    final films = Stock.films.where(groups[filmGroup]!.$2).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: SizedBox(
          width: double.infinity,
          child: Segmented<String>(
            small: true,
            items: {for (final e in groups.entries) e.key: e.value.$1},
            value: filmGroup,
            onChanged: (v) => setState(() => filmGroup = v),
          ),
        ),
      ),
      Expanded(child: _cards(films, _s.film, (s) => _edit((x) => x.copyWith(film: s.id), film: true))),
    ]);
  }

  Widget _paperPane() {
    if (Stock.byId(_s.film).isPositive) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('反转片冲出来就是正像，直接扫描，不经过相纸。\n换一卷负片就可以选相纸。',
              textAlign: TextAlign.center, style: TextStyle(color: kSecondaryLabel, height: 1.6)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _cards(Stock.papers, _s.paper, (s) => _edit((x) => x.copyWith(paper: s.id), film: false)),
    );
  }

  Widget _cards(List<Stock> stocks, String chosen, void Function(Stock) onTap) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      itemCount: stocks.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (_, i) => StockCard(stock: stocks[i], selected: stocks[i].id == chosen, onTap: () => onTap(stocks[i])),
    );
  }

  Widget _adjustPane() {
    final s = _s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Grouped(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
          child: Column(children: [
            Row(children: [
              const Text('曝光', style: TextStyle(color: kLabel, fontSize: 16)),
              const Spacer(),
              Text('${s.exposure >= 0 ? '+' : ''}${s.exposure.toStringAsFixed(1)} EV',
                  style: const TextStyle(
                      color: kSecondaryLabel, fontSize: 15, fontFeatures: [FontFeature.tabularFigures()])),
              if (s.exposure != 0)
                CupertinoButton(
                  padding: const EdgeInsets.only(left: 8),
                  minimumSize: const Size(28, 28),
                  onPressed: () => _edit((x) => x.copyWith(exposure: 0), film: true),
                  child: const Icon(CupertinoIcons.arrow_counterclockwise, size: 16, color: kTint),
                ),
            ]),
            SizedBox(
              width: double.infinity,
              child: CupertinoSlider(
                value: s.exposure,
                min: -3,
                max: 3,
                divisions: 60,
                activeColor: kTint,
                // Moves without printing; prints on release.
                onChanged: (v) => setState(() {
                  for (final p in targets) {
                    p.settings = p.settings.copyWith(exposure: v);
                  }
                }),
                onChangeEnd: (_) => _edit((x) => x, film: true),
              ),
            ),
          ]),
        ),
        _switchRow('颗粒', s.grain, (v) => _edit((x) => x.copyWith(grain: v), film: true)),
        _switchRow('光晕', s.halation, (v) => _edit((x) => x.copyWith(halation: v), film: true)),
      ]),
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Text(label, style: const TextStyle(color: kLabel, fontSize: 16)),
          const Spacer(),
          CupertinoSwitch(value: value, activeTrackColor: kTint, onChanged: onChanged),
        ]),
      ),
    );
  }
}

/// The photo alone on black. Tap to close; double-tap to zoom.
class _Fullscreen extends StatefulWidget {
  final Widget image;
  const _Fullscreen(this.image);

  @override
  State<_Fullscreen> createState() => _FullscreenState();
}

class _FullscreenState extends State<_Fullscreen> {
  final _zoom = TransformationController();
  TapDownDetails? _doubleTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        onDoubleTapDown: (d) => _doubleTap = d,
        onDoubleTap: () {
          final p = _doubleTap!.localPosition;
          _zoom.value = _zoom.value.isIdentity()
              ? (Matrix4.identity()
                ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
                ..scaleByDouble(2.5, 2.5, 1, 1))
              : Matrix4.identity();
        },
        child: InteractiveViewer(
          transformationController: _zoom,
          maxScale: 6,
          child: SizedBox.expand(child: widget.image),
        ),
      ),
    );
  }
}
