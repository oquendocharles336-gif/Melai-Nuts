import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/customer_local_db.dart';
import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/customer_profile.dart';

/// Reads/writes the customer's business profile (`customer_profiles`) and
/// saved addresses (`customer_addresses`) in Supabase. Firebase Auth still
/// owns the account itself (email, password, verification); this is
/// everything else about the customer.
class CustomerProfileRepository {
  CustomerProfileRepository._();
  static final CustomerProfileRepository instance = CustomerProfileRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  /// The row inserted the first time a customer is seen. The phone given at
  /// registration is included so checkout (`place_order`) has a contact
  /// number without the customer re-entering it. Empty values are left out.
  static Map<String, dynamic> newProfileRow({
    required String firebaseUid,
    required String fullName,
    required String email,
    String phone = '',
  }) {
    final trimmedPhone = phone.trim();
    return {
      'firebase_uid': firebaseUid,
      'full_name': fullName,
      'email': email,
      if (trimmedPhone.isNotEmpty) 'phone': trimmedPhone,
    };
  }

  /// True when an existing profile has no phone yet but one is known from
  /// the account (e.g. accounts created before the phone was saved here).
  static bool shouldBackfillPhone(CustomerProfile existing, String phone) =>
      existing.phone.trim().isEmpty && phone.trim().isNotEmpty;

  /// Fetches the profile for [firebaseUid], creating a row (seeded from the
  /// Firebase account's name/email and registration phone) the first time
  /// this customer is seen.
  Future<CustomerProfile> ensureProfile({
    required String firebaseUid,
    required String fallbackName,
    required String fallbackEmail,
    String fallbackPhone = '',
  }) async {
    final existing = await _client
        .from('customer_profiles')
        .select()
        .eq('firebase_uid', firebaseUid)
        .maybeSingle();
    if (existing != null) {
      final profile = CustomerProfile.fromRow(existing);
      if (!shouldBackfillPhone(profile, fallbackPhone)) return profile;
      try {
        final row = await _client
            .from('customer_profiles')
            .update({'phone': fallbackPhone.trim()})
            .eq('firebase_uid', firebaseUid)
            .select()
            .single();
        return CustomerProfile.fromRow(row);
      } catch (caughtError, caughtStack) {
        // Not critical: checkout lets the customer enter a phone inline.
        AppErrors.report(caughtError, caughtStack, 'customer_profile_repository:backfillPhone');
        return profile;
      }
    }

    final created = await _client
        .from('customer_profiles')
        .insert(newProfileRow(
          firebaseUid: firebaseUid,
          fullName: fallbackName,
          email: fallbackEmail,
          phone: fallbackPhone,
        ))
        .select()
        .single();
    return CustomerProfile.fromRow(created);
  }

  /// Reads the existing profile row (never creates one). Null if none yet.
  Future<CustomerProfile?> fetchProfile(String firebaseUid) async {
    final row = await _client
        .from('customer_profiles')
        .select()
        .eq('firebase_uid', firebaseUid)
        .maybeSingle();
    return row == null ? null : CustomerProfile.fromRow(row);
  }

  Future<CustomerProfile> updateProfile({
    required String firebaseUid,
    required String fullName,
    required String phone,
  }) async {
    final row = await _client
        .from('customer_profiles')
        .update({'full_name': fullName, 'phone': phone})
        .eq('firebase_uid', firebaseUid)
        .select()
        .single();
    return CustomerProfile.fromRow(row);
  }

  // RFID card numbers are linked by staff, never by the customer: the card
  // number identifies the account at the POS, and the database gives the
  // customer roles no write access to `rfid_card_number`.

  /// Persists the customer's chosen branch (see `BranchController`) so it's
  /// restored automatically the next time they sign in.
  Future<void> setDefaultBranch(String firebaseUid, String branchId) async {
    await _client
        .from('customer_profiles')
        .update({'default_branch_id': branchId})
        .eq('firebase_uid', firebaseUid);
  }

