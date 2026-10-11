import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/app_text_styles.dart';

/// Camera barcode scanner for the POS. Returns the scanned (or typed) code,
/// or null. The code is matched to `product_variants.sku` by the caller.
/// "Type the code" is the fallback when the camera is unavailable, denied or
/// the label will not scan.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanScreen()));

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final MobileScannerController _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
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
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type the code'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'SKU / barcode'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text), child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    _finish(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan barcode')),
      body: Column(
        children: [
          Expanded(
            child: Semantics(
              label: 'Camera view. Point it at the product barcode.',
              child: MobileScanner(
                controller: _controller,
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
                  Text('Point the camera at the barcode on the pack.', style: AppTextStyles.bodyMd, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _typeCode,
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    label: const Text('Type the code instead'),
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
