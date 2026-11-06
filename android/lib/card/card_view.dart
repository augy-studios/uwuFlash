// Drawing a card (the site's js/render.js and its .card-* styles). One renderer, used by the editor
// preview, the presenter and the other screen, so what somebody arranges is exactly what the room
// sees. The only difference between them is the size of the box it's given, which is why every
// size here is a fraction of that box, as the site's are in cqw and cqh.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/deck.dart';
import '../data/images.dart';
import '../theme/theme.dart';
import 'ticker.dart';

/// Sized against the card's height, the same sizes as the ticker's, so turning a card's ticker on
/// or off keeps its words the size they were. On a Big Screen, as wide as every screen together,
/// that leaves the extra width to the line.
double textFraction(String size) => switch (size) {
      's' => 0.16,
      'm' => 0.24,
      'xl' => 0.48,
      _ => 0.34,
    };

/// A picture filling the card keeps its words readable with a glow in the card's own colour.
List<Shadow> cardGlow(double fontSize, Color bg) => [
      Shadow(color: bg, blurRadius: fontSize * 0.25),
      Shadow(color: bg, blurRadius: fontSize * 0.6),
    ];

/// How large to decode a picture: one size for everything on this screen, so the preview, the
/// presenter and what's been made ready ahead of time all share one decoded copy.
ImageProvider cardImageProvider(BuildContext context, Uint8List bytes, {double? longest}) {
  final media = MediaQuery.of(context);
  final screen = longest ?? math.max(media.size.width, media.size.height);
  final px = (screen * media.devicePixelRatio).ceil().clamp(1, 4096);
  return ResizeImage(MemoryImage(bytes), width: px, height: px, policy: ResizeImagePolicy.fit, allowUpscaling: false);
}

/// One card, drawn to fill its box, or its ticker when [ticker] is on.
class CardView extends StatefulWidget {
  const CardView({
    super.key,
    required this.card,
    this.presenting = false,
    this.padFraction = 0.04,
    this.onWall = false,
    this.colors,
    this.images,
    this.ticker = false,
    this.tickerSpeed = 'normal',
    this.now,
  });

  final FlashCard card;
  final bool presenting;
  final double padFraction;
  final bool onWall; // a Big Screen: margins that don't grow with every screen added
  final ({Color bg, Color ink})? colors; // the card's colours, if not this device's own
  final ImageSource? images;
  final bool ticker;
  final String tickerSpeed;
  final int Function()? now; // the clock every screen agrees on, for a ticker

  @override
  State<CardView> createState() => _CardViewState();
}

class _CardViewState extends State<CardView> {
  final Map<String, Uint8List?> _loaded = {};
  final Set<String> _asked = {};

  // A picture's width over its height, once decoded, by id: the same picture's the same shape
  // wherever it's drawn, so a card redrawn elsewhere has it from the first frame.
  static final Map<String, double> _aspects = {};
  final Set<String> _measuring = {};

