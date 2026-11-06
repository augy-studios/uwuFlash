// The other screen: the guest's side of sharing (the site's js/viewer.js; see STUN-p2p-spec.md at the
// repo root, and share_host.dart for the host's side).
//
// It joins a host by code, then waits on a plain screen until the host presses play; from then on it
// shows whatever card the host is presenting, in the host's colours, and goes back to waiting when
// the host stops. It never touches this device's own deck or its saved theme: pictures are held in
// memory only.
//
// On a Big Screen this is one of several screens showing one card. The host says where it sits in the
// grid, and it draws the whole card at the size of the whole grid with only its own piece inside the
// screen. Asked to, it shows its number over everything, so the screens can be put in order, or lines
// across the whole wall, so the bezels between them can be set.
//
// With the card's ticker on, its words roll along one line instead, timed by the host's clock so that
// every screen of a Big Screen has the line in the same place.
//
// The one exception is a host that picked Send. Then nothing is shown, and the host's whole deck
// arrives instead, pictures and all, with a choice to add it to this device's cards or replace them.
//
// Everything that arrives is input from another device, so it's checked field by field before it's
// used.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter/rendering.dart' show EdgeInsets;
import 'package:flutter/widgets.dart' show Size;

import '../app/state.dart';
import '../card/ticker.dart' show tickerSpeeds;
import '../data/deck.dart';
import '../data/images.dart';
import '../data/store.dart';
import '../native/native_bridge.dart';
import '../native/screen.dart';
import '../theme/theme.dart';
import 'p2p.dart';

// Measured in time, not missed snapshots: at twenty a second, three missed is shorter than an ordinary
// wifi stall.
const _staleMs = 2000;
const _beatEvery = Duration(milliseconds: 500);
// A card whose picture hasn't arrived yet is held back this long, so it doesn't paint its words first
// and the picture a moment later.
const _imageWaitMs = 4000;
const _retryFirstMs = 2000;
const _retryMaxMs = 30000;
// A screen this close to the card's shape fills itself with the card, cropping a sliver, rather than
// showing thin bars down two sides.
const _shapeSlack = 0.12;
// The host's clock is read off each snapshot. The one that took least time to arrive is the truest, so
// the best of the last few seconds is kept.
const _clockWindowMs = 5000;

const _maxImages = 40;
const _maxIncoming = 4;
const _maxChunks = 1000;
const _maxChunkChars = 16000;
const _maxLayers = 40;
const _maxText = 2000;
const _maxDeckCards = 500;
// Replace throws away this device's own cards, so it takes a second tap within this long.
const _armMs = 4000;
final _imageIdRe = RegExp(r'^img-[a-z0-9-]{1,40}$');
const _imageTypes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/avif', 'image/bmp', 'image/svg+xml'};

class WallPlace {
  WallPlace({required this.n, required this.of, required this.col, required this.row, required this.cols, required this.rows, required this.identify, required this.lines, required this.box});
  final int n, of, col, row, cols, rows;
  final bool identify, lines;
  final ({double x, double y, double w, double h}) box;
}

class ViewState {
  ViewState({required this.mode, required this.card, required this.color, required this.dark, required this.cardColors, required this.wall, required this.shape, required this.tickerSpeed});
  final String mode; // "show" or "send"
  final FlashCard? card;
  final String color; // a brand colour's id
  final bool dark;
  final ({Color bg, Color ink})? cardColors; // Material You's, from another uwuFlash app
  final WallPlace? wall;
  final double? shape;
  final String? tickerSpeed;

  bool get presenting => card != null;
}

class Offer {
  Offer(this.cards, this.imageIds);
  final List<FlashCard> cards;
  final Set<String> imageIds;
  final Map<String, Uint8List> blobs = {};
  final Set<String> missing = {};
}

class _Incoming {
  _Incoming(this.mime, this.total) : parts = List<String?>.filled(total, null);
  final String mime;
  final int total;
  final List<String?> parts;
  int count = 0;
}

