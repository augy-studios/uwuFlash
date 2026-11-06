// The deck model (the site's js/deck.js): a stack of cards, each card a list of layers.
//
// A layer is either text or an image. Layers are ordered back to front, so the last entry draws on
// top, the way a layers panel in PowerPoint or Photoshop reads from the top down. The list on
// screen is therefore shown reversed; the list's order is the drawing order and the only order
// stored. That order is also what puts text above or below the image on a stacked layout, except
// under image-between, which splits the text around the image itself.
//
// Stored and sent in exactly the site's JSON, so a deck from the WebView app or another device
// reads as it is.
import 'dart:math' as math;

class LayoutOption {
  const LayoutOption(this.id, this.label);
  final String id;
  final String label;
}

const layouts = [
  LayoutOption('image-center', 'Image centre'),
  LayoutOption('image-left', 'Image left of text'),
  LayoutOption('image-right', 'Image right of text'),
  LayoutOption('image-between', 'Image between text'),
];
const defaultLayout = 'image-center';

/// A card can show its words as a news ticker instead: every line run together onto one line that
/// rolls across the screen. Each card has its own switch and speed.
const tickerSpeedIds = ['slow', 'normal', 'fast'];
const defaultTickerSpeed = 'normal';

String readTickerSpeed(Object? speed) => tickerSpeedIds.contains(speed) ? speed as String : defaultTickerSpeed;

const textSizes = [
  LayoutOption('s', 'Small'),
  LayoutOption('m', 'Medium'),
  LayoutOption('l', 'Large'),
  LayoutOption('xl', 'Huge'),
];
const textAligns = ['left', 'center', 'right'];

final _random = math.Random();
String _base36(int length) => [for (var i = 0; i < length; i++) _random.nextInt(36).toRadixString(36)].join();

String newId() => '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${_base36(6)}';
String newImageId() => 'img-${newId()}';

class Focus2 {
  const Focus2(this.x, this.y);
  final double x;
  final double y;

  static Focus2 read(Object? focus) {
    double pct(Object? n) => n is num && n.isFinite ? n.toDouble().clamp(0.0, 100.0) : 50.0;
    return focus is Map ? Focus2(pct(focus['x']), pct(focus['y'])) : const Focus2(50, 50);
  }

  Map<String, Object?> toJson() => {'x': _plain(x), 'y': _plain(y)};
}

// 50 rather than 50.0, as the site's JSON has it.
num _plain(double n) => n == n.truncateToDouble() ? n.toInt() : n;

class Layer {
  Layer.text({
    required this.id,
    this.text = '',
    this.size = 'l',
    this.align = 'center',
    this.hidden = false,
  })  : type = 'text',
        imageId = '',
        fit = 'contain',
        fill = false,
        focus = const Focus2(50, 50);

  Layer.image({
    required this.id,
    required this.imageId,
    this.fit = 'contain',
    this.fill = false,
    this.focus = const Focus2(50, 50),
    this.hidden = false,
  })  : type = 'image',
        text = '',
        size = 'l',
        align = 'center';

  final String type;
  String id;
  bool hidden;

  // Text.
  String text;
  String size;
  String align;

  // Image. `fill` puts the picture behind the whole card, edge to edge, with the words over it;
  // it only counts on a card with no other picture (soleImage). `focus` is the point of the
  // picture kept in view when it's cropped, as percentages across and down.
  String imageId;
  String fit;
  bool fill;
  Focus2 focus;

  bool get isImage => type == 'image';
  bool get isText => type == 'text';

  /// What's in a text layer, as the card and the ticker read it.
  bool get hasWords => isText && text.trim().isNotEmpty;

  Layer copyWithId(String newId) => isImage
      ? Layer.image(id: newId, imageId: imageId, fit: fit, fill: fill, focus: focus, hidden: hidden)
      : Layer.text(id: newId, text: text, size: size, align: align, hidden: hidden);