  void _measure(String id, Uint8List bytes, double? longest) {
    if (_aspects.containsKey(id) || !_measuring.add(id)) return;
    if (isSvg(bytes)) {
      _aspects[id] = 1;
      return;
    }
    final stream = cardImageProvider(context, bytes, longest: longest).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      _aspects[id] = info.image.width / info.image.height;
      if (mounted) setState(() {});
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  ImageSource get _source => widget.images ?? Images.I;

  Uint8List? _bytes(String id) => _loaded[id] ?? _source.peek(id);

  // Whether a picture's been looked for and isn't there, rather than still on its way.
  bool _missing(String id) => _loaded.containsKey(id) && _loaded[id] == null && _source.peek(id) == null;

  void _ask(String id) {
    if (_source.peek(id) != null || _asked.contains(id)) return;
    _asked.add(id);
    _source.load(id).then((bytes) {
      if (!mounted) return;
      setState(() => _loaded[id] = bytes);
    }).catchError((Object _) {
      if (mounted) setState(() => _loaded[id] = null);
    });
  }

  @override
  void didUpdateWidget(CardView old) {
    super.didUpdateWidget(old);
    if (old.images != widget.images) {
      _loaded.clear();
      _asked.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final colors = widget.colors ?? (bg: flash.cardBg, ink: flash.cardInk);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) return const SizedBox.shrink();
      final card = widget.card;
      final fill = card.fillImage;
      final longest = widget.onWall ? math.max(w, h) : null;

      Widget? background;
      if (fill != null) {
        _ask(fill.imageId);
        final bytes = _bytes(fill.imageId);
        background = bytes != null
            ? Positioned.fill(
                child: _Picture(
                  bytes: bytes,
                  fit: BoxFit.cover,
                  alignment: Alignment(fill.focus.x / 50 - 1, fill.focus.y / 50 - 1),
                  longest: longest,
                ),
              )
            : (_missing(fill.imageId) ? Positioned.fill(child: ColoredBox(color: colors.ink.withValues(alpha: 0.12))) : null);
      }

      final Widget content;
      if (widget.ticker && showsTicker(card)) {
        content = Center(
          child: TickerLine(
            card: card,
            color: colors.ink,
            glow: fill != null ? colors.bg : null,
            height: h,
            speed: widget.tickerSpeed,
            now: widget.now,
          ),
        );
      } else {
        content = _layout(context, card, w, h, colors, fill != null, longest);
      }

      return ClipRect(
        child: Stack(fit: StackFit.expand, children: [?background, content]),
      );
    });
  }

  Widget _layout(BuildContext context, FlashCard card, double w, double h, ({Color bg, Color ink}) colors, bool filled, double? longest) {
    final pad = widget.onWall ? math.min(0.05 * w, 0.08 * h) : widget.padFraction * w;
    final gap = widget.onWall ? math.min(0.03 * w, 0.048 * h) : 0.03 * w;
    final slotGap = 0.02 * h;
    final radius = 0.02 * w;
    final across = card.layout == 'image-left' || card.layout == 'image-right';
    final slots = groupLayers(card);

    if (slots.isEmpty) {
      if (filled) return const SizedBox.shrink();
      return Center(child: _note('This card is empty', w, colors.ink));
    }

    final children = <LayoutId>[];
    final bleeds = <bool>[];
    var imageAspects = <double?>[];
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      if (slot.isImage) {
        for (final l in slot.layers) {
          _ask(l.imageId);
        }
        // Pictures set to fill their space run out to the card's edges rather than sitting inside
        // its margin, which framed them in a border.
        final bleed = slot.layers.every((l) => l.fit == 'cover' && (_bytes(l.imageId) != null));
        bleeds.add(bleed);
        for (final l in slot.layers) {
          final bytes = _bytes(l.imageId);
          if (bytes != null) _measure(l.imageId, bytes, longest);
        }
        imageAspects = [for (final l in slot.layers) _aspects[l.imageId]];
        children.add(LayoutId(
          id: i,
          child: Column(children: [
            for (var n = 0; n < slot.layers.length; n++) ...[
              if (n > 0) SizedBox(height: slotGap),
              Expanded(child: SizedBox.expand(child: _image(slot.layers[n], w, bleed ? 0 : radius, colors.ink, longest))),
            ],
          ]),
        ));
      } else {
        bleeds.add(false);
        children.add(LayoutId(
          id: i,
          child: _TextSlot(
            layers: slot.layers,
            height: h,
            gap: slotGap,
            wrap: card.wrap,
            presenting: widget.presenting,
            color: colors.ink,
            glow: filled ? colors.bg : null,
          ),
        ));
      }
    }

    return CustomMultiChildLayout(
      delegate: _CardLayout(
        across: across,
        isImage: [for (final s in slots) s.isImage],
        bleeds: bleeds,
        pad: pad,
        gap: gap,
        slotGap: slotGap,
        imageFirst: card.layout == 'image-left',
        imageAspects: imageAspects,
      ),
      children: children,
    );
  }

  Widget _image(Layer layer, double w, double radius, Color ink, double? longest) {
    final bytes = _bytes(layer.imageId);
    if (bytes == null) {
      return _missing(layer.imageId) ? Center(child: _note('Image unavailable', w, ink)) : const SizedBox.shrink();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: _Picture(
        bytes: bytes,
        fit: layer.fit == 'cover' ? BoxFit.cover : BoxFit.contain,
        longest: longest,
        onError: () => Center(child: _note('Image unavailable', w, ink)),
      ),
    );
  }

  Widget _note(String text, double w, Color ink) => Text(
        text,
        textAlign: TextAlign.center,
        textScaler: TextScaler.noScaling,
        style: TextStyle(fontSize: 0.04 * w, color: ink.withValues(alpha: 0.55)),
      );
}

