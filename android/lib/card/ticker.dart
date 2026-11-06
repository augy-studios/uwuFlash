// A card's words as a news ticker (the site's js/ticker.js): every line of text on the card, run
// together onto one line that rolls right to left, round and round.
//
// Drawn in the same box as the card, so on a Big Screen the line is as wide as the whole wall and
// runs from one screen onto the next behind the bezels. Every screen works out where the line is
// from the same clock, the host's, so the screens agree on it without being sent a frame of it. A
// picture filling the card stays behind the line.
//
// Where the line is depends only on the time and how many letters it has, never on how wide it
// measures, which differs a hair between two devices and would otherwise pull them apart a little
// more on every lap.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/deck.dart';
import 'card_view.dart';

/// Letters a second, roughly, in em, for each of deck.dart's tickerSpeedIds.
const tickerSpeeds = {'slow': 1.5, 'normal': 3.0, 'fast': 5.0};
const _letterEm = 0.55; // a rough width of one letter, in em
const _lineHeight = 1.2;

/// How long one lap takes, in milliseconds.
double tickerPeriod(String text, String speed) =>
    (text.runes.length.clamp(1, 1 << 30) * _letterEm * 1000) / (tickerSpeeds[speed] ?? tickerSpeeds['normal']!);

class TickerLine extends StatefulWidget {
  const TickerLine({
    super.key,
    required this.card,
    required this.color,
    required this.height,
    required this.speed,
    this.glow,
    this.now,
  });

  final FlashCard card;
  final Color color;
  final double height; // the card's
  final String speed;
  final Color? glow;
  final int Function()? now;

  @override
  State<TickerLine> createState() => _TickerLineState();
}

class _TickerLineState extends State<TickerLine> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _lap = ValueNotifier<double>(0);

  int _now() => widget.now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  String get _text => tickerText(widget.card) + tickerGap;

  // The biggest size among the card's words.
  String get _size {
    const order = ['s', 'm', 'l', 'xl'];
    var size = 's';
    for (final l in widget.card.layers) {
      if (l.isText && !l.hidden && order.indexOf(l.size) > order.indexOf(size)) size = l.size;
    }
    return size;
  }

  void _tick() {
    final period = tickerPeriod(_text, widget.speed);
    final at = _now() % period;
    _lap.value = (at < 0 ? at + period : at) / period;
  }

  @override
  void initState() {
    super.initState();
    _tick();
    _ticker = createTicker((_) => _tick())..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = textFraction(_size) * widget.height;
    final style = DefaultTextStyle.of(context).style.merge(TextStyle(
          fontSize: size,
          height: _lineHeight,
          color: widget.color,
          shadows: widget.glow == null ? null : cardGlow(size, widget.glow!),
        ));
    final painter = TextPainter(
      text: TextSpan(text: _text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return Semantics(
      label: tickerText(widget.card),
      child: SizedBox(
        width: double.infinity,
        height: painter.height,
        child: ClipRect(
          child: CustomPaint(
            painter: _TickerPainter(
              painter,
              _lap,
              // Reduced motion still rolls, since a ticker that stood still would only ever show
              // its first words, but in whole steps rather than a glide.
              steps: MediaQuery.disableAnimationsOf(context) ? 8 : 0,
            ),
          ),
        ),
      ),
    );
  }
}

class _TickerPainter extends CustomPainter {
  _TickerPainter(this.text, this.lap, {required this.steps}) : super(repaint: lap);
  final TextPainter text;
  final ValueNotifier<double> lap;
  final int steps;

  @override
  void paint(Canvas canvas, Size size) {
    final width = text.width;
    if (width <= 0) return;
    final at = steps > 0 ? (lap.value * steps).floorToDouble() / steps : lap.value;
    // Enough copies of the line to cover the box with one to spare, so the end of one lap is
    // always followed on screen by the start of the next.
    for (var x = -at * width; x < size.width; x += width) {
      if (x + width >= 0) text.paint(canvas, Offset(x, 0));
    }
  }

  @override
  bool shouldRepaint(_TickerPainter old) => old.text != text || old.steps != steps;
}
