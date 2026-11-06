// The screen while presenting and while showing shared cards (the site's js/screen.js, and
// FlashPlugin.java):
//
// - Kept on, at full brightness (this app's window only, so the phone's setting is never touched),
//   and with every bar hidden.
// - The volume keys, while presenting: down for the next card, up for the one before, either held
//   for the ticker.
// - A flick of the wrist, while presenting with it switched on.
// - Speaking a card's words, through Android's own speech screen.
import 'native_bridge.dart';

class Screen {
  Screen._();

  /// What each part of the app wants of the screen: the presenter, and the viewer. The screen gets
  /// all of them at once, so one letting go never takes away what the other still wants.
  static final Map<String, ({bool awake, bool bright, bool immersive})> _holds = {};

  static void hold(String owner, {bool awake = true, bool bright = true, bool immersive = false}) {
    _holds[owner] = (awake: awake, bright: bright, immersive: immersive);
    _apply();
  }

  static void release(String owner) {
    if (_holds.remove(owner) != null) _apply();
  }

  static void _apply() {
    if (!Native.has('screen')) return;
    Native.call('Flash', 'screen', {
      'awake': _holds.values.any((h) => h.awake),
      'bright': _holds.values.any((h) => h.bright),
      'immersive': _holds.values.any((h) => h.immersive),
    }).catchError((_) => null);
  }

  // ---------- the volume keys ----------

  static void Function(String key)? _keyHandler;
  static NativeListener? _keyListener;

  /// While a handler is set, the keys come to it as "next", "previous" and "hold"; set null, they
  /// go back to the phone.
  static void captureKeys(void Function(String key)? handler) {
    if (!Native.has('keys')) return;
    _keyHandler = handler;
    _keyListener ??= Native.on('Flash', 'key', (d) {
      final key = d['key'];
      if (key is String) _keyHandler?.call(key);
    });
    Native.call('Flash', 'keys', {'on': handler != null}).catchError((_) => null);
  }

  // ---------- flick ----------

  static void Function(int direction)? _flickHandler;
  static NativeListener? _flickListener;

  static bool get canFlick => Native.has('flick');

  /// While a handler is set, flicks come to it as 1 (next) or -1 (before).
  static void watchFlick(void Function(int direction)? handler) {
    if (!canFlick) return;
    _flickHandler = handler;
    _flickListener ??= Native.on('Flash', 'flick', (d) {
      final direction = d['direction'];
      if (direction == 1 || direction == -1) _flickHandler?.call(direction as int);
    });
    Native.call('Flash', 'flick', {'on': handler != null}).catchError((_) => null);
  }

  // ---------- speaking ----------

  static bool get canListen => Native.has('listen');

  /// What was said, or null if the speech screen was backed out of.
  static Future<String?> listen(String prompt) async {
    try {
      final r = await Native.call('Flash', 'listen', {'prompt': prompt});
      final text = r?['text'];
      return text is String && text.trim().isNotEmpty ? text.trim() : null;
    } catch (_) {
      return null;
    }
  }
}
