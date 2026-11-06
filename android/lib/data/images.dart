// The pictures on the cards, as files on the phone (images_io.dart), kept apart from the deck as
// the site kept them in IndexedDB: a deck with four photographs in it is many megabytes. Everything
// here is local to the device, so the app works with no network at all.
//
// The last few read are held in memory, the same bytes each time, so a picture isn't decoded again
// on every redraw (Flutter's image cache knows a picture by its bytes).
import 'dart:typed_data';

import 'images_web.dart' if (dart.library.io) 'images_io.dart' as disk;

/// Where a card's pictures come from: this device's own, or what a shared screen has been sent.
abstract class ImageSource {
  /// The picture's bytes if they're to hand, without waiting.
  Uint8List? peek(String id);

  /// The picture's bytes, or null if there's no such picture.
  Future<Uint8List?> load(String id);
}

class Images implements ImageSource {
  Images._();
  static final Images I = Images._();

  static const _keepBytes = 96 * 1024 * 1024;
  final Map<String, Uint8List> _cache = {}; // oldest first

  void _keep(String id, Uint8List bytes) {
    _cache.remove(id);
    _cache[id] = bytes;
    var total = _cache.values.fold<int>(0, (n, b) => n + b.length);
    while (total > _keepBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      total -= _cache[oldest]!.length;
      _cache.remove(oldest);
    }
  }

  @override
  Uint8List? peek(String id) => _cache[id];

  @override
  Future<Uint8List?> load(String id) async {
    final held = _cache[id];
    if (held != null) return held;
    final bytes = await disk.read(id);
    if (bytes != null) _keep(id, bytes);
    return bytes;
  }

  Future<void> put(String id, Uint8List bytes) async {
    await disk.write(id, bytes);
    _keep(id, bytes);
  }

  /// Pictures outlive the layer that used them only until the next sweep, called after a delete,
  /// so a deck that has had many pictures swapped in and out doesn't keep every one of them. A
  /// sweep that fails costs space, not correctness.
  Future<void> prune(Set<String> keep) async {
    try {
      for (final id in await disk.list()) {
        if (keep.contains(id)) continue;
        _cache.remove(id);
        await disk.remove(id);
      }
    } catch (_) {
      // Not worth saying.
    }
  }
}

/// What kind of picture these bytes are, by their first few, or null if they aren't one.
String? imageMime(Uint8List b) {
  bool starts(List<int> sig, [int at = 0]) {
    if (b.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[at + i] != sig[i]) return false;
    }
    return true;
  }

  if (starts([0x89, 0x50, 0x4e, 0x47])) return 'image/png';
  if (starts([0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (starts([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts([0x42, 0x4d])) return 'image/bmp';
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
  if (starts([0x66, 0x74, 0x79, 0x70], 4)) {
    if (starts([0x61, 0x76, 0x69, 0x66], 8) || starts([0x61, 0x76, 0x69, 0x73], 8)) return 'image/avif';
    if (starts([0x68, 0x65, 0x69], 8) || starts([0x68, 0x65, 0x76], 8) || starts([0x6d, 0x69, 0x66, 0x31], 8)) return 'image/heic';
  }
  if (isSvg(b)) return 'image/svg+xml';
  return null;
}

bool isSvg(Uint8List b) {
  final head = String.fromCharCodes(b.take(512)).trimLeft().toLowerCase();
  return head.startsWith('<svg') || (head.startsWith('<?xml') && head.contains('<svg'));
}