  /// A layer read back from storage or another device, or null if it isn't one.
  static Layer? read(Object? raw, {String? id}) {
    if (raw is! Map) return null;
    if (raw['type'] == 'image') {
      final imageId = raw['imageId'];
      if (imageId is! String || imageId.isEmpty) return null;
      return Layer.image(
        id: id ?? _readId(raw),
        imageId: imageId,
        fit: raw['fit'] == 'cover' ? 'cover' : 'contain',
        fill: raw['fill'] == true,
        focus: Focus2.read(raw['focus']),
        hidden: raw['hidden'] == true,
      );
    }
    return Layer.text(
      id: id ?? _readId(raw),
      text: raw['text'] is String ? raw['text'] as String : '',
      size: textSizes.any((s) => s.id == raw['size']) ? raw['size'] as String : 'l',
      align: textAligns.contains(raw['align']) ? raw['align'] as String : 'center',
      hidden: raw['hidden'] == true,
    );
  }

  static String _readId(Map raw) => raw['id'] is String && (raw['id'] as String).isNotEmpty ? raw['id'] as String : newId();

  Map<String, Object?> toJson() => isImage
      ? {'id': id, 'type': 'image', 'imageId': imageId, 'fit': fit, 'fill': fill, 'focus': focus.toJson(), 'hidden': hidden}
      : {'id': id, 'type': 'text', 'text': text, 'size': size, 'align': align, 'hidden': hidden};
}

class FlashCard {
  FlashCard({
    required this.id,
    this.layout = defaultLayout,
    List<Layer>? layers,
    this.ticker = false,
    this.tickerSpeed = defaultTickerSpeed,
    this.wrap = true,
  }) : layers = layers ?? [];

  factory FlashCard.blank([String text = '']) => FlashCard(id: newId(), layers: [Layer.text(id: newId(), text: text)]);

  String id;
  String layout;
  List<Layer> layers;
  bool ticker;
  String tickerSpeed;

  /// Off keeps each line of the card's words on one line, however long, rather than breaking it.
  bool wrap;

  /// The card's one picture, or null if it has none or several. Hidden pictures count: they're
  /// still on the card, and showing one again shouldn't quietly turn another one's fill off.
  Layer? get soleImage {
    final images = layers.where((l) => l.isImage).toList();
    return images.length == 1 ? images.first : null;
  }

  /// The picture filling the whole card, if it does.
  Layer? get fillImage {
    final image = soleImage;
    return image != null && image.fill && !image.hidden ? image : null;
  }

  /// The text a card is summarised by in the card strip.
  String get summary {
    final text = layers.where((l) => l.hasWords).map((l) => l.text.trim()).join(' ');
    if (text.isNotEmpty) return text.length > 40 ? '${text.substring(0, 40)}...' : text;
    return layers.any((l) => l.isImage) ? 'Image' : 'Empty card';
  }

  FlashCard duplicate() => FlashCard(
        id: newId(),
        layout: layout,
        layers: [for (final l in layers) l.copyWithId(newId())],
        ticker: ticker,
        tickerSpeed: tickerSpeed,
        wrap: wrap,
      );

  /// A card read back from storage. Written by an older build as easily as by this one, so
  /// anything missing is filled in rather than the shape trusted.
  static FlashCard read(Object? raw) {
    final m = raw is Map ? raw : const {};
    return FlashCard(
      id: m['id'] is String && (m['id'] as String).isNotEmpty ? m['id'] as String : newId(),
      layout: layouts.any((l) => l.id == m['layout']) ? m['layout'] as String : defaultLayout,
      layers: m['layers'] is List ? (m['layers'] as List).map(Layer.read).whereType<Layer>().toList() : [],
      ticker: m['ticker'] == true,
      tickerSpeed: readTickerSpeed(m['tickerSpeed']),
      wrap: m['wrap'] != false,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'layout': layout,
        'layers': [for (final l in layers) l.toJson()],
        'ticker': ticker,
        'tickerSpeed': tickerSpeed,
        'wrap': wrap,
      };
}

class Deck {
  Deck(this.cards);
  factory Deck.blank() => Deck([FlashCard.blank()]);

  List<FlashCard> cards;

