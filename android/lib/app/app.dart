// The app: its look (theme/theme.dart), redrawn as it changes, the main screen, and what it was opened
// with.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native/native_bridge.dart';
import '../screens/editor.dart';
import '../screens/present.dart';
import '../screens/share_sheet.dart';
import '../screens/sheets.dart';
import '../screens/update_bar.dart';
import '../screens/viewer_screen.dart';
import '../share/p2p.dart';
import '../share/share_host.dart';
import '../share/viewer.dart';
import '../theme/theme.dart';
import '../ui/kit.dart';
import 'edge_tray.dart';
import 'state.dart';

class FlashApp extends StatefulWidget {
  const FlashApp({super.key});

  @override
  State<FlashApp> createState() => _FlashAppState();
}

class _FlashAppState extends State<FlashApp> with WidgetsBindingObserver {
  NativeListener? _open;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLook.I.addListener(_redraw);
    // Links the app's opened with, now and later, once the first frame's up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _open = Native.on('Flash', 'open', (d) {
        final url = d['url'];
        if (url is String) openLink(url);
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLook.I.removeListener(_redraw);
    _open?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The wallpaper's colours read again each time the app comes back, and the clock's light or
      // dark checked.
      AppLook.I.readPhone();
      Viewer.I.resumed();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // A deck half written when the app goes away is worse than one written a fraction early.
      AppState.I.flush();
    }
  }

  void _redraw() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final look = AppLook.I;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 2.0,
      child: MaterialApp(
        title: 'uwuFlash',
        debugShowCheckedModeBanner: false,
        navigatorKey: AppNav.navigatorKey,
        theme: look.theme(Brightness.light),
        darkTheme: look.theme(Brightness.dark),
        themeMode: look.themeMode(),
        builder: (context, child) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          // The status bar's icons follow the app's light or dark, not the phone's.
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarContrastEnforced: false,
            ),
            child: child!,
          );
        },
        home: const Home(),
      ),
    );
  }
}

/// What the app was opened with: the site's own links, such as a scanned share code. A code in the
/// link means "be the other screen".
void openLink(String url) {
  final link = Uri.tryParse(url);
  final code = link?.queryParameters['join'];
  if (code == null || !isValidCode(code)) return;
  AppNav.closeSheets();
  final share = ShareHost.I;
  if (share.isHosting) share.stopHosting(tellGuest: true);
  if (AppState.I.presenting) AppState.I.exitPresent();
  // A scanned code is somebody asking to join.
  Viewer.I.startViewing(code, ask: true);
}

/// The main screen: the editor, the Edge Tray over it, the update bar above them, and the presenter
/// and the other screen over everything while they're up.
class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_redraw);
    ShareHost.I.addListener(_redraw);
    Viewer.I.addListener(_viewerChanged);
    _viewing = Viewer.I.isOpen;
  }

  @override
  void dispose() {
    AppState.I.removeListener(_redraw);
    ShareHost.I.removeListener(_redraw);
    Viewer.I.removeListener(_viewerChanged);
    super.dispose();
  }

  bool _presenting = false;
  bool _hosting = false;
  bool _viewing = false;

  // Only what the main screen itself shows: the editor and the sheets listen for the rest.
  void _redraw() {
    final app = AppState.I;
    final share = ShareHost.I;
    if (app.presenting == _presenting && share.isHosting == _hosting) return;
    setState(() {});
  }

  void _viewerChanged() {
    if (Viewer.I.isOpen != _viewing) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final share = ShareHost.I;
    final v = Viewer.I;
    _presenting = app.presenting;
    _hosting = share.isHosting;
    _viewing = v.isOpen;
    final covered = _presenting || _viewing;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Off the first screen the app goes to the background rather than closing, so the deck and
        // any sharing keep their place.
        if (!didPop && !covered && Native.available) {
          Native.call('Flash', 'background').catchError((_) => null);
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: Stack(fit: StackFit.expand, children: [
          // Out of reach of focus and screen readers while a card fills the screen.
          ExcludeFocus(
            excluding: covered,
            child: ExcludeSemantics(
              excluding: covered,
              child: Column(children: [
                const UpdateBar(),
                Expanded(
                  child: Builder(
                    builder: (context) => Stack(fit: StackFit.expand, children: [
                      const Editor(),
                      if (!covered)
                        Positioned(
                          top: MediaQuery.paddingOf(context).top + 14,
                          right: 0,
                          child: EdgeTray(
                            page: [
                              TrayAction('cast', share.isHosting ? 'Sharing screen' : 'Share screen', () => openShareSheet(context), live: share.isHosting),
                              TrayAction('play', 'Present fullscreen', app.enterPresent),
                            ],
                            global: [
                              // The app's own, with the global actions.
                              if (Native.has('push')) TrayAction('bell', 'Notifications', () => openNotifySheet(context)),
                              if (Native.has('checkupdate')) const TrayAction('appUpdate', 'Check for updates', checkForUpdates),
                              TrayAction('settings', 'Settings', () => openSettingsSheet(context)),
                              TrayAction(Theme.of(context).brightness == Brightness.dark ? 'moon' : 'sun', 'Theme', () => openThemeSheet(context)),
                            ],
                          ),
                        ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
          // Behind the status bar, as the page scrolls under it: the clock stays readable.
          if (!covered)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top,
              child: IgnorePointer(child: ColoredBox(color: context.flash.page)),
            ),
          if (_presenting) const Presenter(),
          if (_viewing) const ViewerScreen(),
        ]),
      ),
    );
  }
}
