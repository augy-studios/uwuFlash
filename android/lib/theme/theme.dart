// How the app looks. Two looks, picked in Settings or Theme:
//
//   Material You (the default)  Material 3, as Android's own apps are: the phone's own fonts
//            (Google Sans on a Pixel, the maker's or the person's chosen font elsewhere), solid
//            tonal cards, pill buttons, sheets from the bottom, and the colours of the phone's
//            wallpaper on Android 12 and later (the app's green tonal palette before that), or one
//            of the brand colours once one's picked. Only in the Android app: the website keeps
//            the UwU Apps theme.
//   The UwU Apps theme  the site's (uwuapps-theme.md, css/theme.css): Jua, see-through glass cards
//            on a soft background, in one of the seven brand colours (uwuflash.colorTheme).
//
// Either way light, dark or by the clock (uwuflash.mode: light 09:00 to 18:00), or the phone's own
// light or dark. Every screen takes its colours from FlashColors, the site's tokens, so a screen
// reads the same in both looks.
// CorePalette and Scheme: what DynamicColorPlugin hands back, and how Android's own palettes map to
// roles; their replacements take no CorePalette.
// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart' show DynamicColorPlugin;
import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show CorePalette, Scheme;

import '../data/store.dart';
import '../native/native_bridge.dart';

/// The site's colour tokens, as both looks have them.
@immutable
class FlashColors extends ThemeExtension<FlashColors> {
  const FlashColors({
    required this.page,
    required this.bg,
    required this.surface,
    required this.surfaceStrong,
    required this.border,
    required this.ink,
    required this.muted,
    required this.mutedStrong,
    required this.brand,
    required this.onBrand,
    required this.brandInk,
    required this.brandFill,
    required this.brandFillStrong,
    required this.error,
    required this.cardBg,
    required this.cardInk,
    required this.glass,
  });

  final Color page; // behind everything
  final Color bg;
  final Color surface;
  final Color surfaceStrong;
  final Color border;
  final Color ink;
  final Color muted;
  final Color mutedStrong; // secondary text on a strong surface
  final Color brand;
  final Color onBrand; // text on brand, brandFill and brandFillStrong
  final Color brandInk; // headings and accents
  final Color brandFill; // what's selected
  final Color brandFillStrong;
  final Color error;

  /// The signboard, the one surface that doesn't follow the page: in light mode the background is
  /// the chosen colour and the text near black; in dark mode the other way round.
  final Color cardBg;
  final Color cardInk;

  final bool glass; // the UwU Apps theme's see-through surfaces

  @override
  FlashColors copyWith({Color? cardBg, Color? cardInk}) => FlashColors(
        page: page, bg: bg, surface: surface, surfaceStrong: surfaceStrong, border: border, ink: ink, muted: muted,
        mutedStrong: mutedStrong, brand: brand, onBrand: onBrand, brandInk: brandInk, brandFill: brandFill,
        brandFillStrong: brandFillStrong, error: error, cardBg: cardBg ?? this.cardBg, cardInk: cardInk ?? this.cardInk, glass: glass,
      );

  @override
  FlashColors lerp(covariant FlashColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return FlashColors(
      page: l(page, other.page), bg: l(bg, other.bg), surface: l(surface, other.surface),
      surfaceStrong: l(surfaceStrong, other.surfaceStrong), border: l(border, other.border), ink: l(ink, other.ink),
      muted: l(muted, other.muted), mutedStrong: l(mutedStrong, other.mutedStrong), brand: l(brand, other.brand),
      onBrand: l(onBrand, other.onBrand), brandInk: l(brandInk, other.brandInk), brandFill: l(brandFill, other.brandFill),
      brandFillStrong: l(brandFillStrong, other.brandFillStrong), error: l(error, other.error),
      cardBg: l(cardBg, other.cardBg), cardInk: l(cardInk, other.cardInk), glass: t < 0.5 ? glass : other.glass,
    );
  }
}

extension FlashTheme on BuildContext {
  FlashColors get flash => Theme.of(this).extension<FlashColors>()!;
  bool get materialYou => AppLook.I.materialYou;
}

class BrandSwatch {
  const BrandSwatch(this.id, this.hex, this.label);
  final String id;
  final int hex;
  final String label;
  Color get color => Color(hex);
}

