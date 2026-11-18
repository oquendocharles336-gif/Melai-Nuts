import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/auth_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/phone_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/repositories/phone_verification_repository.dart';

enum _Step { number, code }

/// Verifies the signed-in customer's mobile number with an SMS code.
///
/// Checkout needs a verified number (migration 20261118040000): it is the
/// contact number for pickup, and the first-order rule keys on it, so a new
/// account cannot pass as a paying customer by typing that customer's number.
/// Firebase sends and checks the code and links the number to this account;
/// the database then reads it from the refreshed sign-in token.
///
/// Pops `true` once the number is verified and saved.
class VerifyPhoneScreen extends StatefulWidget {
  const VerifyPhoneScreen({super.key, this.initialNumber});

  /// Pre-filled number (e.g. the profile's contact number), local or E.164.
  final String? initialNumber;

  @override
  State<VerifyPhoneScreen> createState() => _VerifyPhoneScreenState();
}

class _VerifyPhoneScreenState extends State<VerifyPhoneScreen> {
  static const int _resendSeconds = 30;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _phoneController;
  final _codeController = TextEditingController();

  _Step _step = _Step.number;
  bool _busy = false;
  bool _done = false;
  String? _error;
  String? _e164;
  String? _verificationId;
  int? _resendToken;
  Timer? _timer;
  int _secondsLeft = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialNumber?.trim() ?? '';
    final e164 = initial.isEmpty ? null : PhoneUtils.tryFormatPhilippineMobile(initial);
    // The field shows the 10 digits after +63.
    _phoneController = TextEditingController(text: e164 == null ? '' : e164.substring(3));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _secondsLeft = _resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _secondsLeft = _secondsLeft <= 1 ? 0 : _secondsLeft - 1);
      if (_secondsLeft == 0) t.cancel();
    });
  }

  Future<void> _sendCode({bool resend = false}) async {
    if (_busy) return;
    String? e164 = _e164;
    if (!resend) {
      if (!FormUtils.validateAndFocus(_formKey)) return;
      e164 = PhoneUtils.tryFormatPhilippineMobile(_phoneController.text);
    }
    if (e164 == null) {
      setState(() => _error = PhoneUtils.invalidMessage);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _e164 = e164;
    });
    await AuthService.instance.sendLinkPhoneCode(
      phoneE164: e164,
      resendToken: resend ? _resendToken : null,
      onCodeSent: (verificationId, resendToken) {
        if (!mounted || _done) return;
        setState(() {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _step = _Step.code;
          _busy = false;
        });
        _codeController.clear();
        _startCountdown();
      },
      onError: (e) {
        if (!mounted || _done) return;
        setState(() {
          _busy = false;
          _error = e.message;
        });
      },
      // Android read the SMS by itself and the number is linked already.
      onAutoVerified: () => _saveVerified(),
    );
  }

  Future<void> _confirmCode() async {
    final verificationId = _verificationId;
    if (_busy || _done || verificationId == null) return;
    if (!FormUtils.validateAndFocus(_formKey)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.confirmLinkPhoneCode(
        verificationId: verificationId,
        smsCode: _codeController.text,
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      return;
    }
    await _saveVerified();
  }

  /// The number is on the Firebase account and in a fresh token: store it.
  Future<void> _saveVerified() async {
    if (_done) return;
    if (mounted) setState(() => _busy = true);
    try {
      await PhoneVerificationRepository.instance.claim();
      _done = true;
      _timer?.cancel();
      unawaited(CustomerDataStore.instance.refresh());
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Your mobile number is verified.')));
      Navigator.of(context).pop(true);
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  void _changeNumber() {
    if (_busy) return;
    _timer?.cancel();
    setState(() {
      _step = _Step.number;
      _error = null;
      _secondsLeft = 0;
      _verificationId = null;
      _resendToken = null;
      _codeController.clear();
    });
  }

  Widget _errorText() {
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(error, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _secondsLeft == 0 && !_busy;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Verify Mobile Number', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text(
                _step == _Step.number
                    ? 'We will text a 6-digit code to your mobile number. A verified number is needed to place orders, and it is the number our staff use to reach you.'
                    : 'We sent a 6-digit code to ${_e164 ?? 'your phone'}.',
                style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_step == _Step.number) ...[
                Text('Mobile Number', style: AppTextStyles.labelLg),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(12),
                  ],
                  style: AppTextStyles.bodyLg,
                  validator: PhoneUtils.validatePhilippineMobile,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  decoration: InputDecoration(
                    hintText: '917 123 4567',
                    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 14, right: 8),
                      child: Text(
                        '+63',
                        style: AppTextStyles.bodyLg.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
                _errorText(),
                const SizedBox(height: AppSpacing.md),
                PrimaryButton(label: 'Send code', icon: Icons.sms_outlined, loading: _busy, onPressed: _sendCode),
              ] else ...[
                Text('6-digit code', style: AppTextStyles.labelLg),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  textAlign: TextAlign.center,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  style: AppTextStyles.headlineMd.copyWith(letterSpacing: 8),
                  validator: ValidationUtils.validateVerificationCode,
                  onChanged: (value) {
                    if (_error != null) setState(() => _error = null);
                    if (value.length == 6 && !_busy) _confirmCode();
                  },
                  decoration: const InputDecoration(hintText: '------'),
                ),
                _errorText(),
                const SizedBox(height: AppSpacing.md),
                PrimaryButton(label: 'Verify number', icon: Icons.verified_outlined, loading: _busy, onPressed: _confirmCode),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(onPressed: _busy ? null : _changeNumber, child: const Text('Change number')),
                    TextButton(
                      onPressed: canResend ? () => _sendCode(resend: true) : null,
                      child: Text(_secondsLeft > 0 ? 'Resend code (${_secondsLeft}s)' : 'Resend code'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
