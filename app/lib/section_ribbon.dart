import 'package:flutter/material.dart';

import 'screens/feed.dart' show filterPill;
import 'theme.dart';

/// The sticky section nav (lifted from the markets redesign so the stock page
/// can reuse it): one chip per section, the active one tracks the scroll, tap
/// jumps, the magnifier filters chips by heading.
class SectionRibbon extends StatefulWidget {
  const SectionRibbon(this.sections, this.active, this.onJump, {super.key});
  final List<({String id, String label})> sections;
  final ValueNotifier<String> active;
  final void Function(String id) onJump;

  @override
  State<SectionRibbon> createState() => _SectionRibbonState();
}

class _SectionRibbonState extends State<SectionRibbon> {
  bool _searching = false;
  String _q = '';
  final _chipKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    widget.active.addListener(_follow);
  }

  @override
  void dispose() {
    widget.active.removeListener(_follow);
    super.dispose();
  }

  /// Keep the active chip in view as the page scrolls underneath.
  void _follow() {
    if (!mounted) return;
    setState(() {});
    final ctx = _chipKeys[widget.active.value]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final match = [
      for (final s in widget.sections)
        if (q.isEmpty || s.label.toLowerCase().contains(q)) s
    ];
    // Before any scroll, the first section is the active one.
    final activeId = widget.sections.any((s) => s.id == widget.active.value)
        ? widget.active.value
        : widget.sections.first.id;
    return Container(
      decoration: const BoxDecoration(
          color: bg, border: Border(bottom: BorderSide(color: border))),
      padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
      child: Row(children: [
        InkWell(
          onTap: () => setState(() {
            _searching = !_searching;
            _q = '';
          }),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(_searching ? Icons.close : Icons.search,
                size: 18, color: inkDim),
          ),
        ),
        if (_searching)
          SizedBox(
            width: 120,
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              style: mono.copyWith(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'jump to…',
                hintStyle: mono.copyWith(fontSize: 12, color: inkDim),
                enabledBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: border)),
                focusedBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: green)),
              ),
            ),
          ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 12),
            child: Row(children: [
              for (final s in match)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: KeyedSubtree(
                    key: _chipKeys.putIfAbsent(s.id, GlobalKey.new),
                    child: filterPill(s.label, s.id == activeId, green, () {
                      widget.onJump(s.id);
                      setState(() {
                        _searching = false;
                        _q = '';
                      });
                    }),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// The scroll-sync half: which section owns the viewport, and animated jumps.
/// Host wires [track] into a NotificationListener and gives each section
/// header [key(id)].
class SectionTracker {
  final keys = <String, GlobalKey>{};
  final active = ValueNotifier<String>('');
  List<String> ids = const [];
  bool _jumping = false;

  GlobalKey key(String id) => keys.putIfAbsent(id, GlobalKey.new);

  void dispose() => active.dispose();

  /// The last section whose header has scrolled to within 80px of the top; at
  /// the very bottom the last section wins even if it never reaches the top.
  bool track(ScrollUpdateNotification n) {
    if (_jumping || n.metrics.axis != Axis.vertical) return false;
    final viewport = n.context?.findRenderObject() as RenderBox?;
    if (viewport == null) return false;
    final threshold = viewport.localToGlobal(Offset.zero).dy + 80;
    String? current;
    for (final id in ids) {
      final box = keys[id]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy <= threshold) {
        current = id;
      } else {
        break;
      }
    }
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 4 && ids.isNotEmpty) {
      current = ids.last;
    }
    if (current != null && current != active.value) active.value = current;
    return false;
  }

  Future<void> jump(String id) async {
    active.value = id;
    final ctx = keys[id]?.currentContext;
    if (ctx == null) return;
    _jumping = true; // don't let en-route sections flicker the ribbon
    await Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _jumping = false;
  }
}
