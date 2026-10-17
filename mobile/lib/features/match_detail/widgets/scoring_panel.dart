import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/json.dart';
import '../../../core/models/league_models.dart';
import '../../../core/models/match_models.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/dialogs.dart';
import '../../fixtures/data/league_repository.dart';
import '../../scoring/scoring_service.dart';

/// Organizer-only scoring controls. Event options come from the sport's
/// `scoring_events` config — nothing sport-specific is hardcoded.
class ScoringPanel extends ConsumerStatefulWidget {
  const ScoringPanel({super.key, required this.score, required this.onChanged});

  final ScoreObject score;
  final VoidCallback onChanged;

  @override
  ConsumerState<ScoringPanel> createState() => _ScoringPanelState();
}

class _ScoringPanelState extends ConsumerState<ScoringPanel> {
  String? _teamId;
  bool _busy = false;

  ScoreObject get score => widget.score;

  Future<void> _send({required String type, required Json payload, required String label, required String confirmText}) async {
    final ok = await confirmAction(context, title: 'Confirm', message: confirmText, confirmLabel: 'Submit');
    if (!ok || !mounted) return;
    await submitScoringEvent(context, ref, score: score, type: type, payload: payload, label: label,
        onBusy: (b) {
          if (mounted) setState(() => _busy = b);
        },
        onDone: widget.onChanged);
  }

  @override
  Widget build(BuildContext context) {
    final online = ref.watch(syncControllerProvider.select((s) => s.online));
    final sportId = score.sportId;
    final teams = [
      if (score.home.teamId != null) (score.home.teamId!, score.homeLabel),
      if (score.away.teamId != null) (score.away.teamId!, score.awayLabel),
    ];
    _teamId ??= teams.isNotEmpty ? teams.first.$1 : null;

    return SectionCard(
      title: 'Scoring',
      icon: Icons.scoreboard_outlined,
      trailing: Text('v${score.version}', style: const TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.w600)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!online)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: Text(
                'You are offline. Events are saved on this device and sent when you reconnect.',
                style: TextStyle(color: AppColors.warning, fontWeight: FontWeight.w600),
              ),
            ),
          if (score.status == MatchStatus.upcoming)
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _send(
                        type: 'match_start',
                        payload: const {},
                        label: 'Start match · ${score.matchId}',
                        confirmText: 'Start ${score.homeLabel} vs ${score.awayLabel}?',
                      ),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start match'),
            ),
          if (score.status == MatchStatus.inProgress) ...[
            if (sportId == null)
              const Text('This match has no sport configured, so scoring options are unavailable.')
            else
              ref.watch(sportProvider(sportId)).when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text(friendlyError(e), style: const TextStyle(color: AppColors.danger)),
                    data: (sport) => _ScoreControls(
                      sport: sport.data,
                      teams: teams,
                      teamId: _teamId,
                      busy: _busy,
                      onTeam: (id) => setState(() => _teamId = id),
                      onEvent: (def) {
                        final team = teams.firstWhere((t) => t.$1 == _teamId);
                        _send(
                          type: 'score',
                          payload: {'team_id': team.$1, 'event_type': def.key},
                          label: '${def.label} — ${team.$2}',
                          confirmText: 'Record "${def.label}" (${def.describe(sport.data.scoringModel)}) for ${team.$2}?',
                        );
                      },
                    ),
                  ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _send(
                        type: 'match_end',
                        payload: const {},
                        label: 'End match · ${score.matchId}',
                        confirmText: 'End the match at ${score.home.display}–${score.away.display}?',
                      ),
              icon: const Icon(Icons.flag),
              label: const Text('End match'),
            ),
          ],
          if (score.status == MatchStatus.completed)
            const Text('This match is finished. Earlier events can still be corrected from the timeline below.'),
        ],
      ),
    );
  }
}

class _ScoreControls extends StatelessWidget {
  const _ScoreControls({
    required this.sport,
    required this.teams,
    required this.teamId,
    required this.busy,
    required this.onTeam,
    required this.onEvent,
  });

  final SportConfig sport;
  final List<(String, String)> teams;
  final String? teamId;
  final bool busy;
  final ValueChanged<String> onTeam;
  final ValueChanged<ScoringEventDef> onEvent;

  @override
  Widget build(BuildContext context) {
    if (teams.length < 2 || teamId == null) {
      return const Text('Teams for this match are not known yet.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: [
            for (final t in teams)
              ButtonSegment(value: t.$1, label: Text(t.$2, overflow: TextOverflow.ellipsis)),
          ],
          selected: {teamId!},
          onSelectionChanged: (s) => onTeam(s.first),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('${sport.name} events', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final def in sport.scoringEvents)
              ActionChip(
                avatar: const Icon(Icons.add_circle_outline, size: 18),
                label: Text('${def.label} · ${def.describe(sport.scoringModel)}'),
                onPressed: busy ? null : () => onEvent(def),
              ),
          ],
        ),
      ],
    );
  }
}

/// Shared submit flow for scoring and compensation: post online, queue offline,
/// and offer to queue when the server cannot be reached mid-request.
Future<void> submitScoringEvent(
  BuildContext context,
  WidgetRef ref, {
  required ScoreObject score,
  required String type,
  required Json payload,
  required String label,
  required ValueChanged<bool> onBusy,
  required VoidCallback onDone,
}) async {
  final service = ref.read(scoringServiceProvider);
  final body = ScoringService.buildEventBody(matchId: score.matchId, type: type, payload: payload);
  onBusy(true);
  try {
    final outcome = await service.submit(body, observedVersion: score.version, label: label);
    if (!context.mounted) return;
    switch (outcome) {
      case ScoringConfirmed(:final ack, :final replay):
        showSnack(context, replay ? 'Already recorded (#${ack.sequence}).' : 'Recorded as event #${ack.sequence}.');
      case ScoringQueued():
        showSnack(context, 'Saved on this device. It will be sent when you are back online.');
    }
    onDone();
  } on ApiException catch (e) {
    if (!context.mounted) return;
    if (e.isConnectivity) {
      final queue = await confirmAction(
        context,
        title: 'Server unreachable',
        message: '${friendlyError(e)}\n\nSave this event on the device and send it automatically later?',
        confirmLabel: 'Save offline',
      );
      if (queue) {
        await service.queue(body, observedVersion: score.version, label: label);
        if (context.mounted) showSnack(context, 'Saved on this device. It will sync when the server is reachable.');
        onDone();
      }
    } else {
      showSnack(context, friendlyError(e), error: true);
      onDone();
    }
  } finally {
    onBusy(false);
  }
}
