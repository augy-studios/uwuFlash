// Sharing with no wifi or internet, between phones that both have the Android app: Google's Nearby
// Connections (NearbyShare.java, and the site's js/nearby.js, which phones on 1.0.0 still run, so
// the two must stay in step). p2p.dart uses it beside PeerJS, so a screen joins whichever way
// reaches first, and with no network at all, this way still does.
//
// The sharing phone advertises a tag made from the share code, not the code: a slow hash, so a
// phone nearby listening for adverts can't read the code off the air or work it back out. The code
// itself is checked by the Java side, inside Nearby's encrypted connection, before a link gets here.
//
// Nearby carries at most 32 KB a message, so longer ones (a sent deck) go in parts and are put back
// together on the other side. Snapshots, twenty a second, are skipped while a slow link still has a
// backlog: the next one says everything the skipped one did. Nothing else is ever skipped.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../native/native_bridge.dart';
import 'peer.dart' show ShareLink;

// Under Nearby's 32 KB once in UTF-8, whatever the characters.
const _maxBytes = 30000;
// A part of a longer message: at most 6 bytes a character once escaped.
const _partChars = 5000;
const _maxParts = 2000;
const _maxPartial = 4;
// Snapshots skipped while this many messages are on their way.
const _backlogLimit = 6;
// A closing link waits this long at most for what it has sent to leave.
const _flushMs = 1000;
const _tagSalt = 'uwuflash-nearby-1';
const _tagRounds = 100000;

final Map<String, NearbyLink> _links = {}; // Nearby's endpoint id -> link
void Function(ShareLink link)? _onLink; // who takes a link that opens: the host's, or the guest's
int _session = 0;
bool _wired = false;

class NearbyLink extends ShareLink {
  NearbyLink(this.id);

  final String id;
  @override
  String get peer => 'nearby-$id';

  bool _open = false;
  bool _closed = false;
  @override
  bool get isOpen => _open;

  // Sent and not yet gone: id -> whether it was a snapshot. Calls not yet answered with an id are
  // counted apart, as an id can be reported gone before its call is answered.
  final Map<String, bool> _inFlight = {};
  int _askingAll = 0;
  int _askingSnapshots = 0;
  final Set<String> _early = {};
  final Map<String, _Partial> _partial = {};
  int _next = 0;

  int get _backlog => _askingAll + _inFlight.length;

  // What a picture's next chunk waits on: anything but snapshots, which never hold a picture up.
  @override
  Future<bool> congested() async => _askingAll - _askingSnapshots + _inFlight.values.where((s) => !s).length > 0;

  @override
  void send(Map<String, Object?> message) {
    if (!_open) return;
    final snapshot = message['type'] == 'state';
    if (snapshot && _backlog >= _backlogLimit) return;
    final text = jsonEncode(message);
    if (utf8.encode(text).length <= _maxBytes) {
      _push(text, snapshot);
      return;
    }
    final parts = splitForNearby(text);
    if (parts.length > _maxParts) return;
    final id = (_next++).toRadixString(36);
    for (var i = 0; i < parts.length; i++) {
      _push(jsonEncode({'~': 'part', 'id': id, 'i': i, 'n': parts.length, 's': parts[i]}), false);
    }
  }

  void _push(String text, bool snapshot) {
    _askingAll++;
    if (snapshot) _askingSnapshots++;
    void answered() {
      _askingAll--;
      if (snapshot) _askingSnapshots--;
    }

    Native.call('Flash', 'nearbySend', {'link': id, 'data': text}).then((r) {
      answered();
      final sent = r?['id'];
      if (sent is! String || _early.remove(sent)) return;
      if (!_closed) _inFlight[sent] = snapshot;
    }, onError: (Object _) => answered());
  }

  // The Java side says a message has gone, or failed.
  void _sent(String sent) {
    if (_inFlight.remove(sent) != null) return;
    _early.add(sent);
    if (_early.length > 64) _early.remove(_early.first);
  }

