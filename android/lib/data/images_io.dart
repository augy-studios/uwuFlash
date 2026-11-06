// The pictures as files, files/images/<id> in the app's own storage, where MigratePlugin also puts
// the WebView app's. Never in the shared gallery: a card's picture isn't anyone else's business.
import 'dart:io';
import 'dart:typed_data';

import '../native/native_bridge.dart';

Directory? _dir;

Future<Directory> _images() async {
  final known = _dir;
  if (known != null) return known;
  final r = await Native.call('Flash', 'filesDir');
  final dir = Directory('${r?['path']}/images');
  if (!await dir.exists()) await dir.create(recursive: true);
  return _dir = dir;
}

Future<Uint8List?> read(String id) async {
  final f = File('${(await _images()).path}/$id');
  return await f.exists() ? f.readAsBytes() : null;
}

// To a temporary name first, so a picture cut short never passes for the whole of it.
Future<void> write(String id, Uint8List bytes) async {
  final dir = await _images();
  final part = File('${dir.path}/$id.part');
  await part.writeAsBytes(bytes, flush: true);
  await part.rename('${dir.path}/$id');
}

Future<void> remove(String id) async {
  final f = File('${(await _images()).path}/$id');
  if (await f.exists()) await f.delete();
}

Future<List<String>> list() async {
  final dir = await _images();
  return [
    await for (final e in dir.list())
      if (e is File && !e.path.endsWith('.part')) e.uri.pathSegments.last,
  ];
}
