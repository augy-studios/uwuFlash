// The sharing's wire, which has to stay what the site and phones on 1.0.0 speak.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwuflash/data/store.dart';
import 'package:uwuflash/native/native_bridge.dart';
import 'package:uwuflash/screens/update_bar.dart';
import 'package:uwuflash/share/binarypack.dart';
import 'package:uwuflash/share/nearby.dart';
import 'package:uwuflash/share/p2p.dart';
import 'package:uwuflash/share/share_host.dart';
import 'package:uwuflash/share/viewer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Native.available = false;
    Store.memory();
  });

  group('BinaryPack', () {
    Object? round(Object? v) => BinaryPack.unpack(BinaryPack.pack(v));

    test('numbers, in the host clock’s range and every size either side', () {
      for (final n in [0, 1, 127, 128, 255, 256, 65535, 65536, 4294967295, 4294967296, 1793917851104, -1, -32, -33, -128, -129, -32768, -32769, -2147483648, -2147483649]) {
        expect(round(n), n, reason: '$n');
      }
      expect(round(1.6), 1.6);
    });

    test('a snapshot comes back the same', () {
      final m = {
        'type': 'state',
        'clock': 1793917851104,
        'presenting': true,
        'shape': 0.462,
        'theme': {'color': 'classic', 'mode': 'dark'},
        'card': {
          'layout': 'image-center',
          'layers': [
            {'type': 'text', 'text': 'Héllo • 你好 🎉', 'size': 'l', 'align': 'center'},
          ],
        },
      };
      expect(round(m), m);
    });

    test('as js-binarypack packs them', () {
      // The first bytes of pack("hi") and pack([1, true, null]) from js-binarypack.
      expect(BinaryPack.pack('hi'), [0xb2, 0x68, 0x69]);
      expect(BinaryPack.pack([1, true, null]), [0x93, 0x01, 0xc3, 0xc0]);
      expect(BinaryPack.pack(Uint8List.fromList([1, 2])), [0xa2, 1, 2]);
    });
  });

  group('codes', () {
    test('made from the site’s alphabet, and read as the site reads them', () {
      for (var i = 0; i < 50; i++) {
        expect(isValidCode(generateCode()), isTrue);
      }
      expect(normaliseCode('bcd 234'), 'BCD234');
      expect(isValidCode('bcd-234'), isTrue);
      expect(isValidCode('AEIOU1'), isFalse, reason: 'no vowels, no 0 or 1');
      expect(isValidCode('BCD23'), isFalse);
      expect(isValidCode(null), isFalse);
    });

    test('the same protocol as js/p2p.js', () {
      final site = File('../main-site/js/p2p.js').readAsStringSync();
      expect(site, contains('export const PROTOCOL_VERSION = $protocolVersion;'));
      expect(site, contains('const CODE_ALPHABET = "$codeAlphabet"'));
      expect(site, contains('export const MAX_SCREENS = $maxScreens;'));
    });
  });

  group('Nearby', () {
    test('the same tag as js/nearby.js makes', () {
      // PBKDF2-SHA256 of "BCD234", salt "uwuflash-nearby-1", 100000 rounds, 8 bytes, from Node's crypto.
      expect(nearbyTagFor('BCD234'), '0f91ea75dc86a50c');
    });

    test('a long message splits without cutting a character in two', () {
      final text = '🎉' * 6000;
      final parts = splitForNearby(text);
      expect(parts.join(), text);
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(5000));
        expect(() => utf8.encode(p), returnsNormally);
        expect(p.codeUnitAt(p.length - 1) & 0xfc00, isNot(0xd800));
      }
    });
  });

  group('the wall', () {
    final host = ShareHost.I;

    setUp(() {
      host.order = [];
      host.cols = null;
      host.gap = gapDefault;
      host.seamsX = [];
      host.seamsY = [];
    });

    test('two screens side by side, with the bezels between them', () {
      host.order = ['aaaaaa', 'bbbbbb'];
      final geo = host.geometry;
      // Screens not heard from are taken as phones on their side, 150 by 70 mm.
      expect(geo.width, 150 + 8 + 150);
      expect(geo.height, 70);
      expect(geo.cells[1].left, 158);
      expect(geo.seamsX.single.at, 150);
      expect(geo.seamsX.single.gap, 8);
    });

    test('a short bottom row has blank places, sized as the usual screen', () {
      host.order = ['aaaaaa', 'bbbbbb', 'cccccc'];
      host.cols = 2;
      final l = host.wallLayout;
      expect((l.cols, l.rows, l.count), (2, 2, 3));
      final geo = host.geometry;
      expect(geo.cells, hasLength(4));
      expect(geo.height, 70 + 8 + 70);
      expect(geo.cells[3].top, 78);
    });

    test('a seam set alone, clamped to the tenth of a millimetre', () {
      host.order = ['aaaaaa', 'bbbbbb', 'cccccc'];
      host.setSeam('x', 1, 3.14);
      expect(host.geometry.seamsX.map((s) => s.gap), [8, 3.1]);
      host.setSeam('x', 0, 999);
      expect(host.geometry.seamsX.first.gap, gapMax);
    });
  });

  group('what a screen is sent is checked', () {
    test('a good snapshot', () {
      final s = Viewer.readState({
        'mode': 'show',
        'presenting': true,
        'theme': {'color': 'not-green-1', 'mode': 'dark', 'card': {'bg': '#112233', 'ink': '#aabbcc'}},
        'shape': 1.6,
        'ticker': {'speed': 'fast'},
        'card': {
          'layout': 'image-left',
          'wrap': false,
          'layers': [
            {'type': 'text', 'text': 'Hi', 'size': 'xl', 'align': 'left'},
            {'type': 'image', 'imageId': 'img-abc-123', 'fit': 'cover', 'fill': true, 'focus': {'x': 10, 'y': 20}},
          ],
        },
      });
      expect(s.color, 'not-green-1');
      expect(s.dark, isTrue);
      expect(s.cardColors?.bg, const Color(0xFF112233));
      expect(s.tickerSpeed, 'fast');
      expect(s.card!.layout, 'image-left');
      expect(s.card!.wrap, isFalse);
      expect(s.card!.fillImage!.focus.x, 10);
    });

    test('a bad one falls back rather than throwing', () {
      final s = Viewer.readState({
        'mode': 'nonsense',
        'presenting': true,
        'theme': {'color': '<script>', 'card': {'bg': 'red', 'ink': 5}},
        'shape': 'wide',
        'ticker': {'speed': 'ludicrous'},
        'card': {
          'layout': 'sideways',
          'layers': [
            {'type': 'image', 'imageId': '../../etc/passwd'},
            {'type': 'video'},
            'not even a layer',
            {'type': 'text', 'text': 'x' * 5000, 'size': 'massive', 'align': 'middle'},
          ],
        },
        'wall': {'n': 9, 'of': 2, 'col': 0, 'row': 0, 'cols': 1, 'rows': 1},
      });
      expect(s.color, 'classic');
      expect(s.cardColors, isNull);
      expect(s.shape, isNull);
      expect(s.wall, isNull, reason: 'numbers that disagree');
      expect(s.tickerSpeed, isNull);
      expect(s.card!.layout, 'image-center');
      expect(s.card!.layers, hasLength(1));
      expect(s.card!.layers.single.text.length, 2000);
      expect(s.card!.layers.single.size, 'l');
    });

    test('a sent deck keeps only what can arrive', () {
      final o = Viewer.readOffer({
        'cards': [
          {'layers': [{'type': 'image', 'imageId': 'img-one', 'hidden': true}, {'type': 'text', 'text': 'Words', 'hidden': true}]},
          'junk',
        ],
      }, null)!;
      expect(o.cards, hasLength(1));
      expect(o.imageIds, {'img-one'});
      expect(o.cards.single.layers.every((l) => l.hidden), isTrue);
      expect(Viewer.readOffer({'cards': 'none'}, null), isNull);
    });
  });

  group('where the card is drawn on the other screen', () {
    test('the card’s shape, centred in a screen of another shape', () {
      final s = ViewState(mode: 'show', card: null, color: 'classic', dark: false, cardColors: null, wall: null, shape: 1.6, tickerSpeed: null);
      final r = Viewer.stageRect(s, const Size(400, 800), EdgeInsets.zero);
      expect(r.w, 1);
      expect(r.h, closeTo(0.3125, 0.0001));
      expect(r.y, closeTo(0.34375, 0.0001));
    });

    test('a shape close enough fills the screen', () {
      final s = ViewState(mode: 'show', card: null, color: 'classic', dark: false, cardColors: null, wall: null, shape: 1.6, tickerSpeed: null);
      final r = Viewer.stageRect(s, const Size(800, 480), EdgeInsets.zero);
      expect((r.x, r.y, r.w, r.h), (0, 0, 1, 1));
    });
  });

  test('versions compare number by number', () {
    expect(newerVersion('1.10.0', '1.9.0'), isTrue);
    expect(newerVersion('1.1.0', '1.1.0'), isFalse);
    expect(newerVersion('1.0.9', '1.1.0'), isFalse);
    expect(newerVersion('2', '1.9.9'), isTrue);
    expect(newerVersion('1.1', '1.1.0'), isFalse);
  });
}
