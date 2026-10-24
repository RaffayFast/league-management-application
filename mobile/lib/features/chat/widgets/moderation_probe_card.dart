import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/status_banner.dart';
import '../models/moderation_result.dart';
import '../services/live_chat_service.dart';

/// Diagnostic card for `POST /audit/v1/moderation/test`, the documented moderation probe.
///
/// It sends sample messages from made-up senders to a new throwaway room, so the kick and mute
/// decisions it records never affect a real room or account. Live chat never uses this route.
class ModerationProbeCard extends ConsumerStatefulWidget {
  const ModerationProbeCard({super.key});

  @override
  ConsumerState<ModerationProbeCard> createState() =>
      _ModerationProbeCardState();
}

class _ModerationProbeCardState extends ConsumerState<ModerationProbeCard> {
  static const _samples = [
    ('probe-fan-1', 'What a goal, well played!'),
    ('probe-fan-2', 'the ref is a b@dw0rd'),
    ('probe-fan-3', 'goooooal'),
  ];

  final _custom = TextEditingController();
  bool _running = false;
  ModerationProbeResult? _result;
  String? _error;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    final room = 'chat-probe-${Random().nextInt(1 << 32).toRadixString(16)}';
    final custom = _custom.text.trim();
    try {
      final result = await ref.read(liveChatServiceProvider).probe(
        roomId: room,
        messages: [..._samples, if (custom.isNotEmpty) ('probe-fan-4', custom)],
      );
      if (mounted) setState(() => _result = result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SectionCard(
      title: 'Chat moderation check',
      icon: Icons.shield_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Asks the server how its moderation judges sample messages, using a throwaway room. '
            'Nothing is posted to any chat.',
            style: TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final (_, text) in _samples)
            Text('• $text',
                style: const TextStyle(fontStyle: FontStyle.italic)),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _custom,
            maxLength: 200,
            decoration: const InputDecoration(
                labelText: 'Add your own test message (optional)',
                counterText: ''),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const ButtonSpinner(color: AppColors.navy)
                : const Icon(Icons.play_arrow),
            label: const Text('Run moderation check'),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            StatusBanner(tone: StatusTone.error, dense: true, message: _error!),
          ],
          if (r != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text('Room ${r.roomId}',
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            for (final m in r.filtered)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    m.flagged ? Icons.shield : Icons.check_circle_outline,
                    color: m.flagged ? AppColors.warning : AppColors.success),
                title: Text(m.text),
                subtitle: Text(
                    '${m.sender}${m.flagged ? ' · masked (${m.reason})' : ' · would be broadcast unchanged'}'),
              ),
            Text(
                'Kicked: ${r.kickedUsers.isEmpty ? 'nobody' : r.kickedUsers.join(', ')}'),
            Text(
                'Muted (flood, never broadcast): ${r.mutedUsers.isEmpty ? 'nobody' : r.mutedUsers.join(', ')}'),
            Text('Notification dead-letter queue: ${r.dlqDepth} event(s)'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Server signature ${r.signature.length > 16 ? '${r.signature.substring(0, 16)}…' : r.signature}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
