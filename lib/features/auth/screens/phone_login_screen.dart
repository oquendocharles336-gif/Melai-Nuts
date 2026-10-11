import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/phone_utils.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../data/models/app_user.dart';
import '../../../data/models/user_role.dart';

enum _PhoneStep { number, code, name }

/// Sign in (or create a customer account) with a mobile number and an SMS
/// one-time code. An ADDITIONAL option next to email + password on
/// [LoginScreen]; shown on Android only.
///
/// Step 1: mobile number. Step 2: 6-digit code. Step 3 (new numbers only):
/// full name. On success it navigates exactly like a successful email login.
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  static const int _resendSeconds = 30;

  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();

  _PhoneStep _step = _PhoneStep.number;
  bool _busy = false;
  String? _error;

  String? _e164;
  String? _verificationId;
  int? _resendToken;

  Timer? _timer;
  int _secondsLeft = 0;

  // Set once a sign-in finished (manually or via Android auto-retrieval) so
  // the other path cannot navigate a second time.
  bool _finished = false;

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    _nameController.dispose();
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
      if (_secondsLeft <= 1) {
        t.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  void _goHome(AppUser user) {
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Signed in as ${user.name} (${user.role.label})')),
    );
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.homeFor(user.role),
      (r) => false,
    );
  }

  Future<void> _sendCode({bool resend = false}) async {
    if (_busy) return;
    final String? e164;
    if (resend) {
      e164 = _e164;
    } else {
      if (!_formKey.currentState!.validate()) return;
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
    await AuthService.instance.sendPhoneCode(
      phoneE164: e164,
      resendToken: resend ? _resendToken : null,
      onCodeSent: (verificationId, resendToken) {
        if (!mounted || _finished) return;
        setState(() {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _step = _PhoneStep.code;
          _busy = false;
          _error = null;
        });
        _codeController.clear();
        _startCountdown();
      },
      onError: (e) {
        if (!mounted || _finished) return;
        setState(() {
          _busy = false;
          _error = e.message;
        });
      },
      onAutoSignedIn: (user) {
        if (!mounted || _finished) return;
        _finished = true;
        _timer?.cancel();
        _goHome(user);
      },
      onNeedsName: () {
        if (!mounted || _finished) return;
        _timer?.cancel();
        setState(() {
          _step = _PhoneStep.name;
          _busy = false;
          _error = null;
        });
      },
    );
  }

  Future<void> _confirmCode() async {
    if (_busy) return;
    final code = _codeController.text.trim();
    final verificationId = _verificationId;
    if (code.length != 6 || verificationId == null) {
      setState(() => _error = 'Please enter the 6-digit code from the SMS.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await AuthService.instance.confirmPhoneCode(
        verificationId: verificationId,
        smsCode: code,
      );
      if (!mounted || _finished) return;
      _finished = true;
      _timer?.cancel();
      _goHome(user);
    } on PhoneNameRequiredException {
      if (!mounted || _finished) return;
      _timer?.cancel();
      setState(() {
        _step = _PhoneStep.name;
        _busy = false;
        _error = null;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  Future<void> _submitName() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await AuthService.instance.completePhoneProfile(_nameController.text);
      if (!mounted || _finished) return;
      _finished = true;
      _goHome(user);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  Future<void> _changeNumber() async {
    if (_busy) return;
    _timer?.cancel();
    final wasNameStep = _step == _PhoneStep.name;
    setState(() {
      _step = _PhoneStep.number;
      _error = null;
      _secondsLeft = 0;
      _verificationId = null;
      _resendToken = null;
      _codeController.clear();
    });
    if (wasNameStep) {
      // Signed in with Firebase but no profile yet: do not leave that behind.
      await AuthService.instance.cancelPhoneSignIn();
    }
  }

  String get _title {
    switch (_step) {
      case _PhoneStep.number:
        return 'Log In with Phone';
      case _PhoneStep.code:
        return 'Enter the Code';
      case _PhoneStep.name:
        return 'One Last Step';
    }
  }

  String get _subtitle {
    switch (_step) {
      case _PhoneStep.number:
        return 'We will text you a 6-digit code to sign in.\nNew here? We will set up your customer account.';
      case _PhoneStep.code:
        return 'We sent a 6-digit code to ${_e164 ?? 'your phone'}.';
      case _PhoneStep.name:
        return 'Your number is verified. Tell us your name\nto finish creating your account.';
    }
  }

  Widget _errorText() {
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          error,
          style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
        ),
      ),
    );
  }

  List<Widget> _numberStep() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: Text('Mobile Number', style: AppTextStyles.labelLg),
      ),
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
              style: AppTextStyles.bodyLg.copyWith(
                color: AppColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
      _errorText(),
      const SizedBox(height: AppSpacing.md),
      PrimaryButton(
        label: 'Send code',
        icon: Icons.sms_outlined,
        loading: _busy,
        onPressed: _sendCode,
      ),
    ];
  }

  List<Widget> _codeStep() {
    final canResend = _secondsLeft == 0 && !_busy;
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: Text('6-digit code', style: AppTextStyles.labelLg),
      ),
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
        onChanged: (value) {
          if (_error != null) setState(() => _error = null);
          if (value.length == 6 && !_busy) _confirmCode();
        },
        decoration: const InputDecoration(hintText: '------'),
      ),
      _errorText(),
      const SizedBox(height: AppSpacing.md),
      PrimaryButton(
        label: 'Verify & continue',
        icon: Icons.verified_outlined,
        loading: _busy,
        onPressed: _confirmCode,
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: _busy ? null : _changeNumber,
            child: const Text('Change number'),
          ),
          TextButton(
            onPressed: canResend ? () => _sendCode(resend: true) : null,
            child: Text(
              _secondsLeft > 0 ? 'Resend code (${_secondsLeft}s)' : 'Resend code',
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _nameStep() {
    return [
      AppTextField(
        label: 'Full Name',
        controller: _nameController,
        prefixIcon: Icons.person_outline_rounded,
        validator: (v) => ValidationUtils.validateName(v, 'Full Name'),
      ),
      _errorText(),
      const SizedBox(height: AppSpacing.md),
      PrimaryButton(
        label: 'Continue',
        icon: Icons.arrow_forward_rounded,
        loading: _busy,
        onPressed: _submitName,
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy ? null : _changeNumber,
        child: const Text('Use a different number'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> stepChildren;
    switch (_step) {
      case _PhoneStep.number:
        stepChildren = _numberStep();
        break;
      case _PhoneStep.code:
        stepChildren = _codeStep();
        break;
      case _PhoneStep.name:
        stepChildren = _nameStep();
        break;
    }

    return PopScope(
      // On the name step "back" must also drop the half-finished sign-in.
      canPop: _step != _PhoneStep.name,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _changeNumber();
      },
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: AppColors.darkBrown,
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.primaryContainer, AppColors.surface, AppColors.canvas],
              stops: [0.0, 0.35, 0.7],
            ),
          ),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                kToolbarHeight,
                AppSpacing.md,
                AppSpacing.lg,
              ),
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.22),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const AppLogo(size: 72),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppShadows.md,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        Text(
                          _title,
                          style: AppTextStyles.headlineLg.copyWith(
                            color: AppColors.darkBrown,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _subtitle,
                          textAlign: TextAlign.center,
                          style: AppTextStyles.bodyMd,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        ...stepChildren,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
