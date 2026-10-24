import 'package:flutter/material.dart';

import '../network/sse_connection.dart';
import '../theme/app_theme.dart';

enum StatusTone { info, success, warning, error, offline }

/// Inline banner for feedback that belongs to one part of a screen: moderation notices, merge
/// state, playback hints. Announced to screen readers as it changes.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.tone,
    required this.message,
    this.title,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.dense = false,
  });

  final StatusTone tone;
  final String message;
  final String? title;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final bool dense;

  static (Color, Color, IconData) palette(StatusTone tone) => switch (tone) {
        StatusTone.info => (
            AppColors.info,
            const Color(0xFFE8F0FC),
            Icons.info_outline
          ),
        StatusTone.success => (
            AppColors.success,
            const Color(0xFFE6F4EA),
            Icons.check_circle_outline
          ),
        StatusTone.warning => (
            AppColors.warning,
            const Color(0xFFFFF1D6),
            Icons.warning_amber_rounded
          ),
        StatusTone.error => (
            AppColors.danger,
            const Color(0xFFFCE8E6),
            Icons.error_outline
          ),
        StatusTone.offline => (
            AppColors.textMuted,
            const Color(0xFFEDEFF3),
            Icons.cloud_off_outlined
          ),
      };

  @override
  Widget build(BuildContext context) {
    final (fg, bg, defaultIcon) = palette(tone);
    final pad = dense ? AppSpacing.sm : AppSpacing.md;
    return Semantics(
      liveRegion: true,
      container: true,
      label: [title, message].whereType<String>().join('. '),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(pad),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppSpacing.radius - 4),
          border: Border.all(color: fg.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
                child: Icon(icon ?? defaultIcon, color: fg, size: 20)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    ExcludeSemantics(
                        child: Text(title!,
                            style: TextStyle(
                                color: fg, fontWeight: FontWeight.w700))),
                  ExcludeSemantics(
                      child: Text(message,
                          style: TextStyle(color: fg, height: 1.3))),
                  if (onAction != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: fg,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm),
                          minimumSize: const Size(48, 40),
                        ),
                        onPressed: onAction,
                        child: Text(actionLabel ?? 'Try again',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, color: fg, size: 18),
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

/// Small pill showing the state of a realtime connection (chat stream, co-stream refresh).
class ConnectionPill extends StatelessWidget {
  const ConnectionPill(
      {super.key, required this.status, this.onRetry, this.onDark = false});

  final RealtimeStatus status;
  final VoidCallback? onRetry;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final (label, color, busy) = switch (status) {
      RealtimeStatus.connecting => ('Connecting', AppColors.textMuted, true),
      RealtimeStatus.live => ('Live', AppColors.success, false),
      RealtimeStatus.reconnecting => ('Reconnecting', AppColors.warning, true),
      RealtimeStatus.offline => ('Offline', AppColors.danger, false),
      RealtimeStatus.failed => ('Unavailable', AppColors.danger, false),
      RealtimeStatus.closed => ('Closed', AppColors.textMuted, false),
    };
    final fg = onDark ? Colors.white : color;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: onDark
            ? Colors.white.withValues(alpha: 0.12)
            : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: onDark ? 0.8 : 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: fg))
          else
            Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
    final retryable = onRetry != null &&
        (status == RealtimeStatus.offline ||
            status == RealtimeStatus.failed ||
            status == RealtimeStatus.reconnecting);
    return Semantics(
      label: 'Connection: $label',
      button: retryable,
      excludeSemantics: true,
      child: retryable
          ? InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: onRetry,
              child: Tooltip(message: 'Reconnect now', child: pill),
            )
          : pill,
    );
  }
}

/// Spinner sized for use inside a button label.
class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key, this.color = Colors.white});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: color));
}
