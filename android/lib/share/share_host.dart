// Sharing the cards with another screen: the host's side (the site's js/share.js; see
// STUN-p2p-spec.md at the repo root).
//
// This device is the host. It holds the deck and publishes a code; the other screen joins as the
// guest. The guest shows nothing until this device presses play, then shows the presented card full
// screen, and goes back to waiting when the presenter closes. Cards being edited never leave this
// device; only a card being presented does.
//
// Four ways to share, picked in the sheet:
//
//   Mirror      both screens show the card.
//   Extend      the other screen shows the card and this one becomes a presenter view: the same
//               card smaller, with the next one beneath it.
//   Big Screen  Extend across several screens at once. Each one joins with the same code and is
//               given a place in a grid; together they show one card, each drawing only its own
//               piece of it. This device is the presenter view, with the grid drawn over the card.
//   Send        nothing is shown. The other device is sent the whole deck, hidden layers and
//               pictures included, and can add it to its own cards or replace its own with it. The
//               one time the deck leaves this device, and only because somebody picked it.
//
// Under any of the first three, a card with its ticker on has its words run together onto one line
// that rolls across the screens like a news ticker.
//
// The host is authoritative and sends a full snapshot twenty times a second. Snapshots carry no
// pictures: those go once each, in chunks, to a guest that says it lacks them, so a card with a
// photo costs its bytes once and a snapshot stays a few hundred bytes.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../app/state.dart';
import '../data/deck.dart';
import '../data/store.dart';
import '../theme/theme.dart';
import '../ui/kit.dart';
import 'p2p.dart';
import 'peer.dart';
import 'shrink.dart';

const _snapshotEvery = Duration(milliseconds: 50);
// A guest pings every half second. Silence for this long is a guest that has gone (a browser
// closed, a laptop lid shut) without its channel saying so.
const _guestSilentMs = 5000;
// Under PeerJS's own 16,300 byte chunk size once the message around it is counted, so the library
// never has to split a chunk of ours again.
const _chunkChars = 12000;
const _preparedLimit = 12;

const shareModes = ['mirror', 'extend', 'bigscreen', 'send'];
const shareModeNotes = {
  'mirror': 'Both screens show the card.',
  'extend': 'The other screen shows the card. This one shows it smaller, with the next card beneath it.',
  'bigscreen': 'Several screens join with the same code and show one card together, each its own piece. This one shows it smaller, with the next card beneath it.',
  'send': 'The other device gets a copy of all your cards, pictures included, to add to its own or to replace them.',
};

const siteHost = 'flash.uwuapps.org';
String joinUrl(String code) => 'https://$siteHost/?join=$code';

final _screenId = RegExp(r'^[a-z0-9]{6,24}$');
// The card as it's made in the editor, which is the shape the other screen draws it in under Extend.
const cardAspect = 16 / 10;
// A screen that hasn't said how big it is, in millimetres: a phone on its side.
const _defaultSize = (w: 150.0, h: 70.0);
// Between two screens of a Big Screen, the part of the card that lands on their bezels, in
// millimetres. Two phones in cases side by side lose about eight. Each seam between two columns or
// two rows has its own, set by dragging it in the sheet until the lines on the screens meet
// straight: a tenth of a millimetre for every pixel dragged, so it can be got exactly.
const gapDefault = 8.0;
const gapStep = 1.0;
const gapMax = 60.0;
const seamPerPx = 0.1;
// The lines stay up on the screens this long after a seam is let go, to judge it by.
const _linesLingerMs = 3000;
// A screen that drops is held its place this long, for a blip in the wifi or a reload, and then let
// go. One that leaves on purpose goes at once.
const _lostMs = 8000;

class _Guest {
  _Guest() : heard = DateTime.now().millisecondsSinceEpoch;
  int heard; // last time anything arrived
  Set<String> images = {}; // ids it says it holds
  final Set<String> offered = {}; // ids sent to it and not yet confirmed
  String? screen; // its screen id once it has said hello
  ({double w, double h})? size; // in millimetres
}

class WallCell {
  WallCell(this.left, this.top, this.w, this.h);
  final double left, top, w, h;
}

class WallSeam {
  WallSeam(this.at, this.gap);
  final double at, gap;
}

class WallGeometry {
  WallGeometry(this.width, this.height, this.cells, this.seamsX, this.seamsY);
  final double width, height;
  final List<WallCell> cells;
  final List<WallSeam> seamsX, seamsY;
}

