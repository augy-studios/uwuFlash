// The share sheet (the site's #shareModal, js/share.js): picking how the other device shares, the
// code and QR code to join with, who's joined, a Big Screen's grid and bezels, and being the other
// device yourself.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/store.dart';
import '../share/p2p.dart';
import '../share/share_host.dart';
import '../share/viewer.dart';
import '../theme/icons.dart';
import '../theme/theme.dart';
import '../ui/kit.dart';

Future<void> openShareSheet(BuildContext context) => showUiSheet<void>(
      context,
      title: 'Share screen',
      builder: (_) => const _ShareSheet(),
    );

class _ShareSheet extends StatefulWidget {
  const _ShareSheet();

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _join = TextEditingController();
  String? _joinNote;

  @override
  void initState() {
    super.initState();
    final last = Store.I.get('uwuflash.lastCode');
    if (last != null) _join.text = last;
  }

  @override
  void dispose() {
    _join.dispose();
    super.dispose();
  }

  void _submitJoin() {
    final share = ShareHost.I;
    final code = normaliseCode(_join.text);
    if (!isValidCode(code)) {
      setState(() => _joinNote = "A code is $codeLength characters, from the other device's share sheet.");
      return;
    }
    // A device is one or the other. Joining somebody else's screen ends this one's sharing, and says
    // so to its own guest.
    if (share.isHosting) share.stopHosting(tellGuest: true);
    Navigator.of(context).pop();
    Viewer.I.startViewing(code, ask: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ShareHost.I,
      builder: (context, _) {
        final share = ShareHost.I;
        final mode = share.mode;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const UiNote('Show your cards on another device on the same wifi, or send it a copy of them.', strong: true),
          const SectionLabel('What the other device does'),
          UiSeg<String>(
            options: const [
              SegOption('mirror', 'Mirror'),
              SegOption('extend', 'Extend'),
              SegOption('bigscreen', 'Big Screen'),
              SegOption('send', 'Send cards'),
            ],
            value: mode,
            onChanged: share.setMode,
          ),
          const SizedBox(height: 8),
          UiNote(shareModeNotes[mode]!),
          const SizedBox(height: 10),
          if (!share.isHosting) ...[
            UiButton(label: 'Start sharing', icon: 'cast', kind: ButtonKind.primary, onTap: () => share.startHosting(ask: true)),
            if (share.hostStatus == 'error') ...[const SizedBox(height: 8), UiNote(share.statusText, live: true)],
          ] else
            const _Live(),
          const SectionLabel('Be the other device'),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _join,
                maxLength: 12,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _submitJoin(),
                style: TextStyle(fontSize: 16, letterSpacing: 1.3, color: context.flash.ink),
                decoration: const InputDecoration(hintText: 'Code', counterText: '', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            UiButton(label: 'Join', onTap: _submitJoin),
          ]),
          if (_joinNote != null) ...[const SizedBox(height: 8), UiNote(_joinNote!, live: true)],
        ]);
      },
    );
  }
}

class _Live extends StatelessWidget {
  const _Live();

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ShareHost.I, builder: (context, _) => _draw(context));

  Widget _draw(BuildContext context) {
    final share = ShareHost.I;
    final flash = context.flash;
    final code = share.shownCode;
    final url = joinUrl(code);
    final mode = share.mode;
    final joined = share.joined;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Centred, with its quiet zone, so a phone pointed at the middle of the screen finds it without
      // hunting. Dark on white in both modes and every colour: a scanner needs the contrast, and some
      // won't read a code whose light and dark are the other way round.
      Center(
        child: Semantics(
          image: true,
          label: 'QR code for the join link',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: QrImageView(
              data: url,
              size: math.min(220.0, MediaQuery.sizeOf(context).width * 0.7),
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: Colors.white,
              // Four modules of margin is what the QR standard asks for.
              padding: const EdgeInsets.all(16),
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
              dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      SelectableText(
        code.length >= 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 35, letterSpacing: 4.2, color: flash.ink),
      ),
      const SizedBox(height: 8),
      const UiNote('Scan the code with the other device, or open $siteHost on it, tap Share screen and type the code.', strong: true, center: true),
      const SizedBox(height: 8),
      SelectableText(url, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.8, color: flash.muted)),
      const SizedBox(height: 8),
      Semantics(
        liveRegion: true,
        child: Text(share.statusText, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.6, color: flash.ink)),
      ),
      if (joined.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (var i = 0; i < joined.length; i++) _GuestRow(id: joined[i], name: joined.length == 1 ? 'Other screen' : 'Screen ${i + 1}'),
      ],
      if (mode == 'bigscreen') const _Wall(),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        UiButton(label: 'New code', icon: 'refresh', onTap: () => share.restartWithFreshCode(tellGuest: true)),
        UiButton(label: 'Stop sharing', icon: 'close', kind: ButtonKind.quiet, onTap: share.stopFromSheet),
      ]),
    ]);
  }
}

