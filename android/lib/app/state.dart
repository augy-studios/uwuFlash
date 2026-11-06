// The deck and what's being done with it (the site's js/app.js): the card and layer on show, every
// edit, saving, and presenting. The screens draw from this and call into it.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/deck.dart';
import '../data/images.dart';
import '../data/store.dart';
import '../native/screen.dart';
import '../share/share_host.dart';
import '../ui/kit.dart';

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState I = AppState._();

  static const deckKey = 'uwuflash.deck';
  static const flickKey = 'uwuflash.flick';
  static const _saveAfter = Duration(milliseconds: 400);

  Deck deck = Deck.blank();
  int cardIndex = 0;
  String? selectedLayerId;
  bool presenting = false;

  FlashCard get card => deck.cards[cardIndex];

  Layer? get selectedLayer {
    for (final l in card.layers) {
      if (l.id == selectedLayerId) return l;
    }
    return null;
  }

  void load() {
    Object? raw;
    try {
      final text = Store.I.get(deckKey);
      raw = text == null ? null : jsonDecode(text);
    } catch (_) {
      // Corrupt storage isn't worth crashing the app over. A fresh deck loses less than a blank
      // screen does.
    }
    deck = Deck.read(raw);
    cardIndex = 0;
    selectedLayerId = card.layers.isEmpty ? null : card.layers.first.id;
  }

  // ---------- saving ----------

  Timer? _saveTimer;

  /// Typing into a card shouldn't write on every keystroke, but a deck must never be left unsaved
  /// either: to the next idle moment, and flushed on anything that could end the app.
  void persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveAfter, flush);
  }

  void flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      Store.I.put(deckKey, jsonEncode(deck.toJson()));
    } catch (_) {
      AppNav.say('Could not save. Storage may be full.');
    }
    // A device copying this deck gets every saved edit. Nothing unless Send is picked and somebody
    // has joined.
    ShareHost.I.deckChanged();
  }

  void changed({bool save = true}) {
    notifyListeners();
    if (save) persist();
  }

  // ---------- cards ----------

  void selectCard(int index) {
    if (index < 0 || index >= deck.cards.length) return;
    cardIndex = index;
    final layers = card.layers;
    selectedLayerId = layers.isEmpty ? null : layers.last.id;
    notifyListeners();
  }

  void addCard() {
    deck.cards.insert(cardIndex + 1, FlashCard.blank());
    selectCard(cardIndex + 1);
    persist();
  }

  // Fresh ids, so editing the copy doesn't edit the original. The picture is shared: two cards
  // pointing at one picture is what a duplicate should be, and prune only drops a picture once no
  // card at all refers to it.
  void duplicateCard() {
    deck.cards.insert(cardIndex + 1, card.duplicate());
    selectCard(cardIndex + 1);
    persist();
  }

  Future<void> deleteCard() async {
    if (deck.cards.length == 1) {
      // Never leave the deck with nothing in it: an empty deck has no screen to show and no
      // obvious way back to one.
      deck.cards = [FlashCard.blank()];
      cardIndex = 0;
    } else {
      deck.cards.removeAt(cardIndex);
      if (cardIndex >= deck.cards.length) cardIndex = deck.cards.length - 1;
    }
    selectCard(cardIndex);
    flush();
    await Images.I.prune(deck.imageIds);
  }

  void moveCard(int delta) {
    final to = cardIndex + delta;
    if (!moveInList(deck.cards, cardIndex, to)) return;
    cardIndex = to;
    changed();
  }

  // ---------- layers ----------

  void selectLayer(String id) {
    selectedLayerId = id;
    notifyListeners();
  }

  Layer addTextLayer() {
    final layer = Layer.text(id: newId());
    card.layers.add(layer);
    selectedLayerId = layer.id;
    changed();
    return layer;
  }

  void toggleLayer(Layer layer) {
    layer.hidden = !layer.hidden;
    changed();
  }

  void reorderLayer(Layer layer, int delta) {
    final from = card.layers.indexOf(layer);
    if (!moveInList(card.layers, from, from + delta)) return;
    selectedLayerId = layer.id;
    changed();
  }

  Future<void> removeLayer(Layer layer) async {
    final layers = card.layers;
    if (!layers.remove(layer)) return;
    if (selectedLayerId == layer.id) selectedLayerId = layers.isEmpty ? null : layers.last.id;
    notifyListeners();
    flush();
    await Images.I.prune(deck.imageIds);
  }

  /// A picture picked for a new layer, or to replace one layer's. Says so if it isn't a picture.
  Future<void> addImage(Uint8List bytes, {Layer? replacing}) async {
    if (imageMime(bytes) == null) {
      AppNav.say('That file is not an image.');
      return;
    }
    final imageId = newImageId();
    try {
      await Images.I.put(imageId, bytes);
    } catch (_) {
      AppNav.say('Could not store that image.');
      return;
    }
    if (replacing != null && card.layers.contains(replacing)) {
      replacing.imageId = imageId;
      selectedLayerId = replacing.id;
    } else {
      final layer = Layer.image(id: newId(), imageId: imageId);
      card.layers.add(layer);
      selectedLayerId = layer.id;
    }
    notifyListeners();
    flush();
    await Images.I.prune(deck.imageIds);
  }

  /// Words said to the speech screen: on a line of their own after any already there, so speaking
  /// never throws away what was typed.
  void addSpoken(Layer layer, String said) {
    final before = layer.text.trimRight();
    layer.text = before.isEmpty ? said : '$before\n$said';
    changed();
  }

  /// Cards sent from another device, added after this deck's own or replacing them. Every picture
  /// is stored under a new id of this device's making, so one sent with the id of a picture
  /// already here can't overwrite it. A layer whose picture never came, or couldn't be stored, is
  /// left out.
  Future<void> importCards(List<FlashCard> cards, Map<String, Uint8List> pictures, {required bool replace}) async {
    final renamed = <String, String>{};
    var unstored = 0;
    for (final e in pictures.entries) {
      final imageId = newImageId();
      try {
        await Images.I.put(imageId, e.value);
        renamed[e.key] = imageId;
      } catch (_) {
        unstored++;
      }
    }

    final incoming = freshCards(cards);
    for (final c in incoming) {
      c.layers = [
        for (final l in c.layers)
          if (!l.isImage)
            l
          else if (renamed.containsKey(l.imageId))
            l..imageId = renamed[l.imageId]!,
      ];
    }
    if (incoming.isEmpty) return;

    // A deck that's still the one blank card a first visit starts with has nothing to keep, so
    // adding to it replaces it.
    if (replace || deck.isBlank) {
      deck.cards = incoming;
      selectCard(0);
    } else {
      deck.cards.addAll(incoming);
      selectCard(deck.cards.length - incoming.length);
    }
    flush();
    await Images.I.prune(deck.imageIds);

    final verb = replace ? 'Replaced your cards with' : 'Added';
    final count = '${incoming.length} card${incoming.length == 1 ? '' : 's'}';
    AppNav.say(unstored > 0 ? '$verb $count. $unstored picture${unstored == 1 ? '' : 's'} could not be stored.' : '$verb $count.');
  }

  // ---------- presenting ----------

  void enterPresent() {
    presenting = true;
    notifyListeners();
    ShareHost.I.shareNow();
    // The screen kept on, at full brightness, every bar hidden, and the volume keys working the
    // cards.
    Screen.hold('present', awake: true, bright: true, immersive: true);
    Screen.captureKeys(_onPresentKey);
    if (flickOn) Screen.watchFlick(stepCard);
  }

  void exitPresent() {
    if (!presenting) return;
    presenting = false;
    // The other screen goes back to waiting at once, not on the next beat.
    ShareHost.I.shareNow();
    Screen.release('present');
    Screen.captureKeys(null);
    Screen.watchFlick(null);
    selectCard(cardIndex);
  }

  void stepCard(int delta) {
    final next = cardIndex + delta;
    if (next < 0 || next >= deck.cards.length) return;
    cardIndex = next;
    notifyListeners();
    ShareHost.I.shareNow();
  }

  void _onPresentKey(String key) {
    switch (key) {
      case 'next':
        stepCard(1);
      case 'previous':
        stepCard(-1);
      case 'hold':
        togglePresentTicker();
    }
  }

  void togglePresentTicker() {
    if (!hasTickerText(card)) return;
    setTicker(card, !card.ticker);
    ShareHost.I.shareNow();
  }

  void setTicker(FlashCard c, bool on) {
    c.ticker = on;
    c.tickerSpeed = readTickerSpeed(c.tickerSpeed);
    changed();
  }

  /// Flick to change cards, on a phone with a gyroscope: off until switched on with its button in
  /// the presenter, as waving a sign about shouldn't change it, and remembered once on.
  bool get flickOn => Screen.canFlick && Store.I.get(flickKey) == '1';

  void togglePresentFlick() {
    final on = !flickOn;
    Store.I.put(flickKey, on ? '1' : null);
    if (presenting) Screen.watchFlick(on ? stepCard : null);
    notifyListeners();
    AppNav.say(on ? 'Flick your wrist right for the next card, left for the one before.' : 'Flick to change cards is off.');
  }
}
