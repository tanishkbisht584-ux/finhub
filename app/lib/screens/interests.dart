import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';
import 'feed.dart' show setInitialCategories;

/// Spec §8 screen 1: sign-in -> pick >=3 interests -> feed, under 60 seconds.
/// The pipeline's category enum verbatim (ai.py CATEGORIES) — a follow row on
/// a category the pipeline never emits would be a dead filter.
const kCategories = [
  'Markets',
  'Economy',
  'IPO',
  'Global',
  'Commodities',
  'Corporate',
  'Policy',
  'Geopolitics',
];

class InterestsScreen extends StatefulWidget {
  const InterestsScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<InterestsScreen> createState() => _InterestsScreenState();
}

class _InterestsScreenState extends State<InterestsScreen> {
  final _picked = <String>{};
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    try {
      if (uid != null) {
        await sb.from('follows').upsert([
          for (final c in _picked)
            {'user_id': uid, 'target_type': 'category', 'target_id': c}
        ]);
      }
    } catch (_) {
      // The feed must never be gated on this write landing — interests can
      // be re-derived from behavior later; a stuck onboarding cannot.
    }
    // Local, must land even when the network write above didn't.
    await setInitialCategories(_picked);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('What do you care about?',
                  style: serif.copyWith(
                      fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  'Pick at least three — your alerts and feed learn from this.',
                  style: mono.copyWith(fontSize: 13)),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in kCategories)
                    FilterChip(
                      label: Text(c),
                      selected: _picked.contains(c),
                      backgroundColor: surface,
                      selectedColor: green.withValues(alpha: 0.18),
                      checkmarkColor: green,
                      side: BorderSide(
                          color: _picked.contains(c) ? green : border),
                      labelStyle:
                          TextStyle(color: _picked.contains(c) ? green : ink),
                      onSelected: (_) => setState(() => _picked.contains(c)
                          ? _picked.remove(c)
                          : _picked.add(c)),
                    ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _picked.length >= 3 && !_saving ? _save : null,
                  child: Text(
                      _saving ? 'Saving…' : 'Continue (${_picked.length}/3)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
