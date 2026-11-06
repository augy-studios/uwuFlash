// The pictures in the browser, for the Playwright suite only (e2e/): the website is still the HTML
// site in main-site/, and this build never ships. Kept in shared_preferences as base64, so a
// reload in a test finds them as a phone would.
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

const _prefix = 'img.';

Future<Uint8List?> read(String id) async {
  final prefs = await SharedPreferences.getInstance();
  final v = prefs.getString('$_prefix$id');
  return v == null ? null : base64Decode(v);
}

Future<void> write(String id, Uint8List bytes) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('$_prefix$id', base64Encode(bytes));
}

Future<void> remove(String id) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('$_prefix$id');
}

Future<List<String>> list() async {
  final prefs = await SharedPreferences.getInstance();
  return [
    for (final k in prefs.getKeys())
      if (k.startsWith(_prefix)) k.substring(_prefix.length),
  ];
}
