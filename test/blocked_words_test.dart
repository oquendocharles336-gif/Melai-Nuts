import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/moderation/blocked_words.dart';
import 'package:melai_nuts/core/utils/validation_utils.dart';

/// The app's copy of the blocked-words check, against the shared test cases
/// in moderation/ (the website's PHP and JavaScript copies and the database
/// run the very same cases).
void main() {
  final cases = jsonDecode(File('moderation/test_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final blocked = (cases['blocked'] as List).cast<String>();
  final allowed = (cases['allowed'] as List).cast<String>();

  group('blocked words (moderation/blocked_words.json)', () {
    test('every blocked case is caught', () {
      expect(blocked.where((t) => !BlockedWords.contains(t)).toList(), isEmpty);
    });

    test('innocent text is never blocked', () {
      expect(allowed.where(BlockedWords.contains).toList(), isEmpty);
      expect(BlockedWords.contains(null), isFalse);
    });

    test('the review and special-instructions validators say so', () {
      expect(ValidationUtils.validateReviewComment('ang p@ngit, gago'), 'Please keep your message respectful.');
      expect(ValidationUtils.validateReviewComment('Masarap!'), isNull);
      expect(ValidationUtils.validateSpecialInstructions('f u c k'), 'Please keep your message respectful.');
      expect(ValidationUtils.validateSpecialInstructions('Pasalubong packing please'), isNull);
      expect(ValidationUtils.validateSpecialInstructions(''), isNull);
    });

    test('the generated list matches the JSON (run scripts/sync_blocked_words.py)', () {
      final json = jsonDecode(File('moderation/blocked_words.json').readAsStringSync()) as Map<String, dynamic>;
      expect(BlockedWords.message, json['message']);
    });
  });
}