/// One place on a Big Screen, as the presenter view draws it over the card, as fractions of the wall.
class BigScreenCell {
  BigScreenCell(this.number, this.online, this.blank, this.x, this.y, this.w, this.h);
  final int number;
  final bool online, blank;
  final double x, y, w, h;
}

class BigScreenView {
  BigScreenView(this.rows, this.aspect, this.cells, this.identify);
  final int rows;
  final double aspect;
  final List<BigScreenCell> cells;
  final bool identify;
}

class ShareHost extends ChangeNotifier {
  ShareHost._();
  static final ShareHost I = ShareHost._();

  Host? _host;
  String hostStatus = 'idle';
  String? statusMessage;
  bool _retriedTaken = false;
  Timer? _beatTimer;
  String shownCode = '';

  final Map<String, _Guest> _guests = {}; // guest peer id -> what's known of it
  bool _pumping = false;
  final Map<String, Future<PreparedImage>> _prepared = {};

  /// Big Screen. `order` is the screens by place, left to right and then down, and a screen's number
  /// is its place plus one. A screen that drops keeps its place for a moment, so a blip brings it
  /// back to the same piece of the card; after that, or when it leaves on purpose or the presenter
  /// removes it, the screens after it close up. `cols` is null until somebody picks it, which puts
  /// every screen in one row. `seamsX` and `seamsY` are the bezels at each seam, in millimetres;
  /// `gap` is the width for a seam not yet set. `lines` puts lines across every screen to set them by.
  List<String> order = [];
  int? cols;
  bool identify = false;
  bool lines = false;
  double gap = gapDefault;
  List<double> seamsX = [];
  List<double> seamsY = [];
  int? picked; // the place tapped first, waiting for a second to swap with
  bool dragging = false; // a seam being dragged
  int _linesUntil = 0;
  final Map<String, ({double w, double h})> _sizes = {}; // kept after a screen drops
  final Map<String, int> _lostAt = {}; // screen id -> when it was first seen not connected

  // ---------- what the rest of the app reads ----------

  bool get isHosting => _host != null;
  bool get online => _host?.online ?? false;
  String get nearbyState => _host?.nearby ?? 'off';

  String get mode {
    final m = Store.I.get('uwuflash.shareMode');
    return shareModes.contains(m) ? m! : 'mirror';
  }

  /// Sends the current picture now rather than on the next beat, so pressing play or stepping a card
  /// reaches the other screen without the wait.
  void shareNow() {
    final h = _host;
    if (h == null || h.links.isEmpty) return;
    _sendSnapshots();
    _pumpImages();
  }

  /// The deck was edited and saved. A guest about to copy it gets the edit, rather than whatever the
  /// deck was when it joined.
  void deckChanged() {
    _sendDeck();
    _pumpImages();
  }

  /// Sharing when the app was last closed: back on the same code, so the other screen rejoins
  /// without anybody reading it out again.
  void resume() {
    if (Store.I.get('uwuflash.shareRole') == 'host') startHosting();
  }

  // ---------- hosting ----------

  /// `ask`: from the Start button, so the app may ask for what sharing with no wifi needs. Never when
  /// sharing resumes on its own.
  Future<void> startHosting({bool ask = false}) async {
    if (_host != null) return;

    final stored = Store.I.get('uwuflash.hostCode');
    final code = isValidCode(stored) ? stored! : generateCode();
    Store.I.put('uwuflash.hostCode', code);
    Store.I.put('uwuflash.shareRole', 'host');

    final h = Host(maxGuests: _maxGuestsFor(mode));
    _host = h;
    hostStatus = 'connecting';
    statusMessage = null;
    _loadWall();
    shownCode = code;

    h.onStatus = (status, {message, type, taken = false}) {
      if (_host != h) return;
      // Another device, or the broker not yet releasing the id after a restart. One fresh code,
      // silently; a second collision in a row isn't stale state and retrying would only hammer
      // the broker.
      if (taken && !_retriedTaken) {
        _retriedTaken = true;
        restartWithFreshCode();
        return;
      }
      if (status == 'waiting') _retriedTaken = false;
      hostStatus = status;
      statusMessage = message;
      _changed();
    };
    // A new guest, or the same screen after a reload: either way it holds no pictures until it says
    // otherwise, and has no place until its hello.
    h.onJoin = (id) {
      if (_host == h) _guests[id] = _Guest();
    };
    h.onLeave = (id) {
      _guests.remove(id);
    };
    h.onMessage = (message, from) {
      if (_host == h) _onMessage(message, from);
    };

    _beatTimer = Timer.periodic(_snapshotEvery, (_) => _beat());
    _changed();
    await h.start(code, ask: ask);
  }

