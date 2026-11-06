// The app's parts, each in both looks (theme/theme.dart): panels, buttons, segmented choices,
// switches, sheets and the little notes that come and go. The site's .glass, .btn, .seg, .toggle-row
// and .modal in the UWU Apps theme; their Material 3 counterparts in Material You.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/icons.dart';
import '../theme/theme.dart';

/// For things outside any screen: notes, and closing what's open.
class AppNav {
  AppNav._();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static OverlayEntry? _toast;
  static Timer? _toastTimer;

  /// A note at the bottom of the screen, as the site's toast: above everything, sheets and the
  /// presenter included, and never in the way of a tap.
  static void say(String text) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _toast?.remove();
    _toastTimer?.cancel();
    final entry = OverlayEntry(builder: (_) => _Toast(text: text));
    _toast = entry;
    overlay.insert(entry);
    _toastTimer = Timer(const Duration(milliseconds: 3200), () {
      entry.remove();
      if (_toast == entry) _toast = null;
    });
  }

  /// Back to the main screen, closing any sheets.
  static void closeSheets() => navigatorKey.currentState?.popUntil((r) => r.isFirst);
}

class _Toast extends StatelessWidget {
  const _Toast({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    return Positioned(
      left: 16,
      right: 16,
      bottom: math.max(16, media.viewPadding.bottom + 16) + media.viewInsets.bottom,
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: media.disableAnimations ? Duration.zero : const Duration(milliseconds: 200),
            curve: Curves.ease,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset(0, (1 - t) * 12), child: child),
            ),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Material(
                color: you ? scheme.inverseSurface : flash.brandFillStrong,
                shape: StadiumBorder(side: you ? BorderSide.none : BorderSide(color: flash.border)),
                elevation: 4,
                shadowColor: Colors.black38,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.6, color: you ? scheme.onInverseSurface : flash.onBrand)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UiPanel extends StatelessWidget {
  const UiPanel({super.key, this.title, this.trailing, required this.children});
  final String? title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: you ? Theme.of(context).colorScheme.surfaceContainerLow : flash.surface,
        borderRadius: BorderRadius.circular(you ? 24 : 20),
        border: you ? null : Border.all(color: flash.border),
        boxShadow: you ? null : const [BoxShadow(color: Color(0x1A14281E), blurRadius: 30, offset: Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Expanded(child: PanelTitle(title!)),
                ?trailing,
              ]),
            ),
          ...spaced(children, 10),
        ],
      ),
    );
  }
}

class PanelTitle extends StatelessWidget {
  const PanelTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        header: true,
        child: Text(
          text,
          style: context.materialYou
              ? Theme.of(context).textTheme.titleMedium!.copyWith(color: context.flash.brandInk, fontWeight: FontWeight.w500)
              : TextStyle(fontSize: 15.2, color: context.flash.brandInk),
        ),
      );
}

List<Widget> spaced(List<Widget> children, double gap) => [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ];

/// A small note, in the site's .mode-note.
class UiNote extends StatelessWidget {
  const UiNote(this.text, {super.key, this.strong = false, this.center = false, this.live = false});
  final String text;
  final bool strong;
  final bool center;
  final bool live;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        liveRegion: live,
        child: Text(
          text,
          textAlign: center ? TextAlign.center : TextAlign.start,
          style: TextStyle(fontSize: 13.6, height: 1.3, color: strong ? context.flash.mutedStrong : context.flash.muted),
        ),
      );
}

enum ButtonKind { plain, primary, quiet }

class UiButton extends StatelessWidget {
  const UiButton({
    super.key,
    this.label,
    this.icon,
    required this.onTap,
    this.kind = ButtonKind.plain,
    this.danger = false,
    this.tooltip,
    this.pressed,
  });
  final String? label;
  final String? icon;
  final VoidCallback? onTap;
  final ButtonKind kind;
  final bool danger;
  final String? tooltip; // what it says, for a button that's only an icon
  final bool? pressed;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    final Color fill;
    Color ink;
    switch (kind) {
      case ButtonKind.primary:
        fill = you ? scheme.primary : flash.brandFill;
        ink = you ? scheme.onPrimary : flash.onBrand;
      case ButtonKind.quiet:
        fill = Colors.transparent;
        ink = flash.mutedStrong;
      case ButtonKind.plain:
        fill = you ? scheme.secondaryContainer : flash.surfaceStrong;
        ink = you ? scheme.onSecondaryContainer : flash.ink;
    }
    if (danger) ink = flash.error;

