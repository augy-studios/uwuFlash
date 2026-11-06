// The app's native parts, from Dart: the Java plugins in android/app/src/main/java/org/uwuapps/
// flash/ (FlashPlugin, MigratePlugin), over the bridge's method channel (bridge/Bridge.java). The
// same calls and events the site's page made of them when the app was a WebView, so FlashPlugin's
// own docs still say what each does.
//
//   Native.call('Flash', 'info')                the plugin's answer, as a map (or null)
//   Native.on('Flash', 'key', (data) {...})     its events, until .cancel()
//   Native.has('flick')                         whether this build and phone can (info's features)
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A plugin call that failed: its message, and the code the plugin gave ("cancelled",
/// "unavailable", ...).
class NativeError implements Exception {
  NativeError(this.message, {this.code});
  final String message;
  final String? code;

  @override
  String toString() => code == null ? message : '$message ($code)';
}

/// One listener on a plugin's event.
class NativeListener {
  NativeListener._(this._key, this._fn);
  final String _key;
  final void Function(Map<String, dynamic>) _fn;

  void cancel() => Native._remove(this);
}

/// Stands in for the Java side where there's none, in the Playwright suite and in tests.
abstract class NativeFake {
  Future<Map<String, dynamic>?> call(String plugin, String method, Map<String, dynamic> options);
}

class Native {
  Native._();

  static const _channel = MethodChannel('org.uwuapps.flash/bridge');
  static final Map<String, List<NativeListener>> _listeners = {};
  static bool _started = false;
  static Map<String, dynamic>? _info;

  /// Set before start() to answer calls without Java.
  static NativeFake? fake;

  /// Whether the native side is there at all: false on the web and in tests, unless faked.
  static bool available = true;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    if (fake == null && kIsWeb) available = false;
    if (fake == null && available) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'event') return null;
        final args = Map<String, dynamic>.from(call.arguments as Map);
        emit('${args['plugin']}', '${args['event']}', _decode(args['data'] as String?) ?? <String, dynamic>{});
        return null;
      });
      try {
        await _channel.invokeMethod('hello');
      } on MissingPluginException {
        available = false;
      } catch (_) {
        // Answered below, if at all.
      }
    }
    try {
      if (available) {
        // Back as it was: a Dart side restarted mid-way through presenting mustn't leave the
        // volume keys caught or the screen held on.
        await call('Flash', 'reset');
        _info = await call('Flash', 'info');
      }
    } catch (_) {
      _info = null;
    }
  }

  /// What this build and phone can do, as FlashPlugin.info lists it.
  static bool has(String feature) => ((_info?['features'] as List?) ?? const []).contains(feature);
  static Map<String, dynamic>? get info => _info;
  static String? get version => _info?['version'] as String?;

  static Future<Map<String, dynamic>?> call(String plugin, String method, [Map<String, dynamic>? options]) async {
    if (!available) throw NativeError('Not in the app', code: 'unavailable');
    final f = fake;
    if (f != null) return f.call(plugin, method, options ?? const {});
    try {
      final json = await _channel.invokeMethod<String>('call', {
        'plugin': plugin,
        'method': method,
        'options': jsonEncode(options ?? const {}),
      });
      return _decode(json);
    } on PlatformException catch (e) {
      throw NativeError(e.message ?? 'Failed', code: e.code);
    } on MissingPluginException {
      available = false;
      throw NativeError('Not in the app', code: 'unavailable');
    }
  }

  static NativeListener on(String plugin, String event, void Function(Map<String, dynamic>) fn) {
    final key = '$plugin.$event';
    final l = NativeListener._(key, fn);
    final list = _listeners.putIfAbsent(key, () => []);
    list.add(l);
    if (list.length == 1 && available && fake == null) {
      _channel.invokeMethod('listen', {'plugin': plugin, 'event': event}).catchError((_) => null);
    }
    return l;
  }

  /// An event, to everything listening for it. From the channel, or from a fake.
  static void emit(String plugin, String event, Map<String, dynamic> data) {
    for (final l in List.of(_listeners['$plugin.$event'] ?? const <NativeListener>[])) {
      try {
        l._fn(data);
      } catch (_) {
        // One listener's trouble isn't the others'.
      }
    }
  }

  static void _remove(NativeListener l) {
    final list = _listeners[l._key];
    if (list == null || !list.remove(l) || list.isNotEmpty || !available || fake != null) return;
    final parts = l._key.split('.');
    _channel.invokeMethod('unlisten', {'plugin': parts[0], 'event': parts[1]}).catchError((_) => null);
  }

  static Map<String, dynamic>? _decode(String? json) {
    if (json == null || json.isEmpty) return null;
    final v = jsonDecode(json);
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }
}
