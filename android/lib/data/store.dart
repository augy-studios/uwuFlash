// What the app keeps on the phone, under the same keys and in the same shapes the site kept in
// localStorage (the site's js/store.js, js/theme.js and js/tray.js), so a feature reads what it
// always did and the data from before the Flutter app (data/migrate.dart) needs no conversion:
// every value a string, JSON where the site's was.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Store {
  Store._(this._prefs);

  static Store? _instance;
  static Store get I => _instance!;

  final SharedPreferences? _prefs;
  // Tests: kept in memory only.
  final Map<String, String> _memory = {};

  static Future<Store> open() async {
    final prefs = await SharedPreferences.getInstance();
    return _instance = Store._(prefs);
  }

  /// A store with these values and nothing written to the phone.
  @visibleForTesting
  static Store memory([Map<String, String> values = const {}]) {
    final s = Store._(null);
    s._memory.addAll(values);
    return _instance = s;
  }

  static const _prefix = 'ls.';

  String? get(String key) => _prefs == null ? _memory[key] : _prefs.getString('$_prefix$key');

  bool has(String key) => get(key) != null;

  void put(String key, String? value) {
    if (_prefs == null) {
      if (value == null) {
        _memory.remove(key);
      } else {
        _memory[key] = value;
      }
    } else if (value == null) {
      _prefs.remove('$_prefix$key');
    } else {
      _prefs.setString('$_prefix$key', value);
    }
  }
}
