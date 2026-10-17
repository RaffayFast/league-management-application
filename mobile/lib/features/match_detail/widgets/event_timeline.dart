import 'package:flutter/material.dart';

import '../../../core/models/match_models.dart';
import '../../../core/sync/pending_action.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/formatters.dart';
import '../../../core/widgets/badges.dart';

/// Chronological event log. Compensated events stay visible (append-only) but
/// are struck through and labelled.
class EventTimeline extends StatelessWidget {
  const EventTimeline({
    super.key,
    required this.score,
    required this.pending,
    this.onCorrect,
  });

  final ScoreObject score;
  final List<PendingAction> pending;
  final void Function(MatchEvent event)? onCorrect;

  String _title(MatchEvent e) {
    final team = score.teamName(e.teamId);
    switch (e.type) {
      case 'match_init':
        return 'Match set up';
      case 'match_start':
        return 'Match started';
      case 'match_end':
        return 'Match ended';
      case 'score':
        return '${humanize(e.eventType ?? 'score')} — $team';
      case 'discipline':
        return 'Discipline — $team (${e.payload['points'] ?? ''})';
      case 'tiebreak_winner':
        return 'Tiebreak won by $team';
      case 'compensation':
        final target = score.events.where((x) => x.eventId == e.compensates).firstOrNull;
        final reason = e.payload['reason'];
        return 'Correction of #${target?.sequence ?? e.compensates}${reason is String && reason.isNotEmpty ? ' — $reason' : ''}';
      default:
        return humanize(e.type);
    }
  }

  IconData _icon(String type) => switch (type) {
        'match_init' => Icons.settings_outlined,
        'match_start' => Icons.play_circle_outline,
        'match_end' => Icons.flag_outlined,
        'score' => Icons.sports_score,
        'discipline' => Icons.style_outlined,
        'tiebreak_winner' => Icons.emoji_events_outlined,
        'compensation' => Icons.undo,
        _ => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) {
    if (score.events.isEmpty && pending.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text('No events yet.', style: TextStyle(color: AppColors.textMuted)),
      );
    }
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final e in score.events)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: e.compensated ? const Color(0xFFEDEFF3) : AppColors.navy,
              child: Icon(_icon(e.type), color: e.compensated ? AppColors.textMuted : AppColors.lime, size: 20),
            ),
            title: Text(
              _title(e),
              style: theme.textTheme.bodyLarge?.copyWith(
                decoration: e.compensated ? TextDecoration.lineThrough : null,
                color: e.compensated ? AppColors.textMuted : null,
              ),
            ),
            subtitle: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('#${e.sequence}'),
                if (e.compensated)
                  const LabelBadge(icon: Icons.undo, text: 'Corrected', color: AppColors.warning),
              ],
            ),
            trailing: onCorrect != null && e.isCompensatable
                ? TextButton(onPressed: () => onCorrect!(e), child: const Text('Correct'))
                : null,
          ),
        for (final a in pending)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: const Color(0xFFFFF1D6),
              child: Icon(a.state == PendingState.rejected ? Icons.error_outline : Icons.schedule,
                  color: AppColors.warning, size: 20),
            ),
            title: Text(a.label),
            subtitle: Text(a.state == PendingState.rejected
                ? 'Rejected by server — see Sync status'
                : 'Saved on this device · waiting to sync'),
          ),
      ],
    );
  }
}
