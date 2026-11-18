import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';

/// Records the signed-in customer's VERIFIED mobile number in Supabase.
///
/// The number is never sent from the app: `claim_verified_phone()` reads it
/// from the Firebase ID token (`phone_number`, set by Firebase only after an
/// SMS code), refuses a number verified on another account, and stores it
/// (migration 20261118040000). Call it right after
/// `AuthService.confirmLinkPhoneCode`, which refreshes the token first.
class PhoneVerificationRepository {
  PhoneVerificationRepository._();
  static final PhoneVerificationRepository instance = PhoneVerificationRepository._();

  /// Returns the stored verified number (E.164). Throws an [AppError] with the
  /// server's customer-safe message when it is refused.
  Future<String> claim() async {
    try {
      final raw = await SupabaseService.instance.client
          .rpc('claim_verified_phone')
          .timeout(AppErrors.rpcTimeout);
      final phone = raw is Map ? raw['verified_phone'] : null;
      if (phone is String && phone.isNotEmpty) return phone;
    } catch (e) {
      throw AppErrors.from(e, scope: ErrorScope.profile);
    }
    throw const AppError(AppErrorKind.invalidData, 'We could not save your verified number. Please try again.');
  }
}
