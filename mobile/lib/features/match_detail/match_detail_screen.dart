import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/league_models.dart';
import '../../core/models/match_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import '../auth/permissions.dart';
import 'match_controller.dart';
import 'widgets/event_timeline.dart';
import 'widgets/scoring_panel.dart';

class MatchDetailScreen extends ConsumerWidget {
  const MatchDetailScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(matchControllerProvider(matchId));
    final controller = ref.read(matchControllerProvider(matchId).notifier);
    final user = ref.watch(authControllerProvider).user;

    return AppScaffold(
      title: 'Match',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: controller.refresh),
      ],
      body: AsyncBody(
        value: async,
        onRetry: controller.refresh,
        data: (cached) {
          final score = cached.data;
          final canScore = Permissions.canScore(user, score.leagueId);
          final pending = ref.watch(pendingForTargetProvider(matchId)).valueOrNull ?? const [];

          Future<void> correct(MatchEvent e) async {
            final reason = await _askReason(context, score, e);
            if (reason == null || !context.mounted) return;
            await submitScoringEvent(
              context,
              ref,
              score: score,
              type: 'compensation',
              payload: {'compensates': e.eventId, 'reason': reason},
              label: 'Correction of #${e.sequence} · ${score.matchId}',
              onBusy: (_) {},
              onDone: controller.refresh,
            );
          }

          return RefreshIndicator(
            onRefresh: controller.refresh,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                if (cached.fromCache) ...[CachedBanner(cachedAt: cached.cachedAt), const SizedBox(height: AppSpacing.md)],
                _ScoreHeader(score: score, live: controller.polling),
                const SizedBox(height: AppSpacing.md),
                _InfoLinks(score: score),
                if (score.pinnedProduct != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _PinnedProductCard(product: score.pinnedProduct!),
                ],
                if (canScore) ...[
                  const SizedBox(height: AppSpacing.md),
                  ScoringPanel(score: score, onChanged: controller.refresh),
                ],
                const SizedBox(height: AppSpacing.md),
                SectionCard(
                  title: 'Timeline',
                  icon: Icons.timeline,
                  child: EventTimeline(score: score, pending: pending, onCorrect: canScore ? correct : null),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<String?> _askReason(BuildContext context, ScoreObject score, MatchEvent e) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Correct event #${e.sequence}?'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A compensating event will cancel "${humanize(e.eventType ?? e.type)}" for '
                '${score.teamName(e.teamId)}. The original stays in the log.',
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Reason'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a reason' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, controller.text.trim());
            },
            child: const Text('Submit correction'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

class _ScoreHeader extends StatelessWidget {
  const _ScoreHeader({required this.score, required this.live});
  final ScoreObject score;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scoreStyle = theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800);
    String outcomeText() {
      if (score.status != MatchStatus.completed) return '';
      return switch (score.outcome) {
        'draw' => 'Draw',
        'undecided' => 'Result undecided',
        _ => '${score.teamName(score.winnerTeamId)} won'
            '${score.tiebreakWinnerTeamId != null ? ' on tiebreak' : ''}',
      };
    }

    return Semantics(
      label: '${score.homeLabel} ${score.home.display}, ${score.awayLabel} ${score.away.display}. '
          '${matchStatusLabel(score.status, score.statusRaw)}. ${outcomeText()}',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(color: AppColors.navy, borderRadius: BorderRadius.circular(AppSpacing.radius)),
        child: ExcludeSemantics(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  MatchStatusBadge(status: score.status, raw: score.statusRaw),
                  if (live) ...[
                    const SizedBox(width: AppSpacing.sm),
                    const LabelBadge(icon: Icons.autorenew, text: 'Auto-updating', color: AppColors.lime, background: AppColors.navySoft),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _Side(name: score.homeLabel, label: 'Home')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    child: FittedBox(
                      child: Text('${score.home.display}  –  ${score.away.display}', style: scoreStyle),
                    ),
                  ),
                  Expanded(child: _Side(name: score.awayLabel, label: 'Away')),
                ],
              ),
              if (outcomeText().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text(outcomeText(), style: const TextStyle(color: AppColors.lime, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: AppSpacing.sm),
              Text('Version ${score.version} · ${score.matchId}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.name, required this.label});
  final String name;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TeamAvatar(name: name, size: 48),
        const SizedBox(height: AppSpacing.sm),
        Text(name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ],
    );
  }
}

class _InfoLinks extends StatelessWidget {
  const _InfoLinks({required this.score});
  final ScoreObject score;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.sports),
            title: Text(score.sportId == null ? 'Sport not set' : humanize(score.sportId!)),
            subtitle: Text(score.leagueId == null ? 'Friendly / no league' : 'League ${score.leagueId}'),
          ),
          if (score.leagueId != null)
            ListTile(
              leading: const Icon(Icons.leaderboard_outlined),
              title: const Text('League standings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/standings?league=${Uri.encodeComponent(score.leagueId!)}'),
            ),
          for (final (id, name) in [(score.home.teamId, score.homeLabel), (score.away.teamId, score.awayLabel)])
            if (id != null)
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: Text('$name club profile'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/club/${Uri.encodeComponent(id)}'),
              ),
        ],
      ),
    );
  }
}

class _PinnedProductCard extends StatelessWidget {
  const _PinnedProductCard({required this.product});
  final PinnedProduct product;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFF4FBE4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        leading: const CircleAvatar(
          backgroundColor: AppColors.navy,
          child: Icon(Icons.checkroom, color: AppColors.lime),
        ),
        title: Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('Match-day pick · ${formatMoney(product.priceMinor, product.currency)}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/product/${Uri.encodeComponent(product.productId)}'),
      ),
    );
  }
}
