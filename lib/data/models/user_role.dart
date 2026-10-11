import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// The four major roles/portals of the Melai Nuts app.
enum UserRole { customer, staff, owner, delivery }

extension UserRoleX on UserRole {
  /// Parses the role string stored in a Firestore user document (e.g.
  /// `'staff'`, matching [UserRole.staff.name]). Throws a [FormatException]
  /// if the value is missing or doesn't match a known role, so a corrupt or
  /// incomplete profile fails loudly instead of silently granting some
  /// default role.
  static UserRole fromName(String? value) {
    if (value == null) {
      throw const FormatException('User profile is missing a role.');
    }
    for (final role in UserRole.values) {
      if (role.name == value) return role;
    }
    throw FormatException('Unknown user role "$value".');
  }

  String get label {
    switch (this) {
      case UserRole.customer:
        return 'Customer';
      case UserRole.staff:
        return 'Branch Staff';
      case UserRole.owner:
        return 'Owner';
      case UserRole.delivery:
        return 'Delivery Personnel';
    }
  }

  String get shortLabel {
    switch (this) {
      case UserRole.customer:
        return 'Customer';
      case UserRole.staff:
        return 'Staff';
      case UserRole.owner:
        return 'Owner';
      case UserRole.delivery:
        return 'Delivery';
    }
  }

  IconData get icon {
    switch (this) {
      case UserRole.customer:
        return Icons.storefront_rounded;
      case UserRole.staff:
        return Icons.badge_rounded;
      case UserRole.owner:
        return Icons.workspace_premium_rounded;
      case UserRole.delivery:
        return Icons.local_shipping_rounded;
    }
  }

  Color get color {
    switch (this) {
      case UserRole.customer:
        return AppColors.roleCustomer;
      case UserRole.staff:
        return AppColors.roleStaff;
      case UserRole.owner:
        return AppColors.roleOwner;
      case UserRole.delivery:
        return AppColors.roleDelivery;
    }
  }
}
