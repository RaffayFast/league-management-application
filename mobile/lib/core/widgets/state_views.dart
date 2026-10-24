import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/error_messages.dart';
import '../theme/app_theme.dart';
import '../util/formatters.dart';

/// Grey placeholder blocks shown while loading.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 5, this.height = 84});
  final int count;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, __) => Semantics(
        label: 'Loading',
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFE9ECF1),
            borderRadius: BorderRadius.circular(AppSpacing.radius),
          ),
        ),
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(message!,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.textMuted),
                  textAlign: TextAlign.center),
            ],
            if (onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.refresh),
                  label: Text(actionLabel ?? 'Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => MessageView(
        icon: Icons.error_outline,
        title: 'Could not load this',
        message: friendlyError(error),
        onAction: onRetry,
      );
}

class EmptyView extends StatelessWidget {
  const EmptyView(
      {super.key,
      required this.title,
      this.message,
      this.icon = Icons.inbox_outlined});
  final String title;
  final String? message;
  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      MessageView(icon: icon, title: title, message: message);
}

/// Labels data served from the SQLite cache as possibly stale.
class CachedBanner extends StatelessWidget {
  const CachedBanner({super.key, required this.cachedAt});
  final DateTime? cachedAt;

  @override
  Widget build(BuildContext context) {
    final age = cachedAt == null ? '' : ' · saved ${relativeAge(cachedAt!)}';
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: const Color(0xFFFFF1D6),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        child: Row(
          children: [
            const Icon(Icons.history, size: 18, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'Offline copy$age — may be out of date',
                style: const TextStyle(
                    color: AppColors.warning, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AsyncValue switch with consistent loading / error UI.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody(
      {super.key,
      required this.value,
      required this.data,
      this.onRetry,
      this.skeletonCount = 5});

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;
  final int skeletonCount;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: data,
      loading: () => SkeletonList(count: skeletonCount),
      error: (e, _) => ErrorView(error: e, onRetry: onRetry),
    );
  }
}