class _GuestRow extends StatelessWidget {
  const _GuestRow({required this.id, required this.name});
  final String id;
  final String name;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(color: flash.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: flash.brandInk, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Text('$name, connected', style: TextStyle(fontSize: 14, color: flash.ink))),
        UiButton(label: 'Remove', icon: 'close', kind: ButtonKind.quiet, onTap: () => ShareHost.I.removeGuest(id)),
      ]),
    );
  }
}

/// The screens of a Big Screen as they sit, numbered by place, drawn where they are on the wall with
/// the bezels between them to scale. Each seam between two columns or rows is a handle; dragging it
/// sets the bezels there while the screens show lines to line up.
class _Wall extends StatelessWidget {
  const _Wall();

  static String _mm(double n) => '${n == n.truncateToDouble() ? n.toInt() : n.toStringAsFixed(1)} mm';

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ShareHost.I, builder: (context, _) => _draw(context));

  Widget _draw(BuildContext context) {
    final share = ShareHost.I;
    final flash = context.flash;
    final geo = share.geometry;
    final l = share.wallLayout;
    final empty = share.order.isEmpty;
    final all = [...geo.seamsX, ...geo.seamsY].map((s) => s.gap).toList();
    final low = all.isEmpty ? share.gap : all.reduce(math.min);
    final high = all.isEmpty ? share.gap : all.reduce(math.max);
    final bezels = high == 0 ? 'No bezels' : (low == high ? 'Bezels ${_mm(low)}' : 'Bezels ${_mm(low)} to ${_mm(high)}');

    Widget stepRow(String lessLabel, VoidCallback? less, String middle, String moreLabel, VoidCallback? more) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            UiButton(icon: 'left', tooltip: lessLabel, onTap: less),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 110),
              child: Semantics(liveRegion: true, child: Text(middle, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: flash.ink))),
            ),
            const SizedBox(width: 10),
            UiButton(icon: 'right', tooltip: moreLabel, onTap: more),
          ],
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Screens'),
      if (empty)
        const UiNote('No screens yet. Join from each one with the code above.', strong: true, center: true)
      else
        Center(child: _WallMap(geo: geo)),
      if (share.order.length >= 2) ...[
        const SizedBox(height: 8),
        UiNote(
          share.picked == null
              ? 'Tap two screens to swap them. Drag a line between two screens until the lines on them meet straight.'
              : 'Now tap the screen to swap with ${share.picked! + 1}.',
          strong: true,
          center: true,
        ),
      ],
      const SizedBox(height: 8),
      stepRow('Fewer screens across', l.cols <= 1 ? null : share.fewerCols, '${l.cols} across', 'More screens across', l.cols >= l.count ? null : share.moreCols),
      const SizedBox(height: 8),
      stepRow('Thinner bezels', high <= 0 ? null : () => share.nudgeAll(-gapStep), bezels, 'Thicker bezels', low >= gapMax ? null : () => share.nudgeAll(gapStep)),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        UiButton(
          label: share.identify ? 'Hide numbers' : 'Show numbers',
          icon: 'grid',
          kind: share.identify ? ButtonKind.primary : ButtonKind.plain,
          pressed: share.identify,
          onTap: share.toggleIdentify,
        ),
        UiButton(
          label: share.lines ? 'Hide lines' : 'Show lines',
          icon: 'lines',
          kind: share.lines ? ButtonKind.primary : ButtonKind.plain,
          pressed: share.lines,
          onTap: share.toggleLines,
        ),
      ]),
    ]);
  }
}

class _WallMap extends StatefulWidget {
  const _WallMap({required this.geo});
  final WallGeometry geo;

  @override
  State<_WallMap> createState() => _WallMapState();
}

class _WallMapState extends State<_WallMap> {
  // The seam under the finger: measured from where the drag began, so the map growing under the finger
  // doesn't run away.
  double _startMm = 0;
  double _startAt = 0;
  String? _hot; // which seam's value to show

