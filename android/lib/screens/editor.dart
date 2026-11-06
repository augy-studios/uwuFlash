// The editor (the site's index.html and js/app.js): the brand line, the card's preview, where the
// image sits, the ticker, the layers and the cards.
//
// The panels read the deck as they draw, so they're never made const: Flutter doesn't redraw a const
// widget, and the card would stop following what's typed.
// ignore_for_file: prefer_const_constructors
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' hide Focus;
import 'package:flutter/material.dart' as m show Focus;
import 'package:flutter/services.dart';

import '../app/edge_tray.dart';
import '../app/state.dart';
import '../card/card_view.dart';
import '../data/deck.dart';
import '../data/images.dart';
import '../native/screen.dart';
import '../theme/icons.dart';
import '../theme/theme.dart';
import '../ui/kit.dart';

class Editor extends StatelessWidget {
  const Editor({super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final narrow = width <= 480;
    final side = narrow ? 10.0 : 14.0;
    final button = TrayMetrics.button(width);
    final edge = TrayMetrics.edge(width, media.padding.right);

    return ValueListenableBuilder<bool>(
      valueListenable: TrayMetrics.open,
      builder: (context, open, _) {
        // Keeping the page clear of the tray: on a screen narrow enough that the column meets it, the
        // column makes room while the tray is open. Collapsed, only the brand line steps in, clear of
        // the tab, so everything else keeps the full width.
        final meets = width <= 920;
        final still = MediaQuery.disableAnimationsOf(context);
        final time = still ? Duration.zero : TrayMetrics.time;
        final roomRight = meets && open ? button + edge + 12 : side;
        final brandRight = meets && !open ? TrayMetrics.tabWidth + 10 - side : 0.0;
        return AnimatedPadding(
          duration: time,
          curve: TrayMetrics.ease,
          padding: EdgeInsets.only(right: math.max(roomRight, media.padding.right), left: math.max(side, media.padding.left)),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListenableBuilder(
                listenable: AppState.I,
                // Everything built all the time, not a lazy list: there's only a screen or two of it,
                // and the text box mustn't lose its place when it scrolls away. Not const, so each
                // redraws as the deck changes.
                builder: (context, _) => SingleChildScrollView(
                  padding: EdgeInsets.only(top: media.padding.top + (narrow ? 10 : 14), bottom: math.max(narrow ? 24 : 28, media.padding.bottom + 12)),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: spaced([
                      AnimatedPadding(duration: time, curve: TrayMetrics.ease, padding: EdgeInsets.only(right: brandRight), child: const _Brand()),
                      _Preview(),
                      _LayoutPanel(),
                      _TickerPanel(),
                      _LayersPanel(),
                      _CardsPanel(),
                    ], 14),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The brand line: the logo and the name, and nothing else.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(children: [
        ExcludeSemantics(
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: flash.border)),
            clipBehavior: Clip.antiAlias,
            child: Image.asset('assets/images/logo.png', fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            header: true,
            child: Text('uwuFlash', style: you ? Theme.of(context).textTheme.titleLarge!.copyWith(color: flash.brandInk) : TextStyle(fontSize: 21.6, color: flash.brandInk)),
          ),
        ),
      ]),
    );
  }
}

/// The card as it stands, in the card's own colours. While a picture fills it, dragging moves the crop.
class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  static const _nudge = 2.0, _nudgeFar = 10.0;
  Focus2? _from;
  Offset _start = Offset.zero;
  double _spareX = 0, _spareY = 0;

  Future<void> _begin(Layer layer, Offset at, Size box) async {
    _from = layer.focus;
    _start = at;
    _spareX = _spareY = 0;
    // How far the picture overhangs the card each way once scaled to cover it.
    final bytes = await Images.I.load(layer.imageId);
    if (bytes == null || !mounted) return;
    final stream = cardImageProvider(context, bytes).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final w = info.image.width.toDouble(), h = info.image.height.toDouble();
      final scale = math.max(box.width / w, box.height / h);
      _spareX = w * scale - box.width;
      _spareY = h * scale - box.height;
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  // Dragging moves the picture with the finger, so dragging right shows more of the left of it. A
  // picture exactly the card's shape has nothing to crop one way, and doesn't move that way.
  void _drag(Layer layer, Offset at) {
    final from = _from;
    if (from == null) return;
    double along(double start, double delta, double spare) => spare > 0.5 ? start - delta / spare * 100 : start;
    double round(double n) => (n.clamp(0.0, 100.0) * 10).roundToDouble() / 10;
    layer.focus = Focus2(round(along(from.x, at.dx - _start.dx, _spareX)), round(along(from.y, at.dy - _start.dy, _spareY)));
    AppState.I.changed(save: false);
  }

  KeyEventResult _key(Layer layer, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final step = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
      LogicalKeyboardKey.arrowRight => const Offset(1, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, -1),
      LogicalKeyboardKey.arrowDown => const Offset(0, 1),
      _ => null,
    };
    if (step == null) return KeyEventResult.ignored;
    final by = HardwareKeyboard.instance.isShiftPressed ? _nudgeFar : _nudge;
    layer.focus = Focus2((layer.focus.x - step.dx * by).clamp(0.0, 100.0), (layer.focus.y - step.dy * by).clamp(0.0, 100.0));
    AppState.I.changed();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final app = AppState.I;
    final card = app.card;
    final fill = card.fillImage;
    final radius = BorderRadius.circular(context.materialYou ? 24 : 16);
    Widget view = AspectRatio(
      aspectRatio: 16 / 10,
      child: Container(
        decoration: BoxDecoration(color: flash.cardBg, borderRadius: radius, border: Border.all(color: flash.border)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: fill == null ? null : (d) => _begin(fill, d.localPosition, box.biggest),
            onPanUpdate: fill == null ? null : (d) => _drag(fill, d.localPosition),
            onPanEnd: fill == null
                ? null
                : (_) {
                    _from = null;
                    app.persist();
                  },
            child: CardView(card: card),
          ),
        ),
      ),
    );
    if (fill != null) {
      view = m.Focus(onKeyEvent: (_, e) => _key(fill, e), child: view);
    }
    return Semantics(
      label: fill != null ? 'Card preview. Drag the picture, or use the arrow keys, to move the crop.' : 'Card preview',
      container: true,
      explicitChildNodes: true,
      child: view,
    );
  }
}

class _LayoutPanel extends StatelessWidget {
  const _LayoutPanel();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final narrow = MediaQuery.sizeOf(context).width <= 480;
    return UiPanel(
      title: 'Where the image sits',
      children: [
        _Grid(
          columns: narrow ? 2 : 4,
          children: [
            for (final l in layouts)
              _LayoutButton(
                option: l,
                on: app.card.layout == l.id,
                onTap: () {
                  app.card.layout = l.id;
                  app.changed();
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});
  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var n = i; n < i + columns; n++) ...[
            if (n > i) const SizedBox(width: 8),
            Expanded(child: n < children.length ? children[n] : const SizedBox.shrink()),
          ],
        ]),
      ));
    }
    return Column(children: spaced(rows, 8));
  }
}

