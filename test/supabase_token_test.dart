import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/supabase_token.dart';

String _jwt(Map<String, Object?> claims) {
  String enc(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'none'})}.${enc(claims)}.sig';
}

void main() {
  test('detects role=authenticated', () {
    expect(
        SupabaseToken.hasAuthenticatedRole(_jwt({'role': 'authenticated'})),
        isTrue);
  });

  test('rejects missing or other roles and garbage', () {
    expect(SupabaseToken.hasAuthenticatedRole(_jwt({'sub': 'u1'})), isFalse);
    expect(SupabaseToken.hasAuthenticatedRole(_jwt({'role': 'anon'})), isFalse);
    expect(SupabaseToken.hasAuthenticatedRole('not-a-jwt'), isFalse);
    expect(SupabaseToken.hasAuthenticatedRole(null), isFalse);
  });
}
