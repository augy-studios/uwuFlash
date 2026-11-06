// Starting the app, shared by main.dart and the Playwright suite's own entry point (e2e/main_e2e.dart).
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/edge_tray.dart';
import 'app/state.dart';
import 'data/migrate.dart';
import 'data/store.dart';
import 'native/native_bridge.dart';
import 'share/share_host.dart';
import 'share/viewer.dart';
import 'theme/theme.dart';
import 'ui/kit.dart';

Future<void> runFlashApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.open();
  await Native.start();
  // Everything the WebView app kept, the first time (data/migrate.dart).
  final migrated = await Migrate.run(store);
  await AppLook.I.readPhone();
  AppLook.I.start();
  TrayMetrics.load();
  AppState.I.load();
  runApp(const FlashApp());
  // The viewer first: a link that opens the app means "be the other screen", and that has to be
  // settled before sharing resumes a host session from last time.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Viewer.I.resume();
    if (!Viewer.I.isOpen) ShareHost.I.resume();
    if (migrated) AppNav.say('Your cards are here from before.');
  });
}
