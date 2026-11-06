// The app as the Playwright suite runs it (README.md here): the real screens in a browser, with a
// stand-in for the Java side, so what only the phone can do is at least reached the right way. Every
// call to the Java side lands in window.e2eCalls, and window.e2eEmit(plugin, event, json) says what
// the Java side would have said, such as a volume key. Screen reader support is switched on, which
// is what the suite finds things by.
//
// Query parameters: ?wallpaper=1 pretends the phone has wallpaper colours (a purple one).
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:uwuflash/native/native_bridge.dart';
import 'package:uwuflash/run.dart';
import 'package:uwuflash/theme/theme.dart';

class _FakeJava implements NativeFake {
  _FakeJava() {
    globalContext.setProperty('e2eCalls'.toJS, <JSAny>[].toJS);
    globalContext.setProperty(
      'e2eEmit'.toJS,
      ((JSString plugin, JSString event, JSString json) {
        Native.emit(plugin.toDart, event.toDart, Map<String, dynamic>.from(jsonDecode(json.toDart) as Map));
      }).toJS,
    );
  }

  final Map<String, bool> _topics = {'releases': false, 'news': false};

  @override
  Future<Map<String, dynamic>?> call(String plugin, String method, Map<String, dynamic> options) async {
    (globalContext.getProperty('e2eCalls'.toJS) as JSObject).callMethod('push'.toJS, jsonEncode({'plugin': plugin, 'method': method, 'options': options}).toJS);
    switch ('$plugin.$method') {
      case 'Flash.info':
        return {
          'version': '1.1.0',
          'versionCode': 2,
          'android': 36,
          'features': ['screen', 'keys', 'settings', 'update', 'checkupdate', 'flick', 'listen', 'push'],
        };
      case 'Flash.fonts':
        return {'body': 'sans-serif', 'headline': 'sans-serif'};
      case 'Flash.topics':
        return _topics;
      case 'Flash.setTopic':
        _topics[options['topic'] as String] = options['on'] as bool;
        return {'topic': options['topic'], 'on': options['on']};
      case 'Flash.checkPermissions':
      case 'Flash.requestPermissions':
        return {'notifications': 'granted'};
      case 'Flash.listen':
        return {'text': 'Spoken words'};
      case 'Migrate.read':
        return {'found': false, 'items': <String, String>{}, 'images': 0};
      default:
        return {};
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  Native.fake = _FakeJava();
  if (Uri.base.queryParameters['wallpaper'] == '1') {
    AppLook.I.phoneLight = ColorScheme.fromSeed(seedColor: const Color(0xFF7B3FF2));
    AppLook.I.phoneDark = ColorScheme.fromSeed(seedColor: const Color(0xFF7B3FF2), brightness: Brightness.dark);
  }
  await runFlashApp();
}