    final radius = BorderRadius.circular(you ? 100 : 12);
    Widget body = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) AppIcon(icon!, size: 17, color: ink),
        if (icon != null && label != null) const SizedBox(width: 6),
        if (label != null) Flexible(child: Text(label!, textAlign: TextAlign.center, style: TextStyle(color: ink, fontSize: 14))),
      ],
    );
    body = Material(
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: you ? BorderSide.none : BorderSide(color: danger ? flash.error : flash.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: 40, minWidth: label == null ? 44 : 0),
          padding: EdgeInsets.symmetric(horizontal: label == null ? 10 : 14, vertical: 9),
          child: body,
        ),
      ),
    );
    if (!enabled) body = Opacity(opacity: 0.6, child: body);
    final semantic = Semantics(
      button: true,
      enabled: enabled,
      toggled: pressed,
      label: label ?? tooltip,
      excludeSemantics: true,
      onTap: onTap,
      child: body,
    );
    return tooltip == null ? semantic : Tooltip(excludeFromSemantics: true, message: tooltip, child: semantic);
  }
}

class SegOption<T> {
  const SegOption(this.value, this.label, {this.icon});
  final T value;
  final String label;
  final String? icon;
}

/// A row of choices, one on at a time (the site's .seg).
class UiSeg<T> extends StatelessWidget {
  const UiSeg({super.key, required this.options, required this.value, required this.onChanged, this.semantic});
  final List<SegOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String? semantic;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    return Semantics(
      container: true,
      label: semantic,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: you ? Theme.of(context).colorScheme.surfaceContainerHigh : flash.surface,
          borderRadius: BorderRadius.circular(you ? 24 : 14),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(child: _segButton(context, options[i])),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _segButton(BuildContext context, SegOption<T> o) {
    final flash = context.flash;
    final on = o.value == value;
    final radius = BorderRadius.circular(context.materialYou ? 20 : 10);
    return Semantics(
      button: true,
      selected: on,
      label: o.label,
      excludeSemantics: true,
      onTap: () => onChanged(o.value),
      child: Material(
        color: on ? flash.brandFill : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => onChanged(o.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (o.icon != null) ...[AppIcon(o.icon!, size: 16, color: on ? flash.onBrand : flash.mutedStrong), const SizedBox(width: 4)],
                Flexible(
                  child: Text(o.label, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.8, color: on ? flash.onBrand : flash.mutedStrong)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A switch with its words (the site's .toggle-row).
class UiSwitchRow extends StatelessWidget {
  const UiSwitchRow({super.key, required this.title, this.hint, required this.value, required this.onChanged});
  final String title;
  final String? hint;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      label: title,
      excludeSemantics: true,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Material(
        color: you ? Theme.of(context).colorScheme.surfaceContainerHigh : flash.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(you ? 20 : 14),
          side: you ? BorderSide.none : BorderSide(color: flash.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontSize: 15.2, color: flash.ink)),
                  if (hint != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(hint!, style: TextStyle(fontSize: 12.5, height: 1.35, color: flash.mutedStrong))),
                ]),
              ),
              const SizedBox(width: 12),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Opens a sheet with a title and a close button. From the bottom in Material You, with Android's
/// drag handle; a glass card in the UwU Apps theme, as the site's modal.
Future<T?> showUiSheet<T>(BuildContext context, {required String title, required WidgetBuilder builder}) {
  final you = context.materialYou;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: you,
    backgroundColor: you ? null : Colors.transparent,
    elevation: you ? null : 0,
    constraints: const BoxConstraints(maxWidth: 640),
    barrierColor: const Color(0x590A0F0C),
    builder: (context) => _SheetBody(title: title, builder: builder),
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.title, required this.builder});
  final String title;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final flash = context.flash;
    final you = context.materialYou;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final list = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(18, you ? 0 : 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Semantics(
                container: true,
                header: true,
                child: Text(
                  title,
                  style: you
                      ? Theme.of(context).textTheme.titleLarge
                      : TextStyle(fontSize: 17.6, color: flash.brandInk),
                ),
              ),
            ),
            UiButton(icon: 'close', tooltip: 'Close', kind: you ? ButtonKind.quiet : ButtonKind.plain, onTap: () => Navigator.of(context).pop()),
          ]),
          const SizedBox(height: 10),
          builder(context),
        ],
      ),
    );
    if (you) return Padding(padding: EdgeInsets.only(bottom: insets), child: list);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + insets),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Material(
                color: Color.alphaBlend(flash.surfaceStrong, flash.page.withValues(alpha: 0.86)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: flash.border)),
                clipBehavior: Clip.antiAlias,
                child: list,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section's label in a sheet (the site's .modal-section-label).
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text, style: TextStyle(fontSize: 13.6, color: context.flash.muted)),
      );
}