  static Deck read(Object? raw) {
    final cards = raw is Map ? raw['cards'] : null;
    if (cards is! List || cards.isEmpty) return Deck.blank();
    return Deck(cards.map(FlashCard.read).toList());
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'cards': [for (final c in cards) c.toJson()],
      };

  /// Every image id the deck still refers to: a picture is only dropped once no card points at it.
  Set<String> get imageIds => {
        for (final c in cards)
          for (final l in c.layers)
            if (l.isImage && l.imageId.isNotEmpty) l.imageId,
      };

  /// A deck still the one blank card a first visit starts with has nothing to keep.
  bool get isBlank => cards.length == 1 && cards.first.layers.every((l) => l.isText && l.text.trim().isEmpty);
}

/// Cards copied in from another device, given fresh ids throughout, so none of them can collide
/// with a card already here.
List<FlashCard> freshCards(List<FlashCard> cards) => [
      for (final c in cards)
        FlashCard(
          id: newId(),
          layout: c.layout,
          layers: [for (final l in c.layers) l.copyWithId(newId())],
          ticker: c.ticker,
          tickerSpeed: readTickerSpeed(c.tickerSpeed),
          wrap: c.wrap,
        ),
    ];

/// Move an item within a list, in place. Used by the layer list and the card strip.
bool moveInList<T>(List<T> list, int from, int to) {
  if (from == to || from < 0 || from >= list.length || to < 0 || to >= list.length) return false;
  list.insert(to, list.removeAt(from));
  return true;
}

// ---------- what a card draws ----------

const tickerGap = '   •   ';

/// Every line of text on the card, run together onto one line.
String tickerText(FlashCard card) => card.layers
    .where((l) => l.isText && !l.hidden && l.text.trim().isNotEmpty)
    .map((l) => l.text.replaceAll(RegExp(r'\s+'), ' ').trim())
    .join(tickerGap);

bool hasTickerText(FlashCard card) => tickerText(card).isNotEmpty;

/// Whether a card is drawn as a ticker: its own switch is on and it has words to roll.
bool showsTicker(FlashCard? card) => card != null && card.ticker && hasTickerText(card);

class CardSlot {
  CardSlot(this.isImage, this.layers);
  final bool isImage;
  final List<Layer> layers;
}

/// The layout decides whether the image sits beside the text or stacked with it. Where in the
/// stack is the layer order's business: text layers before the image draw above it, text layers
/// after it draw below. A card with no image draws as text alone whatever its layout says, so
/// switching layouts never blanks a card. Empty slots are left out.
List<CardSlot> groupLayers(FlashCard card) {
  final visible = card.layers.where((l) => !l.hidden).toList();
  final texts = visible.where((l) => l.isText).toList();
  List<CardSlot> slots;

  if (card.fillImage != null) {
    // A picture filling the card is drawn behind it, not in a slot.
    slots = [CardSlot(false, texts)];
  } else {
    final images = visible.where((l) => l.isImage).toList();
    if (images.isEmpty) {
      slots = [CardSlot(false, visible)];
    } else if (card.layout == 'image-between') {
      // The one layout that places the image itself: text is split down the middle and the image
      // goes in the gap, wherever the layers sit in the list.
      final half = (texts.length / 2).ceil();
      slots = [CardSlot(false, texts.sublist(0, half)), CardSlot(true, images), CardSlot(false, texts.sublist(half))];
    } else if (card.layout == 'image-left') {
      slots = [CardSlot(true, images), CardSlot(false, texts)];
    } else if (card.layout == 'image-right') {
      slots = [CardSlot(false, texts), CardSlot(true, images)];
    } else {
      // image-center: the text split on the image's position in the list, so the layer arrows
      // move the picture up and down the card. Several images draw as one block at the first
      // one's place.
      final first = visible.indexOf(images.first);
      final last = visible.indexOf(images.last);
      slots = [
        CardSlot(false, visible.sublist(0, first)),
        CardSlot(true, images),
        CardSlot(false, visible.sublist(last + 1).where((l) => l.isText).toList()),
      ];
    }
  }
  return slots.where((s) => s.layers.isNotEmpty).toList();
}