  /// `tellGuest` for stopping on purpose: the guest hears `end` and says the sharing ended, rather
  /// than reporting a dropped connection and trying to come back to a code that's gone.
  void stopHosting({bool tellGuest = false}) {
    final h = _host;
    if (h == null) return;
    _host = null;
    _beatTimer?.cancel();
    _beatTimer = null;
    _guests.clear();
    identify = false;
    lines = false;
    picked = null;
    dragging = false;
    _lostAt.clear();
    hostStatus = 'idle';
    statusMessage = null;
    h.onStatus = null;
    if (tellGuest && h.links.isNotEmpty) {
      h.send({'type': 'end'});
      // Long enough for `end` to leave; close() tears the channel down at once.
      Timer(const Duration(milliseconds: 300), h.close);
    } else {
      h.close();
    }
  }

  void restartWithFreshCode({bool tellGuest = false}) {
    stopHosting(tellGuest: tellGuest);
    Store.I.put('uwuflash.hostCode', null);
    startHosting();
  }

  /// Stop sharing, from the sheet. A Big Screen put together next time starts from no screens.
  void stopFromSheet() {
    stopHosting(tellGuest: true);
    Store.I.put('uwuflash.shareRole', null);
    _clearWall();
    _changed();
  }

  void setMode(String m) {
    final next = shareModes.contains(m) ? m : 'mirror';
    Store.I.put('uwuflash.shareMode', next);
    final h = _host;
    if (h != null) {
      // Screens already joined become the first places of a Big Screen. Leaving one keeps them
      // connected, showing the same card.
      h.maxGuests = _maxGuestsFor(next);
      if (next == 'bigscreen') {
        for (final g in _guests.values) {
          if (g.screen != null) _placeScreen(g.screen!);
        }
      }
    }
    _changed();
    // Straight away rather than on the next beat, and the deck right behind the snapshot that says
    // to expect one.
    shareNow();
    _sendDeck();
  }

  void _onMessage(Map<String, dynamic> message, String from) {
    final guest = _guests[from];
    if (guest != null) guest.heard = DateTime.now().millisecondsSinceEpoch;

    switch (message['type']) {
      case 'hello':
        if (message['v'] != protocolVersion) {
          _host?.send({'type': 'outdated'}, from);
          return;
        }
        if (guest != null) {
          guest.size = _readSize(message);
          _claimScreen(guest, message['screen'], from);
        }
        _sendSnapshots(from);
        _sendDeck(from);
      case 'size':
        if (guest == null) break;
        guest.size = _readSize(message);
        if (guest.screen != null && guest.size != null) _sizes[guest.screen!] = guest.size!;
        if (mode == 'bigscreen') _wallChanged();
      case 'imported':
        AppNav.say('The other device copied your cards.');
      case 'have':
        if (guest == null) break;
        guest.images = _readImageList(message['images']);
        guest.offered.removeAll(guest.images);
        _pumpImages();
      case 'bye':
        // One screen of several leaving takes nothing from the rest, and a Big Screen keeps its code
        // while it's being put together. Otherwise the code is spent: one shown to a room in this
        // session shouldn't keep working in the next. A screen that left on purpose gives up its
        // place, and the rest close up.
        final screen = guest?.screen;
        _dropGuest(from);
        if (screen != null && !_isOnline(screen)) _forgetScreen(screen);
        if (mode == 'bigscreen' || (_host?.links.isNotEmpty ?? false)) {
          _changed();
        } else {
          restartWithFreshCode();
        }
      default:
        // `ping`, and anything from a newer build. Never thrown on.
        break;
    }
  }

  void _dropGuest(String id) {
    final h = _host;
    final link = h?.links[id];
    _guests.remove(id);
    if (link == null) return;
    h!.drop(link);
    h.refreshStatus();
  }

  /// Let one screen go because the presenter said so. It's told, and shows that it was removed rather
  /// than trying to come back.
  void removeGuest(String id) {
    final h = _host;
    final link = h?.links[id];
    _guests.remove(id);
    if (link != null) h!.kick(link, {'type': 'removed'});
    _changed();
  }

  /// Who's joined under Mirror, Extend and Send, to let go of. On a Big Screen the tiles do this.
  List<String> get joined {
    final h = _host;
    if (h == null || mode == 'bigscreen') return const [];
    return _guests.keys.where(h.links.containsKey).toList();
  }

