import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../models/customer_profile.dart';

/// Reads/writes the customer's business profile (`customer_profiles`) and
/// saved addresses (`customer_addresses`) in Supabase. Firebase Auth still
/// owns the account itself (email, password, verification); this is
/// everything else about the customer.
class CustomerProfileRepository {
  CustomerProfileRepository._();
  static final CustomerProfileRepository instance = CustomerProfileRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  /// Fetches the profile for [firebaseUid], creating a row (seeded from the
  /// Firebase account's name/email) the first time this customer is seen.
  Future<CustomerProfile> ensureProfile({
    required String firebaseUid,
    required String fallbackName,
    required String fallbackEmail,
  }) async {
    final existing = await _client
        .from('customer_profiles')
        .select()
        .eq('firebase_uid', firebaseUid)
        .maybeSingle();
    if (existing != null) return CustomerProfile.fromRow(existing);

    final created = await _client
        .from('customer_profiles')
        .insert({
          'firebase_uid': firebaseUid,
          'full_name': fallbackName,
          'email': fallbackEmail,
        })
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
        .order('is_default', ascending: false);
    return List<Map<String, dynamic>>.from(raw).map(CustomerAddress.fromRow).toList();
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
