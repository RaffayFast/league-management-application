import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/validators.dart';
import '../../core/widgets/status_banner.dart';
import 'auth_controller.dart';

/// Opens the progressive sign-in / registration sheet over the current screen.
///
/// The screen underneath (video, chat, cart) stays mounted, so the viewer keeps their place.
/// Resolves to true once a member session exists.
Future<bool> showProgressiveAuthSheet(BuildContext context,
    {required String reason}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ProgressiveAuthSheet(reason: reason),
  );
  return result ?? false;
}

enum _Mode { signIn, register }

class ProgressiveAuthSheet extends ConsumerStatefulWidget {
  const ProgressiveAuthSheet({super.key, required this.reason});

  /// Why an account is needed, e.g. "Sign in to chat".
  final String reason;

  @override
  ConsumerState<ProgressiveAuthSheet> createState() =>
      _ProgressiveAuthSheetState();
}

class _ProgressiveAuthSheetState extends ConsumerState<ProgressiveAuthSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(authControllerProvider.notifier);
    try {
      if (_mode == _Mode.signIn) {
        await auth.login(_email.text, _password.text);
      } else {
        await auth.register(
            name: _name.text, email: _email.text, password: _password.text);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'UNAUTHENTICATED') {
          _error = 'Incorrect email or password.';
        } else if (e.code == 'USER_EXISTS') {
          _mode = _Mode.signIn;
          _error = describeErrorCode(e.code);
        } else {
          _error = friendlyError(e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final register = _mode == _Mode.register;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.reason, style: theme.textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'You stay on this screen. Your guest cart is kept and can be merged into your account.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SegmentedButton<_Mode>(
                      segments: const [
                        ButtonSegment(
                            value: _Mode.signIn,
                            label: Text('Sign in'),
                            icon: Icon(Icons.login)),
                        ButtonSegment(
                            value: _Mode.register,
                            label: Text('Create account'),
                            icon: Icon(Icons.person_add_alt)),
                      ],
                      selected: {_mode},
                      onSelectionChanged:
                          _busy ? null : (s) => setState(() => _mode = s.first),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (_error != null) ...[
                      StatusBanner(
                          tone: StatusTone.error,
                          message: _error!,
                          dense: true),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (register) ...[
                      TextFormField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        decoration: const InputDecoration(
                            labelText: 'Display name',
                            prefixIcon: Icon(Icons.badge_outlined)),
                        validator: (v) {
                          final t = v?.trim() ?? '';
                          if (t.isEmpty) return 'Enter a display name';
                          if (t.length > 80) return 'Use at most 80 characters';
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.alternate_email)),
                      validator: validateEmail,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      autofillHints: [
                        register
                            ? AutofillHints.newPassword
                            : AutofillHints.password
                      ],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        helperText: register ? '8 to 128 characters' : null,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                          icon: Icon(_obscure
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) {
                        if (!register) return validatePassword(v);
                        final len = v?.length ?? 0;
                        return len < 8 || len > 128
                            ? 'Use 8 to 128 characters'
                            : null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const ButtonSpinner()
                          : Text(register
                              ? 'Create account and continue'
                              : 'Sign in and continue'),
                    ),
                    TextButton(
                      onPressed:
                          _busy ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Not now'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