Color? hexColor(Object? s) {
  if (s is! String) return null;
  final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(s.trim());
  return m == null ? null : Color(0xFF000000 | int.parse(m[1]!, radix: 16));
}

String colorHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class AppLook extends ChangeNotifier {
  AppLook._();
  static final AppLook I = AppLook._();

  static const lookKey = 'app.look'; // "usual", or unset for Material You
  static const youColoursKey = 'app.youColours'; // "brand", or unset for the phone's
  static const colorKey = 'uwuflash.colorTheme';
  static const modeKey = 'uwuflash.mode';
  static const lightFromHour = 9;
  static const lightUntilHour = 18;

  static const swatches = [
    BrandSwatch('classic', 0xFFCCFFCC, 'Classic'),
    BrandSwatch('not-green-1', 0xFFFFCCCC, 'Not green 1'),
    BrandSwatch('not-green-2', 0xFFCCCCFF, 'Not green 2'),
    BrandSwatch('not-green-3', 0xFFFFFFCC, 'Not green 3'),
    BrandSwatch('not-green-4', 0xFFFFCCFF, 'Not green 4'),
    BrandSwatch('not-green-5', 0xFFCCFFFF, 'Not green 5'),
    BrandSwatch('really-light-green', 0xFFFFFFFF, 'Really really light green'),
  ];

  /// The phone's wallpaper colours (Android 12 and later), once read.
  ColorScheme? phoneLight;
  ColorScheme? phoneDark;
  bool get hasPhoneColours => phoneLight != null;

  /// The phone's own fonts, as Android names them ("google-sans-text" on a Pixel), once read.
  /// "sans-serif" is the phone's default font everywhere else.
  String phoneBodyFont = 'sans-serif';
  String phoneHeadFont = 'sans-serif';

  bool get materialYou => Store.I.get(lookKey) != 'usual';
  set materialYou(bool on) {
    Store.I.put(lookKey, on ? null : 'usual');
    _changed();
  }

  /// In Material You: the phone's colours (the default), or the brand colour picked.
  bool get youUseBrand => Store.I.get(youColoursKey) == 'brand';
  set youUseBrand(bool on) {
    Store.I.put(youColoursKey, on ? 'brand' : null);
    _changed();
  }

  String get swatchId {
    final v = Store.I.get(colorKey);
    return swatches.any((s) => s.id == v) ? v! : swatches.first.id;
  }

  set swatchId(String id) {
    Store.I.put(colorKey, id);
    _changed();
  }

  BrandSwatch get swatch => swatches.firstWhere((s) => s.id == swatchId);

  /// "phone", "light", "dark" or "time". Material You starts with the phone's; the UwU Apps theme
  /// with light, as the site always does.
  String get modePreference {
    final v = Store.I.get(modeKey);
    return const ['phone', 'light', 'dark', 'time'].contains(v) ? v! : (materialYou ? 'phone' : 'light');
  }

  set modePreference(String v) {
    Store.I.put(modeKey, v);
    _changed();
  }

  void _changed() {
    _scheduleClock();
    notifyListeners();
  }

  void changed() => notifyListeners();

  static bool daylight([DateTime? now]) {
    final h = (now ?? DateTime.now()).hour;
    return h >= lightFromHour && h < lightUntilHour;
  }

  ThemeMode themeMode() => switch (modePreference) {
        'dark' => ThemeMode.dark,
        'time' => daylight() ? ThemeMode.light : ThemeMode.dark,
        'phone' => ThemeMode.system,
        _ => ThemeMode.light,
      };

  // Keeping the time based mode honest while the app stays open.
  Timer? _clock;
  void _scheduleClock() {
    _clock?.cancel();
    _clock = null;
    if (modePreference != 'time') return;
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, now.hour < lightFromHour ? lightFromHour : lightUntilHour);
    if (now.hour >= lightUntilHour) next = DateTime(now.year, now.month, now.day + 1, lightFromHour);
    // A second of slack, so a timer that fires a fraction early doesn't land back in the hour it
    // just left.
    _clock = Timer(next.difference(now) + const Duration(seconds: 1), _changed);
  }

  void start() => _scheduleClock();

  // Made once for each change, as the other screen's told the card's colours many times a second.
  final Map<Brightness, ThemeData> _themes = {};

  ThemeData theme(Brightness b) => _themes[b] ??= materialYou ? _material(b) : _usual(b);

  @override
  void notifyListeners() {
    _themes.clear();
    super.notifyListeners();
  }

  /// What the app's in right now, from anywhere: light or dark.
  Brightness get resolvedNow => switch (themeMode()) {
        ThemeMode.dark => Brightness.dark,
        ThemeMode.light => Brightness.light,
        ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  /// The tokens for what the app's in right now.
  FlashColors get tokensNow => theme(resolvedNow).extension<FlashColors>()!;

  // ---------- Material You ----------

  static const _seed = Color(0xFF2E7D32); // the site's green, as a tone that seeds well

  ColorScheme _youScheme(Brightness b) {
    if (youUseBrand) return ColorScheme.fromSeed(seedColor: swatch.color, brightness: b);
    return (b == Brightness.dark ? phoneDark : phoneLight) ?? ColorScheme.fromSeed(seedColor: _seed, brightness: b);
  }

  ThemeData _material(Brightness b) {
    final scheme = _youScheme(b);
    final dark = b == Brightness.dark;
    final flash = FlashColors(
      page: scheme.surface,
      bg: scheme.surface,
      surface: scheme.surfaceContainer,
      surfaceStrong: scheme.surfaceContainerHigh,
      border: scheme.outlineVariant,
      ink: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      mutedStrong: scheme.onSurfaceVariant,
      brand: scheme.primaryContainer,
      onBrand: scheme.onSecondaryContainer,
      brandInk: scheme.primary,
      brandFill: scheme.secondaryContainer,
      brandFillStrong: scheme.secondaryContainer,
      error: scheme.error,
      cardBg: dark ? scheme.surface : scheme.primaryContainer,
      cardInk: dark ? scheme.primary : scheme.onPrimaryContainer,
      glass: false,
    );
    // The phone's own fonts: its headline font for the big words, its body font for the rest, and
    // the phone's default (then Noto) for anything they lack.
    const fallback = ['sans-serif', 'Roboto', 'Noto Sans'];
    final base = Typography.material2021(platform: TargetPlatform.android);
    final plain = (dark ? base.white : base.black).apply(fontFamily: phoneBodyFont, fontFamilyFallback: fallback);
    TextStyle? head(TextStyle? t) => t?.copyWith(fontFamily: phoneHeadFont, fontFamilyFallback: fallback);
    final text = plain.copyWith(
      displayLarge: head(plain.displayLarge),
      displayMedium: head(plain.displayMedium),
      displaySmall: head(plain.displaySmall),
      headlineLarge: head(plain.headlineLarge),
      headlineMedium: head(plain.headlineMedium),
      headlineSmall: head(plain.headlineSmall),
      titleLarge: head(plain.titleLarge),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: b,
      fontFamily: phoneBodyFont,
      fontFamilyFallback: fallback,
      textTheme: text,
      scaffoldBackgroundColor: flash.page,
      extensions: [flash],
      bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      }),
    );
  }

  // ---------- the UwU Apps theme ----------

  ThemeData _usual(Brightness b) {
    final dark = b == Brightness.dark;
    final brand = swatch.color;
    final bg = dark ? const Color(0xFF0C100E) : const Color(0xFFEEF2F0);
    final ink = dark ? const Color(0xFFEEF2EF) : const Color(0xFF121815);
    final surfaceStrong = dark ? const Color(0x1CFFFFFF) : const Color(0xC7FFFFFF);
    const onBrand = Color(0xFF121815);
    // The site's color-mix(in srgb, var(--brand) 55%, var(--surface-strong)), over the page.
    Color fill(double amount) => Color.lerp(Color.alphaBlend(surfaceStrong, bg), brand, amount)!;
    final flash = FlashColors(
      page: Color.lerp(bg, brand, 0.10)!,
      bg: bg,
      surface: dark ? const Color(0x0FFFFFFF) : const Color(0x8CFFFFFF),
      surfaceStrong: surfaceStrong,
      border: dark ? const Color(0x24FFFFFF) : const Color(0xA6FFFFFF),
      ink: ink,
      muted: dark ? const Color(0xFF9AA7A0) : const Color(0xFF5B665F),
      mutedStrong: ink.withValues(alpha: 0.7),
      brand: brand,
      onBrand: onBrand,
      brandInk: dark ? const Color(0xFFBFF5CF) : const Color(0xFF1F6B3D),
      brandFill: fill(0.55),
      brandFillStrong: fill(0.75),
      error: dark ? const Color(0xFFFA9696) : const Color(0xFFB91C1C),
      cardBg: dark ? bg : brand,
      cardInk: dark ? brand : onBrand,
      glass: true,
    );
    final solid = Color.alphaBlend(surfaceStrong, flash.page);
    final scheme = ColorScheme(
      brightness: b,
      primary: flash.brandInk,
      onPrimary: dark ? const Color(0xFF0C100E) : Colors.white,
      primaryContainer: brand,
      onPrimaryContainer: onBrand,
      secondary: flash.brandInk,
      onSecondary: dark ? const Color(0xFF0C100E) : Colors.white,
      secondaryContainer: flash.brandFill,
      onSecondaryContainer: onBrand,
      error: flash.error,
      onError: Colors.white,
      surface: flash.page,
      onSurface: ink,
      onSurfaceVariant: flash.muted,
      surfaceContainerLowest: solid,
      surfaceContainerLow: solid,
      surfaceContainer: solid,
      surfaceContainerHigh: solid,
      surfaceContainerHighest: solid,
      outline: flash.muted,
      outlineVariant: flash.border,
    );
    // Jua has no "•" or other languages' letters: the phone's font stands in for them.
    const fallback = ['Roboto', 'Noto Sans'];
    final base = Typography.material2021(platform: TargetPlatform.android);
    final text = (dark ? base.white : base.black).apply(fontFamily: 'Jua', fontFamilyFallback: fallback, bodyColor: ink, displayColor: ink);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: b,
      fontFamily: 'Jua',
      fontFamilyFallback: fallback,
      textTheme: text,
      scaffoldBackgroundColor: flash.page,
      extensions: [flash],
      splashFactory: NoSplash.splashFactory,
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? flash.bg : Color.alphaBlend(surfaceStrong, bg)),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? flash.brandInk : ink.withValues(alpha: 0.22)),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceStrong,
        hintStyle: TextStyle(color: flash.mutedStrong),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: flash.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: flash.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: flash.brandInk, width: 2)),
      ),
    );
  }

  // Android's own tonal palettes as the scheme: seeded from them for the newer roles, then the
  // roles Android sets itself put back, so the app matches the phone's other apps.
  static ColorScheme _fromPalette(CorePalette p, Brightness b) {
    final s = b == Brightness.dark ? Scheme.darkFromCorePalette(p) : Scheme.lightFromCorePalette(p);
    return ColorScheme.fromSeed(seedColor: Color(s.primary), brightness: b).copyWith(
      primary: Color(s.primary),
      onPrimary: Color(s.onPrimary),
      primaryContainer: Color(s.primaryContainer),
      onPrimaryContainer: Color(s.onPrimaryContainer),
      secondary: Color(s.secondary),
      onSecondary: Color(s.onSecondary),
      secondaryContainer: Color(s.secondaryContainer),
      onSecondaryContainer: Color(s.onSecondaryContainer),
      tertiary: Color(s.tertiary),
      onTertiary: Color(s.onTertiary),
      tertiaryContainer: Color(s.tertiaryContainer),
      onTertiaryContainer: Color(s.onTertiaryContainer),
      surface: Color(s.surface),
      onSurface: Color(s.onSurface),
      onSurfaceVariant: Color(s.onSurfaceVariant),
      outline: Color(s.outline),
      outlineVariant: Color(s.outlineVariant),
      inverseSurface: Color(s.inverseSurface),
      onInverseSurface: Color(s.inverseOnSurface),
      inversePrimary: Color(s.inversePrimary),
    );
  }

  /// Reads the wallpaper's colours (Android 12 and later) and the phone's fonts, each time the app
  /// opens or comes back.
  Future<void> readPhone() async {
    try {
      final fonts = await Native.call('Flash', 'fonts');
      if (fonts != null) {
        phoneBodyFont = (fonts['body'] as String?) ?? 'sans-serif';
        phoneHeadFont = (fonts['headline'] as String?) ?? phoneBodyFont;
      }
    } catch (_) {
      // No native side: the default font.
    }
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        phoneLight = _fromPalette(palette, Brightness.light);
        phoneDark = _fromPalette(palette, Brightness.dark);
      }
    } catch (_) {
      // Before Android 12, or no dynamic colours: the app's green.
    }
    notifyListeners();
  }
}
