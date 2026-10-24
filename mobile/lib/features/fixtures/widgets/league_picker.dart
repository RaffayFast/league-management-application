import 'package:flutter/material.dart';

import '../../../core/models/league_models.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/formatters.dart';

/// Sport chips (derived from the leagues the server returns) + league dropdown.
class LeaguePicker extends StatelessWidget {
  const LeaguePicker({
    super.key,
    required this.leagues,
    required this.selectedLeagueId,
    required this.onLeagueChanged,
    this.selectedSport,
    this.onSportChanged,
  });

  final List<League> leagues;
  final String? selectedLeagueId;
  final ValueChanged<String> onLeagueChanged;
  final String? selectedSport;
  final ValueChanged<String?>? onSportChanged;

  @override
  Widget build(BuildContext context) {
    final sports = leagues.map((l) => l.sportId).toSet().toList()..sort();
    final visible = selectedSport == null
        ? leagues
        : leagues.where((l) => l.sportId == selectedSport).toList();
    final value = visible.any((l) => l.leagueId == selectedLeagueId)
        ? selectedLeagueId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onSportChanged != null && sports.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All sports'),
                  selected: selectedSport == null,
                  onSelected: (_) => onSportChanged!(null),
                ),
                for (final s in sports) ...[
                  const SizedBox(width: AppSpacing.sm),
                  ChoiceChip(
                    label: Text(humanize(s)),
                    selected: selectedSport == s,
                    onSelected: (_) => onSportChanged!(s),
                  ),
                ],
              ],
            ),
          ),
        if (onSportChanged != null && sports.length > 1)
          const SizedBox(height: AppSpacing.sm),
        DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(
              labelText: 'League',
              prefixIcon: Icon(Icons.emoji_events_outlined)),
          items: [
            for (final l in visible)
              DropdownMenuItem(
                  value: l.leagueId,
                  child: Text('${l.name} · ${humanize(l.sportId)}',
                      overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            if (v != null) onLeagueChanged(v);
          },
        ),
      ],
    );
  }
}