  @override
  Widget build(BuildContext context) {
    final share = ShareHost.I;
    final geo = widget.geo;
    final flash = context.flash;
    final aspect = geo.width / geo.height;
    // Narrower as the wall gets taller, so a column of screens fits the sheet.
    return LayoutBuilder(builder: (context, box) {
      final mapW = math.min(box.maxWidth, (220 * aspect).clamp(120.0, 340.0));
      final mapH = mapW / aspect;
      final scale = mapW / geo.width;
      final time = share.dragging ? Duration.zero : const Duration(milliseconds: 420);
      const curve = Cubic(0.65, 0, 0.35, 1);

      Widget handle(String axis, int i, WallSeam seam) {
        final across = axis == 'x';
        final middle = (seam.at + seam.gap / 2) * scale;
        final key = '$axis$i';
        final label = across ? 'Bezels between columns ${i + 1} and ${i + 2}' : 'Bezels between rows ${i + 1} and ${i + 2}';
        return Positioned(
          left: across ? middle - 12 : -6,
          top: across ? -6 : middle - 12,
          width: across ? 24 : mapW + 12,
          height: across ? mapH + 12 : 24,
          child: Semantics(
            slider: true,
            label: label,
            value: _WallText.mm(seam.gap),
            onIncrease: () => _nudge(axis, i, 0.5),
            onDecrease: () => _nudge(axis, i, -0.5),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) {
                setState(() => _hot = key);
                _startMm = seam.gap;
                _startAt = across ? d.globalPosition.dx : d.globalPosition.dy;
                share.startSeamDrag();
              },
              onPanUpdate: (d) {
                final moved = (across ? d.globalPosition.dx : d.globalPosition.dy) - _startAt;
                share.dragSeam(axis, i, _startMm + moved * seamPerPx);
              },
              onPanEnd: (_) {
                setState(() => _hot = null);
                share.endSeamDrag();
              },
              onPanCancel: () {
                setState(() => _hot = null);
                share.endSeamDrag();
              },
              child: Stack(alignment: Alignment.center, children: [
                Container(
                  width: across ? 3 : double.infinity,
                  height: across ? double.infinity : 3,
                  decoration: BoxDecoration(color: flash.brandInk.withValues(alpha: _hot == key ? 1 : 0.55), borderRadius: BorderRadius.circular(2)),
                ),
                if (_hot == key)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: flash.brandFill, borderRadius: BorderRadius.circular(999)),
                    child: Text(_WallText.mm(seam.gap), style: TextStyle(fontSize: 11.2, color: flash.onBrand)),
                  ),
              ]),
            ),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: mapW,
          height: mapH,
          child: Stack(clipBehavior: Clip.none, children: [
            for (var i = 0; i < share.order.length; i++)
              // Keyed by the screen, so two trading places are seen to travel.
              AnimatedPositioned(
                key: ValueKey(share.order[i]),
                duration: time,
                curve: curve,
                left: geo.cells[i].left * scale,
                top: geo.cells[i].top * scale,
                width: geo.cells[i].w * scale,
                height: geo.cells[i].h * scale,
                child: _Tile(place: i),
              ),
            for (var i = 0; i < geo.seamsX.length; i++) handle('x', i, geo.seamsX[i]),
            for (var i = 0; i < geo.seamsY.length; i++) handle('y', i, geo.seamsY[i]),
          ]),
        ),
      );
    });
  }

  void _nudge(String axis, int i, double by) {
    final share = ShareHost.I;
    share.startSeamDrag();
    share.dragSeam(axis, i, share.seamValue(axis, i) + by);
    share.endSeamDrag();
  }
}

class _WallText {
  static String mm(double n) => '${n == n.truncateToDouble() ? n.toInt() : n.toStringAsFixed(1)} mm';
}

class _Tile extends StatelessWidget {
  const _Tile({required this.place});
  final int place;

  @override
  Widget build(BuildContext context) {
    final share = ShareHost.I;
    final flash = context.flash;
    final screen = share.order[place];
    final online = share.screenOnline(screen);
    final picked = share.picked == place;
    final ink = picked ? flash.onBrand : (online ? flash.ink : flash.mutedStrong);
    final label = 'Screen ${place + 1}${online ? '' : ', reconnecting'}';
    return Stack(fit: StackFit.expand, children: [
      Semantics(
        button: true,
        selected: picked,
        label: label,
        excludeSemantics: true,
        onTap: () => share.tapPlace(place),
        child: Material(
          color: picked ? flash.brandFill : (online ? flash.surfaceStrong : Colors.transparent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: flash.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => share.tapPlace(place),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${place + 1}', style: TextStyle(height: 1, fontSize: share.identify ? 30 : 18, color: ink)),
                  if (!online) Text('Reconnecting', style: TextStyle(fontSize: 10.4, color: ink)),
                ]),
              ),
            ),
          ),
        ),
      ),
      Positioned(
        top: 2,
        right: 2,
        child: Tooltip(
          excludeFromSemantics: true,
          message: 'Remove screen ${place + 1}',
          child: Semantics(
            button: true,
            label: 'Remove screen ${place + 1}',
            excludeSemantics: true,
            onTap: () => share.removeScreen(place),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => share.removeScreen(place),
              child: Opacity(opacity: 0.6, child: SizedBox(width: 24, height: 24, child: Center(child: AppIcon('close', size: 14, color: ink)))),
            ),
          ),
        ),
      ),
    ]);
  }
}