class _LayoutButton extends StatelessWidget {
  const _LayoutButton({required this.option, required this.on, required this.onTap});
  final LayoutOption option;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final ink = on ? flash.onBrand : flash.mutedStrong;
    final radius = you ? 20.0 : 14.0;
    return Semantics(
      button: true,
      selected: on,
      label: option.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: on ? flash.brandFill : (you ? scheme.surfaceContainerHigh : flash.surface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: you ? BorderSide.none : BorderSide(color: flash.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _LayoutThumb(id: option.id, color: ink),
              const SizedBox(height: 6),
              Text(option.label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.2, color: ink)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A diagram of where the picture sits, in the text's colour.
class _LayoutThumb extends StatelessWidget {
  const _LayoutThumb({required this.id, required this.color});
  final String id;
  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget block(double alpha, int flex) => Expanded(
          flex: flex,
          child: Container(decoration: BoxDecoration(color: color.withValues(alpha: alpha), borderRadius: BorderRadius.circular(2))),
        );
    final picture = block(0.85, id == 'image-left' || id == 'image-right' ? 1 : 2);
    final words = block(0.35, 1);
    final Widget inner = switch (id) {
      'image-left' => Row(children: [picture, const SizedBox(width: 2), words]),
      'image-right' => Row(children: [words, const SizedBox(width: 2), picture]),
      'image-between' => Column(children: [words, const SizedBox(height: 2), picture]),
      _ => Column(children: [picture, const SizedBox(height: 2), words]),
    };
    return Container(
      width: 38,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), border: Border.all(color: color)),
      child: inner,
    );
  }
}

class _TickerPanel extends StatelessWidget {
  const _TickerPanel();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final card = app.card;
    final on = card.ticker;
    final wrap = card.wrap;
    return UiPanel(
      title: 'Ticker',
      children: [
        // This card only. Also switched from the presenter.
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          UiButton(
            label: on ? 'Ticker on' : 'Ticker off',
            icon: 'ticker',
            kind: on ? ButtonKind.primary : ButtonKind.plain,
            pressed: on,
            onTap: () => app.setTicker(card, !on),
          ),
        ]),
        if (on)
          UiSeg<String>(
            semantic: 'Ticker speed',
            options: const [SegOption('slow', 'Slow'), SegOption('normal', 'Normal'), SegOption('fast', 'Fast')],
            value: readTickerSpeed(card.tickerSpeed),
            onChanged: (v) {
              card.tickerSpeed = v;
              app.changed();
            },
          ),
        const UiNote('With the ticker on, this card\'s words roll along one line, round and round, like a news ticker, when it is shown.'),
        // Only while the ticker is off: a ticker never wraps.
        if (!on) ...[
          Wrap(children: [
            UiButton(
              label: wrap ? 'Wrapping on' : 'Wrapping off',
              icon: 'text',
              kind: wrap ? ButtonKind.primary : ButtonKind.plain,
              pressed: wrap,
              onTap: () {
                card.wrap = !wrap;
                app.changed();
              },
            ),
          ]),
          const UiNote('With wrapping off, each line of this card\'s words stays on one line, however long, rather than breaking to fit.'),
        ],
      ],
    );
  }
}

