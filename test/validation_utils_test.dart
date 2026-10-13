import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/input_rules.dart';
import 'package:melai_nuts/core/utils/validation_utils.dart';

/// Criterion 1 — input and field validation (lib/core/utils/validation_utils.dart).
void main() {
  group('validateName', () {
    test('accepts real Filipino names (Ñ, accents, hyphens, apostrophes, periods)', () {
      for (final name in ['Niño', 'Ñora', 'Dela Cruz-Reyes', "O'Brien", 'Ma. Cristina', 'José Rizal', 'Bb. Ana']) {
        expect(ValidationUtils.validateName(name), isNull, reason: name);
      }
    });

    test('rejects blanks, digits, symbols, one letter and over 50 characters', () {
      expect(ValidationUtils.validateName('   '), isNotNull);
      expect(ValidationUtils.validateName('A'), isNotNull);
      expect(ValidationUtils.validateName('Juan 3'), isNotNull);
      expect(ValidationUtils.validateName('Ana@home'), isNotNull);
      expect(ValidationUtils.validateName('--'), isNotNull);
      expect(ValidationUtils.validateName('A' * 51), isNotNull);
    });
  });

  group('validatePassword', () {
    test('accepts a strong password', () {
      expect(ValidationUtils.validatePassword('Kasoy#Tanim42'), isNull);
    });

    test('is not trimmed: a trailing space counts toward the length', () {
      // 7 visible characters + 1 space = 8: valid only because the space is kept.
      expect(ValidationUtils.validatePassword('Kas#y4z '), isNull);
      expect(ValidationUtils.validatePassword('Kas#y4z'), isNotNull);
      expect(ValidationUtils.validatePassword('        '), isNotNull);
    });

    test('enforces length, uppercase, number and symbol', () {
      expect(ValidationUtils.validatePassword('Ab1!'), contains('8'));
      expect(ValidationUtils.validatePassword('kasoytanim#42'), contains('uppercase'));
      expect(ValidationUtils.validatePassword('KasoyTanim#'), contains('number'));
      expect(ValidationUtils.validatePassword('KasoyTanim42'), contains('special'));
      expect(ValidationUtils.validatePassword('Aa1!${'x' * 61}'), contains('64'));
    });

    test('the checklist helpers match the validator (any symbol counts)', () {
      // Change Password used a narrower symbol list than the validator, so
      // these valid passwords left its submit button disabled.
      for (final password in ['Kasoy-Tanim9', 'Nuts+2026x', 'Kasoy~Tanim4', 'Kasoy₱Tanim4']) {
        expect(ValidationUtils.validatePassword(password), isNull, reason: password);
        expect(ValidationUtils.hasUpper(password), isTrue, reason: password);
        expect(ValidationUtils.hasDigit(password), isTrue, reason: password);
        expect(ValidationUtils.hasSpecial(password), isTrue, reason: password);
      }
      // A space is not a special character, in either place.
      expect(ValidationUtils.hasSpecial('Kasoy Tanim4'), isFalse);
      expect(ValidationUtils.validatePassword('Kasoy Tanim4'), contains('special'));
      expect(ValidationUtils.hasUpper('kasoy#tanim4'), isFalse);
      expect(ValidationUtils.hasDigit('Kasoy#Tanim'), isFalse);
    });

    test('rejects common passwords and ones containing the email or name', () {
      expect(ValidationUtils.validatePassword('Password1!'), contains('common'));
      expect(ValidationUtils.validatePassword('P@ssw0rd1!'), contains('common'));
      expect(ValidationUtils.validatePassword('Qwerty123\$'), contains('common'));
      expect(ValidationUtils.validatePassword('Mariel#2026', email: 'mariel@mail.ph'), contains('email'));
      expect(ValidationUtils.validatePassword('Santos#2026x', name: 'Ana Santos'), contains('name'));
    });
  });

  group('validatePhone delegates to PhoneUtils (one rule everywhere)', () {
    test('accepts every PH mobile format PhoneUtils accepts', () {
      for (final p in ['09171234567', '0917 123 4567', '+639171234567', '639171234567', '9171234567']) {
        expect(ValidationUtils.validatePhone(p), isNull, reason: p);
      }
    });

    test('rejects landlines and foreign numbers; optional variant allows empty', () {
      expect(ValidationUtils.validatePhone('028123456'), isNotNull);
      expect(ValidationUtils.validatePhone('+14155552671'), isNotNull);
      expect(ValidationUtils.validatePhone(''), isNotNull);
      expect(ValidationUtils.validateOptionalPhone(''), isNull);
      expect(ValidationUtils.validateOptionalPhone('123'), isNotNull);
    });

    test('normalizePhone stores E.164', () {
      expect(ValidationUtils.normalizePhone('0917 123 4567'), '+639171234567');
      expect(ValidationUtils.normalizePhone(' +63 917-123-4567 '), '+639171234567');
      expect(ValidationUtils.normalizePhone(''), '');
    });
  });

  group('validateNumber', () {
    test('peso sign only for money fields', () {
      expect(ValidationUtils.validateNumber('-1', fieldName: 'Cost', min: 0), contains('₱0.00'));
      final msg = ValidationUtils.validateNumber('-1', fieldName: 'Points', min: 0, currencySymbol: null);
      expect(msg, isNot(contains('₱')));
      expect(msg, contains('0'));
    });

    test('money allows at most two decimals', () {
      expect(ValidationUtils.validateNumber('10.555', fieldName: 'Cost'), contains('2 decimal'));
      expect(ValidationUtils.validatePrice('10.5'), isNull);
      expect(ValidationUtils.validatePrice('10.555'), isNotNull);
      expect(ValidationUtils.validatePrice('0'), isNotNull);
    });
  });

  group('dates and quantities', () {
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));
    final tomorrow = today.add(const Duration(days: 1));

    test('expiry cannot be in the past or before the received date', () {
      expect(ValidationUtils.validateDateValue(yesterday, fieldName: 'Expiry', allowPast: false), contains('past'));
      expect(ValidationUtils.validateDateValue(tomorrow, fieldName: 'Expiry', allowPast: false), isNull);
      expect(
        ValidationUtils.validateDateValue(today, fieldName: 'Expiry', notBefore: tomorrow, notBeforeLabel: 'received'),
        contains('received'),
      );
      expect(ValidationUtils.validateDateValue(null, fieldName: 'Expiry'), contains('required'));
    });

    test('received date / date of birth cannot be in the future', () {
      expect(ValidationUtils.validateDateValue(tomorrow, fieldName: 'Received', allowFuture: false), contains('future'));
      expect(ValidationUtils.validateDate('2999-01-01', fieldName: 'Birthday', allowFuture: false), contains('future'));
    });

    test('quantities are whole numbers in range', () {
      expect(ValidationUtils.validateQuantity('0'), isNotNull);
      expect(ValidationUtils.validateQuantity('2.5'), isNotNull);
      expect(ValidationUtils.validateQuantity('100000'), isNotNull);
      expect(ValidationUtils.validateQuantity('12'), isNull);
    });
  });

  group('free text, codes', () {
    test('reasons: required, length limits, no emoji-only input', () {
      expect(ValidationUtils.validateReason(''), contains('required'));
      expect(ValidationUtils.validateReason('too short'), contains('10'));
      expect(ValidationUtils.validateReason('👍👍👍👍👍👍👍👍👍👍👍'), contains('emoji'));
      expect(ValidationUtils.validateReason('The cashews were stale'), isNull);
      expect(ValidationUtils.validateReason('x' * 501), contains('500'));
      expect(ValidationUtils.validateReason('Gate locked', minLength: 5, maxLength: 300), isNull);
    });

    test('optional notes may be empty but not symbols only', () {
      expect(ValidationUtils.validateText(''), isNull);
      expect(ValidationUtils.validateText('...'), isNotNull);
      expect(ValidationUtils.validateText('x' * 301), isNotNull);
    });

    test('verification code is exactly 6 digits', () {
      expect(ValidationUtils.validateVerificationCode('123456'), isNull);
      expect(ValidationUtils.validateVerificationCode('12345'), isNotNull);
      expect(ValidationUtils.validateVerificationCode('12a456'), isNotNull);
    });

    test('voucher codes and SKUs: allowed characters and length', () {
      expect(ValidationUtils.validateVoucherCode('PASALUBONG-10'), isNull);
      expect(ValidationUtils.validateVoucherCode('BAD CODE!'), isNotNull);
      expect(ValidationUtils.validateVoucherCode('A' * 31), isNotNull);
      expect(ValidationUtils.validateSku('4800016644313'), isNull);
      expect(ValidationUtils.validateSku('SKU 1'), isNotNull);
      expect(ValidationUtils.validateSku('', required: false), isNull);
    });

    test('postal codes are 4 digits', () {
      expect(ValidationUtils.validatePostalCode('4027'), isNull);
      expect(ValidationUtils.validatePostalCode('402'), isNotNull);
    });
  });

  group('input formatters', () {
    TextEditingValue v(String t) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));

    String apply(List<TextInputFormatter> fs, String oldText, String newText) {
      var value = v(newText);
      for (final f in fs) {
        value = f.formatEditUpdate(v(oldText), value);
      }
      return value.text;
    }

    test('decimal keeps at most 2 decimals and digits only', () {
      expect(apply(InputRules.decimal(), '12.3', '12.34'), '12.34');
      expect(apply(InputRules.decimal(), '12.34', '12.345'), '12.34');
      expect(apply(InputRules.decimal(), '12', '12a'), '12');
    });

    test('integer, code and voucher formatters', () {
      expect(apply(InputRules.integer(), '', '12x3'), '123');
      expect(apply(InputRules.verificationCode(), '', '1234567'), '123456');
      expect(apply(InputRules.voucherCode(), '', 'promo 1'), 'PROMO1');
    });
  });
}
