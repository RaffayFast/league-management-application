import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/league_models.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/formatters.dart';
import '../../../core/widgets/badges.dart';

class FixtureCard extends StatelessWidget {
  const FixtureCard({super.key, required this.fixture, this.leagueName});

  final Fixture fixture;
  final String? leagueName;

  @override
  Widget build(BuildContext context) {
    final f = fixture;
    final showScore =
        f.status == MatchStatus.inProgress || f.status == MatchStatus.completed;
    final theme = Theme.of(context);

    return Semantics(
      button: true,
      label:
          '${f.homeLabel} versus ${f.awayLabel}, ${matchStatusLabel(f.status, f.statusRaw)}'
          '${showScore ? ', score ${f.homeScore} to ${f.awayScore}' : ''}. Open match.',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/match/${Uri.encodeComponent(f.matchId)}'),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      MatchStatusBadge(status: f.status, raw: f.statusRaw),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          leagueName != null
                              ? '$leagueName · ${formatKickoff(f.scheduledAt)}'
                              : formatKickoff(f.scheduledAt),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.textMuted),
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _TeamLine(
                      name: f.homeLabel,
                      score: showScore ? '${f.homeScore}' : null,
                      leading: f.homeScore > f.awayScore &&
                          f.status == MatchStatus.completed),
                  const SizedBox(height: AppSpacing.sm),
                  _TeamLine(
                      name: f.awayLabel,
                      score: showScore ? '${f.awayScore}' : null,
                      leading: f.awayScore > f.homeScore &&
                          f.status == MatchStatus.completed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TeamLine extends StatelessWidget {
  const _TeamLine({required this.name, this.score, this.leading = false});
  final String name;
  final String? score;
  final bool leading;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: leading ? FontWeight.w800 : FontWeight.w600,
        );
    return Row(
      children: [
        TeamAvatar(name: name, size: 28),
        const SizedBox(width: AppSpacing.md),
        Expanded(
            child: Text(name, style: style, overflow: TextOverflow.ellipsis)),
        if (score != null)
          Text(score!,
              style: style?.copyWith(
                  fontSize: 20,
                  fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}
