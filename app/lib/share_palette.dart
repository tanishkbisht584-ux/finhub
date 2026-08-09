import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'theme.dart';

/// One destination in the hold-and-slide share palette.
class ShareTarget {
  const ShareTarget(this.id, this.label, this.icon, this.tint);
  final String id;
  final String label;
  final IconData icon;
  final Color tint;
}

/// Ordered right-to-left from the thumb: the shortest slide hits the most-used
/// destination. "Card" carries the rendered image; the messaging apps take the
/// hook plus link, because Android has no way to hand an image to a *named*
/// app without going through the chooser — which is the thing this palette
/// exists to skip.
const shareTargets = <ShareTarget>[
  ShareTarget('whatsapp', 'WhatsApp', Icons.chat_rounded, Color(0xFF25D366)),
  ShareTarget('telegram', 'Telegram', Icons.send_rounded, Color(0xFF2AABEE)),
  ShareTarget('x', 'X', Icons.tag_rounded, Color(0xFFE8E6E3)),
  ShareTarget('copy', 'Copy', Icons.link_rounded, inkDim),
  ShareTarget('card', 'Card', Icons.image_rounded, green),
];

String shareText(Story s) =>
    '${s.hook ?? s.headline}\n\nvia FinSwipe · ${s.sourceUrl}';

/// Runs a target. Returns the toast line to show, or null when the app itself
/// took over the screen.
Future<String?> runShareTarget(
  String id,
  Story story,
  Future<Uint8List?> Function() renderCard,
) async {
  final text = shareText(story);
  final encoded = Uri.encodeComponent(text);

  Future<bool> tryScheme(String scheme, String webFallback) async {
    final uri = Uri.parse(scheme);
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return launchUrl(Uri.parse(webFallback),
        mode: LaunchMode.externalApplication);
  }

  switch (id) {
    case 'whatsapp':
      await tryScheme('whatsapp://send?text=$encoded',
          'https://wa.me/?text=$encoded');
      return null;
    case 'telegram':
      await tryScheme('tg://msg?text=$encoded',
          'https://t.me/share/url?url=${Uri.encodeComponent(story.sourceUrl)}&text=$encoded');
      return null;
    case 'x':
      await tryScheme('twitter://post?message=$encoded',
          'https://x.com/intent/post?text=$encoded');
      return null;
    case 'copy':
      await Clipboard.setData(ClipboardData(text: text));
      return 'Link copied';
    case 'card':
    default:
      final png = await renderCard();
      await SharePlus.instance.share(ShareParams(
        files: png == null
            ? const []
            : [
                XFile.fromData(png,
                    mimeType: 'image/png', name: 'finswipe_${story.id}.png')
              ],
        text: text,
      ));
      return null;
  }
}

/// The palette itself: a row of targets that rises above the action rail while
/// the finger is held down. Deliberately plain — a scale-and-fade, no bounce,
/// no colour until a target is actually under the thumb.
class SharePaletteRow extends StatelessWidget {
  const SharePaletteRow({
    super.key,
    required this.animation,
    required this.activeIndex,
    required this.tileSize,
    required this.gap,
  });

  final Animation<double> animation;
  final int? activeIndex;
  final double tileSize;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: animation,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(shareTargets.length, (i) {
          final t = shareTargets[i];
          final active = i == activeIndex;
          // Each tile trails the one before it slightly, so the row unfurls
          // toward the thumb instead of popping in as a block.
          final start = 0.06 * i;
          final curve = CurvedAnimation(
            parent: animation,
            curve: Interval(start, (start + 0.7).clamp(0.0, 1.0),
                curve: Curves.easeOutCubic),
          );
          return Padding(
            padding: EdgeInsets.only(right: i == shareTargets.length - 1 ? 0 : gap),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.7, end: 1).animate(curve),
              child: AnimatedScale(
                scale: active ? 1.18 : 1,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: tileSize,
                    height: tileSize,
                    decoration: BoxDecoration(
                      color: active
                          ? t.tint.withValues(alpha: 0.18)
                          : surface.withValues(alpha: 0.96),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: active ? t.tint : border,
                          width: active ? 1.5 : 1),
                    ),
                    child: Icon(t.icon,
                        size: 22, color: active ? t.tint : inkDim),
                  ),
                  const SizedBox(height: 5),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 140),
                    opacity: active ? 1 : 0.45,
                    child: Text(t.label,
                        style: mono.copyWith(
                            fontSize: 9.5, color: active ? t.tint : inkDim)),
                  ),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}
