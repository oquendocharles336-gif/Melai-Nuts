import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/app_error.dart';

void main() {
  test('expected field conditions are classified, not reported as crashes', () {
    final e = AppErrors.report(TimeoutException('slow'), StackTrace.current, 'test:1');
    expect(e.kind, AppErrorKind.timeout);
    expect(AppErrors.expectedKinds, contains(e.kind));
    expect(e.message, isNot(contains('slow')), reason: 'raw details never reach the UI');
  });

  test('a network failure is "no internet" and expected', () {
    final e = AppErrors.report(Exception('SocketException: Failed host lookup'), StackTrace.current, 'test:2');
    expect(e.kind, AppErrorKind.noInternet);
    expect(AppErrors.expectedKinds, contains(e.kind));
  });

  test('a programming error is unexpected (sent to the crash reporter) and still gets a safe message', () {
    final e = AppErrors.report(StateError('bad state: secret internals'), StackTrace.current, 'test:3');
    expect(AppErrors.expectedKinds, isNot(contains(e.kind)));
    expect(e.message, isNot(contains('secret internals')));
    expect(e.message, isNotEmpty);
  });

  test('an AppError passes through unchanged', () {
    const original = AppError(AppErrorKind.invalidVoucher, 'That voucher is not valid.');
    expect(identical(AppErrors.report(original, StackTrace.current, 'test:4'), original), isTrue);
  });
}