class _Picture extends StatelessWidget {
  const _Picture({required this.bytes, required this.fit, this.alignment = Alignment.center, this.longest, this.onError});
  final Uint8List bytes;
  final BoxFit fit;
  final Alignment alignment;
  final double? longest;
  final Widget Function()? onError;

  @override
  Widget build(BuildContext context) {
    if (isSvg(bytes)) return SvgPicture.memory(bytes, fit: fit, alignment: alignment);
    return Image(
      image: cardImageProvider(context, bytes, longest: longest),
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => onError?.call() ?? const SizedBox.shrink(),
    );
  }
}

/// A slot of words: its layers one under another, each as wide as the slot. With wrapping off,
/// each line stays on one line however long, overhanging the card's edges rather than breaking;
/// centred words overhang both edges evenly.
class _TextSlot extends StatelessWidget {
  const _TextSlot({
    required this.layers,
    required this.height,
    required this.gap,
    required this.wrap,
    required this.presenting,
    required this.color,
    this.glow,
  });
  final List<Layer> layers;
  final double height; // the card's
  final double gap;
  final bool wrap;
  final bool presenting;
  final Color color;
  final Color? glow;

  static const _lineHeight = 1.15;

  // As HTML draws it: runs of spaces as one when wrapping (kept with wrapping off, which is
  // white-space: pre), and a last line break adding no empty line.
  static String displayText(String text, bool wrap) {
    var t = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
    if (wrap) t = t.split('\n').map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).join('\n');
    return t;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < layers.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          _line(layers[i]),
        ],
      ],
    );
  }

  Widget _line(Layer layer) {
    final size = textFraction(layer.size) * height;
    final align = switch (layer.align) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      _ => TextAlign.center,
    };
    final empty = layer.text.trim().isEmpty;
    final style = TextStyle(
      fontSize: size,
      height: _lineHeight,
      leadingDistribution: TextLeadingDistribution.even,
      color: empty ? color.withValues(alpha: 0.45) : color,
      fontStyle: empty ? FontStyle.italic : null,
      shadows: glow == null ? null : cardGlow(size, glow!),
    );
    if (empty) {
      // Blank layers still take part in the layout while editing, so somebody adding a line
      // doesn't watch the card jump when they type the first letter. Never shown when presenting.
      return SizedBox(
        width: double.infinity,
        child: Text(presenting ? '' : 'Text', textAlign: align, style: style, textScaler: TextScaler.noScaling, strutStyle: StrutStyle(fontSize: size, height: _lineHeight, forceStrutHeight: true)),
      );
    }
    final words = displayText(layer.text, wrap);
    if (wrap) {
      return SizedBox(
        width: double.infinity,
        child: Text(words, textAlign: align, style: style, textScaler: TextScaler.noScaling, strutStyle: StrutStyle(fontSize: size, height: _lineHeight, forceStrutHeight: true)),
      );
    }
    final lines = '\n'.allMatches(words).length + 1;
    return SizedBox(
      width: double.infinity,
      height: lines * size * _lineHeight,
      child: OverflowBox(
        minWidth: 0,
        maxWidth: double.infinity,
        alignment: switch (layer.align) {
          'left' => Alignment.centerLeft,
          'right' => Alignment.centerRight,
          _ => Alignment.center,
        },
        child: Text(words, textAlign: align, softWrap: false, overflow: TextOverflow.visible, style: style, textScaler: TextScaler.noScaling, strutStyle: StrutStyle(fontSize: size, height: _lineHeight, forceStrutHeight: true)),
      ),
    );
  }
}

/// The card's slots, as the site's flex box has them: side by side for image left and right, each
/// half the width; otherwise stacked. Stacked, each slot starts as tall as its contents, a picture
/// as tall as its shape makes it at the slot's width. With room to spare the picture takes it. Without
/// enough, every slot gives up its share by how tall it is, so a picture is never squeezed out by
/// large words: the words run past their slot, over and under the picture, as they do on the site.
class _CardLayout extends MultiChildLayoutDelegate {
  _CardLayout({
    required this.across,
    required this.isImage,
    required this.bleeds,
    required this.pad,
    required this.gap,
    required this.slotGap,
    required this.imageFirst,
    required this.imageAspects,
  });
  final bool across;
  final List<bool> isImage;
  final List<bool> bleeds;
  final double pad;
  final double gap;
  final double slotGap;
  final bool imageFirst;
  final List<double?> imageAspects; // of the picture slot's pictures, null until they're known

