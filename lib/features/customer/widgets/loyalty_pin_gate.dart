import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/app_error.dart';
import '../../../data/models/loyalty_card.dart';
import '../../../data/repositories/loyalty_card_repository.dart';

/// Before the customer spends points in the app (an order with points, a reward): asks for
/// their loyalty PIN when they set one (migration 20261120020000).
///
/// Returns true when the spend may go ahead: no PIN set, or the right PIN (the server then
/// holds a single-use pass for a few minutes). Returns false when the customer cancelled or
/// the PIN was refused. A customer without a PIN never sees anything.
///
/// The server decides either way: without a valid pass it refuses the spend itself, so this
/// is the friendly step, not the protection.
Future<bool> confirmLoyaltyPinIfSet(BuildContext context) async {
  final LoyaltyPinStatus status;
  try {
    status = await LoyaltyCardRepository.instance.fetchPinStatus().timeout(AppErrors.rpcTimeout);
  } catch (caughtError, caughtStack) {
    // Unknown (offline, older server): go ahead; the server still checks.
    AppErrors.report(caughtError, caughtStack, 'loyalty_pin_gate:status');
    return true;
  }
  if (!status.hasPin) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const LoyaltyPinDialog(),
  );
  return ok ?? false;
}

/// "Enter your loyalty PIN" with the server's answer (wrong PIN: tries left; locked: 15 minutes).
class LoyaltyPinDialog extends StatefulWidget {
  const LoyaltyPinDialog({super.key});

  @override
  State<LoyaltyPinDialog> createState() => _LoyaltyPinDialogState();
}

class _LoyaltyPinDialogState extends State<LoyaltyPinDialog> {
  static final _rule = RegExp(r'^\d{4,6}$');
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pin = _pin.text.trim();
    if (!_rule.hasMatch(pin)) {
      setState(() => _error = 'Enter your 4 to 6 digit loyalty PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final problem = await AppErrors.guard(
        () => LoyaltyCardRepository.instance.verifyPin(pin),
        timeout: AppErrors.rpcTimeout,
      );
      if (!mounted) return;
      if (problem == null) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _error = problem;
        _pin.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = AppErrors.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter your loyalty PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('You set a PIN for your points. Enter it to use them.'),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'Loyalty PIN', errorText: _error, counterText: ''),
            onSubmitted: (_) => _busy ? null : _verify(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Continue'),
        ),
      ],
    );
  }
}