/// What the viewer's panel says and offers.
class ViewerPanel {
  ViewerPanel(this.title, this.message, this.actions, this.badge);
  final String title;
  final String message;
  final Set<String> actions; // leave, retry, fullscreen, copy
  final String badge;
}

class Viewer extends ChangeNotifier implements ImageSource {
  Viewer._();
  static final Viewer I = Viewer._();

  bool isOpen = false;
  String code = '';
  String status = 'idle';
  ViewState? state;
  Offer? offer;
  bool copying = false;
  bool replaceArmed = false;
  bool appFull = false;

  Guest? _guest;
  String _failure = '';
  bool _ended = false;
  bool _removed = false;
  bool _outdated = false;
  bool _full = false;
  bool _resuming = false;
  Timer? _retryTimer;
  int _retryDelay = _retryFirstMs;
  int _lastStateAt = 0;
  Timer? _beatTimer;
  bool _askNearby = false;
  Timer? _armTimer;
  String _screenId = '';
  Size _screen = const Size(800, 400);

  // Image id -> bytes, oldest first.
  final Map<String, Uint8List> _images = {};
  final Map<String, _Incoming> _incoming = {};

  // What's on screen: a key for the card and the pictures arrived, so a card only redraws when
  // something about it has changed.
  FlashCard? shownCard;
  String? shownTicker;
  String _shownKey = '';
  String _waitKey = '';
  int _waitSince = 0;
  String _visibleKey = '';

  /// A place moved to in the same grid, for the screen to slide: as -1, 0 or 1 across and down.
  final moves = StreamController<({int dx, int dy})>.broadcast();

  // Host clock minus this one's, from snapshots: [(at, offset)], newest last.
  final List<(int, int)> _clockSamples = [];

  // ---------- pictures, as a card asks for them ----------

  @override
  Uint8List? peek(String id) => offer?.blobs[id] ?? _images[id];

  @override
  Future<Uint8List?> load(String id) async => peek(id);

  // ---------- joining ----------

  /// `ask`: started by somebody pressing Join or scanning a code, so the app may ask for what joining
  /// with no wifi needs.
  bool startViewing(String input, {bool ask = false}) {
    final next = normaliseCode(input);
    if (!isValidCode(next)) return false;
    code = next;
    _askNearby = ask;
    Store.I.put('uwuflash.lastCode', code);
    Store.I.put('uwuflash.shareRole', 'guest');
    _ended = false;
    _removed = false;
    _outdated = false;
    _resuming = false;
    _retryDelay = _retryFirstMs;
    state = null;
    _clockSamples.clear();
    _showNothing();
    _open();
    _join();
    return true;
  }

  /// The screen this device was last showing, after the app was closed.
  void resume() {
    if (Store.I.get('uwuflash.shareRole') != 'guest') return;
    final last = Store.I.get('uwuflash.lastCode');
    if (isValidCode(last)) startViewing(last!);
  }

  /// What this screen calls itself to the host, so a Big Screen puts it back in the same place after a
  /// dropped connection or a restart.
  String _ownScreenId() {
    if (_screenId.isNotEmpty) return _screenId;
    final kept = Store.I.get('uwuflash.screenId');
    if (kept != null && RegExp(r'^[a-z0-9]{6,24}$').hasMatch(kept)) return _screenId = kept;
    final r = math.Random.secure();
    _screenId = [for (var i = 0; i < 12; i++) r.nextInt(36).toRadixString(36)].join();
    Store.I.put('uwuflash.screenId', _screenId);
    return _screenId;
  }

  /// This screen's size, and how many of its pixels make a millimetre, so a Big Screen of different
  /// screens can line them up by how big they really are. Phones draw about 160 to the inch, tablets
  /// about 132. Two of the same model always agree, which is the usual Big Screen.
  Map<String, Object?> _screenSize() {
    final short = math.min(_screen.width, _screen.height);
    final perInch = short < 600 ? 160 : 132;
    return {'w': _screen.width, 'h': _screen.height, 'ppm': (perInch / 25.4 * 1000).roundToDouble() / 1000};
  }