  /// A guest's screen in millimetres, from its own say-so: its size in CSS pixels and its guess at how
  /// many of those make a millimetre. Kept to sizes a screen can have. A guest from before the guess
  /// was sent is taken for a phone, the usual case.
  ({double w, double h})? _readSize(Map<String, dynamic> m) {
    final w = m['w'], h = m['h'], ppm = m['ppm'];
    if (w is! num || h is! num || !w.isFinite || !h.isFinite || w <= 0 || h <= 0) return null;
    final per = ppm is num && ppm.isFinite ? ppm.toDouble().clamp(2.0, 12.0) : 160 / 25.4;
    final aspect = (w / h).clamp(0.25, 4.0);
    final width = (w / per).clamp(20.0, 3000.0);
    return (w: width, h: width / aspect);
  }

  // ---------- Big Screen ----------

  int _maxGuestsFor(String m) => m == 'bigscreen' ? maxScreens : 1;

  void _claimScreen(_Guest guest, Object? screen, String from) {
    if (screen is! String || !_screenId.hasMatch(screen)) return;
    // The same screen back on a new connection before its old one timed out.
    for (final e in _guests.entries.toList()) {
      if (e.key != from && e.value.screen == screen) _dropGuest(e.key);
    }
    guest.screen = screen;
    if (guest.size != null) _sizes[screen] = guest.size!;
    if (mode == 'bigscreen') _placeScreen(screen);
    _changed();
  }

  /// A screen new to this wall takes the next place, or, once every place is taken, the first one
  /// whose screen isn't connected. There's always one: no more screens can be connected than there
  /// are places.
  void _placeScreen(String screen) {
    if (order.contains(screen)) return;
    if (order.length < maxScreens) {
      order.add(screen);
    } else {
      final free = order.indexWhere((s) => !_isOnline(s));
      if (free < 0) return;
      order[free] = screen;
    }
    _saveWall();
  }

  // Out of the wall, its place closed up by the screens after it.
  void _forgetScreen(String screen) {
    _lostAt.remove(screen);
    if (!order.remove(screen)) return;
    picked = null;
    _wallChanged();
  }

  void removeScreen(int place) {
    if (place >= order.length) return;
    final screen = order[place];
    for (final e in _guests.entries.toList()) {
      if (e.value.screen == screen) removeGuest(e.key);
    }
    _forgetScreen(screen);
  }

  /// Screens that dropped and haven't come back in time are let go, so the wall is only ever the
  /// screens that are there.
  void _forgetLost(int now) {
    final lost = <String>[];
    for (final screen in order) {
      if (_isOnline(screen)) {
        _lostAt.remove(screen);
      } else if (!_lostAt.containsKey(screen)) {
        _lostAt[screen] = now;
      } else if (now - _lostAt[screen]! > _lostMs) {
        lost.add(screen);
      }
    }
    if (lost.isEmpty) return;
    lost.forEach(_lostAt.remove);
    order = order.where((s) => !lost.contains(s)).toList();
    picked = null;
    _wallChanged();
  }

  bool _isOnline(String screen) => _guests.values.any((g) => g.screen == screen);
  bool screenOnline(String screen) => _isOnline(screen);
  int get onlineCount => order.where(_isOnline).length;

  ({int count, int cols, int rows}) get wallLayout {
    final count = math.max(1, order.length);
    final c = math.min(math.max(cols ?? count, 1), count);
    return (count: count, cols: c, rows: (count / c).ceil());
  }

  // The middle of what the placed screens say, the size given to a blank place, so one odd screen
  // doesn't set it.
  ({double w, double h}) _middleSize() {
    final known = order.map((s) => _sizes[s]).whereType<({double w, double h})>().toList();
    if (known.isEmpty) return _defaultSize;
    double mid(Iterable<double> list) {
      final sorted = list.toList()..sort();
      return sorted[sorted.length ~/ 2];
    }

    return (w: mid(known.map((s) => s.w)), h: mid(known.map((s) => s.h)));
  }

  // The bezels at each seam, one per gap between two columns (`x`) or two rows (`y`). A seam nobody
  // has set takes the last width set for them all.
  List<double> seams(String axis, int count) {
    final list = axis == 'x' ? seamsX : seamsY;
    return [for (var i = 0; i < math.max(0, count); i++) i < list.length && list[i].isFinite ? list[i] : gap];
  }

  static double clampGap(double mm) => (mm.clamp(0.0, gapMax) * 10).roundToDouble() / 10;

