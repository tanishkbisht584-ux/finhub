import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
const _storySuggested = [
  'What does this mean for investors?',
  'Who gains and who loses?',
  'What should I watch next?',
];
const _symbolSuggested = [
  'Is this stock expensive compared to its sector?',
  'How has it performed this year?',
  'What are its key ratios?',
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

const _historyKey = 'ask_history_v1';

/// Ask history, newest first, one entry per question text, capped. Pure so
/// the ordering and the cap are testable; the screen only persists it.
List<Map<String, dynamic>> pushHistory(List<Map<String, dynamic>> history,
        String question, Map<String, dynamic> raw,
        {int max = 20}) =>
    [
      {'q': question, 'raw': raw, 'at': DateTime.now().toIso8601String()},
      ...history.where((e) => e['q'] != question),
    ].take(max).toList();

/// The Ask tab, and since 2026-09-13 also "ask about this": pushed as a route
/// from a deep read ([storyId]) or a stock page ([symbol]). The server then
/// grounds on that story's cluster or that symbol's live numbers and skips its
/// planner call, so a context answer is one model call instead of two.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key, this.storyId, this.symbol, this.contextLabel});
  final int? storyId;
  final String? symbol;
  final String? contextLabel;
  bool get hasContext => storyId != null || symbol != null;

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _controller = TextEditingController();
  QaAnswer? _answer;
  bool _loading = false;
  String? _error;

  /// Progressive copy under the spinner: a sourced answer is 2-4 s warm and
  /// longer on a cold function, and a silent spinner past ~3 s reads as hung.
  String? _status;
  Timer? _t3, _t8;

  List<Map<String, dynamic>> _history = const [];

  @override
  void initState() {
    super.initState();
    // Prefs are a convenience: no plugin (widget tests) or a corrupt blob
    // just means no history.
    SharedPreferences.getInstance().then((p) {
      final raw = p.getString(_historyKey);
      if (raw == null || !mounted) return;
      try {
        setState(() => _history = [
              for (final e in jsonDecode(raw) as List)
                Map<String, dynamic>.from(e as Map)
            ]);
      } catch (_) {
        p.remove(_historyKey);
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _t3?.cancel();
    _t8?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _remember(String question, Map<String, dynamic> raw) {
    final label = widget.contextLabel;
    _history = pushHistory(
        _history, label == null ? question : '$label: $question', raw);
    SharedPreferences.getInstance()
        .then((p) => p.setString(_historyKey, jsonEncode(_history)))
        .catchError((_) => false);
  }

  void _armStatus() {
    _t3?.cancel();
    _t8?.cancel();
    _status = null;
    _t3 = Timer(const Duration(seconds: 3), () {
      if (mounted && _loading) setState(() => _status = 'Reading our sources…');
    });
    _t8 = Timer(const Duration(seconds: 8), () {
      if (mounted && _loading) {
        setState(
            () => _status = 'Still thinking… a full answer takes a moment.');
      }
    });
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
    _armStatus();
    if (!remoteConfig.qaEnabled) {
      // Admin paused Ask: say so instead of a round trip that would 503.
      setState(() {
        _loading = false;
        _error = 'Ask is paused for maintenance — back soon.';
      });
      return;
    }
    try {
      // Entity routing only from the bare tab: on an "ask about TCS" page a
      // bare "TCS" is a question about the context, not a second stock page.
      final term = widget.hasContext || looksLikeQuestion(question)
          ? null
          : safeEntityTerm(question);
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
      // 25 s: comfortably past a real answer's worst case; the function's own
      // per-lane timeouts mean a stall is a stall, not a slow answer.
      final res = await Supabase.instance.client.functions.invoke('qa', body: {
        'question': question,
        if (widget.storyId != null) 'story_id': widget.storyId,
        if (widget.symbol != null) 'symbol': widget.symbol,
      }).timeout(const Duration(seconds: 25));
      if (!mounted) return;
      final raw = Map<String, dynamic>.from(res.data);
      final a = QaAnswer.fromJson(raw);
      // A 200 whose body defaulted to nothing everywhere renders as a bare
      // divider — treat it as the failure it is.
      if (a.isBlank) {
        setState(() => _error = 'Could not get an answer — try again.');
      } else {
        _remember(question, raw);
        setState(() => _answer = a);
      }
    } on FunctionException catch (e) {
      // The guard and outage cases are expected states, not crashes — say what
      // happened in the user's terms rather than dumping a status code.
      if (!mounted) return;
      setState(() => _error = switch (e.status) {
            429 =>
              "That's a lot of questions for one day — try again tomorrow.",
            503 when '${e.details}'.contains('busy today') =>
              "Ask has used today's free budget. Answers already given still "
                  'open — ask something new tomorrow.',
            503 => 'Our answer service is busy. Try again in a minute.',
            _ => 'Could not get an answer — try again.',
          });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _error = 'Taking too long — try again.');
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _error = 'Could not reach FinFlick — check your connection.');
    } finally {
      _t3?.cancel();
      _t8?.cancel();
      if (mounted) {
        setState(() {
          _loading = false;
          _status = null;
        });
      }
    }
  }

  List<String> get _suggestions => widget.storyId != null
      ? _storySuggested
      : widget.symbol != null
          ? _symbolSuggested
          : _suggested;

  @override
  Widget build(BuildContext context) {
    final label = widget.contextLabel;
    final body = SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Icon(
                    widget.symbol != null
                        ? Icons.show_chart
                        : Icons.article_outlined,
                    size: 16,
                    color: inkDim),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 12))),
              ]),
            ),
          TextField(
            controller: _controller,
            autofocus: widget.hasContext,
            textInputAction: TextInputAction.search,
            onSubmitted: _ask,
            decoration: InputDecoration(
              hintText: widget.symbol != null
                  ? 'Ask about ${widget.symbol}'
                  : widget.storyId != null
                      ? 'Ask about this story'
                      : 'Why is the market moving?',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          // Chips stay up under an error too — they were the only path back
          // besides retyping the question.
          if (_answer == null && !_loading)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggestions
                  .map((q) =>
                      ActionChip(label: Text(q), onPressed: () => _ask(q)))
                  .toList(),
            ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  appSpinner(),
                  if (_status != null) ...[
                    const SizedBox(height: 14),
                    Text(_status!, style: mono.copyWith(fontSize: 12)),
                  ],
                ]),
              ),
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
          // Recent answers reopen instantly from the device — no round trip,
          // no quota. Kept only here; the server never stores question text.
          if (_answer == null && !_loading && _history.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('RECENT', style: monoLabel),
            for (final h in _history.take(10))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(h['q'] as String,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.history, size: 16, color: inkDim),
                onTap: () => setState(() {
                  _controller.text = h['q'] as String;
                  _answer = QaAnswer.fromJson(
                      Map<String, dynamic>.from(h['raw'] as Map));
                }),
              ),
          ],
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
    if (!widget.hasContext) return body;
    // Pushed as a route (deep read / stock page): it needs its own chrome.
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text('ASK', style: serif.copyWith(fontSize: 18)),
      ),
      body: body,
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
