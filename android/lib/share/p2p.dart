// Host and guest pairing (the site's js/p2p.js; see STUN-p2p-spec.md at the repo root). The host is
// the device with the cards. The guest is the other screen. A free public broker introduces the two
// over PeerJS (peer.dart), and after that nothing passes through a server. Beside it there's a
// second way: Google's Nearby Connections, phone to phone over Bluetooth and direct wifi, with no
// network and no broker at all (nearby.dart). The host takes screens from both at once; a screen
// tries both and keeps whichever connects first. Their links look the same, so nothing past this
// file can tell.
import 'dart:async';
import 'dart:math' as math;

import 'nearby.dart';
import 'peer.dart';

const codeAlphabet = 'BCDFGHJKLMNPQRSTVWXYZ23456789';
const codeLength = 6;
// 2 added sending the deck, 3 Big Screen, 4 a picture filling the card, 5 the ticker, screens the
// host can remove, and the lines for setting bezels. The site's js/p2p.js says the same: a device
// on another number is told to update.
const protocolVersion = 5;
// The most pictures either side keeps track of for the other.
const maxSharedImages = 200;
// The most screens one Big Screen takes.
const maxScreens = 12;
const _connectTimeout = Duration(seconds: 15);

String generateCode() {
  final r = math.Random.secure();
  return [for (var i = 0; i < codeLength; i++) codeAlphabet[r.nextInt(codeAlphabet.length)]].join();
}

String normaliseCode(String input) {
  final s = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return s.length > codeLength ? s.substring(0, codeLength) : s;
}

bool isValidCode(String? input) {
  if (input == null) return false;
  final c = normaliseCode(input);
  return c.length == codeLength && c.split('').every(codeAlphabet.contains);
}

/// The site's Connection: the status, and one link's open and close said once each.
abstract class _Connection {
  String status = 'idle';
  void Function(String status, {String? message, String? type, bool taken})? onStatus;
  void Function(Map<String, dynamic> message, String from)? onMessage;

  void setStatus(String s, {String? message, String? type, bool taken = false}) {
    status = s;
    onStatus?.call(s, message: message, type: type, taken: taken);
  }

  void linkOpened(ShareLink link);
  void linkClosed(ShareLink link, bool everOpened);

  void bindLink(ShareLink link) {
    // A link that closes without ever opening never reached the other device.
    var everOpened = false;
    var finished = false;
    link.onOpen = () {
      everOpened = true;
      linkOpened(link);
    };
    link.onData = (message) => onMessage?.call(message, link.peer);
    link.onClose = () {
      if (finished) return;
      finished = true;
      linkClosed(link, everOpened);
    };
  }
}

class Host extends _Connection {
  Host({this.maxGuests = 1});

  int maxGuests;
  final Map<String, ShareLink> links = {}; // guest id -> open link
  void Function(String id)? onJoin;
  void Function(String id)? onLeave;

  /// Nearby: "off" where it can't run, else its answer.
  String nearby = 'off';
  NearbySession? _nearbySession;

  /// Whether screens can reach this one through PeerJS's broker just now.
  bool online = false;
  bool _closed = false;
  PeerListener? _listener;

  /// `ask` lets the app ask for Nearby's permissions: only from a button.
  Future<void> start(String code, {bool ask = false}) async {
    setStatus('connecting');
    final started = _startNearby(code, ask);
    _listener = PeerListener(
      code,
      onLink: _accept,
      onOpen: () {
        online = true;
        refreshStatus();
      },
      onError: (type) {
        if (_closed) return;
        if (type == 'unavailable-id') {
          setStatus('error', message: describePeerError(type), taken: true);
          return;
        }
        online = false;
        // Guests already attached don't need the broker, and neither do phones joining over Nearby.
        if (brokerErrors.contains(type) && (links.isNotEmpty || nearby == 'ready')) {
          refreshStatus();
          return;
        }
        setStatus('error', message: describePeerError(type));
      },
    );
    await _listener!.start();
    await started;
    if (!_closed && nearby == 'ready' && status == 'connecting') refreshStatus();
  }

