import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'theme.dart';

/// term -> definition, once per session across every screen. The qa
/// function's qa_cache makes the fetch itself a once-ever cost globally.
final _termDefs = <String, String>{};

Future<String?> defineTerm(String term) async {
  final key = term.toLowerCase();
  if (_termDefs.containsKey(key)) return _termDefs[key];
  try {
    final res = await Supabase.instance.client.functions
        .invoke('qa', body: {'question': term, 'mode': 'define'});
    final a = QaAnswer.fromJson(Map<String, dynamic>.from(res.data));
    final def =
        a.sections.isNotEmpty ? a.sections.first.body : a.whatsHappening;
    if (def.trim().isEmpty) return null;
    return _termDefs[key] = def;
  } catch (_) {
    return null; // a failed lookup shows the honest fallback, never an error
  }
}

void showDefineSheet(BuildContext context, String term) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: bg,
    shape: const RoundedRectangleBorder(),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(term.toUpperCase(),
                style:
                    mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            FutureBuilder<String?>(
              future: defineTerm(term),
              builder: (_, snap) => Text(
                  snap.connectionState != ConnectionState.done
                      ? 'Looking it up…'
                      : snap.data ??
                          'No definition right now — try asking in Ask.',
                  style: const TextStyle(fontSize: 15, height: 1.5)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Text whose glossary terms (models.dart glossaryTerms) carry a dotted
/// underline and open the define sheet on tap — the card summary's treatment,
/// extracted so Markets/Stock footnotes and table labels get it too.
class GlossaryText extends StatefulWidget {
  const GlossaryText(this.text,
      {super.key, this.style, this.maxLines, this.overflow});
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  State<GlossaryText> createState() => _GlossaryTextState();
}

class _GlossaryTextState extends State<GlossaryText> {
  /// Rebuilt per build, disposed here — the State owns the recognizers.
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _taps) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(children: [
        for (final seg in glossarySegments(widget.text))
          if (seg.isTerm)
            TextSpan(
              text: seg.text,
              style: base.copyWith(
                  decoration: TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted,
                  decorationColor: inkDim),
              recognizer: () {
                final r = TapGestureRecognizer()
                  ..onTap = () => showDefineSheet(context, seg.text);
                _taps.add(r);
                return r;
              }(),
            )
          else
            TextSpan(text: seg.text, style: base),
      ]),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