  Future<List<CustomerAddress>> fetchAddresses(String firebaseUid) async {
    final raw = await _client
        .from('customer_addresses')
        .select()
        .eq('firebase_uid', firebaseUid)
        .order('is_default', ascending: false)
        .limit(100); // the database allows at most 20 per hour; 100 is a safety cap
    final rows = List<Map<String, dynamic>>.from(raw);
    unawaited(CustomerLocalDb.instance.replaceAll(firebaseUid, LocalKind.addresses, rows));
    return rows.map(CustomerAddress.fromRow).toList();
  }

  /// The last copy of the customer's saved addresses kept on this device.
  Future<List<CustomerAddress>> localAddresses(String firebaseUid) async {
    final page = await CustomerLocalDb.instance.query(firebaseUid, LocalKind.addresses, sort: LocalSort.serverOrder);
    return page.rows.map(CustomerAddress.fromRow).toList();
  }

  Future<CustomerAddress> addAddress({
    required String firebaseUid,
    required String label,
    required String recipientName,
    required String phone,
    required String line1,
    required String city,
    required String province,
    required String postalCode,
    bool isDefault = false,
    double? latitude,
    double? longitude,
  }) async {
    if (isDefault) {
      await _client
          .from('customer_addresses')
          .update({'is_default': false})
          .eq('firebase_uid', firebaseUid);
    }
    final row = await _client
        .from('customer_addresses')
        .insert({
          'firebase_uid': firebaseUid,
          'label': label,
          'recipient_name': recipientName,
          'phone': phone,
          'line1': line1,
          'city': city,
          'province': province,
          'postal_code': postalCode,
          'is_default': isDefault,
          'latitude': latitude,
          'longitude': longitude,
        })
        .select()
        .single();
    return CustomerAddress.fromRow(row);
  }

  Future<CustomerAddress> updateAddress({
    required String id,
    required String firebaseUid,
    required String label,
    required String recipientName,
    required String phone,
    required String line1,
    required String city,
    required String province,
    required String postalCode,
    bool isDefault = false,
    double? latitude,
    double? longitude,
  }) async {
    if (isDefault) {
      await _client
          .from('customer_addresses')
          .update({'is_default': false})
          .eq('firebase_uid', firebaseUid);
    }
    final row = await _client
        .from('customer_addresses')
        .update({
          'label': label,
          'recipient_name': recipientName,
          'phone': phone,
          'line1': line1,
          'city': city,
          'province': province,
          'postal_code': postalCode,
          'is_default': isDefault,
          'latitude': latitude,
          'longitude': longitude,
        })
        .eq('id', id)
        .eq('firebase_uid', firebaseUid)
        .select()
        .single();
    return CustomerAddress.fromRow(row);
  }

  /// Moves only the map pin of one of the customer's own addresses (the
  /// checkout "Pin on map" shortcut). Row-level security limits the update
  /// to the signed-in customer's rows; the database refuses 0,0 and
  /// out-of-range values. Orders already placed keep their own snapshot.
  Future<CustomerAddress> updateAddressPin({
    required String id,
    required String firebaseUid,
    required double latitude,
    required double longitude,
  }) async {
    final row = await _client
        .from('customer_addresses')
        .update({'latitude': latitude, 'longitude': longitude})
        .eq('id', id)
        .eq('firebase_uid', firebaseUid)
        .select()
        .single();
    return CustomerAddress.fromRow(row);
  }

  /// Marks [id] as the default delivery address and unsets every other
  /// address belonging to [firebaseUid].
  Future<void> setDefaultAddress(String firebaseUid, String id) async {
    await _client
        .from('customer_addresses')
        .update({'is_default': false})
        .eq('firebase_uid', firebaseUid);
    await _client
        .from('customer_addresses')
        .update({'is_default': true})
        .eq('id', id)
        .eq('firebase_uid', firebaseUid);
  }

  Future<void> deleteAddress(String id) async {
    await _client.from('customer_addresses').delete().eq('id', id);
  }
}
