import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/input_rules.dart';
import 'package:melai_nuts/core/utils/person_name.dart';
import 'package:melai_nuts/core/utils/phone_utils.dart';
import 'package:melai_nuts/core/utils/validation_utils.dart';

void main() {
  group('PersonName', () {
    test('composes the stored name', () {
      expect(const PersonName(first: ' Juan ', middleInitial: 'd', last: 'Dela Cruz').fullName, 'Juan D. Dela Cruz');
      expect(const PersonName(first: 'Juan', last: 'Cruz').fullName, 'Juan Cruz');
    });

    test('round-trips a composed name', () {
      final n = PersonName.parse('Maria Ana D. De Los Reyes');
      expect(n.first, 'Maria Ana');
      expect(n.middleInitial, 'D');
      expect(n.last, 'De Los Reyes');
      expect(n.fullName, 'Maria Ana D. De Los Reyes');
    });

    test('splits existing names that have no initial', () {
      final simple = PersonName.parse('shachi Sagales');
      expect(simple.first, 'shachi');
      expect(simple.middleInitial, '');
      expect(simple.last, 'Sagales');
      final particle = PersonName.parse('Juan Dela Cruz');
      expect(particle.first, 'Juan');
      expect(particle.last, 'Dela Cruz');
      expect(PersonName.parse('Madonna').first, 'Madonna');
      expect(PersonName.parse('  ').fullName, '');
    });
  });

  group('mobile number', () {
    test('needs exactly 11 digits starting with 09', () {
      expect(ValidationUtils.validateMobile('09171234567'), isNull);
      for (final bad in ['', '0917123456', '091712345678', '19171234567', '+639171234567']) {
        expect(ValidationUtils.validateMobile(bad), isNotNull, reason: bad);
      }
      expect(ValidationUtils.validateOptionalMobile(''), isNull);
      expect(ValidationUtils.validateOptionalMobile('123'), isNotNull);
    });

    test('typing stops at 11 digits and drops anything else', () {
      var value = const TextEditingValue(text: '0917-123 4567899');
      for (final f in InputRules.phone()) {
        value = f.formatEditUpdate(TextEditingValue.empty, value);
      }
      expect(value.text, '09171234567');
    });

    test('a stored number fills the form as 11 digits and saves as E.164', () {
      expect(PhoneUtils.toLocal('+639171234567'), '09171234567');
      expect(PhoneUtils.toLocal(''), '');
      expect(ValidationUtils.normalizePhone('09171234567'), '+639171234567');
    });
  });
}
