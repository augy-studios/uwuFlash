// The deck: what the WebView app stored reads as it is, and goes back the same; and which slot each
// layer lands in, as the site's js/render.js has them.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwuflash/data/deck.dart';
import 'package:uwuflash/data/images.dart';
import 'package:uwuflash/data/migrate.dart';
import 'package:uwuflash/data/store.dart';
import 'package:uwuflash/native/native_bridge.dart';

Layer text(String t, {bool hidden = false}) => Layer.text(id: t, text: t, hidden: hidden);
Layer image(String id, {bool fill = false, bool hidden = false}) => Layer.image(id: id, imageId: 'img-$id', fill: fill, hidden: hidden);
FlashCard card(String layout, List<Layer> layers) => FlashCard(id: 'c', layout: layout, layers: layers);
List<String> shape(FlashCard c) => groupLayers(c).map((s) => '${s.isImage ? 'img' : 'txt'}:${s.layers.map((l) => l.id).join(',')}').toList();

class _OldApp implements NativeFake {
  _OldApp(this.items);
  final Map<String, String> items;
  int reads = 0;

  @override
  Future<Map<String, dynamic>?> call(String plugin, String method, Map<String, dynamic> options) async {
    expect('$plugin.$method', 'Migrate.read');
    reads++;
    return {'found': true, 'items': items, 'images': 0};
  }
}