  Future<void> _startNearby(String code, bool ask) async {
    if (!nearbyAvailable || _closed) return;
    final session = await nearbyBegin('nearbyHost', code, ask: ask, onLink: _accept);
    if (_closed) {
      session.stop();
      return;
    }
    _nearbySession = session;
    nearby = session.state;
    if (status != 'connecting') refreshStatus();
  }

  // A screen knocking, by either way.
  void _accept(ShareLink link) {
    if (_closed) {
      link.close();
      return;
    }
    if (maxGuests == 1) {
      // The newcomer replaces the incumbent, once it's really there.
      bindLink(link);
      return;
    }
    if (links.length >= maxGuests) {
      link.onOpen = () {
        link.send({'type': 'full'});
        link.close(flush: true);
      };
      return;
    }
    bindLink(link);
  }

  @override
  void linkOpened(ShareLink link) {
    if (maxGuests == 1) {
      for (final old in List.of(links.values)) {
        if (old != link) drop(old);
      }
    }
    links[link.peer] = link;
    onJoin?.call(link.peer);
    refreshStatus();
  }

  @override
  void linkClosed(ShareLink link, bool everOpened) {
    // Links this end dropped, and links that never opened, aren't in the map.
    if (links[link.peer] != link) return;
    links.remove(link.peer);
    onLeave?.call(link.peer);
    refreshStatus();
  }

  // A guest that dropped and one that never came look the same from here.
  void refreshStatus() {
    if (_closed) return;
    setStatus(links.isNotEmpty ? 'connected' : 'waiting');
  }

  // Removed before closing, as closing says so straight away.
  void drop(ShareLink link) {
    links.remove(link.peer);
    link.close();
  }

  // Let go of one guest on purpose: told why first, and closed once that has had time to leave.
  // Out of the map at once, so nothing else is sent to it.
  void kick(ShareLink link, Map<String, Object?> message) {
    links.remove(link.peer);
    try {
      link.send(message);
    } catch (_) {
      // Already closing; it goes all the same.
    }
    Timer(const Duration(milliseconds: 300), link.close);
    refreshStatus();
  }

  /// To one guest when `to` is given, otherwise to all of them.
  void send(Map<String, Object?> message, [String? to]) {
    links.forEach((id, link) {
      if (to != null && id != to) return;
      try {
        link.send(message);
      } catch (_) {
        // Closed between the check and the send; its close handler reports it.
      }
    });
  }

  void close() {
    _closed = true;
    for (final link in List.of(links.values)) {
      drop(link);
    }
    _listener?.close();
    _listener = null;
    _nearbySession?.stop();
    _nearbySession = null;
    online = false;
    status = 'idle';
    onStatus?.call('idle', message: null, type: null, taken: false);
  }
}

class Guest extends _Connection {
  /// `introduce` returns what goes in `hello` beside the version: asked at the moment the link
  /// opens, so it describes the screen as it is then.
  Guest({required this.introduce});

  final Map<String, Object?> Function() introduce;
  ShareLink? link;

  // Links on their way to opening, one each way at most. The first to open is kept and the other
  // closed.
  final Set<ShareLink> _candidates = {};
  Timer? _timer;
  NearbySession? _nearbySession;
  bool _searching = false;
  PeerDialer? _dialer;
  // What PeerJS said went wrong while Nearby was still looking, to say if Nearby finds nothing either.
  ({String message, String type})? _webError;

