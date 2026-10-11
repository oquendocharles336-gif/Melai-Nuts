/// Helpers for Philippine mobile numbers (used by phone / SMS sign-in).
class PhoneUtils {
  PhoneUtils._();

  static const String invalidMessage =
      'Please enter a valid Philippine mobile number, e.g. 0917 123 4567.';

  // Optional +63 / 63 / 0 prefix, then 10 digits starting with 9.
  static final RegExp _mobile = RegExp(r'^(?:\+63|63|0)?(9\d{9})$');

  /// Converts [input] to E.164 (`+639171234567`), or returns `null` when it is
  /// not a valid PH mobile number. Spaces, dashes, dots and parentheses are
  /// ignored. Accepts `09171234567`, `9171234567`, `+639171234567` and
  /// `63 917 123 4567`.
  static String? tryFormatPhilippineMobile(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\s\-().]'), '');
    final match = _mobile.firstMatch(cleaned);
    if (match == null) return null;
    return '+63${match.group(1)}';
  }

  /// Same as [tryFormatPhilippineMobile] but throws a [FormatException]
  /// carrying [invalidMessage] for an invalid number.
  static String formatPhilippineMobile(String input) {
    final result = tryFormatPhilippineMobile(input);
    if (result == null) throw const FormatException(invalidMessage);
    return result;
  }

  /// Form-field validator: `null` when valid, otherwise [invalidMessage].
  static String? validatePhilippineMobile(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your mobile number.';
    }
    return tryFormatPhilippineMobile(value) == null ? invalidMessage : null;
  }
}
