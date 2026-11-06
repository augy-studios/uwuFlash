// The first launch after updating from the WebView app (1.0.0): everything the site kept in the
// WebView's localStorage brought into the app's own store, as it was, and its pictures into the app's
// own files (MigratePlugin reads both). The WebView's copy is left alone, so nothing's lost either way,
// and if a picture the deck uses doesn't come, the next launch tries again.
import 'dart:convert';

import '../native/native_bridge.dart';
import 'deck.dart';
import 'images.dart';
import 'store.dart';

class Migrate {
  static const doneKey = 'app.migrated';
  static const triesKey = 'app.migrateTries';
  static const maxTries = 3;
  static const _prefix = 'uwuflash.';
  static const _deckKey = '${_prefix}deck';

  /// Whether a deck came over this time (false when it was done before, or there was nothing).
  /// `hasPicture` says whether a picture's here: the app's own files, unless a test says otherwise.
  static Future<bool> run(Store store, {Future<bool> Function(String id)? hasPicture}) async {
    if (store.has(doneKey) || !Native.available) return false;
    final tries = int.tryParse(store.get(triesKey) ?? '') ?? 0;
    var brought = false;
    try {
      final r = await Native.call('Migrate', 'read');
      final items = Map<String, dynamic>.from((r?['items'] as Map?) ?? const {});
      items.forEach((k, v) {
        // Only the site's own, and never over anything the app has set since.
        if (!k.startsWith(_prefix) || store.has(k) || v is! String) return;
        // The site writes "light" on every first visit, chosen or not, so it says nothing about
        // what you want. Left out, Material You follows the phone, and the UwU Apps theme still
        // starts light.
        if (k == '${_prefix}mode' && v == 'light') return;
        store.put(k, v);
      });
      brought = tries == 0 && items.containsKey(_deckKey);
    } on NativeError {
      // No WebView to read: a phone that never had the old app's data either.
    }

    // Not done until the deck has what it points at, or that's been tried enough to say it's gone.
    if (tries + 1 < maxTries && await _missingPictures(store, hasPicture ?? _onDisk)) {
      store.put(triesKey, '${tries + 1}');
      return brought;
    }
    store.put(doneKey, DateTime.now().millisecondsSinceEpoch.toString());
    store.put(triesKey, null);
    return brought;
  }

  static Future<bool> _onDisk(String id) async => await Images.I.load(id) != null;

  static Future<bool> _missingPictures(Store store, Future<bool> Function(String id) hasPicture) async {
    try {
      final text = store.get(_deckKey);
      if (text == null) return false;
      for (final id in Deck.read(jsonDecode(text)).imageIds) {
        if (!await hasPicture(id)) return true;
      }
      return false;
    } catch (_) {
      // A deck that doesn't read has no pictures to wait for.
      return false;
    }
  }
}