  /// `ask` lets the app ask for Nearby's permissions: only from a button.
  Future<void> connect(String code, {bool ask = false}) async {
    setStatus('connecting');

    // Nothing errors when ICE can't find a path, or Nearby no phone; both just keep trying.
    _timer = Timer(_connectTimeout, () {
      if (status != 'connecting') return;
      final error = _webError;
      hangUp();
      if (error != null) {
        setStatus('error', message: error.message, type: error.type);
      } else {
        setStatus('unreachable');
      }
    });

    final started = _startNearby(code, ask);
    final dialer = PeerDialer(
      onLink: (l) {
        _candidates.add(l);
        bindLink(l);
      },
      onError: (type) {
        if (status == 'connected' && brokerErrors.contains(type)) return;
        final message = describePeerError(type);
        // Nobody with that code on PeerJS may be a phone sharing over Nearby alone, with no
        // network: let Nearby keep looking.
        if (status == 'connecting' && _searching) {
          _webError = (message: message, type: type);
          _dropWeb();
          return;
        }
        if (status != 'connecting') return;
        hangUp();
        setStatus('error', message: message, type: type);
      },
    );
    _dialer = dialer;
    await Future.wait([started, dialer.connect(code)]);
  }

  Future<void> _startNearby(String code, bool ask) async {
    if (!nearbyAvailable || status != 'connecting') return;
    final session = await nearbyBegin('nearbyJoin', code, ask: ask, onLink: (l) {
      _candidates.add(l);
      bindLink(l);
    });
    if (status != 'connecting') {
      session.stop();
      return;
    }
    _nearbySession = session;
    _searching = session.state == 'searching';
    final held = _webError;
    // PeerJS failed before Nearby answered, and Nearby can't look either.
    if (held != null && !_searching) {
      hangUp();
      setStatus('error', message: held.message, type: held.type);
    }
  }

  @override
  void linkOpened(ShareLink l) {
    if (!_candidates.contains(l) || link != null) {
      l.close();
      return;
    }
    _candidates.remove(l);
    link = l;
    // Emptied first: closing one says so at once, and it's no candidate now.
    final others = List.of(_candidates);
    _candidates.clear();
    for (final other in others) {
      other.close();
    }
    _timer?.cancel();
    // The other way is no longer needed.
    if (l.peer.startsWith('nearby-')) {
      _dropWeb();
    } else {
      _nearbySession?.stop();
      _nearbySession = null;
    }
    _searching = false;
    setStatus('connected');
    send({...introduce(), 'type': 'hello', 'v': protocolVersion});
  }

  @override
  void linkClosed(ShareLink l, bool everOpened) {
    if (l == link) {
      link = null;
      setStatus(everOpened ? 'dropped' : 'unreachable');
      return;
    }
    if (!_candidates.remove(l)) return;
    // One way came to nothing: unreachable, unless the other is still trying.
    if (status == 'connecting' && _candidates.isEmpty && !_searching) {
      hangUp();
      setStatus('unreachable');
    }
  }

  // PeerJS let go of, while Nearby goes on.
  void _dropWeb() {
    for (final l in List.of(_candidates)) {
      if (l.peer.startsWith('nearby-')) continue;
      _candidates.remove(l);
      l.close();
    }
    _dialer?.close();
    _dialer = null;
  }

  void send(Map<String, Object?> message) {
    final l = link;
    if (l == null || !l.isOpen) return;
    try {
      l.send(message);
    } catch (_) {
      // As on the host.
    }
  }

  /// Leaving on purpose: `bye` first, and a flushed close so it arrives.
  void leave() {
    send({'type': 'bye'});
    _timer?.cancel();
    final l = link;
    final dialer = _dialer;
    final session = _nearbySession;
    link = null;
    _dialer = null;
    _nearbySession = null;
    _searching = false;
    final others = List.of(_candidates);
    _candidates.clear();
    for (final other in others) {
      other.close();
    }
    onStatus = null;
    l?.close(flush: true);
    // After the flush, which hanging up on Nearby would cut short.
    Timer(const Duration(seconds: 1), () {
      dialer?.close();
      session?.stop();
    });
    status = 'idle';
  }

  void hangUp() {
    _timer?.cancel();
    final l = link;
    link = null;
    l?.close();
    final others = List.of(_candidates);
    _candidates.clear();
    for (final other in others) {
      other.close();
    }
    _dialer?.close();
    _dialer = null;
    _nearbySession?.stop();
    _nearbySession = null;
    _searching = false;
  }

  void close() {
    hangUp();
    setStatus('idle');
  }
}
