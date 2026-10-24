import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/validators.dart';
import '../cart/controllers/guest_cart_controller.dart';
import 'auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(_email.text, _password.text);
      // Router redirect moves to /home.
    } on ApiException catch (e) {
      setState(() => _error = e.code == 'UNAUTHENTICATED'
          ? 'Incorrect email or password.'
          : friendlyError(e));
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fillDemo(DemoAccount account) {
    setState(() {
      _email.text = account.email;
      _password.text = DemoAccount.password;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final message = ref.watch(authControllerProvider.select((a) => a.message));
    final baseUrl = ref.watch(baseUrlProvider);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.navy,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Brand(),
                  const SizedBox(height: AppSpacing.xl),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Form(
                        key: _formKey,
                        child: AutofillGroup(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('Sign in',
                                  style: theme.textTheme.titleLarge),
                              const SizedBox(height: AppSpacing.lg),
                              if (message != null && _error == null)
                                _Notice(text: message, error: false),
                              if (_error != null)
                                _Notice(text: _error!, error: true),
                              TextFormField(
                                controller: _email,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                  prefixIcon: Icon(Icons.alternate_email),
                                ),
                                validator: validateEmail,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              TextFormField(
                                controller: _password,
                                obscureText: _obscure,
                                autofillHints: const [AutofillHints.password],
                                textInputAction: TextInputAction.done,
                                onFieldSubmitted: (_) => _submit(),
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    tooltip: _obscure
                                        ? 'Show password'
                                        : 'Hide password',
                                    icon: Icon(_obscure
                                        ? Icons.visibility
                                        : Icons.visibility_off),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                validator: validatePassword,
                              ),
                              const SizedBox(height: AppSpacing.lg),
                              FilledButton(
                                onPressed: _busy ? null : _submit,
                                child: _busy
                                    ? const SizedBox(
                                        height: 22,
                                        width: 22,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: Colors.white),
                                      )
                                    : const Text('Sign in'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const _GuestEntry(),
                  const SizedBox(height: AppSpacing.lg),
                  _DemoAccounts(onPick: _fillDemo),
                  const SizedBox(height: AppSpacing.md),
                  TextButton.icon(
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white70),
                    onPressed: () => context.push('/settings'),
                    icon: const Icon(Icons.dns_outlined, size: 18),
                    label: Text('Server: $baseUrl',
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Watching, scanning and staging merchandise need no account.
class _GuestEntry extends ConsumerWidget {
  const _GuestEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count =
        ref.watch(guestCartControllerProvider.select((s) => s.itemCount));
    final style = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white38),
      minimumSize: const Size(48, 48),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('No account needed to watch',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70)),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: style,
                onPressed: () => context.push('/scan'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                style: style,
                onPressed: () => context.push('/guest-cart'),
                icon: const Icon(Icons.shopping_bag_outlined),
                label: Text(count == 0 ? 'Guest cart' : 'Guest cart ($count)'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
              color: AppColors.lime, borderRadius: BorderRadius.circular(20)),
          child: const Icon(Icons.sports_soccer,
              size: 40, color: AppColors.navy, semanticLabel: 'LeagueHub logo'),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppConfig.appName,
          style: Theme.of(context)
              .textTheme
              .headlineMedium
              ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        const Text("powered by NaSCon '26",
            style:
                TextStyle(color: AppColors.lime, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.error});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.danger : AppColors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              Icon(error ? Icons.error_outline : Icons.info_outline,
                  color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                  child: Text(text,
                      style: TextStyle(
                          color: color, fontWeight: FontWeight.w600))),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoAccounts extends StatelessWidget {
  const _DemoAccounts({required this.onPick});
  final ValueChanged<DemoAccount> onPick;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        collapsedIconColor: Colors.white,
        iconColor: AppColors.lime,
        title: const Text('Demo accounts',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: const Text('Tap one to fill in the form',
            style: TextStyle(color: Colors.white70)),
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final a in DemoAccount.all)
                ActionChip(
                  avatar: const Icon(Icons.person, size: 18),
                  label: Text(a.label),
                  onPressed: () => onPick(a),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
