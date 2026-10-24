import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/auth_models.dart';
import '../../core/models/club_models.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/util/ids.dart';
import '../../core/util/validators.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import 'data/roster_repository.dart';
import 'transfer_service.dart';

class TransferFormScreen extends ConsumerStatefulWidget {
  const TransferFormScreen(
      {super.key,
      required this.leagueId,
      this.initialPlayerId,
      this.initialType});

  final String leagueId;
  final String? initialPlayerId;
  final String? initialType;

  @override
  ConsumerState<TransferFormScreen> createState() => _TransferFormScreenState();
}

class _TransferFormScreenState extends ConsumerState<TransferFormScreen> {
  late TransferType _type;
  String? _playerId;
  String? _toSquadId;
  String? _effectiveDate;
  String? _loanEndDate;
  final _reason = TextEditingController();
  List<String> _errors = const [];
  String? _serverError;
  bool _busy = false;

  /// Generated once per form so a retry after a timeout is idempotent server-side.
  final String _requestId = newId('tr');

  @override
  void initState() {
    super.initState();
    _type = TransferType.values.firstWhere((t) => t.name == widget.initialType,
        orElse: () => TransferType.transfer);
    _playerId = widget.initialPlayerId;
    _effectiveDate = isoDate(DateTime.now());
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<String?> _pickDate(String? current,
      {String? first, String? last}) async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(current ?? '') ?? now;
    final firstDate = DateTime.tryParse(first ?? '') ?? DateTime(now.year - 1);
    final lastDate = DateTime.tryParse(last ?? '') ?? DateTime(now.year + 2);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(firstDate)
          ? firstDate
          : (initial.isAfter(lastDate) ? lastDate : initial),
      firstDate: firstDate,
      lastDate: lastDate,
    );
    return picked == null ? null : isoDate(picked);
  }

  Future<void> _submit(RosterResponse roster, AppUser user, SquadPlayer? player,
      Squad? fromSquad) async {
    setState(() {
      _serverError = null;
      _errors = validateTransferForm(
        type: _type,
        playerId: _playerId,
        fromSquadId: fromSquad?.squadId,
        toSquadId: _toSquadId,
        effectiveDate: _effectiveDate,
        loanEndDate: _loanEndDate,
        reason: _reason.text,
        window: roster.transferWindow,
      );
    });
    if (_errors.isNotEmpty || player == null || fromSquad == null) return;

    final toName = roster.squad(_toSquadId)?.name ?? _toSquadId;
    final summary = switch (_type) {
      TransferType.transfer =>
        'Transfer ${player.name} from ${fromSquad.name} to $toName, effective ${formatDate(_effectiveDate)}?',
      TransferType.loan =>
        'Loan ${player.name} from ${fromSquad.name} to $toName from ${formatDate(_effectiveDate)} until ${formatDate(_loanEndDate)}?',
      TransferType.release =>
        'Release ${player.name} from ${fromSquad.name}, effective ${formatDate(_effectiveDate)}? '
            'The player will no longer be registered to any squad.',
    };
    final ok = await confirmAction(
      context,
      title: 'Confirm ${_type.name}',
      message: summary,
      confirmLabel: 'Submit',
      destructive: _type == TransferType.release,
    );
    if (!ok || !mounted) return;

    final request = TransferRequest(
      requestId: _requestId,
      leagueId: roster.leagueId,
      playerId: player.playerId,
      type: _type,
      fromSquadId: fromSquad.squadId,
      toSquadId: _type == TransferType.release ? null : _toSquadId,
      effectiveDate: _effectiveDate!,
      loanEndDate: _type == TransferType.loan ? _loanEndDate : null,
      reason: _reason.text.trim(),
      requestedBy: user.email,
    );
    final label = '${humanize(_type.name)} ${player.name}'
        '${_type == TransferType.release ? '' : ' → $toName'}';
    final service = ref.read(transferServiceProvider);

    setState(() => _busy = true);
    try {
      final outcome = await service.submit(request, label: label);
      if (!mounted) return;
      _afterSuccess(outcome, roster, player.name);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isConnectivity) {
        final queue = await confirmAction(
          context,
          title: 'Server unreachable',
          message:
              '${friendlyError(e)}\n\nSave this ${_type.name} on the device and send it when you reconnect?',
          confirmLabel: 'Save offline',
        );
        if (queue && mounted) {
          _afterSuccess(
              await service.queue(request, label: label), roster, player.name);
        }
      } else {
        setState(() => _serverError = friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _afterSuccess(
      TransferOutcome outcome, RosterResponse roster, String playerName) {
    ref.read(refreshTickProvider.notifier).state++;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          outcome is TransferQueued
              ? Icons.cloud_upload_outlined
              : Icons.check_circle,
          color:
              outcome is TransferQueued ? AppColors.warning : AppColors.success,
          size: 40,
        ),
        title: Text(switch (outcome) {
          TransferConfirmed(:final response) when response.isDeferred =>
            'Accepted — waiting for match end',
          TransferConfirmed() => 'Done',
          TransferQueued() => 'Saved on this device',
        }),
        content: Text(switch (outcome) {
          TransferConfirmed(:final response, :final replay)
              when response.isDeferred =>
            'The server accepted the ${_type.name} of $playerName, but a squad involved is playing match '
                '${response.blockingMatchId}. The move takes effect automatically when that match ends.'
                '${replay ? '\n\n(This request had already been received.)' : ''}',
          TransferConfirmed(:final response, :final replay) =>
            '$playerName is now ${response.registration?.squadId == null ? 'not registered to a squad' : 'registered to ${roster.squad(response.registration!.squadId)?.name ?? response.registration!.squadId}'}'
                '${response.registration?.parentSquadId != null ? ' on loan from ${roster.squad(response.registration!.parentSquadId)?.name ?? response.registration!.parentSquadId}' : ''}.'
                '${response.auditEntry != null ? '\nAudit ref ${response.auditEntry!.auditId}.' : ''}'
                '${replay ? '\n\n(This request had already been received.)' : ''}',
          TransferQueued() =>
            'You are offline. The ${_type.name} is queued and will be sent automatically when you reconnect. '
                'The server will make the final decision — check Sync status for the result.',
        }),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.pop();
            },
            child: const Text('Back to roster'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).user!;
    final online = ref.watch(syncControllerProvider.select((s) => s.online));
    final async = ref.watch(rosterProvider(widget.leagueId));

    return AppScaffold(
      title: 'Transfer, loan or release',
      body: AsyncBody(
        value: async,
        onRetry: () => ref.invalidate(rosterProvider(widget.leagueId)),
        data: (cached) {
          final roster = cached.data;
          final mySquads = user.role == UserRole.superAdmin
              ? roster.squads
              : roster.squads.where((s) => s.clubId == user.clubId).toList();
          final players = [
            for (final s in mySquads)
              for (final p in s.players) (s, p),
          ];
          final selected =
              players.where((e) => e.$2.playerId == _playerId).firstOrNull;
          final fromSquad = selected?.$1;
          final player = selected?.$2;
          final destinations = roster.squads
              .where((s) => s.squadId != fromSquad?.squadId)
              .toList();
          if (_toSquadId != null &&
              !destinations.any((s) => s.squadId == _toSquadId)) {
            _toSquadId = null;
          }

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (cached.fromCache) ...[
                CachedBanner(cachedAt: cached.cachedAt),
                const SizedBox(height: AppSpacing.md)
              ],
              if (!online)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.md),
                  child: LabelBadge(
                    icon: Icons.cloud_off,
                    text: 'Offline: this will be queued and synced later',
                    color: AppColors.warning,
                  ),
                ),
              SegmentedButton<TransferType>(
                segments: const [
                  ButtonSegment(
                      value: TransferType.transfer,
                      icon: Icon(Icons.swap_horiz),
                      label: Text('Transfer')),
                  ButtonSegment(
                      value: TransferType.loan,
                      icon: Icon(Icons.schedule_send),
                      label: Text('Loan')),
                  ButtonSegment(
                      value: TransferType.release,
                      icon: Icon(Icons.logout),
                      label: Text('Release')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: AppSpacing.lg),
              DropdownButtonFormField<String>(
                value: player?.playerId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Player', prefixIcon: Icon(Icons.person)),
                items: [
                  for (final (s, p) in players)
                    DropdownMenuItem(
                      value: p.playerId,
                      child: Text(
                          '${p.name} · ${p.position.toUpperCase()} · ${s.name}${p.onLoan ? ' (on loan)' : ''}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _playerId = v),
              ),
              const SizedBox(height: AppSpacing.md),
              InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'From squad',
                    prefixIcon: Icon(Icons.shield_outlined)),
                child: Text(fromSquad?.name ?? 'Select a player first'),
              ),
              if (_type != TransferType.release) ...[
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  value: _toSquadId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'To squad', prefixIcon: Icon(Icons.shield)),
                  items: [
                    for (final s in destinations)
                      DropdownMenuItem(
                        value: s.squadId,
                        child: Text(
                            '${s.name} (${s.players.length}/${roster.maxSquadSize})',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _toSquadId = v),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              _DateField(
                label: 'Effective date',
                value: _effectiveDate,
                helper:
                    'Transfer window ${formatDate(roster.transferWindow.open)} – ${formatDate(roster.transferWindow.close)}',
                onTap: () async {
                  final d = await _pickDate(_effectiveDate);
                  if (d != null) setState(() => _effectiveDate = d);
                },
              ),
              if (_type == TransferType.loan) ...[
                const SizedBox(height: AppSpacing.md),
                _DateField(
                  label: 'Loan end date',
                  value: _loanEndDate,
                  helper: 'Must be after the effective date',
                  onTap: () async {
                    final d = await _pickDate(_loanEndDate ?? _effectiveDate,
                        first: _effectiveDate);
                    if (d != null) setState(() => _loanEndDate = d);
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _reason,
                maxLength: 200,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                    labelText: 'Reason', alignLabelWithHint: true),
              ),
              if (_errors.isNotEmpty) _MessageBox(lines: _errors, error: true),
              if (_serverError != null)
                _MessageBox(lines: [_serverError!], error: true),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _submit(roster, user, player, fromSquad),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(online ? Icons.send : Icons.save_alt),
                label:
                    Text(online ? 'Review & submit' : 'Review & save offline'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField(
      {required this.label,
      required this.value,
      required this.onTap,
      this.helper});
  final String label;
  final String? value;
  final String? helper;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixIcon: const Icon(Icons.event),
          suffixIcon: const Icon(Icons.edit_calendar),
        ),
        child: Text(value == null ? 'Choose a date' : formatDate(value)),
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.lines, required this.error});
  final List<String> lines;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.danger : AppColors.info;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: AppSpacing.md),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, color: color, size: 18),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                        child: Text(l,
                            style: TextStyle(
                                color: color, fontWeight: FontWeight.w600))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
