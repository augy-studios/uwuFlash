// The Edge Tray (edge-tray-spec.md at the repo root): a column of buttons pinned to the top right,
// holding Share and Present, then the global actions. Its tab slides the column off the right edge,
// leaving only the tab, flush with the edge, so the tray can be brought back. Remembered on the phone,
// open unless it was last left collapsed.
//
// Everything runs at one pace. The tray slides as one, the tab reshapes and its chevron turns round,
// the page makes room, and on opening the buttons unroll: each fades in, slides 12 px back from the
// edge and grows from 85%, 18 ms after the one above it. On collapse they all go together.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/store.dart';
import '../theme/icons.dart';
import '../theme/theme.dart';

class TrayAction {
  const TrayAction(this.icon, this.label, this.onTap, {this.live = false});
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool live; // lit, as the share button is while sharing
}

/// Whether the tray's open, and how big it is, for the page to keep clear of it.
class TrayMetrics {
  TrayMetrics._();
  static const key = 'uwuflash.trayOpen';
  static const time = Duration(milliseconds: 340);
  static const ease = Cubic(0.2, 0.8, 0.2, 1);
  static const tabWidth = 24.0;
  static const gap = 8.0;

  static double button(double width) => width <= 480 ? 40 : 44;
  static double edge(double width, double safeRight) {
    final base = width <= 480 ? 10.0 : 16.0;
    return safeRight + base > base ? safeRight + base : base;
  }

  static final open = ValueNotifier<bool>(true);
  static void load() => open.value = Store.I.get(key) != '0';
}

class EdgeTray extends StatefulWidget {
  const EdgeTray({super.key, required this.page, required this.global});
  final List<TrayAction> page; // the page's own, above the rule
  final List<TrayAction> global; // the app's, below it

  @override
  State<EdgeTray> createState() => _EdgeTrayState();
}

