import 'package:flutter/services.dart';

import 'validation_utils.dart';

/// Ready-made `inputFormatters` so number, phone and code fields stop bad
/// characters at the keyboard, before validation runs. Pair each with the
/// matching keyboard (see the getters' docs) and validator in
/// [ValidationUtils]. The limits come from [InputLimits].
class InputRules {
  InputRules._();

  /// Whole numbers only (stock, quantities). Use with `TextInputType.number`.
  static List<TextInputFormatter> integer({int maxDigits = InputLimits.quantityDigits}) => [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(maxDigits),
      ];

  /// Money / decimal amounts: digits, one dot, at most [decimals] decimals.
  /// Use with `TextInputType.numberWithOptions(decimal: true)`.
  static List<TextInputFormatter> decimal({
    int maxDigits = InputLimits.moneyDigits,
    int decimals = 2,
  }) =>
      [_PatternFormatter(RegExp('^\\d{0,$maxDigits}(\\.\\d{0,$decimals})?\$'))];

  /// Philippine mobile numbers: digits, "+", spaces and dashes, max 16.
  /// Use with `TextInputType.phone`.
  static List<TextInputFormatter> phone() => [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
        LengthLimitingTextInputFormatter(InputLimits.phone),
      ];

  /// The 6-digit e-mail verification code. Use with `TextInputType.number`.
  static List<TextInputFormatter> verificationCode() => [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(InputLimits.verificationCode),
      ];

  /// SKU / barcode typed by hand.
  static List<TextInputFormatter> sku() => [
        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._-]')),
        LengthLimitingTextInputFormatter(InputLimits.sku),
      ];

  /// Voucher codes are case-insensitive; shown in capitals.
  static List<TextInputFormatter> voucherCode() => [
        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_-]')),
        LengthLimitingTextInputFormatter(InputLimits.voucherCode),
        const _UpperCaseFormatter(),
      ];
}

/// Accepts an edit only when the whole new text matches [pattern]; otherwise
/// keeps the previous text (so the caret never jumps).
class _PatternFormatter extends TextInputFormatter {
  const _PatternFormatter(this.pattern);
  final RegExp pattern;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      pattern.hasMatch(newValue.text) ? newValue : oldValue;
}

class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
