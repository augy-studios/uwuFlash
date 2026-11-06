// The app's other sheets: Theme (the site's #themeModal), Settings, where Material You is switched
// off for the usual UwU Apps theme, and Notifications (the site's js/app-notify.js).
import 'package:flutter/material.dart';

import '../native/native_bridge.dart';
import '../theme/theme.dart';
import '../ui/kit.dart';

/// The one switch between the two looks, in both sheets.
class MaterialYouSwitch extends StatelessWidget {
  const MaterialYouSwitch({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: AppLook.I,
        builder: (context, _) => UiSwitchRow(
          title: 'Material You',
          hint: "Your phone's font and colours. Off, the app wears the usual UwU Apps theme.",
          value: AppLook.I.materialYou,
          onChanged: (on) => AppLook.I.materialYou = on,
        ),
      );
}

Future<void> openThemeSheet(BuildContext context) => showUiSheet<void>(context, title: 'Theme', builder: (_) => const _ThemeSheet());

class _ThemeSheet extends StatelessWidget {
  const _ThemeSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLook.I,
      builder: (context, _) {
        final look = AppLook.I;
        final you = look.materialYou;
        final pref = look.modePreference;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const MaterialYouSwitch(),
          const SectionLabel('Mode'),
          UiSeg<String>(
            options: const [
              SegOption('phone', 'Phone', icon: 'phone'),
              SegOption('light', 'Light', icon: 'sun'),
              SegOption('dark', 'Dark', icon: 'moon'),
              SegOption('time', 'Time-based', icon: 'clock'),
            ],
            value: pref,
            onChanged: (v) => look.modePreference = v,
          ),
          if (pref == 'time') ...[
            const SizedBox(height: 8),
            UiNote('Following the clock. Currently ${look.resolvedNow == Brightness.dark ? 'dark' : 'light'}.', live: true),
          ],
          const SectionLabel('Brand colour'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            // Material You's colours are the wallpaper's until a brand colour's picked.
            if (you && look.hasPhoneColours)
              _Swatch(
                label: "Your phone's",
                color: look.phoneLight!.primary,
                on: !look.youUseBrand,
                onTap: () => look.youUseBrand = false,
              ),
            for (final s in AppLook.swatches)
              _Swatch(
                label: s.label,
                color: s.color,
                on: look.swatchId == s.id && (!you || look.youUseBrand || !look.hasPhoneColours),
                onTap: () {
                  look.swatchId = s.id;
                  if (you) look.youUseBrand = true;
                },
              ),
          ]),
        ]);
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.label, required this.color, required this.on, required this.onTap});
  final String label;
  final Color color;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, _) {
      final media = MediaQuery.sizeOf(context).width;
      // One column on a phone's width, two where there's room, as the site's grid.
      final width = media <= 480 ? double.infinity : 178.0;
      return Semantics(
        button: true,
        selected: on,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Container(
            decoration: on
                // Ringed in its own colour, plus a containment ring: the pale swatches reach only 1:1
                // against the surface on their own, so the outer ring carries the active state.
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(you ? 20 : 14),
                    boxShadow: [
                      BoxShadow(color: flash.ink.withValues(alpha: 0.5), spreadRadius: 3),
                      BoxShadow(color: color, spreadRadius: 2),
                    ],
                  )
                : null,
            child: Material(
              color: you ? scheme.surfaceContainerHigh : Color.alphaBlend(flash.surface, flash.page),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(you ? 20 : 14), side: you ? BorderSide.none : BorderSide(color: flash.border)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: flash.ink.withValues(alpha: 0.3))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, color: flash.ink))),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