  void setSeam(String axis, int index, double mm) {
    final l = wallLayout;
    final filled = seams(axis, math.max(axis == 'x' ? l.cols - 1 : l.rows - 1, index + 1));
    filled[index] = clampGap(mm);
    if (axis == 'x') {
      seamsX = filled;
    } else {
      seamsY = filled;
    }
  }

  double seamValue(String axis, int index) {
    final l = wallLayout;
    final list = seams(axis, axis == 'x' ? l.cols - 1 : l.rows - 1);
    return index < list.length ? list[index] : gap;
  }

  /// The wall laid out in millimetres, so screens of different sizes each show the piece of the card
  /// that's really in front of them. Every column is as wide as its widest screen and every row as
  /// tall as its tallest, each screen centred in its cell, with each seam's own bezels between cells.
  /// A blank place in a short bottom row is given the usual size.
  WallGeometry get geometry {
    final l = wallLayout;
    final usual = _middleSize();
    ({double w, double h}) sizeAt(int i) => (i < order.length ? _sizes[order[i]] : null) ?? usual;

    final colW = List<double>.filled(l.cols, 0);
    final rowH = List<double>.filled(l.rows, 0);
    for (var i = 0; i < l.cols * l.rows; i++) {
      final s = sizeAt(i);
      colW[i % l.cols] = math.max(colW[i % l.cols], s.w);
      rowH[i ~/ l.cols] = math.max(rowH[i ~/ l.cols], s.h);
    }

    final gapX = seams('x', l.cols - 1);
    final gapY = seams('y', l.rows - 1);
    double sum(List<double> list, int n) => list.take(n).fold(0.0, (a, b) => a + b);
    final colX = [for (var i = 0; i < l.cols; i++) sum(colW, i) + sum(gapX, i)];
    final rowY = [for (var i = 0; i < l.rows; i++) sum(rowH, i) + sum(gapY, i)];
    final cells = [
      for (var i = 0; i < l.cols * l.rows; i++)
        () {
          final s = sizeAt(i);
          final c = i % l.cols, r = i ~/ l.cols;
          return WallCell(colX[c] + (colW[c] - s.w) / 2, rowY[r] + (rowH[r] - s.h) / 2, s.w, s.h);
        }(),
    ];

    return WallGeometry(
      colX[l.cols - 1] + colW[l.cols - 1],
      rowY[l.rows - 1] + rowH[l.rows - 1],
      cells,
      [for (var i = 0; i < gapX.length; i++) WallSeam(colX[i] + colW[i], gapX[i])],
      [for (var i = 0; i < gapY.length; i++) WallSeam(rowY[i] + rowH[i], gapY[i])],
    );
  }

  /// What the presenter view draws over the card while it's a Big Screen, or null. Blank cells are
  /// the places past the last screen in a short bottom row.
  BigScreenView? get bigScreen {
    if (_host == null || mode != 'bigscreen') return null;
    final geo = geometry;
    return BigScreenView(
      wallLayout.rows,
      geo.width / geo.height,
      [
        for (var i = 0; i < geo.cells.length; i++)
          BigScreenCell(
            i + 1,
            i < order.length && _isOnline(order[i]),
            i >= order.length,
            geo.cells[i].left / geo.width,
            geo.cells[i].top / geo.height,
            geo.cells[i].w / geo.width,
            geo.cells[i].h / geo.height,
          ),
      ],
      identify,
    );
  }

  /// Sharing in Extend or Big Screen turns the presenter into a presenter view: the other screen has
  /// the card, so this one shows it smaller with the next card beneath it.
  bool get isPresenterView => isHosting && (mode == 'extend' || mode == 'bigscreen');

  /// Where one screen sits, sent in its snapshot. Null for a screen with no place, which draws the
  /// whole card rather than nothing. `box` is the whole wall measured in this screen: where it starts
  /// and how big it is, in widths and heights of this screen.
  Map<String, Object?>? _wallTile(String screen) {
    final i = order.indexOf(screen);
    if (i < 0) return null;
    final l = wallLayout;
    final geo = geometry;
    final cell = geo.cells[i];
    double round(double n) => (n * 10000).roundToDouble() / 10000;
    return {
      'n': i + 1,
      'of': l.count,
      'col': i % l.cols,
      'row': i ~/ l.cols,
      'cols': l.cols,
      'rows': l.rows,
      'identify': identify,
      'lines': _linesShowing,
      'box': {
        'x': round(-cell.left / cell.w),
        'y': round(-cell.top / cell.h),
        'w': round(geo.width / cell.w),
        'h': round(geo.height / cell.h),
      },
    };
  }

