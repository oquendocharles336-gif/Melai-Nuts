import 'dart:math' show min;

import 'phone_utils.dart';

/// Maximum lengths shared by the app forms, the admin website's FormRequests
/// (`admin/app/Http/Requests/Rules.php`) and the database CHECK constraints
/// (`supabase/migrations/20261025000000_input_check_constraints.sql`). Change
/// all three together. Listed per field in docs/FORM_FIELDS.md.
class InputLimits {
  InputLimits._();
  static const int name = 50;
  static const int email = 254;
  static const int passwordMin = 8;
  static const int passwordMax = 64;
  static const int phone = 16; // "+63 917 123 4567"
  static const int address = 200;
  static const int addressLabel = 40;
  static const int productName = 100;
  static const int description = 1000;
  static const int sku = 64;
  static const int voucherCode = 30;
  static const int note = 300;
  static const int reason = 500;
  static const int reasonMin = 10;
  static const int shortReasonMin = 5;
  static const int shortReason = 300;
  static const int verificationCode = 6;
  static const int search = 100;
  static const int quantityDigits = 5; // up to 99,999
  static const int moneyDigits = 7; // up to 9,999,999.99
}

class ValidationUtils {
  /// Required field check. Cannot be blank or empty spaces.
  static String? validateRequired(String? value, [String fieldName = 'Field']) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required.';
    }
    return null;
  }

  /// Min character length check.
  static String? validateMinLength(String? value, int minLength, [String fieldName = 'Field']) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;

    final trimmedValue = value!.trim();
    if (trimmedValue.length < minLength) {
      return '$fieldName must be at least $minLength characters.';
    }
    return null;
  }

  /// Max character length check.
  static String? validateMaxLength(String? value, int maxLength, [String fieldName = 'Field']) {
    if (value == null || value.trim().isEmpty) return null;
    if (value.trim().length > maxLength) {
      return '$fieldName cannot exceed $maxLength characters.';
    }
    return null;
  }

  // Any letter in any alphabet (Ñ, ñ, é, ü …) plus combining marks, spaces,
  // hyphens, apostrophes (straight and curly) and periods: "Niño",
  // "Ñora", "Dela Cruz-Reyes", "O'Brien", "Ma. Cristina".
  static final RegExp _namePattern = RegExp(r"^[\p{L}\p{M}\s'’.\-]+$", unicode: true);
  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Name field validation:
  /// - Cannot be blank
  /// - 2 to 50 characters (after trimming)
  /// - Letters from any alphabet (Ñ/ñ and accents included), spaces, hyphens,
  ///   apostrophes and periods only; at least two letters
  static String? validateName(String? value, [String fieldName = 'Name']) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;

    final trimmedValue = value!.trim();
    if (trimmedValue.length < 2) {
      return '$fieldName must be at least 2 characters long.';
    }

    if (trimmedValue.length > InputLimits.name) {
      return '$fieldName cannot exceed ${InputLimits.name} characters.';
    }

    if (RegExp(r'[0-9]').hasMatch(trimmedValue)) {
      return '$fieldName should only contain letters, spaces, hyphens, apostrophes or periods.';
    }

    if (!_namePattern.hasMatch(trimmedValue) ||
        _letter.allMatches(trimmedValue).length < 2) {
      return 'Please enter a valid $fieldName.';
    }

    return null;
  }

  // Popular mailbox providers. Used ONLY to catch typos such as `gmai.com`.
  static const List<String> _commonEmailDomains = [
    'gmail.com',
    'yahoo.com',
    'yahoo.com.ph',
    'outlook.com',
    'hotmail.com',
    'icloud.com',
    'live.com',
    'msn.com',
    'aol.com',
    'proton.me',
    'protonmail.com',
  ];

  // Local part: dot-separated atoms of allowed characters (no leading,
  // trailing or consecutive dots).
  static final RegExp _emailLocalPattern = RegExp(
    r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$",
  );
  // Domain label: letters/digits/hyphens, 1-63 chars, no leading/trailing hyphen.
  static final RegExp _emailDomainLabel = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
  );
  static final RegExp _emailTld = RegExp(r'^[A-Za-z]{2,24}$');

  /// Email FORMAT validation only (structure, lengths, allowed characters,
  /// well-formed domain with a real-looking TLD). Use this where an existing
  /// account may already be on file (sign-in, forgot password) so a legacy or
  /// unusual address is never blocked.
  static String? validateEmailFormat(String? value) {
    final requiredError = validateRequired(value, 'Email address');
    if (requiredError != null) return requiredError;

    const invalid = 'Please enter a valid email address (e.g. user@example.com).';
    final email = value!.trim();
    if (email.length > 254) return invalid;

    final at = email.indexOf('@');
    if (at <= 0 || at != email.lastIndexOf('@')) return invalid;

    final local = email.substring(0, at);
    final domain = email.substring(at + 1);
    if (local.length > 64 || !_emailLocalPattern.hasMatch(local)) return invalid;

    final labels = domain.split('.');
    if (labels.length < 2) return invalid;
    for (final label in labels) {
      if (!_emailDomainLabel.hasMatch(label)) return invalid;
    }
    if (!_emailTld.hasMatch(labels.last)) return invalid;

    return null;
  }

  /// Email validation for NEW addresses (registration, adding a user, editing
  /// a profile): everything in [validateEmailFormat], plus it rejects
  /// near-misses of popular providers (e.g. `gmai.com`, `gmial.com`,
  /// `yahoo.con`) with a "Did you mean ...?" hint.
  ///
  /// Note: no client-side check can prove an inbox exists. Only sending a
  /// verification email and having the person click it proves ownership.
  static String? validateEmail(String? value) {
    final formatError = validateEmailFormat(value);
    if (formatError != null) return formatError;

    final email = value!.trim();
    final at = email.indexOf('@');
    final local = email.substring(0, at);
    final domain = email.substring(at + 1).toLowerCase();

    if (!_commonEmailDomains.contains(domain)) {
      for (final known in _commonEmailDomains) {
        if (_editDistance(domain, known) == 1) {
          return 'Did you mean $local@$known? Please check the spelling.';
        }
      }
    }
    return null;
  }

  /// Edit distance where an insertion, deletion, substitution or swap of two
  /// adjacent characters each count as 1. Returns 2 for anything further apart.
  static int _editDistance(String a, String b) {
    final n = a.length;
    final m = b.length;
    if ((n - m).abs() > 1) return 2;
    final d = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = 0; i <= n; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= m; j++) {
      d[0][j] = j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var v = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost);
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
          v = min(v, d[i - 2][j - 2] + 1);
        }
        d[i][j] = v;
      }
    }
    return d[n][m];
  }

  // Core words of passwords that appear at the top of every breach list. A
  // password whose letters (digits and symbols removed) are one of these is
  // refused even when it meets the character rules ("Password1!", "Qwerty123$").
  static const Set<String> _weakPasswordWords = {
    'password', 'passw', 'pass', 'pword', 'qwerty', 'qwertyuiop', 'asdf', 'asdfgh',
    'zxcvbn', 'welcome', 'admin', 'administrator', 'letmein', 'iloveyou', 'abc',
    'abcd', 'abcdef', 'abcdefg', 'monkey', 'dragon', 'football', 'baseball',
    'sunshine', 'princess', 'master', 'login', 'changeme', 'secret', 'melainuts',
    'melai', 'nuts', 'test', 'user', 'qazwsx', 'trustno', 'iloveu', 'mahalkita',
  };

  /// True when [password] is a well-known weak password with the usual
  /// "capital + number + symbol" decoration added.
  static bool isCommonPassword(String password) {
    final lower = password.toLowerCase();
    String lettersOf(String v) => v.replaceAll(RegExp(r'[^a-z]'), '');
    if (lettersOf(lower).isEmpty) return true; // only digits/symbols
    // "P@ssw0rd1!" -> "password": undo the usual letter-for-symbol swaps.
    final leet = lower
        .replaceAll('@', 'a')
        .replaceAll('0', 'o')
        .replaceAll('3', 'e')
        .replaceAll('\$', 's');
    final candidates = {
      lettersOf(lower),
      lettersOf(leet),
      lettersOf(leet.replaceAll('1', 'i')),
      lettersOf(leet.replaceAll('1', 'l')),
    };
    return candidates.any(_weakPasswordWords.contains);
  }

  /// Password validation. The value is **not trimmed**: a leading or trailing
  /// space is part of the password the person typed.
  /// - 8 to 64 characters
  /// - At least one uppercase letter, one number and one special character
  /// - Must not contain the person's e-mail name or their name
  /// - Must not be a common password such as "Password1!"
  static String? validatePassword(String? value, {String? email, String? name}) {
    if (value == null || value.isEmpty) return 'Password is required.';
    if (value.trim().isEmpty) return 'Password cannot be only spaces.';

    final password = value;
    if (password.length < InputLimits.passwordMin) {
      return 'Password must be at least ${InputLimits.passwordMin} characters long.';
    }

    if (password.length > InputLimits.passwordMax) {
      return 'Password cannot exceed ${InputLimits.passwordMax} characters.';
    }

    if (!RegExp(r'[A-Z]').hasMatch(password)) {
      return 'Password must contain at least one uppercase letter (A-Z).';
    }

    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return 'Password must contain at least one number (0-9).';
    }

    if (!RegExp(r'[^A-Za-z0-9\s]').hasMatch(password)) {
      return 'Password must contain at least one special character (!@#\$...).';
    }

    final lower = password.toLowerCase();
    final emailName = (email ?? '').trim().toLowerCase().split('@').first;
    if (emailName.length >= 3 && lower.contains(emailName)) {
      return 'Password must not contain your email address.';
    }
    for (final part in (name ?? '').toLowerCase().split(RegExp(r'[\s\-.]+'))) {
      if (part.length >= 3 && lower.contains(part)) {
        return 'Password must not contain your name.';
      }
    }

    if (isCommonPassword(password)) {
      return 'This password is too common. Choose something harder to guess.';
    }

    return null;
  }

  /// Contact phone number validation (Philippine mobile). Delegates to
  /// [PhoneUtils] so every screen accepts the same inputs (`0917 123 4567`,
  /// `09171234567`, `+639171234567`, `639171234567`). Save the value with
  /// [normalizePhone] so the database always holds E.164 (`+639171234567`).
  static String? validatePhone(String? value, [String fieldName = 'Phone number']) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;
    return PhoneUtils.validatePhilippineMobile(value);
  }

  /// Same as [validatePhone] but an empty value is allowed (optional fields).
  static String? validateOptionalPhone(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return PhoneUtils.validatePhilippineMobile(value);
  }

  /// The one stored format for phone numbers: E.164 (`+639171234567`).
  /// Returns the trimmed input unchanged when it is not a PH mobile number
  /// (validation should have stopped it already), and '' for empty input.
  static String normalizePhone(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return '';
    return PhoneUtils.tryFormatPhilippineMobile(v) ?? v;
  }

  /// Delivery/customer address validation:
  /// - Cannot be blank or whitespace-only
  /// - Must contain enough information to actually be useful (rejects
  ///   very short meaningless values like "ok" or "123")
  static String? validateAddress(String? value, [String fieldName = 'Delivery address']) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return 'Please enter a valid delivery address.';

    final trimmedValue = value!.trim();
    if (trimmedValue.length < 10) {
      return 'Please enter a valid delivery address.';
    }

    // Require at least one digit (house/unit/street number) alongside
    // letters, so a random short word isn't accepted as an address.
    if (!_letter.hasMatch(trimmedValue)) {
      return 'Please enter a valid delivery address.';
    }

    if (trimmedValue.length > InputLimits.address) {
      return '$fieldName cannot exceed ${InputLimits.address} characters.';
    }

    return null;
  }

  /// Numeric range & format validation (for prices, costs, amounts).
  static String? validateNumber(
      String? value, {
        String fieldName = 'Amount',
        double? min,
        double? max,
        bool allowEmpty = false,
        String? currencySymbol = '₱',
      }) {
    if (allowEmpty && (value == null || value.trim().isEmpty)) return null;

    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;

    final trimmed = value!.trim();
    final number = double.tryParse(trimmed);
    if (number == null) {
      return '$fieldName must be a valid numeric value.';
    }

    if (!number.isFinite) {
      return '$fieldName must be a valid numeric value.';
    }

    String show(double n) => currencySymbol == null
        ? (n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toString())
        : '$currencySymbol${n.toStringAsFixed(2)}';

    if (min != null && number < min) {
      return '$fieldName cannot be less than ${show(min)}.';
    }

    if (max != null && number > max) {
      return '$fieldName cannot exceed ${show(max)}.';
    }

    if (currencySymbol != null && RegExp(r'\.\d{3,}$').hasMatch(trimmed)) {
      return '$fieldName can have at most 2 decimal places.';
    }

    return null;
  }

  /// Positive price / currency validator (e.g. retail price, COGS).
  static String? validatePrice(
      String? value, {
        String fieldName = 'Price',
        double min = 0.01,
        double max = 100000.0,
        bool allowZero = false,
      }) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;

    final trimmed = value!.trim();
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite) {
      return '$fieldName must be a valid price (e.g. 150.00).';
    }
    if (RegExp(r'\.\d{3,}$').hasMatch(trimmed)) {
      return '$fieldName can have at most 2 decimal places.';
    }

    if (allowZero && parsed == 0) return null;

    if (parsed < min) {
      return '$fieldName must be at least ₱${min.toStringAsFixed(2)}.';
    }

    if (parsed > max) {
      return '$fieldName cannot exceed ₱${max.toStringAsFixed(2)}.';
    }

    return null;
  }

  /// Integer / quantity validator (e.g. stock count, items).
  static String? validateQuantity(
      String? value, {
        String fieldName = 'Quantity',
        int min = 1,
        int max = 99999,
      }) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;

    final trimmed = value!.trim();
    final parsed = int.tryParse(trimmed);
    if (parsed == null) {
      return '$fieldName must be a valid whole number.';
    }

    if (parsed < min) {
      return '$fieldName must be at least $min.';
    }

    if (parsed > max) {
      return '$fieldName cannot exceed $max.';
    }

    return null;
  }

  /// Date string validation (YYYY-MM-DD or MM/DD/YYYY).
  static String? validateDate(
      String? value, {
        String fieldName = 'Date',
        bool allowPast = true,
        bool allowFuture = true,
      }) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;

    final trimmed = value!.trim();
    DateTime? parsedDate;

    // Try parsing ISO format (YYYY-MM-DD) or US format (MM/DD/YYYY)
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
      parsedDate = DateTime.tryParse(trimmed);
    } else if (RegExp(r'^\d{1,2}/\d{1,2}/\d{4}$').hasMatch(trimmed)) {
      final parts = trimmed.split('/');
      final month = int.tryParse(parts[0]);
      final day = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);
      if (month != null && day != null && year != null) {
        parsedDate = DateTime.tryParse(
          '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
        );
      }
    }

    if (parsedDate == null) {
      return 'Enter a valid date (e.g. YYYY-MM-DD or MM/DD/YYYY).';
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateOnly = DateTime(parsedDate.year, parsedDate.month, parsedDate.day);

    if (!allowPast && dateOnly.isBefore(today)) {
      return '$fieldName cannot be in the past.';
    }

    if (!allowFuture && dateOnly.isAfter(today)) {
      return '$fieldName cannot be in the future.';
    }

    return null;
  }

  /// Validates a [DateTime] picked with a date picker (most date fields in the
  /// app are pickers, not typed text). Same rules as [validateDate].
  static String? validateDateValue(
    DateTime? value, {
    String fieldName = 'Date',
    bool required = true,
    bool allowPast = true,
    bool allowFuture = true,
    DateTime? notBefore,
    String? notBeforeLabel,
  }) {
    if (value == null) return required ? '$fieldName is required.' : null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(value.year, value.month, value.day);
    if (!allowPast && day.isBefore(today)) return '$fieldName cannot be in the past.';
    if (!allowFuture && day.isAfter(today)) return '$fieldName cannot be in the future.';
    if (notBefore != null) {
      final floor = DateTime(notBefore.year, notBefore.month, notBefore.day);
      if (day.isBefore(floor)) {
        return '$fieldName cannot be before ${notBeforeLabel ?? 'the earlier date'}.';
      }
    }
    return null;
  }

  /// Free text such as notes and reasons:
  /// - trimmed before checking
  /// - [minLength]..[maxLength] characters (required when [required] or minLength > 0)
  /// - must contain at least one letter or digit (rejects emoji-only or
  ///   punctuation-only input such as "👍👍" or "...")
  static String? validateText(
    String? value, {
    String fieldName = 'This field',
    bool required = false,
    int minLength = 0,
    int maxLength = InputLimits.note,
  }) {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return (required || minLength > 0) ? '$fieldName is required.' : null;
    }
    if (!_letterOrDigit.hasMatch(v)) {
      return '$fieldName must contain words, not only emoji or symbols.';
    }
    if (v.length < minLength) {
      return '$fieldName must be at least $minLength characters.';
    }
    if (v.length > maxLength) {
      return '$fieldName cannot exceed $maxLength characters.';
    }
    return null;
  }

  /// A required reason (refund, cancellation, delay, adjustment).
  static String? validateReason(
    String? value, {
    String fieldName = 'Reason',
    int minLength = InputLimits.reasonMin,
    int maxLength = InputLimits.reason,
  }) =>
      validateText(value,
          fieldName: fieldName, required: true, minLength: minLength, maxLength: maxLength);

  /// E-mail verification code: exactly 6 digits.
  static String? validateVerificationCode(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter the 6-digit code from the email.';
    if (!RegExp(r'^\d{6}$').hasMatch(v)) return 'The code must be exactly 6 digits.';
    return null;
  }

  /// Voucher / promo code: letters, digits, hyphen and underscore, max 30.
  static String? validateVoucherCode(String? value, {bool required = true}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return required ? 'Enter a voucher code.' : null;
    if (v.length > InputLimits.voucherCode) {
      return 'Voucher code cannot exceed ${InputLimits.voucherCode} characters.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v)) {
      return 'Voucher code can only use letters, numbers, - and _.';
    }
    return null;
  }

  /// SKU / barcode typed by hand: letters, digits, hyphen, underscore and
  /// period, max 64 (EAN/UPC barcodes are digits only and always fit).
  static String? validateSku(String? value, {String fieldName = 'SKU', bool required = true}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return required ? '$fieldName is required.' : null;
    if (v.length > InputLimits.sku) {
      return '$fieldName cannot exceed ${InputLimits.sku} characters.';
    }
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(v)) {
      return '$fieldName can only use letters, numbers, ".", "-" and "_".';
    }
    return null;
  }

  /// Product / category / supplier / branch names: 2..[maxLength] characters,
  /// must contain a letter or digit. Digits are allowed (e.g. "Cashew 250g").
  static String? validateTitle(
    String? value, {
    String fieldName = 'Name',
    int maxLength = InputLimits.productName,
  }) {
    final requiredError = validateRequired(value, fieldName);
    if (requiredError != null) return requiredError;
    final v = value!.trim();
    if (v.length < 2) return '$fieldName must be at least 2 characters long.';
    if (v.length > maxLength) return '$fieldName cannot exceed $maxLength characters.';
    if (!_letterOrDigit.hasMatch(v)) return 'Please enter a valid $fieldName.';
    return null;
  }

  /// Philippine postal (ZIP) code: exactly 4 digits.
  static String? validatePostalCode(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Postal code is required.';
    if (!RegExp(r'^\d{4}$').hasMatch(v)) return 'Postal code must be 4 digits (e.g. 4027).';
    return null;
  }
}
