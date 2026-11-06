// The presenter (the site's .present, js/app.js): the card filling the screen. Tapping the sides
// switches cards, which is the whole gesture: somebody holding a phone up switches with a thumb
// without looking at it.
//
// Sharing in Extend or Big Screen turns it into a presenter view: the other screen has the card, so
// this one shows it smaller with the next card beneath it. Big Screen is the same, with the card
// drawn the shape of the whole grid and the grid over it.
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Focus;
import 'package:flutter/material.dart' as m show Focus;
import 'package:flutter/services.dart';

import '../app/state.dart';
import '../card/card_view.dart';
import '../data/deck.dart';
import '../data/images.dart';
import '../native/screen.dart';
import '../share/share_host.dart';
import '../theme/icons.dart';
import '../theme/theme.dart';

class Presenter extends StatefulWidget {
  const Presenter({super.key});

  @override
  State<Presenter> createState() => _PresenterState();
}

class _PresenterState extends State<Presenter> {
  double? _touchX;
  final _focus = FocusNode(debugLabel: 'presenter');

  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_readyNeighbours);
    _readyNeighbours();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    AppState.I.removeListener(_readyNeighbours);
    _focus.dispose();
    super.dispose();
  }

  // The next and last cards' pictures made ready, so stepping to them is instant.
  void _readyNeighbours() {
    if (!mounted) return;
    final app = AppState.I;
    final i = app.cardIndex;
    final cards = app.deck.cards;
    for (final c in [if (i + 1 < cards.length) cards[i + 1], if (i > 0) cards[i - 1]]) {
      for (final l in c.layers) {
        if (!l.isImage || l.hidden) continue;
        Images.I.load(l.imageId).then((bytes) {
          if (bytes != null && mounted && !isSvg(bytes)) precacheImage(cardImageProvider(context, bytes), context);
        });
      }
    }
  }

  KeyEventResult _key(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final app = AppState.I;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.space) {
      app.stepCard(1);
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.pageUp) {
      app.stepCard(-1);
    } else if (key == LogicalKeyboardKey.escape) {
      app.exitPresent();
    } else if (key == LogicalKeyboardKey.keyT) {
      app.togglePresentTicker();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final media = MediaQuery.of(context);
    final inset = media.padding;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) AppState.I.exitPresent();
      },
      child: m.Focus(
        focusNode: _focus,
        onKeyEvent: (_, e) => _key(e),
        child: ListenableBuilder(
          listenable: Listenable.merge([AppState.I, ShareHost.I]),
          builder: (context, _) {
            final app = AppState.I;
            final share = ShareHost.I;
            final remote = share.isPresenterView;
            final card = app.card;
            final shown = showsTicker(card);
            final ink = flash.cardInk;
            return Material(
              color: flash.cardBg,
              child: Listener(
                onPointerDown: (e) => _touchX = e.position.dx,
                onPointerUp: (e) {
                  final from = _touchX;
                  _touchX = null;
                  if (from == null) return;
                  final dx = e.position.dx - from;
                  if (dx.abs() > 60) app.stepCard(dx < 0 ? 1 : -1);
                },
                child: Stack(fit: StackFit.expand, children: [
                  if (remote)
                    _RemoteView(card: card, next: app.cardIndex + 1 < app.deck.cards.length ? app.deck.cards[app.cardIndex + 1] : null)
                  else
                    CardView(card: card, presenting: true, padFraction: 0.05, ticker: shown, tickerSpeed: readTickerSpeed(card.tickerSpeed)),
                  // The two sides of the screen are the control, invisible, over the card.
                  Row(children: [
                    Expanded(child: _Tap(label: 'Previous card', onTap: () => app.stepCard(-1))),
                    const Spacer(),
                    Expanded(child: _Tap(label: 'Next card', onTap: () => app.stepCard(1))),
                  ]),
                  Positioned(
                    top: math.max(10, inset.top),
                    right: math.max(10, inset.right),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      // In the app on a phone with a gyroscope: flick the wrist to change cards.
                      if (Screen.canFlick) ...[
                        _Control(icon: 'flick', label: 'Flick to change cards', on: app.flickOn, onTap: app.togglePresentFlick),
                        const SizedBox(width: 10),
                      ],
                      // Not there for a card with no words to roll.
                      if (hasTickerText(card)) ...[
                        _Control(icon: 'ticker', label: 'Ticker for this card', on: card.ticker, onTap: app.togglePresentTicker),
                        const SizedBox(width: 10),
                      ],
                      _Control(icon: 'exit', label: 'Stop presenting', onTap: app.exitPresent),
                    ]),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: math.max(10, inset.bottom),
                    child: IgnorePointer(
                      child: Semantics(
                        container: true,
                        child: Text(
                          '${app.cardIndex + 1} / ${app.deck.cards.length}',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.8, color: ink.withValues(alpha: 0.45)),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: onTap),
      );
}

class _Control extends StatelessWidget {
  const _Control({required this.icon, required this.label, required this.onTap, this.on});
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool? on;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final lit = on == true;
    return Tooltip(
      excludeFromSemantics: true,
      message: label,
      child: Semantics(
        button: true,
        toggled: on,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Opacity(
          opacity: lit ? 0.8 : 0.55,
          child: Material(
            color: lit ? flash.cardInk : flash.cardInk.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(width: 42, height: 42, child: Center(child: AppIcon(icon, size: 20, color: lit ? flash.cardBg : flash.cardInk))),
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteView extends StatelessWidget {
  const _RemoteView({required this.card, required this.next});
  final FlashCard card;
  final FlashCard? next;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final media = MediaQuery.of(context);
    final share = ShareHost.I;
    final wall = share.bigScreen;
    final aspect = wall?.aspect ?? cardAspect;
    final labelStyle = TextStyle(fontSize: 13.6, color: flash.cardInk.withValues(alpha: 0.7));

    final String status;
    if (wall != null) {
      final online = wall.cells.where((c) => c.online).length;
      status = online > 0 ? 'On $online screen${online == 1 ? '' : 's'}' : 'Waiting for screens to join';
    } else {
      status = share.hostStatus == 'connected' ? 'On the other screen' : 'Waiting for the other screen to join';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, math.max(60, media.padding.top), 16, math.max(44, media.padding.bottom)),
      child: LayoutBuilder(builder: (context, box) {
        final nowW = math.min(box.maxWidth, media.size.height * 0.5 * aspect);
        final nextW = math.min(box.maxWidth * 0.6, media.size.height * 0.22 * aspect);
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: box.maxWidth,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(container: true, liveRegion: true, child: Text(status, style: labelStyle)),
                const SizedBox(height: 10),
                _Frame(
                  width: nowW,
                  aspect: aspect,
                  child: Stack(fit: StackFit.expand, children: [
                    CardView(
                      card: card,
                      presenting: true,
                      onWall: wall != null,
                      ticker: showsTicker(card),
                      tickerSpeed: readTickerSpeed(card.tickerSpeed),
                    ),
                    if (wall != null) _WallGrid(wall: wall),
                  ]),
                ),
                const SizedBox(height: 10),
                Text('Next', style: labelStyle),
                const SizedBox(height: 10),
                Opacity(
                  opacity: 0.75,
                  child: _Frame(
                    width: nextW,
                    aspect: aspect,
                    child: next != null
                        ? CardView(card: next!, presenting: true, onWall: wall != null)
                        : Center(child: Text('End of the cards', style: TextStyle(fontSize: nextW * 0.04, color: flash.cardInk.withValues(alpha: 0.55)))),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.width, required this.aspect, required this.child});
  final double width;
  final double aspect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ink = context.flash.cardInk;
    return Container(
      width: width,
      height: width / aspect,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: ink.withValues(alpha: 0.3))),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Over the card, not instead of it: lines where each screen really is, and its number in its corner,
/// large while the numbers are on. What falls between them is the card behind the bezels, which no
/// screen shows.
class _WallGrid extends StatelessWidget {
  const _WallGrid({required this.wall});
  final BigScreenView wall;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final ink = flash.cardInk;
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        return Stack(children: [
          for (final c in wall.cells)
            Positioned(
              left: c.x * box.maxWidth,
              top: c.y * box.maxHeight,
              width: c.w * box.maxWidth,
              height: c.h * box.maxHeight,
              child: c.blank
                  ? ColoredBox(color: ink.withValues(alpha: 0.08))
                  : Opacity(
                      opacity: c.online ? 1 : 0.4,
                      child: Container(
                        alignment: wall.identify ? Alignment.center : Alignment.topLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        decoration: BoxDecoration(
                          color: wall.identify ? flash.cardBg.withValues(alpha: 0.7) : null,
                          border: Border.all(color: ink.withValues(alpha: 0.45)),
                        ),
                        child: Text('${c.number}',
                            style: TextStyle(color: ink, fontSize: wall.identify ? (box.maxHeight * 0.4 / wall.rows).clamp(16.0, 96.0) : 12)),
                      ),
                    ),
            ),
        ]);
      }),
    );
  }
}
