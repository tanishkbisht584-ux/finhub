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

/// A 3x3 grid, not a row. Nine targets in one line put the ends a full
/// thumb-stretch away; in a grid every target is at most one cell from the
/// centre in each axis, so nothing is further than a short glide.
///
/// Card sits in the middle because that is where the palette opens, and
/// Cancel takes the far corner where you are least likely to land by accident.
const shareGridColumns = 3;
const shareTargets = <ShareTarget>[
  ShareTarget('whatsapp', 'WhatsApp', Icons.chat_rounded, Color(0xFF25D366)),
  ShareTarget('telegram', 'Telegram', Icons.send_rounded, Color(0xFF2AABEE)),
  ShareTarget('messenger', 'Messenger', Icons.forum_rounded, Color(0xFF0084FF)),
  ShareTarget('reddit', 'Reddit', Icons.reddit_rounded, Color(0xFFFF4500)),
  ShareTarget('card', 'Card', Icons.image_rounded, green),
  ShareTarget('x', 'X', Icons.tag_rounded, Color(0xFFE8E6E3)),
  ShareTarget(
      'discord', 'Discord', Icons.headphones_rounded, Color(0xFF5865F2)),
  ShareTarget('copy', 'Copy', Icons.link_rounded, inkDim),
  ShareTarget('cancel', 'Cancel', Icons.close_rounded, red),
];

/// The centre cell — what the palette opens on.
final int defaultShareTarget = shareTargets.indexWhere((t) => t.id == 'card');

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

  final link = Uri.encodeComponent(story.sourceUrl);
  final title = Uri.encodeComponent(story.hook ?? story.headline);

  switch (id) {
    case 'cancel':
      return null; // deliberate no-op: the user backed out
    case 'messenger':
      await tryScheme(
          'fb-messenger://share/?link=$link', 'https://www.messenger.com/');
      return null;
    case 'reddit':
      await tryScheme('https://www.reddit.com/submit?url=$link&title=$title',
          'https://www.reddit.com/submit?url=$link&title=$title');
      return null;
    case 'discord':
      // Discord exposes no share intent, so the honest path is clipboard plus
      // a jump to the app — and say so, rather than looking like it failed.
      await Clipboard.setData(ClipboardData(text: text));
      await tryScheme('discord://', 'https://discord.com/channels/@me');
      return 'Copied — paste it in Discord';
    case 'whatsapp':
      await tryScheme(
          'whatsapp://send?text=$encoded', 'https://wa.me/?text=$encoded');
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
    final rows = (shareTargets.length / shareGridColumns).ceil();
    return FadeTransition(
      opacity: animation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(rows, (r) {
          return Padding(
            padding: EdgeInsets.only(bottom: r == rows - 1 ? 0 : gap),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(shareGridColumns, (c) {
                final i = r * shareGridColumns + c;
                if (i >= shareTargets.length) {
                  return SizedBox(width: tileSize + gap);
                }
                return Padding(
                  padding: EdgeInsets.only(
                      right: c == shareGridColumns - 1 ? 0 : gap),
                  child: _Tile(
                    target: shareTargets[i],
                    active: i == activeIndex,
                    animation: animation,
                    // Unfurl outward from the centre cell, where the thumb is.
                    delay: 0.05 * ((r - 1).abs() + (c - 1).abs()),
                    tileSize: tileSize,
                  ),
                );
              }),
            ),
          );
        }),
      ),
    );
  }
}

/// One target: a circle that only takes colour once the thumb is on it.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.target,
    required this.active,
    required this.animation,
    required this.delay,
    required this.tileSize,
  });

  final ShareTarget target;
  final bool active;
  final Animation<double> animation;
  final double delay;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: animation,
      curve: Interval(delay, (delay + 0.7).clamp(0.0, 1.0),
          curve: Curves.easeOutCubic),
    );
    return ScaleTransition(
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
                  ? target.tint.withValues(alpha: 0.18)
                  : surface.withValues(alpha: 0.96),
              shape: BoxShape.circle,
              border: Border.all(
                  color: active ? target.tint : border,
                  width: active ? 1.5 : 1),
            ),
            child: Icon(target.icon,
                size: 22, color: active ? target.tint : inkDim),
          ),
          const SizedBox(height: 4),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 140),
            opacity: active ? 1 : 0.4,
            child: Text(target.label,
                style: mono.copyWith(
                    fontSize: 10.5, color: active ? target.tint : inkDim)),
          ),
        ]),
      ),
    );
  }
}

/// The bookmark's ribbon: same hold-and-slide idea as the share palette, but
/// vertical and stacked above the card. Icon-only by design — a menu of one
/// today, with room for shelves and filters later.
const ribbonTargets = <ShareTarget>[
  ShareTarget('cancel', 'Cancel', Icons.close_rounded, red),
  ShareTarget('watchlist', 'Watchlist', Icons.star_rounded, amber),
  ShareTarget('saved', 'Saved', Icons.bookmarks_rounded, green),
];

/// Opens on Saved, the tile nearest the thumb; sliding up reaches Cancel.
final int defaultRibbonTarget =
    ribbonTargets.indexWhere((t) => t.id == 'saved');

class RibbonColumn extends StatelessWidget {
  const RibbonColumn({
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(ribbonTargets.length, (i) {
          final t = ribbonTargets[i];
          final active = i == activeIndex;
          // Unfurl from the bottom up, toward the thumb.
          final start = 0.08 * (ribbonTargets.length - 1 - i);
          final curve = CurvedAnimation(
            parent: animation,
            curve: Interval(start, (start + 0.7).clamp(0.0, 1.0),
                curve: Curves.easeOutCubic),
          );
          return Padding(
            padding: EdgeInsets.only(
                bottom: i == ribbonTargets.length - 1 ? 0 : gap),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.7, end: 1).animate(curve),
              child: AnimatedScale(
                scale: active ? 1.18 : 1,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: AnimatedContainer(
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
                  child:
                      Icon(t.icon, size: 22, color: active ? t.tint : inkDim),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
