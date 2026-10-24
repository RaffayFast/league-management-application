import 'package:flutter/material.dart';

import '../../../core/models/club_models.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/formatters.dart';
import '../../../core/widgets/badges.dart';

/// Immutable audit trail from GET /api/v1/roster/history/{player_id}.
class HistoryList extends StatelessWidget {
  const HistoryList(
      {super.key, required this.history, required this.squadName});

  final RosterHistory history;
  final String Function(String?) squadName;

  @override
  Widget build(BuildContext context) {
    if (history.history.isEmpty) {
      return Text('No moves recorded as of ${formatDate(history.asOf)}.',
          style: const TextStyle(color: AppColors.textMuted));
    }

    // The server reports the squad as of `as_of`; a loan that has ended shows
    // the player back at the lending squad with no parent.
    final lastLoan =
        history.history.where((e) => e.action == 'loan').lastOrNull;
    final loanReturned = lastLoan != null &&
        history.parentSquadId == null &&
        history.currentSquadId == lastLoan.fromSquadId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (loanReturned)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: LabelBadge(
              icon: Icons.keyboard_return,
              text: 'Loan ended — back at ${squadName(lastLoan.fromSquadId)}',
              color: AppColors.info,
            ),
          ),
        for (final e in history.history.reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: AppColors.navy,
              child: Icon(
                switch (e.action) {
                  'loan' => Icons.schedule_send,
                  'release' => Icons.logout,
                  _ => Icons.swap_horiz,
                },
                color: AppColors.lime,
                size: 20,
              ),
            ),
            title: Text(switch (e.action) {
              'release' => 'Released from ${squadName(e.fromSquadId)}',
              'loan' =>
                'Loaned ${squadName(e.fromSquadId)} → ${squadName(e.toSquadId)}',
              _ =>
                'Transferred ${squadName(e.fromSquadId)} → ${squadName(e.toSquadId)}',
            }),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Effective ${formatDate(e.effectiveDate)} · by ${e.who}'),
                if (e.why.isNotEmpty) Text('Reason: ${e.why}'),
                if (e.state == 'deferred_until_match_end')
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: LabelBadge(
                        icon: Icons.hourglass_top,
                        text: 'Waits for match end',
                        color: AppColors.warning),
                  ),
              ],
            ),
            isThreeLine: true,
          ),
      ],
    );
  }
}
