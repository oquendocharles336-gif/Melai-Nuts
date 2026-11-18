import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/account_email_service.dart';

// Our own account e-mails (Supabase function account-email): the server's answer codes are
// turned into customer-facing text, never shown raw.
void main() {
  group('AccountEmailService.messageFor', () {
    test('link problems ask for a new link', () {
      expect(AccountEmailService.messageFor('link_used', 400), contains('already used'));
      expect(AccountEmailService.messageFor('link_expired', 400), contains('expired'));
      expect(AccountEmailService.messageFor('link_invalid', 400), contains('most recent'));
    });

    test('cooldown says how long to wait', () {
      expect(AccountEmailService.messageFor('cooldown', 429, retryAfter: 42), contains('42 seconds'));
    });

    test('a weak password shows the server rule', () {
      expect(
        AccountEmailService.messageFor('weak_password', 422, serverText: 'Password must contain a number.'),
        'Password must contain a number.',
      );
    });

    test('unknown answers stay generic', () {
      expect(AccountEmailService.messageFor(null, 500), 'Something went wrong. Please try again.');
    });
  });

  test('captcha and link helpers', () {
    expect(const AccountEmailException('x', code: 'captcha_required').needsCaptcha, isTrue);
    expect(const AccountEmailException('x', code: 'link_used').isLinkProblem, isTrue);
    expect(const AccountEmailException('x', code: 'cooldown').isLinkProblem, isFalse);
  });
}
