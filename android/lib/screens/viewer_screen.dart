// The other screen, drawn (share/viewer.dart has what it knows). Painted like the presenter, card
// colours and all, because once play is pressed that's exactly what it is.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../card/card_view.dart';
import '../data/deck.dart';
import '../share/viewer.dart';
import '../theme/icons.dart';
import '../theme/theme.dart';
import '../ui/kit.dart';

/// The host's colours, not this device's own: its saved theme is never touched.
({Color bg, Color ink}) hostCardColors(ViewState? s, BuildContext context) {
  if (s == null) return (bg: context.flash.cardBg, ink: context.flash.cardInk);
  final given = s.cardColors;
  if (given != null) return given;
  final brand = AppLook.swatches.firstWhere((x) => x.id == s.color).color;
  return s.dark ? (bg: const Color(0xFF0C100E), ink: brand) : (bg: brand, ink: const Color(0xFF121815));
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  late final StreamSubscription<({int dx, int dy})> _moves;
  ({int dx, int dy})? _move;
  Widget? _ghost;
  Widget? _lastStage;

  static const _swap = Duration(milliseconds: 420);
  static const _curve = Cubic(0.65, 0, 0.35, 1);

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(vsync: this, duration: _swap)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() {
            _ghost = null;
            _move = null;
          });
        }
      });
    // When the host swaps this screen with another, what's on it slides off towards the other screen's
    // place in the grid and the new picture follows in behind, all one way. The other screen does the
    // same towards this one, so between them the two are seen to trade.
    _moves = Viewer.I.moves.stream.listen((move) {
      if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
      setState(() {
        _move = move;
        _ghost = _lastStage;
      });
      _slide.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _moves.cancel();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Viewer.I.leave();
      },
      child: ListenableBuilder(
        listenable: Viewer.I,
        builder: (context, _) {
          final v = Viewer.I;
          final media = MediaQuery.of(context);
          final size = media.size;
          v.setScreen(size);
          final colors = hostCardColors(v.state, context);
          final panel = v.panel;
          final wall = v.status == 'connected' ? v.state?.wall : null;
          final identify = wall?.identify ?? false;
          final stage = _stage(v, size, media.padding, colors);
          _lastStage = stage;
          final t = _curve.transform(_slide.value);
          final move = _move;

          Widget sliding(Widget child, double from, double to) => move == null
              ? child
              : AnimatedBuilder(
                  animation: _slide,
                  builder: (context, child) {
                    final at = from + (to - from) * _curve.transform(_slide.value);
                    return Transform.translate(offset: Offset(move.dx * size.width * at, move.dy * size.height * at), child: child);
                  },
                  child: child,
                );

          final front = (v.showing || v.lining) ? stage : _Panel(panel: panel, ink: colors.ink);
          return Material(
            color: colors.bg,
            child: Stack(fit: StackFit.expand, children: [
              sliding(front, move == null ? 0 : -1, 0),
              if (_ghost != null && move != null && t < 1) IgnorePointer(child: sliding(_ghost!, 0, 1)),
              if (panel.badge.isNotEmpty && v.showing)
                Positioned(
                  bottom: math.max(12, media.padding.bottom),
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: colors.ink.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                      child: Text(panel.badge, style: TextStyle(fontSize: 12.8, color: colors.ink)),
                    ),
                  ),
                ),
              // This screen's number, big enough to read from where the screens are being arranged,
              // over the card if one is showing.
              if (identify)
                IgnorePointer(
                  child: ColoredBox(
                    color: colors.bg,
                    child: Center(
                      child: Semantics(
                        liveRegion: true,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('${wall!.n}', style: TextStyle(height: 1, fontSize: math.min(size.height * 0.6, size.width * 0.5), color: colors.ink)),
                          Text('of ${wall.of}', style: TextStyle(fontSize: (size.height * 0.05).clamp(16.0, 48.0), color: colors.ink.withValues(alpha: 0.7))),
                        ]),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: math.max(10, media.padding.top),
                right: math.max(10, media.padding.right),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _Corner(icon: 'fullscreen', label: 'Toggle full screen', ink: colors.ink, onTap: v.toggleFullscreen),
                  const SizedBox(width: 8),
                  _Corner(icon: 'exit', label: 'Stop showing shared cards', ink: colors.ink, onTap: v.leave),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }

  /// The size of the whole Big Screen, moved so this screen's piece is the part on show; otherwise the
  /// card in the other device's shape, fitted inside this screen.
  Widget _stage(Viewer v, Size size, EdgeInsets inset, ({Color bg, Color ink}) colors) {
    final rect = Viewer.stageRect(v.state, size, inset);
    final card = v.shownCard;
    final onWall = v.state?.wall != null;
    return ClipRect(
      child: Stack(children: [
        Positioned(
          left: rect.x * size.width,
          top: rect.y * size.height,
          width: rect.w * size.width,
          height: rect.h * size.height,
          child: Stack(fit: StackFit.expand, children: [
            if (card != null)
              RepaintBoundary(
                child: CardView(
                  key: const ValueKey('viewer-card'),
                  card: card,
                  presenting: true,
                  padFraction: 0.05,
                  onWall: onWall,
                  colors: colors,
                  images: v,
                  ticker: v.shownTicker != null,
                  tickerSpeed: v.shownTicker ?? defaultTickerSpeed,
                  now: v.hostNow,
                ),
              ),
            if (v.lining) IgnorePointer(child: CustomPaint(painter: _WallLines(colors.ink.withValues(alpha: 0.85)))),
          ]),
        ),
      ]),
    );
  }
}

/// For setting the bezels: a lattice of diagonal lines and a cross through the middle, drawn across
/// the whole wall. Where a line bends crossing from one screen to the next, the bezels between them
/// are set wrong. Sized against the wall, so it's the same lattice on every screen.
class _WallLines extends CustomPainter {
  _WallLines(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.height * 0.01;
    final paint = Paint()
      ..color = color
      ..strokeWidth = unit;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), paint);
    final spacing = unit * 10 * math.sqrt2;
    final span = size.width + size.height;
    for (var c = 0.0; c < span; c += spacing) {
      canvas.drawLine(Offset(c, 0), Offset(c - size.height, size.height), paint);
      canvas.drawLine(Offset(c - size.height, 0), Offset(c, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_WallLines old) => old.color != color;
}

class _Panel extends StatelessWidget {
  const _Panel({required this.panel, required this.ink});
  final ViewerPanel panel;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final v = Viewer.I;
    final size = MediaQuery.sizeOf(context);
    final actions = panel.actions;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 544),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Semantics(header: true, child: Text(panel.title, textAlign: TextAlign.center, style: TextStyle(fontSize: (size.width * 0.04).clamp(24.0, 41.6), color: ink))),
              const SizedBox(height: 14),
              Semantics(
                liveRegion: true,
                child: Text(panel.message, textAlign: TextAlign.center, style: TextStyle(fontSize: (size.width * 0.02).clamp(15.2, 20.0), color: ink.withValues(alpha: 0.8))),
              ),
              const SizedBox(height: 14),
              Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                if (actions.contains('fullscreen') && !v.appFull) UiButton(label: 'Full screen', icon: 'fullscreen', onTap: v.toggleFullscreen),
                if (actions.contains('retry')) UiButton(label: 'Try again', icon: 'refresh', onTap: v.retry),
                if (actions.contains('copy')) ...[
                  UiButton(label: 'Add to my cards', icon: 'plus', onTap: v.canCopy ? () => v.copyCards(replace: false) : null),
                  UiButton(
                    label: v.replaceArmed ? 'Tap again to replace' : 'Replace my cards',
                    icon: 'cards',
                    danger: v.replaceArmed,
                    onTap: v.canCopy ? () => v.copyCards(replace: true) : null,
                  ),
                ],
                UiButton(label: v.ended ? 'Back to my cards' : 'Leave', kind: ButtonKind.quiet, onTap: v.leave),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Corner extends StatelessWidget {
  const _Corner({required this.icon, required this.label, required this.ink, required this.onTap});
  final String icon;
  final String label;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        excludeFromSemantics: true,
        message: label,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          onTap: onTap,
          child: Opacity(
            opacity: 0.45,
            child: Material(
              color: ink.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: SizedBox(width: 42, height: 42, child: Center(child: AppIcon(icon, size: 20, color: ink))),
              ),
            ),
          ),
        ),
      );
}
