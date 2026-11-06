// A picture made ready to send to another screen (the site's share.js, shrink). A photograph
// straight off a phone is 12 megapixels and several megabytes. No screen this is shown on needs more
// than 1080p, so anything larger is scaled before it's sent.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../data/images.dart';

const _maxEdge = 1920;
const _keepBytes = 400 * 1024;
const _quality = 85;

class PreparedImage {
  PreparedImage(this.mime, this.data);
  final String mime;
  final String data; // base64
}

/// The bytes to send: as they are when small enough, or JPEG when there's no transparency to keep
/// (PNG when there is). The original, if that came out no smaller.
Future<({Uint8List bytes, String mime})> shrink(Uint8List bytes) async {
  final original = imageMime(bytes) ?? 'image/png';
  if (original == 'image/svg+xml') return (bytes: bytes, mime: original);

  try {
    var scale = 1.0;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      scale = _maxEdge / (w > h ? w : h);
      if (scale > 1) scale = 1;
      return ui.TargetImageSize(width: (w * scale).round().clamp(1, _maxEdge), height: (h * scale).round().clamp(1, _maxEdge));
    });
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    if (scale == 1 && bytes.length <= _keepBytes) {
      image.dispose();
      return (bytes: bytes, mime: original);
    }
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final width = image.width, height = image.height;
    image.dispose();
    if (raw == null) return (bytes: bytes, mime: original);

    final out = await compute(_encode, _Raw(raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes), width, height));
    return out.bytes.length < bytes.length ? out : (bytes: bytes, mime: original);
  } catch (_) {
    // Something the phone can't read. Sent as it is; the other screen may manage.
    return (bytes: bytes, mime: original);
  }
}

class _Raw {
  _Raw(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

({Uint8List bytes, String mime}) _encode(_Raw raw) {
  var opaque = true;
  for (var i = 3; i < raw.rgba.length; i += 4) {
    if (raw.rgba[i] != 255) {
      opaque = false;
      break;
    }
  }
  final image = img.Image.fromBytes(width: raw.width, height: raw.height, bytes: raw.rgba.buffer, bytesOffset: raw.rgba.offsetInBytes, numChannels: 4);
  return opaque
      ? (bytes: Uint8List.fromList(img.encodeJpg(image, quality: _quality)), mime: 'image/jpeg')
      : (bytes: Uint8List.fromList(img.encodePng(image, level: 6)), mime: 'image/png');
}

Future<PreparedImage> prepareImage(String id) async {
  final bytes = await Images.I.load(id);
  if (bytes == null) throw StateError('image missing');
  final small = await shrink(bytes);
  return PreparedImage(small.mime, base64Encode(small.bytes));
}