  /// The screen's size, from what draws it.
  void setScreen(Size size) {
    if (size == _screen) return;
    _screen = size;
    if (isOpen) _sendSizeSoon();
  }

  // Being turned or resized says so many times a second; the host only needs where it ends up.
  Timer? _resizeTimer;
  void _sendSizeSoon() {
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 250), () => _guest?.send({'type': 'size', ..._screenSize()}));
  }

  Future<void> _join() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    final old = _guest;
    _guest = null;
    old?.close();

    final g = Guest(introduce: () => {'screen': _ownScreenId(), ..._screenSize()});
    _guest = g;
    status = 'connecting';
    _failure = '';
    _full = false;
    notifyListeners();

    g.onStatus = (s, {message, type, taken = false}) {
      if (_guest == g) _onStatus(s, message);
    };
    g.onMessage = (message, _) {
      if (_guest == g) _onMessage(message);
    };
    final ask = _askNearby;
    _askNearby = false;
    await g.connect(code, ask: ask);
  }

  void _onStatus(String s, String? message) {
    switch (s) {
      case 'connecting':
        status = 'connecting';
      case 'connected':
        status = 'connected';
        _resuming = false;
        _retryDelay = _retryFirstMs;
        _lastStateAt = DateTime.now().millisecondsSinceEpoch;
        // Pictures kept from before a reconnect are still good.
        _sendHave();
      case 'dropped':
        status = 'dropped';
        _resuming = true;
        _scheduleRetry();
      case 'unreachable':
        status = 'unreachable';
        if (_resuming) _scheduleRetry();
      case 'error':
        status = 'error';
        _failure = message ?? 'The connection failed.';
        if (_resuming) _scheduleRetry();
      default:
        return;
    }
    notifyListeners();
  }

  void _scheduleRetry() {
    if (!isOpen) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: _retryDelay), _join);
    _retryDelay = math.min(_retryDelay * 2, _retryMaxMs);
  }

  void _hangUp() {
    final g = _guest;
    _guest = null;
    g?.onStatus = null;
    g?.close();
    status = 'idle';
  }

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'state':
        final next = readState(message);
        final move = _placeMove(state?.wall, next.wall);
        state = next;
        _lastStateAt = DateTime.now().millisecondsSinceEpoch;
        final clock = message['clock'];
        if (clock is num && clock.isFinite) _noteClock(clock.toInt());
        // The host went back to showing cards. Its deck is no longer on offer.
        if (next.mode != 'send' && offer != null) _dropOffer();
        _apply();
        if (move != null) moves.add(move);
        return;
      case 'deck':
        offer = readOffer(message, offer);
        _disarmReplace();
        // A fresh copy may want pictures the last one didn't.
        _sendHave();
      case 'image':
        _receiveImage(message);
      case 'noimage':
        final id = message['id'];
        if (id is String && (offer?.imageIds.contains(id) ?? false)) offer!.missing.add(id);
      case 'removed':
      case 'end':
        // The host stopped on purpose, or let this screen go. Either way there's nothing to come back to.
        _ended = true;
        _removed = message['type'] == 'removed';
        state = null;
        _dropOffer();
        _retryTimer?.cancel();
        _resuming = false;
        _hangUp();
        _apply();
      case 'outdated':
        _outdated = true;
        _hangUp();
      case 'full':
        _hangUp();
        // Coming back from a drop, the place held by this screen's old connection frees up when the
        // host notices it went quiet.
        if (_resuming) {
          _scheduleRetry();
        } else {
          _full = true;
        }
      default:
        // Anything from a newer build. Never thrown on.
        return;
    }
    notifyListeners();
  }

  // While a deck is on offer, the pictures it needs are the only ones that count; the host isn't
  // showing anything.
  void _sendHave() {
    final held = offer != null ? offer!.blobs.keys : _images.keys;
    _guest?.send({'type': 'have', 'images': held.toList()});
  }

  void _dropOffer() {
    offer = null;
    _disarmReplace();
  }

  // ---------- checking what arrives ----------

  @visibleForTesting
  static ViewState readState(Map<String, dynamic> m) {
    final theme = m['theme'] is Map ? m['theme'] as Map : const {};
    final color = AppLook.swatches.any((s) => s.id == theme['color']) ? theme['color'] as String : AppLook.swatches.first.id;
    final mode = m['mode'] == 'send' ? 'send' : 'show';
    final card = mode == 'show' && m['presenting'] == true ? _readCard(m['card']) : null;
    final wall = mode == 'show' ? _readWall(m['wall']) : null;
    final shape = m['shape'] is num && (m['shape'] as num).isFinite ? (m['shape'] as num).toDouble().clamp(0.25, 4.0) : null;
    final ticker = m['ticker'] is Map ? (m['ticker'] as Map)['speed'] : null;
    final tickerSpeed = card != null && ticker is String && tickerSpeeds.containsKey(ticker) ? ticker : null;
    final cardTheme = theme['card'];
    ({Color bg, Color ink})? cardColors;
    if (cardTheme is Map) {
      final bg = hexColor(cardTheme['bg']), ink = hexColor(cardTheme['ink']);
      if (bg != null && ink != null) cardColors = (bg: bg, ink: ink);
    }
    return ViewState(mode: mode, card: card, color: color, dark: theme['mode'] == 'dark', cardColors: cardColors, wall: wall, shape: shape, tickerSpeed: tickerSpeed);
  }

  /// Where this screen sits in a Big Screen, or null for the whole card. Every number has to agree
  /// with the others, or the screen draws the whole card rather than some other screen's piece.
  static WallPlace? _readWall(Object? wall) {
    if (wall is! Map) return null;
    bool within(Object? n, int min, int max) => n is num && n == n.truncate() && n >= min && n <= max;
    final n = wall['n'], of = wall['of'], col = wall['col'], row = wall['row'], cols = wall['cols'], rows = wall['rows'];
    if (!within(cols, 1, maxScreens) || !within(rows, 1, maxScreens)) return null;
    final c = (cols as num).toInt(), r = (rows as num).toInt();
    if (c * r > maxScreens * 2 || !within(col, 0, c - 1) || !within(row, 0, r - 1) || !within(of, 1, maxScreens) || !within(n, 1, (of as num).toInt())) {
      return null;
    }
    return WallPlace(
      n: (n as num).toInt(),
      of: of.toInt(),
      col: (col as num).toInt(),
      row: (row as num).toInt(),
      cols: c,
      rows: r,
      identify: wall['identify'] == true,
      lines: wall['lines'] == true,
      box: _readBox(wall['box'], col.toInt(), row.toInt(), c, r),
    );
  }

  // The whole wall measured in this screen. Without one, from a host before screens had sizes, every
  // screen takes an equal share.
  static ({double x, double y, double w, double h}) _readBox(Object? box, int col, int row, int cols, int rows) {
    bool fine(Object? n, double min, double max) => n is num && n.isFinite && n >= min && n <= max;
    if (box is Map && fine(box['w'], 1, 100) && fine(box['h'], 1, 100) && fine(box['x'], -100, 0) && fine(box['y'], -100, 0)) {
      return (x: (box['x'] as num).toDouble(), y: (box['y'] as num).toDouble(), w: (box['w'] as num).toDouble(), h: (box['h'] as num).toDouble());
    }
    return (x: -col.toDouble(), y: -row.toDouble(), w: cols.toDouble(), h: rows.toDouble());
  }

  /// A sent deck. Cards that don't read are dropped, and so are image layers past the picture limit,
  /// so what's offered is exactly what can arrive. Pictures already received for an earlier copy are
  /// kept.
  @visibleForTesting
  static Offer? readOffer(Map<String, dynamic> message, Offer? previous) {
    final raw = message['cards'];
    if (raw is! List) return null;
    final imageIds = <String>{};
    final cards = <FlashCard>[];
    for (final c in raw.take(_maxDeckCards)) {
      final card = _readCard(c);
      if (card == null) continue;
      card.layers = card.layers.where((l) {
        if (!l.isImage || imageIds.contains(l.imageId)) return true;
        if (imageIds.length >= maxSharedImages) return false;
        imageIds.add(l.imageId);
        return true;
      }).toList();
      cards.add(card);
    }
    if (cards.isEmpty) return null;
    final out = Offer(cards, imageIds);
    previous?.blobs.forEach((id, b) {
      if (imageIds.contains(id)) out.blobs[id] = b;
    });
    out.missing.addAll(previous?.missing.where(imageIds.contains) ?? const []);
    return out;
  }

  int get _picturesPending {
    final o = offer;
    return o == null ? 0 : o.imageIds.length - o.blobs.length - o.missing.length;
  }

  // Layer ids are made here, by position, rather than taken from the wire. A shown card never carries
  // hidden layers; a sent deck flags them.
  static FlashCard? _readCard(Object? card) {
    if (card is! Map || card['layers'] is! List) return null;
    final layers = <Layer>[];
    final raw = (card['layers'] as List).take(_maxLayers).toList();
    for (var i = 0; i < raw.length; i++) {
      final layer = raw[i];
      if (layer is! Map) continue;
      if (layer['type'] == 'image') {
        final imageId = layer['imageId'];
        if (imageId is! String || !_imageIdRe.hasMatch(imageId)) continue;
        layers.add(Layer.read(layer, id: 'l$i')!);
      } else if (layer['type'] == 'text') {
        final text = layer['text'] is String ? layer['text'] as String : '';
        final l = Layer.read(layer, id: 'l$i')!;
        l.text = text.length > _maxText ? text.substring(0, _maxText) : text;
        layers.add(l);
      }
    }
    return FlashCard(
      id: 'wire',
      layout: layouts.any((l) => l.id == card['layout']) ? card['layout'] as String : defaultLayout,
      layers: layers,
      ticker: card['ticker'] == true,
      tickerSpeed: readTickerSpeed(card['tickerSpeed']),
      wrap: card['wrap'] != false,
    );
  }

  void _receiveImage(Map<String, dynamic> m) {
    final id = m['id'], mime = m['mime'], total = m['total'], seq = m['seq'], data = m['data'];
    if (id is! String || !_imageIdRe.hasMatch(id) || mime is! String || !_imageTypes.contains(mime) ||
        total is! num || total != total.truncate() || total < 1 || total > _maxChunks ||
        seq is! num || seq != seq.truncate() || seq < 0 || seq >= total ||
        data is! String || data.length > _maxChunkChars) {
      return;
    }
    final inOffer = offer?.imageIds.contains(id) ?? false;
    if (inOffer ? offer!.blobs.containsKey(id) : _images.containsKey(id)) return;

    var entry = _incoming[id];
    if (entry == null || entry.total != total || entry.mime != mime) {
      entry = _incoming[id] = _Incoming(mime, total.toInt());
      // Bounded, so a host that starts transfers and never finishes them can't fill this device's memory.
      while (_incoming.length > _maxIncoming) {
        _incoming.remove(_incoming.keys.first);
      }
    }
    final s = seq.toInt();
    if (entry.parts[s] == null) {
      entry.parts[s] = data;
      entry.count++;
    }
    if (entry.count < entry.total) return;

    _incoming.remove(id);
    final Uint8List bytes;
    try {
      bytes = base64Decode(entry.parts.join());
    } catch (_) {
      return;
    }

    // Asked again here, not at the first chunk: the deck may have been sent afresh while this picture
    // was on its way.
    if (offer?.imageIds.contains(id) ?? false) {
      offer!.blobs[id] = bytes;
      offer!.missing.remove(id);
      _sendHave();
      notifyListeners();
      return;
    }

    _images[id] = bytes;
    // Oldest first. The card on screen was touched when it was drawn, so its own pictures are the
    // newest and are never the ones to go.
    while (_images.length > _maxImages) {
      _images.remove(_images.keys.first);
    }
    _sendHave();
    _apply();
  }

  void _touchImages(FlashCard card) {
    for (final l in card.layers) {
      if (!l.isImage) continue;
      final bytes = _images.remove(l.imageId);
      if (bytes != null) _images[l.imageId] = bytes;
    }
  }

  // ---------- the host's clock ----------

  void _noteClock(int hostClock) {
    final at = DateTime.now().millisecondsSinceEpoch;
    _clockSamples.add((at, hostClock - at));
    while (_clockSamples.length > 1 && at - _clockSamples.first.$1 > _clockWindowMs) {
      _clockSamples.removeAt(0);
    }
  }

  /// Now, by the host's clock. A snapshot is late by however long it took to arrive, so the largest
  /// offset seen lately is the closest to the truth.
  int hostNow() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_clockSamples.isEmpty) return now;
    return now + _clockSamples.map((s) => s.$2).reduce(math.max);
  }

  // ---------- drawing ----------

  /// Where the card is drawn, as fractions of this screen.
  ///
  /// On a Big Screen the card is drawn the size of the whole wall and moved so this screen's piece is
  /// the part inside it. Otherwise the card keeps the shape it has on the other device, as large as
  /// fits inside the part of this screen clear of notches and rounded corners, with the card's colour
  /// round it. A picture is then cropped the same here as there, instead of a wide card being cut down
  /// to a tall phone's shape and looking zoomed in.
  static ({double x, double y, double w, double h}) stageRect(ViewState? state, Size screen, EdgeInsets inset) {
    final wall = state?.wall;
    if (wall != null) return wall.box;
    final bigW = screen.width, bigH = screen.height;
    final roomW = math.max(1.0, bigW - inset.left - inset.right);
    final roomH = math.max(1.0, bigH - inset.top - inset.bottom);
    var w = roomW, h = roomH;
    final shape = state?.shape;
    if (shape != null && (math.log((roomW / roomH) / shape)).abs() > math.log(1 + _shapeSlack)) {
      if (roomW / roomH > shape) {
        w = roomH * shape;
      } else {
        h = roomW / shape;
      }
    }
    return (
      x: (inset.left + (roomW - w) / 2) / bigW,
      y: (inset.top + (roomH - h) / 2) / bigH,
      w: w / bigW,
      h: h / bigH,
    );
  }

  bool get showing => shownCard != null;
  bool get lining => (state?.wall?.lines ?? false) && status == 'connected' && !_ended;

  void _apply() {
    final card = state?.presenting == true ? state!.card : null;
    if (card == null) {
      if (_shownKey.isNotEmpty) _showNothing();
      _notifyIfVisible();
      return;
    }
    final tickerSpeed = state!.tickerSpeed != null && hasTickerText(card) ? state!.tickerSpeed : null;
    final cardKey = jsonEncode([card.toJson(), tickerSpeed]);
    // A ticker only draws a picture that fills the card.
    final imageLayers = card.layers.where((l) => l.isImage && (tickerSpeed == null || l.fill)).toList();
    final ready = imageLayers.where((l) => _images.containsKey(l.imageId)).length;
    // The pictures that have arrived are part of the key, so one landing after the wait ran out
    // redraws the card with it.
    final key = '$cardKey|$ready';
    if (key != _shownKey) {
      if (ready < imageLayers.length) {
        if (_waitKey != cardKey) {
          _waitKey = cardKey;
          _waitSince = DateTime.now().millisecondsSinceEpoch;
        }
        if (DateTime.now().millisecondsSinceEpoch - _waitSince < _imageWaitMs) {
          _notifyIfVisible();
          return;
        }
      }
      _shownKey = key;
      _touchImages(card);
      shownCard = card;
      shownTicker = tickerSpeed;
    }
    _notifyIfVisible();
  }

  // Twenty snapshots a second mostly say nothing new: redrawn only when something on screen changes.
  void _notifyIfVisible() {
    final s = state;
    final wall = s?.wall;
    final key = [
      _shownKey,
      s?.color,
      s?.dark,
      s?.cardColors?.bg.toARGB32(),
      s?.cardColors?.ink.toARGB32(),
      s?.shape,
      s?.mode,
      wall == null ? null : [wall.n, wall.of, wall.identify, wall.lines, wall.box.x, wall.box.y, wall.box.w, wall.box.h],
    ].join('|');
    if (key == _visibleKey) return;
    _visibleKey = key;
    notifyListeners();
  }

  // Which way this screen's place moved in the same grid, or null. A grid of a new shape moves every
  // screen at once, which isn't a swap.
  static ({int dx, int dy})? _placeMove(WallPlace? before, WallPlace? after) {
    if (before == null || after == null || before.cols != after.cols || before.rows != after.rows) return null;
    final dx = (after.col - before.col).sign, dy = (after.row - before.row).sign;
    return dx != 0 || dy != 0 ? (dx: dx, dy: dy) : null;
  }

  void _showNothing() {
    _shownKey = '';
    shownCard = null;
    shownTicker = null;
  }

  /// What the panel says just now.
  ViewerPanel get panel {
    final stale = status == 'connected' && DateTime.now().millisecondsSinceEpoch - _lastStateAt > _staleMs;
    final readable = code.length >= 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    const staleWords = 'Not hearing from the other device. It may be asleep or out of range.';
    final held = Native.has('screen');
    if (_ended) {
      return ViewerPanel(_removed ? 'Removed' : 'Sharing ended', _removed ? 'The other device removed this screen.' : 'The other device stopped sharing.', {'leave'}, '');
    }
    if (_outdated) {
      return ViewerPanel('Different versions', 'These two devices are running different versions of uwuFlash. Update the app, or reload the page on the other.', {'leave'}, '');
    }
    if (_full) {
      return ViewerPanel('No room', 'The other device already has as many screens as it takes, $maxScreens for a Big Screen. Try again once one has left.', {'retry', 'leave'}, '');
    }
    if (_resuming) {
      return ViewerPanel('Reconnecting', 'Lost the connection to the other device. Trying again...', {'leave'}, 'Reconnecting...');
    }
    if (status == 'unreachable') {
      var words = 'Could not reach the other device. Both have to be on the same network: join the same wifi, or turn on a hotspot on one and join it from the other. Check the code is still the one on screen.';
      if (Native.has('nearby')) words += ' If both phones have the uwuFlash app, turn on Bluetooth on both and they can share with no wifi.';
      return ViewerPanel('Could not connect', words, {'retry', 'leave'}, '');
    }
    if (status == 'error') return ViewerPanel('Could not connect', _failure, {'retry', 'leave'}, '');
    if (status == 'connected' && state?.mode == 'send') {
      final (message, actions) = _offerText(readable);
      return ViewerPanel('Copy cards', stale ? staleWords : message, actions, '');
    }
    final wall = state?.wall;
    if (status == 'connected' && wall != null) {
      return ViewerPanel(
        'Screen ${wall.n} of ${wall.of}',
        stale
            ? staleWords
            : 'Joined $readable as part of a Big Screen. This screen shows its piece of each card when the other device presses play. '
                '${held ? 'This one is at full brightness; turn any others up to match.' : 'Turn every screen\'s brightness up to the same level so they match.'}',
        {'fullscreen', 'leave'},
        stale ? 'Connection looks stale' : '',
      );
    }
    if (status == 'connected') {
      return ViewerPanel(
        'Ready',
        stale ? staleWords : 'Joined $readable. The cards appear here when the other device presses play.${held ? '' : " Turn this screen's brightness up so they read across the room."}',
        {'fullscreen', 'leave'},
        stale ? 'Connection looks stale' : '',
      );
    }
    return ViewerPanel('Connecting', 'Joining $readable...', {'leave'}, '');
  }

  bool get ended => _ended || _outdated;
  bool get canCopy => offer != null && _picturesPending == 0 && !copying;

  (String, Set<String>) _offerText(String readable) {
    final o = offer;
    if (o == null) return ('Joined $readable. Getting the cards...', {'leave'});
    String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
    final cards = '${plural(o.cards.length, 'card')} from the other device.';
    if (copying) return ('$cards Copying...', {'copy', 'leave'});
    final pending = _picturesPending;
    if (pending > 0) {
      final got = o.imageIds.length - pending;
      return ('$cards Receiving pictures, $got of ${o.imageIds.length}...', {'copy', 'leave'});
    }
    final lost = o.missing.isNotEmpty ? ' ${plural(o.missing.length, 'picture')} could not be sent and will be left out.' : '';
    return (
      o.cards.length == 1 ? '$cards$lost Add it to yours, or replace yours with it.' : '$cards$lost Add them to yours, or replace yours with them.',
      {'copy', 'leave'},
    );
  }

  // ---------- copying the deck ----------

  void _disarmReplace() {
    _armTimer?.cancel();
    _armTimer = null;
    replaceArmed = false;
  }

  Future<void> copyCards({required bool replace}) async {
    final o = offer;
    if (o == null || copying || _picturesPending > 0) return;
    if (replace && !replaceArmed) {
      replaceArmed = true;
      _armTimer = Timer(const Duration(milliseconds: _armMs), () {
        _disarmReplace();
        notifyListeners();
      });
      notifyListeners();
      return;
    }
    _disarmReplace();
    copying = true;
    notifyListeners();
    try {
      await AppState.I.importCards(o.cards, o.blobs, replace: replace);
    } catch (_) {
      copying = false;
      notifyListeners();
      return;
    }
    copying = false;
    _guest?.send({'type': 'imported'});
    leave();
  }

  // ---------- the overlay ----------

  void _open() {
    if (isOpen) return;
    isOpen = true;
    _beatTimer = Timer.periodic(_beatEvery, (_) => _beat());
    Screen.hold('viewer', awake: true, bright: true, immersive: appFull);
    notifyListeners();
  }

  // Twice a second: the ping the host uses to notice a screen that has gone, the staleness check, and
  // the image wait running out.
  void _beat() {
    _guest?.send({'type': 'ping'});
    _apply();
    // The panel's words can go stale without anything arriving.
    if (!showing) notifyListeners();
  }

  void toggleFullscreen() {
    appFull = !appFull;
    Screen.hold('viewer', awake: true, bright: true, immersive: appFull);
    notifyListeners();
  }

  void retry() {
    _retryDelay = _retryFirstMs;
    _askNearby = true;
    _join();
  }

  /// A channel often dies with a backgrounded app. Coming back, it tries again at once.
  void resumed() {
    if (isOpen && _resuming && _retryTimer != null) _join();
  }

  void leave() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _resuming = false;
    final g = _guest;
    _guest = null;
    if (g?.status == 'connected') {
      g!.leave();
    } else {
      g?.onStatus = null;
      g?.close();
    }
    Store.I.put('uwuflash.shareRole', null);
    Store.I.put('uwuflash.lastCode', null);
    _beatTimer?.cancel();
    _beatTimer = null;
    _images.clear();
    _incoming.clear();
    _dropOffer();
    state = null;
    _clockSamples.clear();
    status = 'idle';
    _ended = false;
    _removed = false;
    _outdated = false;
    _full = false;
    _resizeTimer?.cancel();
    _showNothing();
    _visibleKey = '';
    isOpen = false;
    Screen.release('viewer');
    appFull = false;
    notifyListeners();
  }
}