  void _loadWall() {
    final store = Store.I;
    order = (store.get('uwuflash.wallOrder') ?? '').split(',').toSet().where(_screenId.hasMatch).take(maxScreens).toList();
    final c = int.tryParse(store.get('uwuflash.wallCols') ?? '');
    cols = c != null && c >= 1 && c <= maxScreens ? c : null;
    final g = double.tryParse(store.get('uwuflash.wallGap') ?? '');
    gap = g != null && g >= 0 && g <= gapMax ? clampGap(g) : gapDefault;
    List<double> list(String name) {
      final raw = store.get(name);
      if (raw == null || raw.isEmpty) return [];
      return raw.split(',').take(maxScreens).map((s) {
        final mm = double.tryParse(s);
        return mm != null && mm.isFinite ? clampGap(mm) : gap;
      }).toList();
    }

    seamsX = list('uwuflash.wallSeamsX');
    seamsY = list('uwuflash.wallSeamsY');
    // Places kept from before are held for their screens as if they'd just dropped, and let go if
    // they don't come back.
    _lostAt.clear();
  }

  void _saveWall() {
    final store = Store.I;
    store.put('uwuflash.wallOrder', order.isEmpty ? null : order.join(','));
    store.put('uwuflash.wallCols', cols?.toString());
    store.put('uwuflash.wallGap', '$gap');
    store.put('uwuflash.wallSeamsX', seamsX.isEmpty ? null : seamsX.join(','));
    store.put('uwuflash.wallSeamsY', seamsY.isEmpty ? null : seamsY.join(','));
  }

  void _clearWall() {
    order = [];
    cols = null;
    picked = null;
    _lostAt.clear();
    _saveWall();
  }

  // Lines across the whole wall on every screen: while a seam is being dragged, a moment after, and
  // while the presenter has them on.
  bool get _linesShowing => lines || dragging || DateTime.now().millisecondsSinceEpoch < _linesUntil;

  // A change to the wall reaches the screens at once, not on the next beat.
  void _wallChanged() {
    _saveWall();
    _changed();
    shareNow();
  }

  /// Tapping one screen and then another swaps them, which is how the grid here is made to match the
  /// screens on the table: show the numbers, see which is where, swap.
  void tapPlace(int place) {
    final p = picked;
    if (p == null || p == place) {
      picked = p == place ? null : place;
      _changed();
      return;
    }
    final other = order[p];
    order[p] = order[place];
    order[place] = other;
    picked = null;
    _wallChanged();
  }

  void fewerCols() {
    cols = math.max(1, wallLayout.cols - 1);
    _wallChanged();
  }

  void moreCols() {
    final l = wallLayout;
    cols = math.min(l.count, l.cols + 1);
    _wallChanged();
  }

  /// Every seam at once, keeping how they differ from one another.
  void nudgeAll(double by) {
    final l = wallLayout;
    seamsX = seams('x', l.cols - 1).map((mm) => clampGap(mm + by)).toList();
    seamsY = seams('y', l.rows - 1).map((mm) => clampGap(mm + by)).toList();
    gap = clampGap(gap + by);
    _linesUntil = DateTime.now().millisecondsSinceEpoch + _linesLingerMs;
    _wallChanged();
  }

  void startSeamDrag() {
    dragging = true;
    shareNow();
    _changed();
  }

  void dragSeam(String axis, int index, double mm) {
    final next = clampGap(mm);
    if (next == seamValue(axis, index)) return;
    setSeam(axis, index, next);
    _changed();
    shareNow();
  }

  void endSeamDrag() {
    if (!dragging) return;
    dragging = false;
    _linesUntil = DateTime.now().millisecondsSinceEpoch + _linesLingerMs;
    _wallChanged();
  }

  /// Every screen shows its number at once, and the grid here shows the same numbers.
  void toggleIdentify() {
    identify = !identify;
    _changed();
    shareNow();
  }

  /// Lines across the whole wall, to judge the bezels by from across the room: where they bend
  /// crossing from one screen to the next, that seam wants more or less.
  void toggleLines() {
    lines = !lines;
    _linesUntil = 0;
    _changed();
    shareNow();
  }

  Set<String> _readImageList(Object? list) {
    if (list is! List) return {};
    return list.take(maxSharedImages).whereType<String>().where((id) => id.length <= 64).toSet();
  }