class _EdgeTrayState extends State<EdgeTray> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  static const _stagger = 18;

  int get _count => widget.page.length + 1 + widget.global.length;
  int get _totalMs => TrayMetrics.time.inMilliseconds + _stagger * (_count - 1);

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: Duration(milliseconds: _totalMs), value: TrayMetrics.open.value ? 1 : 0);
    TrayMetrics.open.addListener(_follow);
  }

  @override
  void dispose() {
    TrayMetrics.open.removeListener(_follow);
    _c.dispose();
    super.dispose();
  }

  void _follow() {
    if (!mounted) return;
    _c.duration = Duration(milliseconds: _totalMs);
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = TrayMetrics.open.value ? 1 : 0;
    } else if (TrayMetrics.open.value) {
      _c.forward();
    } else {
      // Collapsing runs at the tray's own pace: they all go at once.
      _c.animateBack(0, duration: TrayMetrics.time);
    }
  }

  void _toggle() {
    final open = !TrayMetrics.open.value;
    TrayMetrics.open.value = open;
    Store.I.put(TrayMetrics.key, open ? '1' : '0');
  }

  // How far along the tray itself is, 0 away and 1 open.
  double get _t {
    final raw = _c.status == AnimationStatus.reverse ? _c.value : (_c.value * _totalMs / TrayMetrics.time.inMilliseconds).clamp(0.0, 1.0);
    return TrayMetrics.ease.transform(raw);
  }

  // The same for one button: opening, a beat after the one above it.
  double _buttonT(int index) {
    if (_c.status == AnimationStatus.reverse) return TrayMetrics.ease.transform(_c.value);
    final start = _stagger * index / _totalMs;
    final end = (start + TrayMetrics.time.inMilliseconds / _totalMs).clamp(0.0, 1.0);
    return Interval(start, end, curve: TrayMetrics.ease).transform(_c.value);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final button = TrayMetrics.button(width);
    final edge = TrayMetrics.edge(width, media.padding.right);
    final shift = button + TrayMetrics.gap + edge;
    final maxHeight = media.size.height - media.padding.top - media.padding.bottom - 22;

    var index = 0;
    Widget unroll(Widget child) {
      final i = index++;
      return AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _buttonT(i);
          return Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset((1 - t) * 12, 0),
              child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
            ),
          );
        },
        child: child,
      );
    }

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in widget.page) Padding(padding: const EdgeInsets.only(bottom: 8), child: unroll(_TrayButton(action: a, size: button))),
        unroll(const _Rule()),
        for (var i = 0; i < widget.global.length; i++)
          Padding(
            padding: EdgeInsets.only(top: 8, bottom: i == widget.global.length - 1 ? 2 : 0),
            child: unroll(_TrayButton(action: widget.global[i], size: button)),
          ),
      ],
    );

    return ValueListenableBuilder<bool>(
      valueListenable: TrayMetrics.open,
      builder: (context, open, _) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Transform.translate(offset: Offset(shift * (1 - _t), 0), child: child),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tab(open, button),
            const SizedBox(width: TrayMetrics.gap),
            // Off-screen buttons must not take focus or taps. A short screen, such as a phone on its
            // side, scrolls the column rather than hiding its last buttons below the bottom.
            IgnorePointer(
              ignoring: !open,
              child: ExcludeFocus(
                excluding: !open,
                child: ExcludeSemantics(
                  excluding: !open,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight > button ? maxHeight : button),
                    child: SingleChildScrollView(child: column),
                  ),
                ),
              ),
            ),
            SizedBox(width: edge),
          ],
        ),
      ),
    );
  }

  Widget _tab(bool open, double height) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final label = open ? 'Hide menu' : 'Show menu';
    return Tooltip(
      excludeFromSemantics: true,
      message: label,
      child: Semantics(
        button: true,
        expanded: open,
        label: label,
        excludeSemantics: true,
        onTap: _toggle,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _t;
            const r = Radius.circular(12);
            final right = Radius.circular(12 * t);
            final body = Material(
              color: you ? scheme.surfaceContainerHigh : flash.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.only(topLeft: r, bottomLeft: r, topRight: right, bottomRight: right),
                side: you ? BorderSide.none : BorderSide(color: flash.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _toggle,
                child: SizedBox(
                  width: TrayMetrics.tabWidth,
                  height: height,
                  // Pointing right to push the tray away; round the other way to pull it back.
                  child: Transform.rotate(
                    angle: (1 - t) * 3.14159265,
                    child: Icon(Icons.chevron_right, size: 18, color: flash.ink),
                  ),
                ),
              ),
            );
            return _Glass(radius: 12, child: body);
          },
        ),
      ),
    );
  }
}

// The glass look wants something behind it to blur: the tray floats over the page.
class _Glass extends StatelessWidget {
  const _Glass({required this.radius, required this.child});
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!context.flash.glass) return child;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [BoxShadow(color: Color(0x1A14281E), blurRadius: 30, offset: Offset(0, 10))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: child),
      ),
    );
  }
}

class _TrayButton extends StatelessWidget {
  const _TrayButton({required this.action, required this.size});
  final TrayAction action;
  final double size;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final on = action.live;
    final fill = on ? flash.brandFill : (you ? scheme.surfaceContainerHigh : flash.surface);
    final ink = on ? flash.onBrand : flash.ink;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(you ? (on ? 14 : size / 2) : 14),
      side: you ? BorderSide.none : BorderSide(color: flash.border),
    );
    return Tooltip(
      excludeFromSemantics: true,
      message: action.label,
      child: Semantics(
        button: true,
        selected: on,
        label: action.label,
        excludeSemantics: true,
        onTap: action.onTap,
        child: _Glass(
          radius: you ? size / 2 : 14,
          child: Material(
            color: fill,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: action.onTap,
              child: SizedBox(width: size, height: size, child: Center(child: AppIcon(action.icon, size: 22, color: ink))),
            ),
          ),
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 1,
        margin: const EdgeInsets.only(top: 2, bottom: 2),
        color: context.flash.ink.withValues(alpha: 0.25),
      );
}
