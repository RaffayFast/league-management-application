import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/models/json.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/dialogs.dart';
import '../auth/auth_controller.dart';

/// Validates a server address typed by the user. Returns an error or null.
String? validateServerUrl(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return 'Enter the server address';
  final uri = Uri.tryParse(value);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
    return 'Use a full address such as http://192.168.43.102:8080';
  }
  return null;
}

class ServerSettingsScreen extends ConsumerStatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  ConsumerState<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen> {
  late final TextEditingController _url;
  final _formKey = GlobalKey<FormState>();
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: ref.read(baseUrlProvider));
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _result = null;
    });
    final client = ApiClient(baseUrl: _url.text, tokenProvider: () => null);
    try {
      final data = await client.get('/health', auth: false);
      final status = asMap(data)['status'];
      setState(() {
        _resultOk = status == 'ok';
        _result = _resultOk
            ? 'Connected. The server is ready.'
            : 'The server answered but is not ready yet (status: ${status ?? 'unknown'}).';
      });
    } on ApiException catch (e) {
      setState(() {
        _resultOk = false;
        _result = e.statusCode == 404
            ? 'Something answered at that address, but it is not the LeagueHub server.'
            : friendlyError(e);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final next = ApiClient.normalizeBaseUrl(_url.text);
    final current = ref.read(baseUrlProvider);
    if (next == current) {
      showSnack(context, 'Server address unchanged.');
      return;
    }
    final signedIn = ref.read(authControllerProvider).status == AuthStatus.signedIn;
    if (signedIn) {
      final ok = await confirmAction(
        context,
        title: 'Change server?',
        message: 'You will be signed out, because sessions belong to one server. '
            'Cached data is cleared; queued offline actions are kept.',
        confirmLabel: 'Change & sign out',
      );
      if (!ok) return;
    }
    await ref.read(settingsStoreProvider).setBaseUrl(next);
    await ref.read(cacheStoreProvider).clear();
    ref.read(baseUrlProvider.notifier).state = next;
    if (signedIn) {
      await ref.read(authControllerProvider.notifier).logout(message: 'Server changed to $next. Please sign in.');
    }
    if (mounted) showSnack(context, 'Server address saved.');
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Server settings',
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Form(
            key: _formKey,
            child: TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Server address', prefixIcon: Icon(Icons.dns_outlined)),
              validator: validateServerUrl,
              onChanged: (_) => setState(() => _result = null),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Android emulator: http://10.0.2.2:8080\n'
            'Phone on the same Wi-Fi/hotspot: http://<laptop LAN IP>:8080 (run ipconfig on the laptop).',
            style: TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check),
                  label: const Text('Test connection'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save')),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: AppSpacing.md),
            Semantics(
              liveRegion: true,
              child: Card(
                child: ListTile(
                  leading: Icon(_resultOk ? Icons.check_circle : Icons.error_outline,
                      color: _resultOk ? AppColors.success : AppColors.danger),
                  title: Text(_result!),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          TextButton(
            onPressed: () => setState(() => _url.text = AppConfig.defaultBaseUrl),
            child: const Text('Reset to emulator default'),
          ),
        ],
      ),
    );
  }
}