  /// Twenty times a second: drop a guest that has gone quiet, send the snapshot, and keep any picture
  /// transfer moving. The snapshot is also the guest's heartbeat.
  void _beat() {
    final h = _host;
    if (h == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in _guests.entries.toList()) {
      if (now - e.value.heard > _guestSilentMs) _dropGuest(e.key);
    }
    _forgetLost(now);
    if (h.links.isEmpty) return;
    _sendSnapshots();
    _pumpImages();
  }

  // ---------- the snapshot ----------

  /// One snapshot for every guest, except on a Big Screen, where each is told its own place. A screen
  /// yet to say hello has no place to be told, so it waits for one rather than drawing the whole card.
  void _sendSnapshots([String? to]) {
    final h = _host;
    if (h == null) return;
    if (mode != 'bigscreen') {
      h.send(snapshot(), to);
      return;
    }
    _guests.forEach((id, guest) {
      if ((to == null || id == to) && guest.screen != null) h.send(snapshot(guest.screen), id);
    });
  }

  // The shape the card is seen in here, so a screen of another shape draws the same picture inside
  // its own rather than cropping it.
  double get _viewShape {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize;
    return size.height == 0 ? cardAspect : (size.width / size.height * 1000).roundToDouble() / 1000;
  }

  @visibleForTesting
  Map<String, Object?> snapshot([String? screen]) {
    final app = AppState.I;
    final look = AppLook.I;
    final tokens = look.tokensNow;
    final sending = mode == 'send';
    final message = <String, Object?>{
      'type': 'state',
      'mode': sending ? 'send' : 'show',
      'presenting': false,
      // The host's clock, which the screens roll a ticker by so they agree.
      'clock': DateTime.now().millisecondsSinceEpoch,
      'theme': {
        'color': look.swatchId,
        'mode': look.resolvedNow == Brightness.dark ? 'dark' : 'light',
        // Material You's own colours, as a browser can't work them out. Another uwuFlash app wears
        // them; the website goes by `color`.
        if (look.materialYou) 'card': {'bg': colorHex(tokens.cardBg), 'ink': colorHex(tokens.cardInk)},
      },
    };
    if (mode == 'bigscreen' && screen != null) {
      message['wall'] = _wallTile(screen);
    } else if (mode == 'mirror') {
      message['shape'] = _viewShape;
    } else if (mode == 'extend') {
      message['shape'] = cardAspect;
    }
    // Nothing about the card until play is pressed: the other screen waits, and what's being edited
    // stays on this one. Sending shows nothing at all; the deck goes separately.
    if (!sending && app.presenting) {
      final card = app.card;
      message['presenting'] = true;
      message['card'] = _wireCard(card);
      // The card's own ticker, which the presenter here draws the same.
      if (showsTicker(card)) message['ticker'] = {'speed': readTickerSpeed(card.tickerSpeed)};
    }
    return message;
  }

  // Only what drawing needs. Hidden layers are left behind rather than sent with a flag, since the
  // other screen has no use for them. Whether the picture fills the card is settled here: a hidden
  // second picture stops it, and the other screen never hears of that one.
  Map<String, Object?> _wireCard(FlashCard card) {
    final filling = card.fillImage;
    return {
      'layout': card.layout,
      'wrap': card.wrap,
      'layers': [
        for (final l in card.layers)
          if (!l.hidden)
            if (l.isImage)
              {'type': 'image', 'imageId': l.imageId, 'fit': l.fit, 'fill': l == filling, 'focus': l.focus.toJson()}
            else
              {'type': 'text', 'text': l.text, 'size': l.size, 'align': l.align},
      ],
    };
  }

  // ---------- sending the deck ----------

  // A copy rather than a picture, so hidden layers go too, flagged, and come out hidden on the other
  // device as they were here.
  Map<String, Object?> _wireDeckCard(FlashCard card) => {
        'layout': card.layout,
        'layers': [
          for (final l in card.layers)
            if (l.isImage)
              {'type': 'image', 'imageId': l.imageId, 'fit': l.fit, 'fill': l.fill, 'focus': l.focus.toJson(), 'hidden': l.hidden}
            else
              {'type': 'text', 'text': l.text, 'size': l.size, 'align': l.align, 'hidden': l.hidden},
        ],
        'ticker': card.ticker,
        'tickerSpeed': card.tickerSpeed,
        'wrap': card.wrap,
      };

  // The whole deck, sent when a guest arrives, when Send is picked, and after every save while it's
  // picked. Words only: the pictures follow like any others.
  void _sendDeck([String? to]) {
    final h = _host;
    if (h == null || h.links.isEmpty || mode != 'send') return;
    h.send({'type': 'deck', 'cards': AppState.I.deck.cards.map(_wireDeckCard).toList()}, to);
  }

