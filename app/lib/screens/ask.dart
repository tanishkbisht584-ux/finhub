import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';

const _suggested = [
  'Why is the NIFTY moving today?',
  'What did the RBI announce recently?',
  'Which sectors are hot this week?',
  'What are FIIs doing right now?',
];

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
    setState(() {
      _loading = true;
      _error = null;
      _answer = null;
    });
    try {
      final res = await Supabase.instance.client.functions
          .invoke('qa', body: {'question': question});
      if (!mounted) return;
      setState(() =>
          _answer = QaAnswer.fromJson(Map<String, dynamic>.from(res.data)));
    } on FunctionException catch (e) {
      // The guard and outage cases are expected states, not crashes — say what
      // happened in the user's terms rather than dumping a status code.
      if (!mounted) return;
      setState(() => _error = switch (e.status) {
            429 => "That's a lot of questions for one day — try again tomorrow.",
            503 => 'Our answer service is busy. Try again in a minute.',
            _ => 'Could not get an answer — try again.',
          });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach FinSwipe — check your connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
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
          if (_answer == null && !_loading && _error == null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggested
                  .map((q) => ActionChip(label: Text(q), onPressed: () => _ask(q)))
                  .toList(),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(_error!,
                  textAlign: TextAlign.center, style: mono.copyWith(fontSize: 13)),
            ),
          if (_answer != null) AnswerCard(answer: _answer!, onFollowup: _ask),
          const SizedBox(height: 24),
          Text('Answers come only from our sources. Not investment advice.',
              textAlign: TextAlign.center, style: mono.copyWith(fontSize: 11)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section("WHAT'S HAPPENING", answer.whatsHappening),
        _section('WHY', answer.why),
        _section("WHO'S AFFECTED", answer.whoIsAffected),
        _section('WHAT TO WATCH', answer.whatToWatch),
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
              title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.sourceName, style: mono.copyWith(fontSize: 11)),
              trailing: const Icon(Icons.open_in_new, size: 16),
              onTap: () =>
                  launchUrl(Uri.parse(s.url), mode: LaunchMode.externalApplication),
            )),
        if (answer.followups.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: answer.followups
                .map((q) => ActionChip(label: Text(q), onPressed: () => onFollowup(q)))
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _section(String label, String body) => body.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: mono.copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(body, style: const TextStyle(fontSize: 15, height: 1.5)),
          ]),
        );
}
