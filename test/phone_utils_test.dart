import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/phone_utils.dart';

void main() {
  group('PhoneUtils.tryFormatPhilippineMobile', () {
    test('accepts the common PH formats and returns E.164', () {
      expect(PhoneUtils.tryFormatPhilippineMobile('09171234567'), '+639171234567');
      expect(PhoneUtils.tryFormatPhilippineMobile('9171234567'), '+639171234567');
      expect(PhoneUtils.tryFormatPhilippineMobile('+639171234567'), '+639171234567');
      expect(PhoneUtils.tryFormatPhilippineMobile('639171234567'), '+639171234567');
    });

    test('ignores spaces, dashes, dots and parentheses', () {
      expect(PhoneUtils.tryFormatPhilippineMobile('63917 123 4567'), '+639171234567');
      expect(PhoneUtils.tryFormatPhilippineMobile('0917-123-4567'), '+639171234567');
      expect(PhoneUtils.tryFormatPhilippineMobile(' +63 (917) 123.4567 '), '+639171234567');
    });

    test('rejects anything that is not a PH mobile number', () {
      expect(PhoneUtils.tryFormatPhilippineMobile(''), isNull);
      expect(PhoneUtils.tryFormatPhilippineMobile('   '), isNull);
      expect(PhoneUtils.tryFormatPhilippineMobile('0917123456'), isNull); // too short
      expect(PhoneUtils.tryFormatPhilippineMobile('091712345678'), isNull); // too long
      expect(PhoneUtils.tryFormatPhilippineMobile('08171234567'), isNull); // not 9xx
      expect(PhoneUtils.tryFormatPhilippineMobile('+14155552671'), isNull); // not PH
      expect(PhoneUtils.tryFormatPhilippineMobile('+0639171234567'), isNull);
      expect(PhoneUtils.tryFormatPhilippineMobile('09171234abc'), isNull);
      expect(PhoneUtils.tryFormatPhilippineMobile('028123456'), isNull); // landline
    });
  });

  group('PhoneUtils.formatPhilippineMobile', () {
    test('returns E.164 for a valid number', () {
      expect(PhoneUtils.formatPhilippineMobile('0917 123 4567'), '+639171234567');
    });

    test('throws a FormatException with a clear message when invalid', () {
      expect(
        () => PhoneUtils.formatPhilippineMobile('12345'),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', PhoneUtils.invalidMessage),
        ),
      );
    });
  });

  group('PhoneUtils.validatePhilippineMobile', () {
    test('returns null for valid and a message otherwise', () {
      expect(PhoneUtils.validatePhilippineMobile('09171234567'), isNull);
      expect(PhoneUtils.validatePhilippineMobile(''), isNotNull);
      expect(PhoneUtils.validatePhilippineMobile(null), isNotNull);
      expect(PhoneUtils.validatePhilippineMobile('555'), PhoneUtils.invalidMessage);
    });
  });
}