  // ---------- pictures ----------

  List<String> _wantedImages() {
    final app = AppState.I;
    if (mode == 'send') {
      // Every picture in the deck, hidden ones included, in card order.
      return {
        for (final c in app.deck.cards)
          for (final l in c.layers)
            if (l.isImage) l.imageId,
      }.take(maxSharedImages).toList();
    }
    final i = app.cardIndex;
    final cards = app.deck.cards;
    // The card on screen first, then its neighbours, so stepping to the next card finds its picture
    // already there.
    return [
      for (final c in [cards[i], if (i + 1 < cards.length) cards[i + 1], if (i > 0) cards[i - 1]])
        for (final l in c.layers)
          if (l.isImage && !l.hidden) l.imageId,
    ];
  }

  /// One picture to one guest at a time, the guests in the order they came. Every screen of a Big
  /// Screen wants the same pictures, so each is sent the card's own before the next gets anything.
  void _pumpImages() {
    final h = _host;
    if (_pumping || h == null) return;
    final wanted = _wantedImages();
    for (final e in _guests.entries) {
      final link = h.links[e.key];
      if (link == null) continue;
      for (final id in wanted) {
        if (!e.value.images.contains(id) && !e.value.offered.contains(id)) {
          _sendImage(h, link, e.value, id);
          return;
        }
      }
    }
  }

  Future<void> _sendImage(Host h, ShareLink link, _Guest guest, String id) async {
    _pumping = true;
    guest.offered.add(id);
    // The guest is a fresh entry whenever its screen joins again.
    bool current() => _host == h && h.links[link.peer] == link && _guests[link.peer] == guest;

    try {
      final prepared = await _preparedImage(id);
      final data = prepared.data;
      final total = math.max(1, (data.length / _chunkChars).ceil());
      for (var seq = 0; seq < total; seq++) {
        // The guest may have gone, or been replaced, mid transfer. The next one asks again from the
        // start.
        while (current() && await link.congested()) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        if (!current()) return;
        h.send({
          'type': 'image',
          'id': id,
          'mime': prepared.mime,
          'seq': seq,
          'total': total,
          'data': data.substring(seq * _chunkChars, math.min(data.length, (seq + 1) * _chunkChars)),
        }, link.peer);
        if (seq % 8 == 7) await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      // Missing from storage or undecodable. Left in `offered`, so it's not tried again on every
      // beat; the card shows without it. Said, so a guest copying the deck isn't left waiting on it.
      if (current()) h.send({'type': 'noimage', 'id': id}, link.peer);
    } finally {
      _pumping = false;
    }
  }

  Future<PreparedImage> _preparedImage(String id) {
    final known = _prepared[id];
    if (known != null) return known;
    final made = prepareImage(id);
    _prepared[id] = made;
    if (_prepared.length > _preparedLimit) _prepared.remove(_prepared.keys.first);
    return made;
  }

  // ---------- the sheet's words ----------

  /// Whether phones can join with no wifi, over Nearby, and what to do if not.
  String get _nearbyText => switch (_host?.nearby) {
        'ready' => online
            ? ' Phones with the uwuFlash app can also join with no wifi.'
            : ' No internet, so only phones with the uwuFlash app nearby can join.',
        'bt-off' => ' Turn on Bluetooth so phones with the uwuFlash app can join with no wifi.',
        'location-off' => ' Turn on location so phones with the uwuFlash app can join with no wifi.',
        'denied' || 'needs-permission' => " To let phones join with no wifi, allow uwuFlash Nearby devices in Android's settings.",
        _ => '',
      };

  String get statusText {
    switch (hostStatus) {
      case 'connecting':
        return 'Starting...';
      case 'waiting':
        return (mode == 'bigscreen' ? 'Waiting for screens to join. Open the code on each of them.' : 'Waiting for the other screen to join.') + _nearbyText;
      case 'connected':
        if (mode == 'bigscreen') {
          final n = onlineCount;
          return '$n screen${n == 1 ? '' : 's'} joined. Together they show your cards when you press play.';
        }
        return mode == 'send' ? 'Connected. The other device can now copy your cards.' : 'Connected. The other screen shows your cards when you press play.';
      case 'error':
        return statusMessage ?? 'The connection failed.';
      default:
        return '';
    }
  }

  void _changed() => notifyListeners();
}
