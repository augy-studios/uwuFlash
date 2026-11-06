// The app's icons. In the UwU Apps theme, the site's own (js/icons.js, drawn in the text's colour),
// so it looks as the website does; in Material You, Android's.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

const _material = <String, IconData>{
  'sun': Icons.light_mode_outlined,
  'moon': Icons.dark_mode_outlined,
  'close': Icons.close,
  'clock': Icons.schedule,
  'phone': Icons.smartphone,
  'plus': Icons.add,
  'text': Icons.notes,
  'image': Icons.image_outlined,
  'play': Icons.play_arrow_outlined,
  'trash': Icons.delete_outline,
  'copy': Icons.content_copy,
  'up': Icons.arrow_upward,
  'down': Icons.arrow_downward,
  'left': Icons.chevron_left,
  'right': Icons.chevron_right,
  'cards': Icons.style_outlined,
  'eye': Icons.visibility_outlined,
  'eyeOff': Icons.visibility_off_outlined,
  'grid': Icons.grid_view,
  'cast': Icons.cast,
  'fullscreen': Icons.fullscreen,
  'refresh': Icons.refresh,
  'ticker': Icons.view_day_outlined,
  'lines': Icons.grid_on,
  'appUpdate': Icons.arrow_circle_down_outlined,
  'bell': Icons.notifications_outlined,
  'mic': Icons.mic_none,
  'flick': Icons.screen_rotation_alt,
  'exit': Icons.logout,
  'settings': Icons.settings_outlined,
  'palette': Icons.palette_outlined,
};

const _strokes = <String, String>{
  'sun': '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/>',
  'moon': '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
  'close': '<path d="M18 6 6 18M6 6l12 12"/>',
  'clock': '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/>',
  'phone': '<rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 18h2"/>',
  'plus': '<path d="M12 5v14M5 12h14"/>',
  'text': '<path d="M4 6h16M8 12h12M8 18h8M4 12h.01M4 18h.01"/>',
  'image': '<rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="8.5" cy="9.5" r="1.7"/><path d="m4 17 4.5-4.5a2 2 0 0 1 2.8 0L16 17M14.5 14l1.8-1.8a2 2 0 0 1 2.8 0L21 14.5"/>',
  'play': '<path d="M7 4.5v15l12-7.5z"/>',
  'trash': '<path d="M4 7h16M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7M6 7l1 12.5A1.5 1.5 0 0 0 8.5 21h7a1.5 1.5 0 0 0 1.5-1.5L18 7M10 11v6M14 11v6"/>',
  'copy': '<rect x="9" y="9" width="12" height="12" rx="2.5"/><path d="M5 15V5.5A1.5 1.5 0 0 1 6.5 4H15"/>',
  'up': '<path d="M12 19V5M5 12l7-7 7 7"/>',
  'down': '<path d="M12 5v14M19 12l-7 7-7-7"/>',
  'left': '<path d="M15 19 8 12l7-7"/>',
  'right': '<path d="m9 5 7 7-7 7"/>',
  'cards': '<rect x="3" y="6" width="13" height="15" rx="2.5"/><path d="M8 3h9.5A2.5 2.5 0 0 1 20 5.5V18"/>',
  'eye': '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  'eyeOff': '<path d="M3 3l18 18M10.6 6a9.6 9.6 0 0 1 1.4-.1c6 0 9.5 6.1 9.5 6.1a17 17 0 0 1-3 3.8M6.2 7.8A17 17 0 0 0 2.5 12S6 18.1 12 18.1a9.4 9.4 0 0 0 3.9-.8M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
  'grid': '<rect x="3" y="3" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2"/>',
  'cast': '<path d="M3 8V6.5A2.5 2.5 0 0 1 5.5 4h13A2.5 2.5 0 0 1 21 6.5v11a2.5 2.5 0 0 1-2.5 2.5H14M3 12a8 8 0 0 1 8 8M3 16a4 4 0 0 1 4 4M3 20h.01"/>',
  'fullscreen': '<path d="M4 9V5.5A1.5 1.5 0 0 1 5.5 4H9M15 4h3.5A1.5 1.5 0 0 1 20 5.5V9M20 15v3.5a1.5 1.5 0 0 1-1.5 1.5H15M9 20H5.5A1.5 1.5 0 0 1 4 18.5V15"/>',
  'refresh': '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4"/>',
  'ticker': '<rect x="2.5" y="7" width="19" height="10" rx="2.5"/><path d="M6 12h7M16 12h2M9 9.5 6 12l3 2.5"/>',
  'lines': '<rect x="3" y="4" width="7.5" height="16" rx="2"/><rect x="13.5" y="4" width="7.5" height="16" rx="2"/><path d="M3 18 21 6"/>',
  'appUpdate': '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v8M8.5 12l3.5 3.5 3.5-3.5"/>',
  'bell': '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5a2 2 0 0 0 4 0"/>',
  'mic': '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
  'flick': '<rect x="8" y="7" width="8" height="13" rx="2"/><path d="M4 9a9 9 0 0 1 4-5.2M20 9a9 9 0 0 0-4-5.2M3 5.5 4 9l3.4-1M21 5.5 20 9l-3.4-1"/>',
  'exit': '<path d="M9 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20H9M16 16l4-4-4-4M20 12H10"/>',
  'settings': '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1.08-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1.08 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33 1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82 1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
  'palette': '<path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 2-2s-.5-1.5-.5-2.5A1.5 1.5 0 0 1 15 15h2a4 4 0 0 0 4-4c0-4.4-4-8-9-8z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10.5" cy="7.5" r="1"/><circle cx="15" cy="8" r="1"/>',
};

class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 20, this.color});
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? IconTheme.of(context).color ?? DefaultTextStyle.of(context).style.color ?? context.flash.ink;
    if (context.materialYou) return Icon(_material[name], size: size + 2, color: tint);
    final svg = '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="none" stroke="#000" stroke-width="1.8" '
        'stroke-linecap="round" stroke-linejoin="round">${_strokes[name] ?? ''}</svg>';
    return SvgPicture.string(svg, width: size, height: size, colorFilter: ColorFilter.mode(tint, BlendMode.srcIn));
  }
}
