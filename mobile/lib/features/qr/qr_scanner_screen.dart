import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/status_banner.dart';
import 'models/qr_payload.dart';
import 'services/qr_scanner_service.dart';

/// In-app QR scanner. Android uses the camera through `mobile_scanner`. Windows has no supported
/// camera implementation, so it gets a paste-a-link field instead. Both paths use the same parser
/// and open the result through `DeepLinkService`.
class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  MobileScannerController? _camera;
  final _manual = TextEditingController();
  bool _resolving = false;
  String? _lastRaw;
  DateTime? _lastAt;
  String? _error;

  bool get _cameraSupported =>
      ref.read(qrScannerServiceProvider).cameraSupported;

  @override
  void initState() {
    super.initState();
    if (_cameraSupported) {
      _camera = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.qrCode],
      );
    }
  }

  @override
  void dispose() {
    final camera = _camera;
    _camera = null;
    if (camera != null) unawaited(camera.dispose()); // releases the camera
    _manual.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_resolving) return;
    final raw =
        capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    final now = DateTime.now();
    // The camera reports the same code many times per second; act on it once.
    if (raw == _lastRaw &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastRaw = raw;
    _lastAt = now;
    unawaited(_open(raw));
  }

  Future<void> _open(String raw) async {
    if (_resolving) return;
    final payload = QrPayload.parse(raw);
    if (!payload.isValid) {
      setState(() => _error = payload.problem);
      return;
    }
    setState(() {
      _resolving = true;
      _error = null;
    });
    final camera = _camera;
    if (camera != null) {
      await camera.stop(); // no further detections while resolving
    }
    try {
      await ref.read(qrScannerServiceProvider).open(payload);
      // Navigation replaced this screen; dispose() releases the camera.
    } on QrOpenFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.code == 'QR_NOT_FOUND'
            ? describeErrorCode(e.code)
            : 'Could not open the code: ${friendlyError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _resolving = false);
        if (_error != null) unawaited(_restartCamera());
      }
    }
  }

  Future<void> _restartCamera() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      await camera.start();
    } on MobileScannerException catch (e) {
      // Shown by MobileScanner's errorBuilder as well; keep the scan error visible here.
      if (mounted) {
        setState(() => _error =
            '${_error ?? ''} The camera could not restart (${e.errorCode.name}).'
                .trim());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a QR code')),
      body: Semantics(
        label: 'qr-scanner-screen',
        child:
            _camera == null ? _desktopFallback(context) : _cameraView(context),
      ),
    );
  }

  Widget _cameraView(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _camera,
                onDetect: _onDetect,
                errorBuilder: (context, error) => _CameraError(error: error),
                overlayBuilder: (context, constraints) => const _ScanFrame(),
              ),
              if (_resolving)
                const ColoredBox(
                  color: Colors.black54,
                  child: Center(
                      child: CircularProgressIndicator(color: AppColors.lime)),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Point the camera at a LeagueHub QR code on a poster, ticket or screen.',
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  StatusBanner(
                      tone: StatusTone.error,
                      message: _error!,
                      dense: true,
                      onDismiss: () => setState(() => _error = null)),
                ],
                const SizedBox(height: AppSpacing.sm),
                TextButton.icon(
                  onPressed:
                      _resolving ? null : () => _showManualEntry(context),
                  icon: const Icon(Icons.keyboard_alt_outlined),
                  label: const Text('Enter the link instead'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showManualEntry(BuildContext context) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open a LeagueHub link'),
        content: TextField(
          controller: _manual,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'nascon://… or http://…/q/…'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, _manual.text),
              child: const Text('Open')),
        ],
      ),
    );
    if (value != null && mounted) await _open(value);
  }

  Widget _desktopFallback(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.qr_code_2, size: 48, color: AppColors.navy),
                  const SizedBox(height: AppSpacing.md),
                  Text('Open a QR code link',
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Camera scanning is available in the Android app. On this computer, paste the link '
                    'from a LeagueHub QR code (or what a phone scanner read) and open it here.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  TextField(
                    controller: _manual,
                    autofocus: true,
                    enabled: !_resolving,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (v) => _open(v),
                    decoration: const InputDecoration(
                      labelText: 'QR link or code',
                      hintText: 'nascon://entity/match-m1',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    StatusBanner(
                        tone: StatusTone.error, message: _error!, dense: true),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    onPressed: _resolving ? null : () => _open(_manual.text),
                    icon: _resolving
                        ? const ButtonSpinner()
                        : const Icon(Icons.open_in_new),
                    label: const Text('Resolve and open'),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Accepted formats', style: theme.textTheme.labelLarge),
                  const SizedBox(height: AppSpacing.xs),
                  const _Example('nascon://entity/match-m1'),
                  const _Example('nascon://stream/cs-session-101'),
                  const _Example('http://<server>:8080/q/m1-live'),
                  const _Example(
                      'http://<server>:8080/web/matches/match-m1/live'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Example extends StatelessWidget {
  const _Example(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SelectableText(text,
            style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Consolas', 'Roboto Mono', 'Courier New'],
                color: AppColors.textMuted)),
      );
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: LayoutBuilder(builder: (context, c) {
          final side = (c.biggest.shortestSide * 0.65).clamp(160.0, 320.0);
          return Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.lime, width: 4),
              borderRadius: BorderRadius.circular(AppSpacing.radius + 4),
            ),
          );
        }),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: AppColors.navy,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(denied ? Icons.no_photography_outlined : Icons.error_outline,
                  color: AppColors.lime, size: 40),
              const SizedBox(height: AppSpacing.md),
              Text(
                denied ? 'Camera access is off' : 'The camera could not start',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                denied
                    ? 'Allow camera access for LeagueHub in system settings, or enter the link below.'
                    : 'You can still enter the link below. (${error.errorCode.name})',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
