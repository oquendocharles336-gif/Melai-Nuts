import 'package:cloud_firestore/cloud_firestore.dart';

import 'user_role.dart';

/// A user's profile document, stored in Firestore at `users/{uid}`.
///
/// Firebase Authentication only knows about email + password (and the uid
/// it issues). Everything app-specific — the person's name, which of the
/// four roles they hold, which branch they're assigned to, and whether an
/// admin has deactivated them — lives here instead.
class AppUser {
  final String uid;
  final String email;
  final String name;
  final UserRole role;
  final String? phone;
  final String? branch;
  final bool isActive;
  final DateTime? createdAt;

  const AppUser({
    required this.uid,
    required this.email,
    required this.name,
    required this.role,
    this.phone,
    this.branch,
    this.isActive = true,
    this.createdAt,
  });

  factory AppUser.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    return AppUser(
      uid: doc.id,
      email: (data['email'] as String?) ?? '',
      name: (data['name'] as String?) ?? '',
      role: UserRoleX.fromName(data['role'] as String?),
      phone: data['phone'] as String?,
      branch: data['branch'] as String?,
      isActive: (data['isActive'] as bool?) ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore({bool serverTimestamp = false}) {
    return {
      'email': email,
      'name': name,
      'role': role.name,
      'phone': phone,
      'branch': branch,
      'isActive': isActive,
      'createdAt': serverTimestamp
          ? FieldValue.serverTimestamp()
          : (createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp()),
    };
  }

  AppUser copyWith({bool? isActive}) {
    return AppUser(
      uid: uid,
      email: email,
      name: name,
      role: role,
      phone: phone,
      branch: branch,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }
}
