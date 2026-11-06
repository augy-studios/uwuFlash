// Updates (the site's js/app-update.js and update-bar-spec.md): the app says its version, and
// /api/app-release the newest one on GitHub; a newer one shows in a bar at the top, whose Update opens
// the update window (UpdateActivity.java). That downloads the APK, checks it, and hands it to
// Android's own installer.
//
// Looked up as the app opens, and again on coming back to it after an hour, as the app can stay open
// for days. "Not now" lasts until the app's next opened.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../native/native_bridge.dart';
import '../share/share_host.dart' show siteHost;
import '../theme/theme.dart';
import '../ui/kit.dart';

/// Whether version a comes after version b, number by number: 1.10.0 after 1.9.0. The same as newer()
/// in main-site/api/_lib/release.js and UpdateActivity.java.
bool newerVersion(String a, String b) {
  List<int> parts(String v) => v.split('.').map((n) => int.tryParse(n.replaceAll(RegExp(r'\D'), '')) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  return false;
}

class UpdateBar extends StatefulWidget {
  const UpdateBar({super.key});

  @override
  State<UpdateBar> createState() => _UpdateBarState();
}

class _UpdateBarState extends State<UpdateBar> with WidgetsBindingObserver {
  static const _checkEvery = Duration(hours: 1);
  DateTime? _checkedAt;
  String? _version;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final at = _checkedAt;
    if (at == null || DateTime.now().difference(at) > _checkEvery) _check();
  }

  Future<void> _check() async {
    if (!Native.has('update')) return;
    final running = Native.version;
    if (running == null) return;
    _checkedAt = DateTime.now();
    try {
      final r = await http.get(Uri.parse('https://$siteHost/api/app-release')).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final latest = jsonDecode(r.body);
      final version = latest is Map ? latest['version'] : null;
      if (version is String && newerVersion(version, running) && mounted) setState(() => _version = version);
    } catch (_) {
      // Offline: next time.
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = _version;
    final show = version != null && !_dismissed;
    final still = MediaQuery.disableAnimationsOf(context);
    return AnimatedSize(
      duration: still ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.ease,
      alignment: Alignment.topCenter,
      child: show ? _bar(context, version) : const SizedBox(width: double.infinity),
    );
  }

  Widget _bar(BuildContext context, String version) {
    final flash = context.flash;
    final you = context.materialYou;
    final fill = you ? Theme.of(context).colorScheme.secondaryContainer : Color.lerp(Color.alphaBlend(flash.surfaceStrong, flash.page), flash.brand, 0.12)!;
    final ink = you ? Theme.of(context).colorScheme.onSecondaryContainer : flash.ink;
    final narrow = MediaQuery.sizeOf(context).width <= 480;
    final words = Semantics(
      liveRegion: true,
      child: Text('Version $version of the uwuFlash app is out.', style: TextStyle(fontSize: 14, color: ink)),
    );
    final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
      UiButton(
        label: 'Update',
        kind: ButtonKind.primary,
        onTap: () => Native.call('Flash', 'update', {'check': false, 'version': version}).catchError((_) => null),
      ),
      const SizedBox(width: 8),
      // Never stored: a reader who dismissed once would otherwise never hear about an update again.
      UiButton(label: 'Not now', kind: ButtonKind.quiet, onTap: () => setState(() => _dismissed = true)),
    ]);
    return Material(
      color: fill,
      child: Container(
        decoration: you ? null : BoxDecoration(border: Border(bottom: BorderSide(color: flash.border))),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: narrow
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [words, const SizedBox(height: 8), Align(alignment: Alignment.centerLeft, child: buttons)])
                : Row(children: [Expanded(child: words), const SizedBox(width: 12), buttons]),
          ),
        ),
      ),
    );
  }
}
