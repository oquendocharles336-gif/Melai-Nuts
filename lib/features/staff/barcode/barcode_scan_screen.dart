import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/services/permission_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Camera barcode scanner for the POS. Returns the scanned (or typed) code,
/// or null. The code is matched to `product_variants.sku` by the caller.
/// "Type the code" is the fallback when the camera is unavailable, denied or
/// the label will not scan.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  /// Explains why the camera is needed (first time / after a denial), then
  /// opens the scanner. "Not now" goes straight to typing the code by hand.
  static Future<String?> open(BuildContext context) async {
    final go = await PermissionService.instance.beforeCamera(context, PermissionPurpose.scanBarcode);
    if (!context.mounted) return null;
    if (!go) return typeCodeDialog(context);
    return Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanScreen()));
  }

  /// Manual SKU / barcode entry: letters, digits, ".", "-" and "_", max 64.
  static Future<String?> typeCodeDialog(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();
    void submit(BuildContext ctx) {
      if (formKey.currentState?.validate() ?? false) Navigator.of(ctx).pop(controller.text.trim());
    }

    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.typeTheCode),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            keyboardType: TextInputType.visiblePassword, // no autocorrect on codes
            autocorrect: false,
            inputFormatters: InputRules.sku(),
            decoration: const InputDecoration(labelText: 'SKU / barcode', counterText: ''),
            validator: (v) => ValidationUtils.validateSku(v, fieldName: 'SKU / barcode'),
            onFieldSubmitted: (_) => submit(ctx),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(t.cancel)),
          FilledButton(onPressed: () => submit(ctx), child: Text(t.add)),
        ],
      ),
    );
    disposeAfterDialog([controller]);
    return code;
  }

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final MobileScannerController _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;
  bool _grantNoted = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScannerState);
  }

  // The camera is running, so permission is granted: forget any old denial.
  void _onScannerState() {
    if (_grantNoted || !_controller.value.isRunning) return;
    _grantNoted = true;
    PermissionService.instance.cameraGranted();
  }

  @override
  void dispose() {
    _controller.removeListener(_onScannerState);
    _controller.dispose();
    super.dispose();
  }

  void _finish(String? code) {
    if (_done || !mounted) return;
    final value = code?.trim();
    if (value == null || value.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(value);
  }

  Future<void> _typeCode() async {
    final code = await BarcodeScanScreen.typeCodeDialog(context);
    _finish(code);
  }

  bool _deniedHandled = false;

  /// The camera could not start. Permission refused: explain, offer Open
  /// Settings / Try again, and keep "Type the code" as the fallback.
  Widget _cameraError(BuildContext context, MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    if (denied && !_deniedHandled) {
      _deniedHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final retry = await PermissionService.instance.cameraDenied(context, PermissionPurpose.scanBarcode);
        if (retry && mounted) {
          _deniedHandled = false;
          await _controller.start();
        }
      });
    }
    final t = AppLocalizations.of(context);
    return ColoredBox(
      color: AppColors.surfaceContainer,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: AppSpacing.sm),
              if (denied) ...[
                Text(
                  t.permDeniedTitle(t.permCameraTitle),
                  style: AppTextStyles.titleMd,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(t.permCameraScanFallback, style: AppTextStyles.bodyMd, textAlign: TextAlign.center),
              if (denied) ...[
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: PermissionService.instance.openAppSettings,
                  child: Text(t.permOpenSettings),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.scanBarcode)),
      body: Column(
        children: [
          Expanded(
            child: Semantics(
              label: t.cameraViewLabel,
              child: MobileScanner(
                controller: _controller,
                errorBuilder: _cameraError,
                onDetect: (capture) {
                  for (final b in capture.barcodes) {
                    if ((b.rawValue ?? '').trim().isNotEmpty) {
                      _finish(b.rawValue);
                      return;
                    }
                  }
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.scanHint, style: AppTextStyles.bodyMd, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _typeCode,
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    label: Text(t.typeCodeInstead),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
