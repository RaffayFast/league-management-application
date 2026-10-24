import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/sse_connection.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/status_banner.dart';
import '../../auth/auth_controller.dart';
import '../../auth/progressive_auth_sheet.dart';
import '../controllers/live_chat_controller.dart';
import '../models/chat_message.dart';
import '../models/moderation_result.dart';

/// Live chat for a match (`chat-<match_id>`) or co-stream (`chat-<session_id>`).
///
/// Messages come from the server stream only, so everything in the list passed moderation.
/// The viewer's own unconfirmed messages are listed apart, marked as not yet sent.
class LiveChatPanel extends ConsumerStatefulWidget {
  const LiveChatPanel(
      {super.key, required this.roomId, this.title = 'Live chat'});

  final String roomId;
  final String title;

  @override
  ConsumerState<LiveChatPanel> createState() => _LiveChatPanelState();
}

class _LiveChatPanelState extends ConsumerState<LiveChatPanel> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final ok =
        await showProgressiveAuthSheet(context, reason: 'Sign in to chat');
    if (ok && mounted) {
      ref
          .read(liveChatControllerProvider(widget.roomId).notifier)
          .dismissNotice();
      _focus.requestFocus();
    }
  }

  Future<void> _send() async {
    if (_sending) return;
    final signedIn =
        ref.read(authControllerProvider).status == AuthStatus.signedIn;
    final controller =
        ref.read(liveChatControllerProvider(widget.roomId).notifier);
    setState(() => _sending = true);
    final result = await controller.send(_input.text, signedIn: signedIn);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case SendResult.sent:
      case SendResult.unconfirmed:
        _input.clear();
      case SendResult.needsAuth:
        await _signIn();
      case SendResult.rejected:
      case SendResult.invalid:
        break; // keep the text so it can be edited
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveChatControllerProvider(widget.roomId));
    final controller =
        ref.read(liveChatControllerProvider(widget.roomId).notifier);
    final auth = ref.watch(authControllerProvider);
    final signedIn = auth.status == AuthStatus.signedIn;
    final me = auth.user?.userId;
    final theme = Theme.of(context);

    return Semantics(
      label: 'live-chat ${widget.roomId}',
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
              child: Row(
                children: [
                  const Icon(Icons.forum_outlined,
                      color: AppColors.navySoft, size: 20),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                      child: Text(widget.title,
                          style: theme.textTheme.titleMedium)),
                  ConnectionPill(
                      status: state.connection, onRetry: controller.reconnect),
                ],
              ),
            ),
            if (state.connectionError != null &&
                state.connection != RealtimeStatus.live)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: StatusBanner(
                  tone: StatusTone.offline,
                  dense: true,
                  message: 'Chat updates paused: ${state.connectionError}',
                  actionLabel: 'Reconnect',
                  onAction: controller.reconnect,
                ),
              ),
            const Divider(height: 1),
            Expanded(child: _MessageList(messages: state.messages, me: me)),
            if (state.outgoing.isNotEmpty) ...[
              const Divider(height: 1),
              for (final o in state.outgoing)
                _OutgoingTile(
                  message: o,
                  onRetry: () => controller.retry(o.messageId),
                  onDiscard: () => controller.discard(o.messageId),
                ),
            ],
            if (state.notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: StatusBanner(
                  tone: state.notice!.tone,
                  dense: true,
                  message: state.notice!.message,
                  actionLabel: state.notice!.requiresAuth ? 'Sign in' : null,
                  onAction: state.notice!.requiresAuth ? _signIn : null,
                  onDismiss: controller.dismissNotice,
                ),
              ),
            if (state.restriction != SenderRestriction.none &&
                state.notice == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: StatusBanner(
                  tone: StatusTone.warning,
                  dense: true,
                  message: switch (state.restriction) {
                    SenderRestriction.kicked =>
                      'Moderation removed you from posting in this chat.',
                    SenderRestriction.muted => 'You are muted in this chat.',
                    _ => 'Moderation is blocking your messages in this chat.',
                  },
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: signedIn ? _composer() : _signInPrompt(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _signInPrompt() => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style:
              OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _signIn,
          icon: const Icon(Icons.login),
          label: const Text('Sign in to chat'),
        ),
      );

  Widget _composer() => Row(
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _send
              },
              child: TextField(
                controller: _input,
                focusNode: _focus,
                maxLength: LiveChatController.maxLength,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Say something',
                  counterText: '',
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            height: 48,
            width: 48,
            child: IconButton.filled(
              tooltip: 'Send message',
              onPressed: _sending ? null : _send,
              icon: _sending ? const ButtonSpinner() : const Icon(Icons.send),
            ),
          ),
        ],
      );
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.messages, required this.me});
  final List<ChatMessage> messages;
  final String? me;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text('No messages yet. Be the first to cheer!',
              style: TextStyle(color: AppColors.textMuted)),
        ),
      );
    }
    // Reversed so the newest message stays in view as messages arrive.
    return Semantics(
      label: 'chat-message-list',
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        itemCount: messages.length,
        itemBuilder: (_, i) {
          final m = messages[messages.length - 1 - i];
          return _MessageTile(
              key: ValueKey(m.messageId),
              message: m,
              mine: me != null && m.sender == me);
        },
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({super.key, required this.message, required this.mine});
  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final time = message.sentAt == null
        ? ''
        : DateFormat.Hm().format(message.sentAt!.toLocal());
    final name = mine ? 'You' : message.sender;
    final masked = message.moderation == ModerationStatus.masked;
    return Semantics(
      label:
          '$name${time.isEmpty ? '' : ' at $time'}: ${message.text}${masked ? '. Moderated' : ''}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TeamAvatar(name: name, size: 32),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(name,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: mine ? AppColors.limeDeep : AppColors.navy,
                          )),
                      if (time.isNotEmpty)
                        Text(time,
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 12)),
                      if (masked)
                        const LabelBadge(
                          icon: Icons.shield_outlined,
                          text: 'Moderated',
                          color: AppColors.warning,
                          background: Color(0xFFFFF1D6),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(message.text),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutgoingTile extends StatelessWidget {
  const _OutgoingTile(
      {required this.message, required this.onRetry, required this.onDiscard});
  final OutgoingChatMessage message;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final sending = message.state == OutgoingState.sending;
    return Semantics(
      liveRegion: true,
      label: sending
          ? 'Sending for moderation: ${message.text}'
          : 'Not confirmed: ${message.text}',
      excludeSemantics: true,
      child: Container(
        color: const Color(0xFFF7F8FA),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
        child: Row(
          children: [
            if (sending)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              const Icon(Icons.cloud_off_outlined,
                  size: 18, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      sending
                          ? 'Sending… waiting for moderation'
                          : 'Not confirmed',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color:
                            sending ? AppColors.textMuted : AppColors.warning,
                      )),
                  Text(message.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted,
                          fontStyle: FontStyle.italic)),
                  if (message.error != null)
                    Text(message.error!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                ],
              ),
            ),
            if (!sending) ...[
              TextButton(onPressed: onRetry, child: const Text('Retry')),
              IconButton(
                  tooltip: 'Discard',
                  onPressed: onDiscard,
                  icon: const Icon(Icons.close, size: 18)),
            ],
          ],
        ),
      ),
    );
  }
}