class _LayersPanel extends StatelessWidget {
  const _LayersPanel();

  Future<void> _pick(Layer? replacing) async {
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'Images', mimeTypes: ['image/*'], extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'svg']),
      ]);
    } catch (_) {
      AppNav.say('Could not open the picture.');
      return;
    }
    if (file == null) return;
    await AppState.I.addImage(await file.readAsBytes(), replacing: replacing);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final card = app.card;
    final layers = card.layers;
    return UiPanel(
      title: 'Layers',
      children: [
        if (layers.isEmpty)
          const UiNote('No layers yet. Add text or an image.')
        else
          // Back to front in the list, top down on screen, the way a layers panel reads.
          Column(children: spaced([
            for (var i = layers.length - 1; i >= 0; i--) _LayerRow(layer: layers[i], index: i, count: layers.length),
          ], 6)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          UiButton(label: 'Add text', icon: 'text', onTap: app.addTextLayer),
          UiButton(label: 'Add image', icon: 'image', onTap: () => _pick(null)),
        ]),
        _Inspector(key: ValueKey(app.selectedLayerId), onReplace: _pick),
      ],
    );
  }
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({required this.layer, required this.index, required this.count});
  final Layer layer;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final app = AppState.I;
    final selected = layer.id == app.selectedLayerId;
    final trimmed = layer.text.trim();
    final label = layer.isImage ? 'Image' : (trimmed.isEmpty ? 'Empty text' : (trimmed.length > 28 ? trimmed.substring(0, 28) : trimmed));
    final ink = selected ? flash.onBrand : flash.ink;

    Widget action(String icon, String tip, VoidCallback? onTap) => _SmallIcon(icon: icon, tooltip: tip, onTap: onTap, color: ink);

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
      decoration: BoxDecoration(
        color: selected ? flash.brandFill : (you ? scheme.surfaceContainerHigh : flash.surface),
        borderRadius: BorderRadius.circular(you ? 20 : 14),
      ),
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            selected: selected,
            label: label,
            excludeSemantics: true,
            onTap: () => app.selectLayer(layer.id),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => app.selectLayer(layer.id),
              child: Opacity(
                opacity: layer.hidden ? 0.5 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Row(children: [
                    AppIcon(layer.isImage ? 'image' : 'text', size: 16, color: ink),
                    const SizedBox(width: 8),
                    Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.6, color: ink))),
                  ]),
                ),
              ),
            ),
          ),
        ),
        action(layer.hidden ? 'eyeOff' : 'eye', layer.hidden ? 'Show layer' : 'Hide layer', () => app.toggleLayer(layer)),
        action('up', 'Bring forward', index == count - 1 ? null : () => app.reorderLayer(layer, 1)),
        action('down', 'Send backward', index == 0 ? null : () => app.reorderLayer(layer, -1)),
        action('trash', 'Delete layer', () => app.removeLayer(layer)),
      ]),
    );
  }
}

class _SmallIcon extends StatelessWidget {
  const _SmallIcon({required this.icon, required this.tooltip, required this.onTap, required this.color});
  final String icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Tooltip(
        excludeFromSemantics: true,
        message: tooltip,
        child: Semantics(
          button: true,
          enabled: onTap != null,
          label: tooltip,
          excludeSemantics: true,
          onTap: onTap,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Opacity(
              opacity: onTap == null ? 0.35 : 1,
              child: SizedBox(width: 32, height: 34, child: Center(child: AppIcon(icon, size: 16, color: color))),
            ),
          ),
        ),
      );
}

class _Inspector extends StatefulWidget {
  const _Inspector({super.key, required this.onReplace});
  final Future<void> Function(Layer layer) onReplace;

