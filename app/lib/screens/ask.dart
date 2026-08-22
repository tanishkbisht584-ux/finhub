import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../remote_config.dart';
import '../theme.dart';
import 'stock.dart';

const _suggested = [
  'Why is the NIFTY moving today?',
  'What did the RBI announce recently?',
  'Which sectors are hot this week?',
  'What are FIIs doing right now?',
];

/// Spec §8 screen 3 — one box, two behaviors. A question goes to Q&A; a bare
/// entity ("Tata Motors") goes to the stock page. Interrogatives and length
/// separate them: nobody types a seven-word company name, and nobody asks a
/// question without a question word — and when this guess is wrong, Q&A
/// answers the entity query with sources anyway, so a miss costs nothing.
const _questionWords = {
  'why',
  'what',
  'how',
  'when',
  'where',
  'who',
  'which',
  'is',
  'are',
  'was',
  'will',
  'should',
  'can',
  'could',
  'does',
  'did',
  'do',
  'explain',
  'tell',
};

bool looksLikeQuestion(String q) {
  final words = q.trim().toLowerCase().split(RegExp(r'\s+'));
  if (words.length > 4) return true;
  return q.contains('?') || words.any(_questionWords.contains);
}

/// Guards the PostgREST `.or()` filter from injection: `,` `(` `)` are
/// syntax there, and a raw term carrying one (e.g. `Tata,id.gt.0`) would
/// splice extra filter conditions. No legitimate ticker/company name
/// contains these, so a term that does just skips routing (falls through
/// to Q&A, which takes any text safely as a JSON body).
String? safeEntityTerm(String q) {
  final term = q.trim();
  return term.contains(RegExp(r'[,()]')) ? null : term;
}

class AskScreen extends StatefulWidget {
  const AskScreen({super.key});
  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _controller = TextEditingController();
  QaAnswer? _answer;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    if (question.trim().isEmpty || _loading) return;
    _controller.text = question;
    // Arm the spinner (and the reentrancy guard above) before the company
    // lookup: that await used to run guardless with an inert UI, and a second
    // enter fired a second lookup — two StockScreens pushed back-to-back.
    setState(() {
      _loading = true;
      _error = null;
      _answer = null;
    });
    if (!remoteConfig.qaEnabled) {
      // Admin paused Ask: say so instead of a round trip that would 503.
      setState(() {
        _loading = false;
        _error = 'Ask is paused for maintenance — back soon.';
      });
      return;
    }
    try {
      final term =
          looksLikeQuestion(question) ? null : safeEntityTerm(question);
      if (term != null) {
        try {
          final rows = await Supabase.instance.client
              .from('companies')
              .select('id,name,nse_symbol')
              .or('nse_symbol.ilike.$term,name.ilike.$term%')
              .limit(5);
          // A prefix match can hit siblings (RELIANCE -> 6 rows, ITC -> 2,
          // Tata Motors -> 2 post-demerger), so an exact match on symbol or
          // name wins over the old "unique prefix" rule when there is one.
          final lower = term.toLowerCase();
          final exact = [
            for (final r in rows)
              if ((r['nse_symbol'] as String?)?.toLowerCase() == lower ||
                  (r['name'] as String?)?.toLowerCase() == lower)
                r
          ];
          final match = exact.length == 1
              ? exact.single
              : (rows.length == 1 ? rows.single : null);
          if (match != null && mounted) {
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StockScreen(company: Company.fromJson(match))));
            return;
          }
        } catch (_) {
          // company lookup down -> just ask; Q&A handles entities with sources
        }
      }
      final res = await Supabase.instance.client.functions
          .invoke('qa', body: {'question': question});
      if (!mounted) return;
      final a = QaAnswer.fromJson(Map<String, dynamic>.from(res.data));
      // A 200 whose body defaulted to nothing everywhere renders as a bare
      // divider — treat it as the failure it is.
      setState(() => a.isBlank
          ? _error = 'Could not get an answer — try again.'
          : _answer = a);
    } on FunctionException catch (e) {
      // The guard and outage cases are expected states, not crashes — say what
      // happened in the user's terms rather than dumping a status code.
      if (!mounted) return;
      setState(() => _error = switch (e.status) {
            429 =>
              "That's a lot of questions for one day — try again tomorrow.",
            503 => 'Our answer service is busy. Try again in a minute.',
            _ => 'Could not get an answer — try again.',
          });
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _error = 'Could not reach FinSwipe — check your connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: _ask,
            decoration: const InputDecoration(
              hintText: 'Why is the market moving?',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          // Chips stay up under an error too — they were the only path back
          // besides retyping the question.
          if (_answer == null && !_loading)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggested
                  .map((q) =>
                      ActionChip(label: Text(q), onPressed: () => _ask(q)))
                  .toList(),
            ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(child: appSpinner()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Column(children: [
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: mono.copyWith(fontSize: 13)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _ask(_controller.text),
                  child: const Text('Try again'),
                ),
              ]),
            ),
          if (_answer != null) AnswerCard(answer: _answer!, onFollowup: _ask),
          const SizedBox(height: 24),
          // Only the empty state makes this blanket promise now. Once an answer
          // is on screen the disclaimer travels with it, because an explainer
          // answer is NOT from our sources and saying otherwise would be a lie.
          if (_answer == null)
            Text('Answers come only from our sources. Not investment advice.',
                textAlign: TextAlign.center,
                style: mono.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

class AnswerCard extends StatelessWidget {
  const AnswerCard({super.key, required this.answer, required this.onFollowup});
  final QaAnswer answer;
  final void Function(String) onFollowup;

  @override
  Widget build(BuildContext context) {
    if (answer.refused) {
      return Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Text(answer.whatsHappening,
            textAlign: TextAlign.center, style: serif.copyWith(fontSize: 18)),
      );
    }
    // An explainer answer carries its own headings; a news answer uses the four
    // fixed ones. Same `_section` widget either way.
    final isExplainer = answer.sections.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isExplainer)
          for (final s in answer.sections)
            _section(s.heading.toUpperCase(), s.body)
        else ...[
          _section("WHAT'S HAPPENING", answer.whatsHappening),
          _section('WHY', answer.why),
          _section("WHO'S AFFECTED", answer.whoIsAffected),
          _section('WHAT TO WATCH', answer.whatToWatch),
        ],
        if (answer.confidence != 'high')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('confidence: ${answer.confidence}',
                style: mono.copyWith(fontSize: 12)),
          ),
        const Divider(height: 32),
        ...answer.sources.map((s) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title:
                  Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.sourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 11)),
              trailing: const Icon(Icons.open_in_new, size: 16),
              onTap: () => openExternal(context, s.url),
            )),
        // The caveat attaches to the answer it qualifies — chips used to sit
        // between them, leaving legal text as the last thing on screen.
        Text(
            isExplainer
                ? 'General explainer, not from our newsroom. Verify current '
                    'rules and rates. Not investment advice.'
                : 'Answers come only from our sources. Not investment advice.',
            textAlign: TextAlign.center,
            style: mono.copyWith(fontSize: 11)),
        if (answer.followups.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: answer.followups
                .map((q) => ActionChip(
                    label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: Text(q,
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    onPressed: () => onFollowup(q)))
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _section(String label, String body) => body.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: monoLabel),
            const SizedBox(height: 6),
            Text(body, style: const TextStyle(fontSize: 15, height: 1.5)),
          ]),
        );
}