  void _received(String data) {
    final Object? message;
    try {
      message = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (message is! Map) return;
    if (message['~'] != 'part') {
      _deliver(message);
      return;
    }
    final id = message['id'], i = message['i'], n = message['n'], s = message['s'];
    if (id is! String || id.length > 12 || n is! int || n < 1 || n > _maxParts || i is! int || i < 0 || i >= n || s is! String || s.length > _partChars) {
      return;
    }
    var entry = _partial[id];
    if (entry == null || entry.parts.length != n) {
      entry = _partial[id] = _Partial(n);
      // Bounded, so a phone that starts long messages and never finishes them can't fill this
      // one's memory.
      while (_partial.length > _maxPartial) {
        _partial.remove(_partial.keys.first);
      }
    }
    if (entry.parts[i] == null) {
      entry.parts[i] = s;
      entry.count++;
    }
    if (entry.count < n) return;
    _partial.remove(id);
    try {
      final whole = jsonDecode(entry.parts.join());
      if (whole is Map) _deliver(whole);
    } catch (_) {
      // Not one message after all: dropped, as any unreadable one is.
    }
  }

  void _deliver(Map message) {
    if (message['type'] is String) onData?.call(Map<String, dynamic>.from(message));
  }

  void _opened() {
    _open = true;
    onOpen?.call();
  }

  @override
  Future<void> close({bool flush = false}) async {
    if (_closed) return;
    _closed = true;
    if (flush) {
      final until = DateTime.now().millisecondsSinceEpoch + _flushMs;
      while (_backlog > 0 && DateTime.now().millisecondsSinceEpoch < until) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    _open = false;
    _links.remove(id);
    Native.call('Flash', 'nearbyClose', {'link': id}).catchError((_) => null);
    onClose?.call();
  }

  // The Java side says it has gone.
  void _ended() {
    if (_closed) return;
    _closed = true;
    _open = false;
    _links.remove(id);
    onClose?.call();
  }
}

class _Partial {
  _Partial(int n) : parts = List<String?>.filled(n, null);
  final List<String?> parts;
  int count = 0;
}

/// Never between the two halves of a character outside the basic plane.
@visibleForTesting
List<String> splitForNearby(String text) {
  final parts = <String>[];
  for (var at = 0; at < text.length;) {
    var end = at + _partChars < text.length ? at + _partChars : text.length;
    final last = text.codeUnitAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end--;
    parts.add(text.substring(at, end));
    at = end;
  }
  return parts;
}

void _wire() {
  if (_wired) return;
  _wired = true;
  bool valid(Object? link) => link is String && RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(link);
  Native.on('Flash', 'nearbyOpen', (d) {
    final link = d['link'];
    if (!valid(link) || _links.containsKey(link)) return;
    final l = NearbyLink(link as String);
    _links[link] = l;
    final take = _onLink;
    if (take == null) {
      l.close();
      return;
    }
    // Handed over first, so its owner is listening when it says it's open.
    take(l);
    l._opened();
  });
  Native.on('Flash', 'nearbyData', (d) {
    final data = d['data'];
    if (data is String) _links[d['link']]?._received(data);
  });
  Native.on('Flash', 'nearbyClosed', (d) => _links[d['link']]?._ended());
  Native.on('Flash', 'nearbySent', (d) {
    final id = d['id'];
    if (id is String) _links[d['link']]?._sent(id);
  });
}

/// The advertised name's tag: PBKDF2 of the code, 64 bits, as 16 hex digits. The same as
/// js/nearby.js's, so a phone on 1.0.0 and one on this find each other.
@visibleForTesting
String nearbyTagFor(String code) {
  final hmac = Hmac(sha256, utf8.encode(code));
  // One block's worth: 64 bits are the first 8 bytes of the first 32.
  final salt = [...utf8.encode(_tagSalt), 0, 0, 0, 1];
  var u = hmac.convert(salt).bytes;
  final t = List<int>.of(u);
  for (var r = 1; r < _tagRounds; r++) {
    u = hmac.convert(u).bytes;
    for (var i = 0; i < t.length; i++) {
      t[i] ^= u[i];
    }
  }
  return t.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Whether this phone can share this way: in the app, with Play services.
bool get nearbyAvailable => Native.has('nearby');

class NearbySession {
  NearbySession(this.state, this.message, this._stop);
  final String state;
  final String message;
  final void Function() _stop;

  /// Ends this session, and nothing if another has started since.
  void stop() => _stop();
}

/// Starting one side, the host's ("nearbyHost") or a screen's ("nearbyJoin"). `ask` lets the app ask
/// for its permissions, which only a button press should.
Future<NearbySession> nearbyBegin(String method, String code, {required bool ask, required void Function(ShareLink link) onLink}) async {
  final mine = ++_session;
  _wire();
  _onLink = onLink;
  void stop() {
    if (_session != mine) return;
    _session++;
    _onLink = null;
    for (final link in List.of(_links.values)) {
      link.close();
    }
    Native.call('Flash', method == 'nearbyHost' ? 'nearbyStop' : 'nearbyLeave').catchError((_) => null);
  }

  Map<String, dynamic>? answer;
  try {
    final tag = await compute(nearbyTagFor, code);
    answer = await Native.call('Flash', method, {'code': code, 'tag': tag, 'ask': ask});
  } catch (_) {
    answer = {'state': 'failed'};
  }
  return NearbySession('${answer?['state'] ?? 'failed'}', '${answer?['message'] ?? ''}', stop);
}