  @override
  State<_Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<_Inspector> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _text.text = AppState.I.selectedLayer?.text ?? '';
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final layer = app.selectedLayer;
    if (layer == null) return const UiNote('Select a layer to edit it.');
    if (layer.isText) {
      // Words that came from somewhere else (speech), which the box hasn't heard about.
      if (_text.text != layer.text) _text.text = layer.text;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
        _Field(
          label: 'Text',
          child: TextField(
            controller: _text,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(fontSize: 15.2, color: context.flash.ink),
            decoration: const InputDecoration(hintText: 'Type what the room should read', isDense: true),
            onChanged: (v) {
              layer.text = v;
              app.changed();
            },
          ),
        ),
        // Android's own speech screen. No microphone permission: it has its own.
        if (Screen.canListen)
          Wrap(children: [
            UiButton(
              label: 'Speak',
              icon: 'mic',
              onTap: () async {
                final said = await Screen.listen('Say what the card should read');
                if (said != null) app.addSpoken(layer, said);
              },
            ),
          ]),
        _Field(
          label: 'Size',
          child: UiSeg<String>(
            options: [for (final s in textSizes) SegOption(s.id, s.label)],
            value: layer.size,
            onChanged: (v) {
              layer.size = v;
              app.changed();
            },
          ),
        ),
        _Field(
          label: 'Alignment',
          child: UiSeg<String>(
            options: const [SegOption('left', 'Left'), SegOption('center', 'Center'), SegOption('right', 'Right')],
            value: layer.align,
            onChanged: (v) {
              layer.align = v;
              app.changed();
            },
          ),
        ),
      ], 10));
    }

    // Filling the whole card is only offered on a card with one picture: two can't both be behind
    // everything.
    final sole = app.card.soleImage == layer;
    final fills = sole && layer.fill;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
      _Field(
        label: 'Image fit',
        child: UiSeg<String>(
          options: [
            const SegOption('contain', 'Fit whole image'),
            const SegOption('cover', 'Fill the space'),
            if (sole) const SegOption('screen', 'Fill the screen'),
          ],
          value: fills ? 'screen' : layer.fit,
          onChanged: (v) {
            // Filling the screen keeps the fit underneath, so turning it off puts the picture back
            // the way it was in its own space.
            if (v == 'screen') {
              layer.fill = true;
            } else {
              layer.fill = false;
              layer.fit = v;
            }
            app.changed();
          },
        ),
      ),
      if (fills) const UiNote('Drag the picture in the preview to choose which part shows. The words sit on top of it.', strong: true),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (fills)
          UiButton(
            label: 'Re-centre',
            icon: 'refresh',
            onTap: () {
              layer.focus = const Focus2(50, 50);
              app.changed();
            },
          ),
        UiButton(label: 'Replace image', kind: ButtonKind.quiet, onTap: () => widget.onReplace(layer)),
      ]),
    ], 10));
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(label, style: TextStyle(fontSize: 12.8, color: context.flash.muted)),
        const SizedBox(height: 6),
        child,
      ]);
}

class _CardsPanel extends StatelessWidget {
  const _CardsPanel();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final flash = context.flash;
    return UiPanel(
      title: 'Cards',
      trailing: Text('${app.cardIndex + 1} of ${app.deck.cards.length}', style: TextStyle(fontSize: 12.8, color: flash.muted)),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              for (var i = 0; i < app.deck.cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _CardChip(index: i, card: app.deck.cards[i], on: i == app.cardIndex),
              ],
            ]),
          ),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          UiButton(label: 'New card', icon: 'plus', onTap: app.addCard),
          UiButton(label: 'Duplicate', icon: 'copy', onTap: app.duplicateCard),
          UiButton(icon: 'left', tooltip: 'Move card earlier', onTap: () => app.moveCard(-1)),
          UiButton(icon: 'right', tooltip: 'Move card later', onTap: () => app.moveCard(1)),
          UiButton(label: 'Delete', icon: 'trash', kind: ButtonKind.quiet, onTap: app.deleteCard),
        ]),
      ],
    );
  }
}

class _CardChip extends StatelessWidget {
  const _CardChip({required this.index, required this.card, required this.on});
  final int index;
  final FlashCard card;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final ink = on ? flash.onBrand : flash.ink;
    final summary = card.summary;
    void select() => AppState.I.selectCard(index);
    return Semantics(
      button: true,
      selected: on,
      label: 'Card ${index + 1}: $summary',
      excludeSemantics: true,
      onTap: select,
      child: Material(
        color: on ? flash.brandFill : (you ? scheme.surfaceContainerHigh : flash.surface),
        shape: StadiumBorder(side: you ? BorderSide.none : BorderSide(color: flash.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: select,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: you ? scheme.surfaceContainerHighest : flash.surfaceStrong),
                child: Text('${index + 1}', style: TextStyle(fontSize: 11.2, color: you ? scheme.onSurface : ink)),
              ),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width <= 480 ? 90 : 130),
                child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.8, color: ink)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