  @override
  void performLayout(Size size) {
    final innerW = math.max(0.0, size.width - 2 * pad);
    final innerH = math.max(0.0, size.height - 2 * pad);
    final n = isImage.length;

    if (across) {
      if (n == 1) {
        if (isImage[0] && bleeds[0]) {
          layoutChild(0, BoxConstraints.tight(size));
          positionChild(0, Offset.zero);
        } else if (isImage[0]) {
          layoutChild(0, BoxConstraints.tight(Size(innerW, innerH)));
          positionChild(0, Offset(pad, pad));
        } else {
          final s = layoutChild(0, BoxConstraints(maxWidth: innerW));
          positionChild(0, Offset(pad, (size.height - s.height) / 2));
        }
        return;
      }
      // Two slots, the picture's running through the margin on its own side when it bleeds.
      final imageIndex = isImage[0] ? 0 : 1;
      final bleed = bleeds[imageIndex];
      final half = (innerW - gap + (bleed ? pad : 0)) / 2;
      final imageX = imageFirst ? (bleed ? 0.0 : pad) : size.width - (bleed ? 0.0 : pad) - half;
      final textX = imageFirst ? imageX + half + gap : pad;
      layoutChild(imageIndex, BoxConstraints.tight(Size(half, bleed ? size.height : innerH)));
      positionChild(imageIndex, Offset(imageX, bleed ? 0 : pad));
      final textIndex = 1 - imageIndex;
      final s = layoutChild(textIndex, BoxConstraints(maxWidth: half));
      positionChild(textIndex, Offset(textX, (size.height - s.height) / 2));
      return;
    }

    // Stacked.
    final texts = List<double>.filled(n, 0);
    var gaps = gap * (n - 1);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      if (isImage[i]) continue;
      texts[i] = layoutChild(i, BoxConstraints(maxWidth: innerW)).height;
      sum += texts[i];
    }
    final imageIndex = isImage.indexOf(true);
    if (imageIndex >= 0) {
      final bleed = bleeds[imageIndex];
      final slotW = bleed ? size.width : innerW;
      // A picture at the top or bottom of the stack runs through that margin too.
      final room = innerH + (bleed ? (imageIndex == 0 ? pad : 0) + (imageIndex == n - 1 ? pad : 0) : 0);
      var basis = 0.0;
      for (final aspect in imageAspects) {
        if (aspect != null && aspect > 0) basis += slotW / aspect;
      }
      if (imageAspects.length > 1) basis += slotGap * (imageAspects.length - 1);
      final bases = [for (var i = 0; i < n; i++) i == imageIndex ? basis : texts[i]];
      final total = sum + basis;
      final free = room - gaps - total;
      final heights = [
        for (var i = 0; i < n; i++)
          free >= 0 ? (i == imageIndex ? bases[i] + free : bases[i]) : (total <= 0 ? 0.0 : math.max(0.0, bases[i] * (1 + free / total))),
      ];
      layoutChild(imageIndex, BoxConstraints.tight(Size(slotW, heights[imageIndex])));
      var y = pad - (bleed && imageIndex == 0 ? pad : 0);
      for (var i = 0; i < n; i++) {
        // Words taller than their slot stay centred on it, running past both ends.
        final top = i == imageIndex ? y : y + (heights[i] - texts[i]) / 2;
        positionChild(i, Offset(isImage[i] && bleed ? 0 : pad, top));
        y += heights[i] + gap;
      }
      return;
    }
    final used = sum + gaps;
    var y = (size.height - used) / 2;
    for (var i = 0; i < n; i++) {
      positionChild(i, Offset(pad, y));
      y += texts[i] + gap;
    }
  }

  @override
  bool shouldRelayout(_CardLayout old) =>
      old.across != across || old.pad != pad || old.gap != gap || old.slotGap != slotGap || old.imageFirst != imageFirst ||
      old.imageAspects.join() != imageAspects.join() ||
      old.isImage.join() != isImage.join() || old.bleeds.join() != bleeds.join();
}
