import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/auth_service.dart';

/// Review fix 6: a delivery account whose creation fails partway is fully
/// undone — driver row, staff row, then the Auth user — even if one undo
/// step fails.
void main() {
  test('undoes in reverse order: driver row, staff row, Auth user', () async {
    final done = <String>[];
    await rollbackManagedAccount(
      removeDriver: () async => done.add('driver'),
      removeStaff: () async => done.add('staff'),
      deleteAuthUser: () async => done.add('auth'),
    );
    expect(done, ['driver', 'staff', 'auth']);
  });

  test('a delivery account (no staff row) removes the driver row, then the Auth user', () async {
    final done = <String>[];
    await rollbackManagedAccount(
      removeDriver: () async => done.add('driver'),
      deleteAuthUser: () async => done.add('auth'),
    );
    expect(done, ['driver', 'auth']);
  });

  test('a failing step does not stop the rest (the Auth user is still deleted)', () async {
    final done = <String>[];
    await rollbackManagedAccount(
      removeDriver: () async => throw Exception('offline'),
      deleteAuthUser: () async => done.add('auth'),
    );
    expect(done, ['auth']);
  });
}