Future<void> openSettingsSheet(BuildContext context) => showUiSheet<void>(context, title: 'Settings', builder: (_) => const _SettingsSheet());

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLook.I,
      builder: (context, _) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
          const MaterialYouSwitch(),
          Wrap(spacing: 8, runSpacing: 8, children: [
            UiButton(
              label: 'Theme',
              icon: 'palette',
              onTap: () {
                final nav = Navigator.of(context);
                nav.pop();
                openThemeSheet(nav.context);
              },
            ),
            if (Native.has('push'))
              UiButton(
                label: 'Notifications',
                icon: 'bell',
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  openNotifySheet(nav.context);
                },
              ),
            if (Native.has('checkupdate')) UiButton(label: 'Check for updates', icon: 'appUpdate', onTap: checkForUpdates),
          ]),
          if (Native.version != null) UiNote('uwuFlash ${Native.version}'),
        ], 10));
      },
    );
  }
}

/// The update window, which says if you have the newest app and asks before downloading one.
void checkForUpdates() {
  Native.call('Flash', 'update', {'check': true}).catchError((_) => null);
}

Future<void> openNotifySheet(BuildContext context) => showUiSheet<void>(context, title: 'Notifications', builder: (_) => const _NotifySheet());

/// Two switches, each an FCM topic the app joins (FlashPlugin.setTopic), so the server keeps no list
/// of phones. Turning one on asks Android's notification permission first (Android 13 and later).
/// Nothing is asked until a switch is turned on.
class _NotifySheet extends StatefulWidget {
  const _NotifySheet();

  @override
  State<_NotifySheet> createState() => _NotifySheetState();
}

class _NotifySheetState extends State<_NotifySheet> with WidgetsBindingObserver {
  static const _denied = "Notifications are off for uwuFlash in Android's settings. Turn them on there, then come back.";
  static const _offline = "Couldn't reach Firebase. Check you're online, then try again.";
  static const _switches = [
    (topic: 'releases', label: 'New versions of the app', hint: 'When an update is ready to install'),
    (topic: 'news', label: 'News from uwuFlash', hint: 'Now and then: new features, and other news'),
  ];

  Map<String, dynamic> _topics = const {};
  final Set<String> _busy = {};
  String? _note;
  bool _settings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android's settings with the sheet still open.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final topics = await Native.call('Flash', 'topics') ?? const {};
      final permission = await Native.call('Flash', 'checkPermissions') ?? const {};
      if (!mounted) return;
      setState(() {
        _topics = topics;
        // Turned on here, then switched off in Android's settings: say why nothing arrives.
        final anyOn = _switches.any((s) => topics[s.topic] == true);
        _note = anyOn && permission['notifications'] != 'granted' ? _denied : null;
        _settings = _note != null;
      });
    } catch (_) {
      // The switches stay as drawn.
    }
  }

  Future<bool> _allowed() async {
    final now = await Native.call('Flash', 'checkPermissions');
    if (now?['notifications'] == 'granted') return true;
    // Once refused for good, Android won't prompt again: its settings are the only way.
    if (now?['notifications'] == 'denied') return false;
    final after = await Native.call('Flash', 'requestPermissions', {
      'permissions': ['notifications'],
    });
    return after?['notifications'] == 'granted';
  }

  Future<void> _toggle(String topic, bool on) async {
    setState(() {
      _busy.add(topic);
      _note = null;
      _settings = false;
    });
    try {
      if (on && !await _allowed()) {
        if (mounted) {
          setState(() {
            _note = _denied;
            _settings = true;
          });
        }
        return;
      }
      await Native.call('Flash', 'setTopic', {'topic': topic, 'on': on});
      if (mounted) setState(() => _topics = {..._topics, topic: on});
    } on NativeError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } catch (_) {
      if (mounted) setState(() => _note = _offline);
    } finally {
      if (mounted) setState(() => _busy.remove(topic));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([
      for (final s in _switches)
        UiSwitchRow(
          title: s.label,
          hint: s.hint,
          value: _topics[s.topic] == true,
          onChanged: _busy.contains(s.topic) ? null : (on) => _toggle(s.topic, on),
        ),
      if (_note != null) UiNote(_note!, live: true),
      if (_settings)
        UiButton(
          label: "Open Android's settings",
          onTap: () => Native.call('Flash', 'openSettings', {'what': 'notifications'}).catchError((_) => null),
        ),
    ], 10));
  }
}
