import 'package:flutter/material.dart';

import '../models/league_models.dart';
import '../theme/app_theme.dart';

/// Icon + text pill; colour is decoration only.
class LabelBadge extends StatelessWidget {
  const LabelBadge(
      {super.key,
      required this.icon,
      required this.text,
      required this.color,
      this.background});

  final IconData icon;
  final String text;
  final Color color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class MatchStatusBadge extends StatelessWidget {
  const MatchStatusBadge({super.key, required this.status, this.raw = ''});
  final MatchStatus status;
  final String raw;

  @override
  Widget build(BuildContext context) {
    final label = matchStatusLabel(status, raw);
    return switch (status) {
      MatchStatus.inProgress =>
        LabelBadge(icon: Icons.circle, text: label, color: AppColors.live),
      MatchStatus.completed =>
        LabelBadge(icon: Icons.flag, text: label, color: AppColors.navySoft),
      MatchStatus.upcoming =>
        LabelBadge(icon: Icons.schedule, text: label, color: AppColors.info),
      _ => LabelBadge(
          icon: Icons.pause_circle_outline,
          text: label,
          color: AppColors.warning),
    };
  }
}

class QualificationBadge extends StatelessWidget {
  const QualificationBadge({super.key, required this.status});
  final QualificationStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
        QualificationStatus.clinched => const LabelBadge(
            icon: Icons.verified, text: 'Clinched', color: AppColors.success),
        QualificationStatus.eliminated => const LabelBadge(
            icon: Icons.block, text: 'Eliminated', color: AppColors.danger),
        QualificationStatus.stillPossible => const LabelBadge(
            icon: Icons.trending_up,
            text: 'Still possible',
            color: AppColors.info),
        QualificationStatus.unknown => const LabelBadge(
            icon: Icons.help_outline,
            text: 'Unknown',
            color: AppColors.textMuted),
      };
}

/// Initials avatar used where the backend provides no logo.
class TeamAvatar extends StatelessWidget {
  const TeamAvatar({super.key, required this.name, this.size = 40});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final words =
        name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final initials = words.isEmpty
        ? '?'
        : words.length == 1
            ? words.first
                .substring(0, words.first.length >= 2 ? 2 : 1)
                .toUpperCase()
            : (words[0][0] + words[1][0]).toUpperCase();
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: AppColors.navy,
        child: Text(
          initials,
          style: TextStyle(
              color: AppColors.lime,
              fontWeight: FontWeight.w800,
              fontSize: size * 0.36),
        ),
      ),
    );
  }
}