void main() {
  group('a deck from the site', () {
    const fromSite = '{"version":1,"cards":[{"id":"mzabc-q1","layout":"image-left","layers":['
        '{"id":"l1","type":"text","text":"Hi\\nthere","size":"xl","align":"left","hidden":false},'
        '{"id":"l2","type":"image","imageId":"img-mzabc-q2","fit":"cover","fill":true,"focus":{"x":12.5,"y":50},"hidden":false}'
        '],"ticker":true,"tickerSpeed":"fast","wrap":false}]}';

    test('reads, and writes back the same', () {
      expect(jsonDecode(jsonEncode(Deck.read(jsonDecode(fromSite)).toJson())), jsonDecode(fromSite));
    });

    test('older or broken ones are filled in rather than trusted', () {
      final d = Deck.read({
        'cards': [
          {'layers': [{'type': 'image'}, {'type': 'text', 'size': 'giant', 'align': 'up'}, 'junk'], 'layout': 'nope', 'tickerSpeed': 'warp'},
          'junk',
        ],
      });
      expect(d.cards, hasLength(2));
      final c = d.cards.first;
      expect(c.layout, defaultLayout);
      expect(c.tickerSpeed, defaultTickerSpeed);
      expect(c.wrap, isTrue);
      expect(c.layers, hasLength(1));
      expect((c.layers.single.size, c.layers.single.align), ('l', 'center'));
      expect(c.id, isNotEmpty);
    });

    test('nothing to read is one blank card', () {
      expect(Deck.read(null).cards, hasLength(1));
      expect(Deck.read({'cards': []}).isBlank, isTrue);
    });
  });

  group('slots', () {
    test('image centre: the layer order moves the picture up and down the card', () {
      expect(shape(card('image-center', [text('a'), image('p'), text('b')])), ['txt:a', 'img:p', 'txt:b']);
      expect(shape(card('image-center', [image('p'), text('a')])), ['img:p', 'txt:a']);
      expect(shape(card('image-center', [text('a'), image('p')])), ['txt:a', 'img:p']);
    });

    test('image between: the words split round it, wherever the layers are', () {
      expect(shape(card('image-between', [image('p'), text('a'), text('b'), text('c')])), ['txt:a,b', 'img:p', 'txt:c']);
      expect(shape(card('image-between', [text('a'), image('p')])), ['txt:a', 'img:p']);
    });

    test('image left and right', () {
      expect(shape(card('image-left', [text('a'), image('p')])), ['img:p', 'txt:a']);
      expect(shape(card('image-right', [image('p'), text('a')])), ['txt:a', 'img:p']);
    });

    test('hidden layers aren’t drawn, and no picture means words alone', () {
      expect(shape(card('image-left', [text('a'), image('p', hidden: true)])), ['txt:a']);
      expect(shape(card('image-center', [text('a', hidden: true)])), isEmpty);
    });

    test('a picture filling the card is behind it, not in a slot', () {
      final c = card('image-left', [image('p', fill: true), text('a')]);
      expect(c.fillImage?.id, 'p');
      expect(shape(c), ['txt:a']);
    });

    test('filling only counts on a card with one picture, hidden ones included', () {
      expect(card('image-center', [image('p', fill: true), image('q', hidden: true)]).fillImage, isNull);
      expect(card('image-center', [image('p', fill: true, hidden: true)]).fillImage, isNull);
    });
  });

  test('the ticker’s line', () {
    final c = card('image-center', [text('One  two\nthree'), text('Gone', hidden: true), image('p'), text('   '), text('Four')]);
    expect(tickerText(c), 'One two three$tickerGap' 'Four');
    expect(showsTicker(c), isFalse);
    c.ticker = true;
    expect(showsTicker(c), isTrue);
    expect(showsTicker(card('image-center', [image('p')])..ticker = true), isFalse);
  });

  test('summaries', () {
    expect(card('image-center', [text('  Hi  ')]).summary, 'Hi');
    expect(card('image-center', [text('x' * 50)]).summary, '${'x' * 40}...');
    expect(card('image-center', [image('p')]).summary, 'Image');
    expect(card('image-center', [text(' ')]).summary, 'Empty card');
  });

  test('a duplicate has fresh ids and shares its picture', () {
    final c = card('image-center', [image('p'), text('a')]);
    final d = c.duplicate();
    expect(d.id, isNot(c.id));
    expect(d.layers.first.id, isNot('p'));
    expect(d.layers.first.imageId, 'img-p');
    d.layers.last.text = 'changed';
    expect(c.layers.last.text, 'a');
  });

  test('what’s a picture and what isn’t', () {
    List<int> b(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    expect(imageMime(Uint8List.fromList(b('89504e470d0a'))), 'image/png');
    expect(imageMime(Uint8List.fromList(b('ffd8ffe0'))), 'image/jpeg');
    expect(imageMime(Uint8List.fromList(utf8.encode('RIFF....WEBPVP8 '))), 'image/webp');
    expect(imageMime(Uint8List.fromList(utf8.encode('....ftypheic'))), 'image/heic');
    expect(imageMime(Uint8List.fromList(utf8.encode('  <svg xmlns="x"></svg>'))), 'image/svg+xml');
    expect(imageMime(Uint8List.fromList(utf8.encode('just some words'))), isNull);
  });

  group('coming from the WebView app', () {
    test('brings the site’s keys once, but not the light it writes unasked', () async {
      final old = _OldApp({
        'uwuflash.deck': '{"version":1,"cards":[]}',
        'uwuflash.colorTheme': 'not-green-2',
        'uwuflash.mode': 'light',
        'uwuflash.flick': '1',
        'somebody.else': 'no',
      });
      Native.available = true;
      Native.fake = old;
      final store = Store.memory();
      expect(await Migrate.run(store), isTrue);
      expect(store.get('uwuflash.colorTheme'), 'not-green-2');
      expect(store.get('uwuflash.flick'), '1');
      expect(store.get('uwuflash.mode'), isNull);
      expect(store.get('somebody.else'), isNull);
      expect(await Migrate.run(store), isFalse);
      expect(old.reads, 1);
      Native.fake = null;
    });

    test('a picture that didn’t come is tried again on the next launches, then let go', () async {
      const deck = '{"version":1,"cards":[{"id":"c","layers":[{"id":"i","type":"image","imageId":"img-gone"}]}]}';
      final old = _OldApp({'uwuflash.deck': deck});
      Native.available = true;
      Native.fake = old;
      final store = Store.memory();
      Future<bool> never(String id) async => false;

      expect(await Migrate.run(store, hasPicture: never), isTrue, reason: 'the words are here, and it says so once');
      expect(store.has(Migrate.doneKey), isFalse);
      expect(await Migrate.run(store, hasPicture: never), isFalse);
      expect(store.has(Migrate.doneKey), isFalse);
      expect(await Migrate.run(store, hasPicture: never), isFalse);
      expect(store.has(Migrate.doneKey), isTrue, reason: 'three goes, then it really isn’t there');
      expect(await Migrate.run(store, hasPicture: never), isFalse);
      expect(old.reads, 3);
      Native.fake = null;
    });

    test('a picture that comes on the second go finishes it, keeping edits made since', () async {
      const deck = '{"version":1,"cards":[{"id":"c","layers":[{"id":"i","type":"image","imageId":"img-late"}]}]}';
      final old = _OldApp({'uwuflash.deck': deck});
      Native.available = true;
      Native.fake = old;
      final store = Store.memory();
      await Migrate.run(store, hasPicture: (id) async => false);
      store.put('uwuflash.deck', deck.replaceAll('"c"', '"edited"'));
      await Migrate.run(store, hasPicture: (id) async => true);
      expect(store.has(Migrate.doneKey), isTrue);
      expect(store.get('uwuflash.deck'), contains('edited'));
      Native.fake = null;
    });

    test('keeps a dark or by-the-clock mode someone chose, and never overwrites', () async {
      Native.available = true;
      Native.fake = _OldApp({'uwuflash.mode': 'dark', 'uwuflash.colorTheme': 'not-green-1'});
      final store = Store.memory({'uwuflash.colorTheme': 'classic'});
      expect(await Migrate.run(store), isFalse, reason: 'no deck came over');
      expect(store.get('uwuflash.mode'), 'dark');
      expect(store.get('uwuflash.colorTheme'), 'classic');
      Native.fake = null;
    });
  });
}
