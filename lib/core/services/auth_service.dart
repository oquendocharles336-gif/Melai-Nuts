import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../data/models/app_user.dart';
import '../../data/models/user_role.dart';
import '../../features/customer/cart_controller.dart';
import '../../data/catalog_store.dart';
import '../../data/repositories/branch_repository.dart';
import 'branch_controller.dart';
import 'customer_data_store.dart';
import 'data_sync_service.dart';
import 'email_verification_service.dart';
import 'staff_session_store.dart';
import 'staff_store.dart';
import 'sync_service.dart';
import '../../data/repositories/driver_repository.dart';
import '../../data/repositories/staff_repository.dart';
import '../utils/app_error.dart';

/// A user-facing authentication failure. The [message] is already written
/// to be shown directly in a SnackBar/dialog — no FirebaseAuthException
/// codes leak past this service.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// Thrown at sign-in / session restore when a customer's Firebase account
/// exists but its email has not been verified yet (sign-up unfinished). The
/// person stays signed in so they can finish verifying.
class EmailVerificationRequiredException extends AuthException {
  const EmailVerificationRequiredException()
      : super('Please verify your email address to finish creating your account.');
}

/// Thrown by [AuthService.confirmPhoneCode] when the SMS code was valid and the
/// person is signed in with Firebase, but no customer profile exists yet for
/// this phone number. The UI must ask for a full name and then call
/// [AuthService.completePhoneProfile].
class PhoneNameRequiredException extends AuthException {
  const PhoneNameRequiredException()
      : super('Please enter your full name to finish creating your account.');
}

/// In-memory brake on repeated failures (exponential back-off after a few
/// free attempts). This is a UX / accidental-hammering brake only — it lives
/// on the device and can be bypassed by a modified client. The real
/// enforcement is Firebase Auth's server-side throttling
/// (`too-many-requests`); see SECURITY.md.
class _FailureBrake {
  static const int freeAttempts = 5;
  static const Duration baseDelay = Duration(seconds: 30);
  static const Duration maxDelay = Duration(minutes: 5);

  int _failures = 0;
  DateTime? _lockedUntil;

  Duration? get remaining {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left.isNegative) {
      _lockedUntil = null;
      return null;
    }
    return left;
  }

  void recordFailure() {
    _failures++;
    if (_failures >= freeAttempts) {
      final int exp = (_failures - freeAttempts).clamp(0, 4).toInt();
      var delay = baseDelay * (1 << exp);
      if (delay > maxDelay) delay = maxDelay;
      _lockedUntil = DateTime.now().add(delay);
    }
  }

  void reset() {
    _failures = 0;
    _lockedUntil = null;
  }
}

/// Wraps Firebase Authentication + the `users` Firestore collection so every
/// screen (customer, staff, owner, delivery) goes through one real,
/// validated sign-in / sign-up path.
///
/// Firestore is the source of truth for *who someone is* (their name, role,
/// branch, and whether an admin has deactivated them) — Firebase Auth only
/// proves *that* they own the email + password. [signIn] always checks both.
///
/// OFFLINE: Firebase Auth itself persists the signed-in session on the device
/// (a refresh token managed by the SDK — this app never stores or sees the
/// password). After a restart with no network, that persisted session plus the
/// Firestore-cached profile lets a *previously authenticated* user keep
/// working. There is deliberately NO custom offline-login mechanism: nobody
/// can "log in" offline without an existing Firebase session.
///
/// AUTHORIZATION: role checks in Dart (this file, route guards, hidden
/// buttons) are a UX layer. The real enforcement is `firestore.rules`.
class AuthService {
  AuthService._() {
    // Drop the cached profile whenever the Firebase identity goes away or changes.
    _auth.authStateChanges().listen((user) {
      if (user == null || user.uid != _currentProfile?.uid) {
        _currentProfile = null;
      }
    });
  }
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const String _usersCollection = 'users';

  final _FailureBrake _signInBrake = _FailureBrake();
  final _FailureBrake _phoneCodeBrake = _FailureBrake();
  final Map<String, DateTime> _lastResetRequest = {};
  static const Duration _resetCooldown = Duration(seconds: 60);

  AppUser? _currentProfile;

  // Sign-up details held only in memory until the email is verified.
  String? _pendingName;
  String? _pendingPhone;

  /// True once the *user* has chosen to sign out, until the next sign-in.
  /// Route guards use it to avoid hijacking the logout flow's own navigation.
  bool _userInitiatedSignOut = false;
  bool get userInitiatedSignOut => _userInitiatedSignOut;

  /// Fires whenever the signed-in Firebase user changes (sign in, sign out,
  /// session invalidated).
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentFirebaseUser => _auth.currentUser;

  /// The validated profile (role, branch, active flag) of the signed-in user,
  /// or `null` if nobody is signed in / it has not been loaded yet. Only ever
  /// set after [_loadAndValidateProfile] succeeded.
  AppUser? get currentProfile => _currentProfile;

  /// Loads the Firestore profile for the currently signed-in Firebase user,
  /// or `null` if nobody is signed in. Throws [AuthException] if the
  /// account is signed in but has no matching/active profile (and signs it
  /// out), so callers never route a "ghost" session into a portal.
  ///
  /// With [allowVerificationResume] a signed-in customer whose email is not
  /// verified yet gets [EmailVerificationRequiredException] (and stays signed
  /// in) instead of being signed out, so they can finish sign-up.
  Future<AppUser?> loadCurrentProfile({bool allowVerificationResume = false}) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return _loadAndValidateProfile(user.uid, allowVerificationResume: allowVerificationResume);
  }

  Future<AppUser> signIn({
    required String email,
    required String password,
    bool allowVerificationResume = false,
  }) async {
    _throwIfBraked(_signInBrake);
    StaffSessionStore.instance.beginAuthentication();
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final uid = credential.user?.uid;
      if (uid == null) {
        throw const AuthException('Sign-in failed. Please try again.');
      }
      final profile = await _loadAndValidateProfile(
        uid,
        allowVerificationResume: allowVerificationResume,
      );
      _signInBrake.reset();
      _userInitiatedSignOut = false;
      return profile;
    } on FirebaseAuthException catch (e) {
      if (e.code != 'network-request-failed') _signInBrake.recordFailure();
      throw AuthException(_messageFor(e));
    } finally {
      // No-op once a staff session owns the store; otherwise (failed or
      // non-staff sign-in) it leaves the "authenticating" phase.
      StaffSessionStore.instance.endAuthentication();
    }
  }

  /// Self-service registration — customers only — STEP 1 of 2.
  ///
  /// Creates the Firebase Auth account and leaves the person signed in so they
  /// can verify their email. NO customer profile exists yet, so the account
  /// has no access to anything. Continue with [sendVerification] and
  /// [completeCustomerRegistration].
  Future<void> startCustomerRegistration({
    required String name,
    required String email,
    required String phone,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AuthException('Account creation failed. Please try again.');
      }
      _pendingName = name.trim();
      _pendingPhone = phone.trim();
      _userInitiatedSignOut = false;
      try {
        await user.updateDisplayName(name.trim());
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'auth_service:224');
        // Not critical; the name is also kept in memory and written to the profile.
      }
    } on FirebaseAuthException catch (e) {
      throw AuthException(_messageFor(e));
    }
  }

  /// Emails the verification code (or Firebase link) to the signed-in
  /// account's own address. Safe to call again to resend.
  Future<void> sendVerification() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your sign-up session expired. Please register again.');
    }
    try {
      await EmailVerificationService.instance.sendCode(user);
    } on EmailVerificationException catch (e) {
      throw AuthException(e.message);
    }
  }

  /// STEP 2 of 2: checks the code (or that the link was tapped), refreshes the
  /// session so Firebase's `email_verified` claim is current, then creates the
  /// customer profile. Firestore rules independently require
  /// `email_verified == true` for this write.
  Future<AppUser> completeCustomerRegistration({String? code}) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your sign-up session expired. Please register again.');
    }
    try {
      await EmailVerificationService.instance.verify(user, code: code);
    } on EmailVerificationException catch (e) {
      throw AuthException(e.message);
    }

    try {
      await user.reload();
      final fresh = _auth.currentUser;
      if (fresh == null || !fresh.emailVerified) {
        throw const AuthException(
          'Your email is not verified yet. Please finish verifying and try again.',
        );
      }
      await fresh.getIdToken(true); // pick up email_verified in the token

      final name = (_pendingName != null && _pendingName!.isNotEmpty)
          ? _pendingName!
          : ((fresh.displayName ?? '').trim().isNotEmpty ? fresh.displayName!.trim() : 'Customer');
      final appUser = AppUser(
        uid: fresh.uid,
        // The identity Firebase recorded; rules require the profile email to match it.
        email: fresh.email ?? '',
        name: name,
        role: UserRole.customer,
        phone: _pendingPhone ?? '',
        isActive: true,
      );
      try {
        await _firestore
            .collection(_usersCollection)
            .doc(fresh.uid)
            .set(appUser.toFirestore(serverTimestamp: true));
      } on FirebaseException {
        throw const AuthException(
          'We could not finish creating your account. Please try again.',
        );
      }
      _pendingName = null;
      _pendingPhone = null;
      _currentProfile = appUser;
      _userInitiatedSignOut = false;
      return appUser;
    } on FirebaseAuthException catch (e) {
      throw AuthException(_messageFor(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Phone (SMS one-time code) sign-in — an ADDITIONAL option next to email +
  // password. A phone-only account has no email: the SMS code proves ownership
  // of the number, so email verification does not apply to it.
  // ---------------------------------------------------------------------------

  /// Asks Firebase to SMS a 6-digit code to [phoneE164] (e.g. `+639171234567`).
  ///
  /// [onCodeSent] fires when the SMS is on its way; keep the `verificationId`
  /// and pass it to [confirmPhoneCode]. Pass the last `resendToken` as
  /// [resendToken] to resend. Failures are reported through [onError] (never
  /// thrown), already worded for the screen.
  ///
  /// On Android the code may be picked up automatically; Firebase then signs
  /// the person in without typing. That is reported through [onAutoSignedIn]
  /// (profile ready) or [onNeedsName] (new customer: collect a name, then call
  /// [completePhoneProfile]).
  Future<void> sendPhoneCode({
    required String phoneE164,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function(AuthException) onError,
    int? resendToken,
    void Function(AppUser user)? onAutoSignedIn,
    void Function()? onNeedsName,
  }) async {
    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneE164,
        timeout: const Duration(seconds: 60),
        forceResendingToken: resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          try {
            final user = await _completePhoneSignIn(credential);
            onAutoSignedIn?.call(user);
          } on PhoneNameRequiredException {
            onNeedsName?.call();
          } on FirebaseAuthException catch (e) {
            onError(AuthException(_messageFor(e)));
          } on AuthException catch (e) {
            onError(e);
          } catch (caughtError, caughtStack) {
            AppErrors.report(caughtError, caughtStack, 'auth_service:343');
            onError(const AuthException('Something went wrong. Please try again.'));
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          onError(AuthException(_messageFor(e)));
        },
        codeSent: (String verificationId, int? token) {
          onCodeSent(verificationId, token);
        },
        codeAutoRetrievalTimeout: (String verificationId) {},
      );
    } on FirebaseAuthException catch (e) {
      onError(AuthException(_messageFor(e)));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'auth_service:357');
      onError(const AuthException('Something went wrong. Please try again.'));
    }
  }

  /// Signs in with the SMS code. Returns the validated profile of an existing
  /// account. For a number with no account yet it throws
  /// [PhoneNameRequiredException] (the person stays signed in with Firebase,
  /// holding no access) unless [fullNameIfNew] is given, in which case the new
  /// customer profile is created right away.
  Future<AppUser> confirmPhoneCode({
    required String verificationId,
    required String smsCode,
    String? fullNameIfNew,
  }) async {
    _throwIfBraked(_phoneCodeBrake);
    final code = smsCode.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const AuthException('Please enter the 6-digit code from the SMS.');
    }
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      );
      final profile = await _completePhoneSignIn(credential, fullName: fullNameIfNew);
      _phoneCodeBrake.reset();
      return profile;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'invalid-verification-code') _phoneCodeBrake.recordFailure();
      throw AuthException(_messageFor(e));
    }
  }

  /// Final step for a NEW phone customer after [PhoneNameRequiredException]:
  /// writes `users/{uid}` (role customer) and loads the profile, which also
  /// creates the customer's Supabase row exactly like any other customer.
  Future<AppUser> completePhoneProfile(String fullName) async {
    final user = _auth.currentUser;
    if (user == null || (user.phoneNumber ?? '').isEmpty) {
      throw const AuthException(
        'Your sign-in session expired. Please verify your phone number again.',
      );
    }
    return _createPhoneCustomer(user, fullName);
  }

  /// Backs out of a phone sign-in that has no profile yet (e.g. "Change
  /// number" on the name step) so nothing stays half signed in.
  Future<void> cancelPhoneSignIn() async {
    _userInitiatedSignOut = true;
    try {
      await _auth.signOut();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'auth_service:410');
    }
  }

  Future<AppUser> _completePhoneSignIn(
    AuthCredential credential, {
    String? fullName,
  }) async {
    StaffSessionStore.instance.beginAuthentication();
    try {
      final result = await _auth.signInWithCredential(credential);
      final fbUser = result.user;
      if (fbUser == null) {
        throw const AuthException('Sign-in failed. Please try again.');
      }
      _userInitiatedSignOut = false;

      final bool hasProfile;
      try {
        final doc = await _firestore.collection(_usersCollection).doc(fbUser.uid).get();
        hasProfile = doc.exists;
      } on FirebaseException {
        // Fail closed and start clean: the SMS code is single-use anyway.
        await _auth.signOut();
        throw const AuthException(
          'We could not verify your account right now. Please check your connection and request a new code.',
        );
      }

      if (hasProfile) {
        return await _loadAndValidateProfile(fbUser.uid);
      }
      final name = (fullName ?? '').trim();
      if (name.isEmpty) {
        throw const PhoneNameRequiredException();
      }
      return await _createPhoneCustomer(fbUser, name);
    } finally {
      StaffSessionStore.instance.endAuthentication();
    }
  }

  Future<AppUser> _createPhoneCustomer(User fbUser, String fullName) async {
    final name = fullName.trim();
    if (name.isEmpty) {
      throw const AuthException('Please enter your full name.');
    }
    if (name.length > 100) {
      throw const AuthException('Your name is too long (100 characters at most).');
    }
    final appUser = AppUser(
      uid: fbUser.uid,
      email: '',
      name: name,
      role: UserRole.customer,
      phone: fbUser.phoneNumber ?? '',
      isActive: true,
    );
    try {
      await _firestore
          .collection(_usersCollection)
          .doc(fbUser.uid)
          .set(appUser.toFirestore(serverTimestamp: true));
    } on FirebaseException {
      throw const AuthException(
        'We could not finish creating your account. Please try again.',
      );
    }
    try {
      await fbUser.updateDisplayName(name);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'auth_service:479');
      // Not critical; the name lives in the profile.
    }
    _userInitiatedSignOut = false;
    // Same path as every customer sign-in: validates the profile and creates
    // the Supabase customer_profiles row (ensureProfile) + hydrates the cart.
    return _loadAndValidateProfile(fbUser.uid);
  }

  /// Abandons an unfinished sign-up: deletes the never-verified account so the
  /// address is not left tied up, and signs out.
  Future<void> cancelCustomerRegistration() async {
    final user = _auth.currentUser;
    _pendingName = null;
    _pendingPhone = null;
    _userInitiatedSignOut = true;
    if (user != null && !user.emailVerified) {
      try {
        await user.delete();
        return;
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'auth_service:499');
        // Fall through to a plain sign-out.
      }
    }
    await _auth.signOut();
  }

  /// Owner-only: creates a staff / owner / delivery account.
  ///
  /// Creating a Firebase Auth user normally signs that user in on the
  /// current app instance, which would kick the owner out of their own
  /// session. To avoid that, this runs the creation on a short-lived
  /// secondary [FirebaseApp] instance and tears it down immediately after,
  /// so the owner's session is never touched.
  ///
  /// Authorization: this method refuses non-owners, but that is only a UX
  /// check. `firestore.rules` allows creating a non-customer profile ONLY for
  /// an active owner, so a modified client cannot mint privileged accounts.
  /// NOTE: creating the Auth user itself is still client-side (anyone with the
  /// public API key can create an *Auth* user, but without a profile document
  /// that user is rejected at sign-in and by the rules). Moving this to a
  /// Cloud Function with the Admin SDK is the stronger long-term design.
  Future<AppUser> createManagedAccount({
    required String name,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
    String? branch,
  }) async {
    _requireActiveOwner();
    if (role == UserRole.customer) {
      throw const AuthException(
        'Customers create their own account from the Customer Access screen.',
      );
    }
    final needsBranch = role == UserRole.staff || role == UserRole.delivery;
    if (needsBranch) {
      // Checked against the real `branches` table before any account is created.
      if (kBranches.isEmpty) await BranchRepository.instance.loadBranches();
      if (branch == null || !kBranches.any((b) => b.name == branch)) {
        throw const AuthException('Please select a valid branch.');
      }
    }

    final tempAppName = 'melai_nuts_admin_create_${DateTime.now().microsecondsSinceEpoch}';
    final tempApp = await Firebase.initializeApp(
      name: tempAppName,
      options: Firebase.app().options,
    );
    try {
      final tempAuth = FirebaseAuth.instanceFor(app: tempApp);
      final credential = await tempAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final newUser = credential.user;
      if (newUser == null) {
        throw const AuthException('Account creation failed. Please try again.');
      }
      try {
        await newUser.updateDisplayName(name.trim());

        final appUser = AppUser(
          uid: newUser.uid,
          email: newUser.email ?? email.trim(),
          name: name.trim(),
          role: role,
          phone: phone?.trim(),
          branch: needsBranch ? branch : null,
          isActive: true,
        );
        // Staff and owners must also exist in the database's own staff
        // registry: that is what the database checks (branch, permissions,
        // active flag) on every staff request. Done BEFORE the Firestore
        // profile so a failure leaves nothing half-created.
        if (role == UserRole.staff || role == UserRole.owner) {
          try {
            await StaffRepository.instance.upsertStaffMember(
              firebaseUid: newUser.uid,
              fullName: name.trim(),
              email: newUser.email ?? email.trim(),
              role: role == UserRole.owner ? 'owner' : 'staff',
              branchName: needsBranch ? branch : null,
            );
          } catch (e) {
            try {
              await newUser.delete();
            } catch (caughtError, caughtStack) {
              AppErrors.report(caughtError, caughtStack, 'auth_service:587');
            }
            throw AuthException(
              e is AuthException ? e.message : 'Could not register this account in the staff database. ${e.toString()}',
            );
          }
        }
        // Delivery accounts are registered in the database's driver registry
        // (what the driver RPCs check), for the same reason as staff above.
        if (role == UserRole.delivery) {
          try {
            await DriverRepository.instance.registerDriver(
              firebaseUid: newUser.uid,
              fullName: name.trim(),
              email: newUser.email ?? email.trim(),
              branchName: branch!,
              phone: phone?.trim(),
            );
          } catch (e) {
            try {
              await newUser.delete();
            } catch (caughtError, caughtStack) {
              AppErrors.report(caughtError, caughtStack, 'auth_service:607');
            }
            throw AuthException(
              e is AuthException ? e.message : 'Could not register this account as a driver. ${e.toString()}',
            );
          }
        }
        await _firestore
            .collection(_usersCollection)
            .doc(newUser.uid)
            .set(appUser.toFirestore(serverTimestamp: true));
        await tempAuth.signOut();
        return appUser;
      } on FirebaseException {
        // Roll back the half-created Auth user (still signed in on tempAuth)
        // AND the staff_members row created above, if any — otherwise that
        // row is orphaned forever: registered against a Firebase UID whose
        // Auth account no longer exists, still showing up in staff lists,
        // and blocking a retry with the same email.
        if (role == UserRole.staff || role == UserRole.owner) {
          try {
            await StaffRepository.instance.removeStaffMember(newUser.uid);
          } catch (caughtError, caughtStack) {
            AppErrors.report(caughtError, caughtStack, 'auth_service:628');
          }
        }
        try {
          await newUser.delete();
        } catch (caughtError, caughtStack) {
          AppErrors.report(caughtError, caughtStack, 'auth_service:632');
        }
        throw const AuthException(
          'Could not save the new account. Please try again.',
        );
      }
    } on FirebaseAuthException catch (e) {
      throw AuthException(_messageFor(e));
    } finally {
      await tempApp.delete();
    }
  }

  /// Sets whether a managed (non-customer) account can sign in. This is a
  /// soft-delete: [signIn] rejects any profile with `isActive == false`, and
  /// `firestore.rules` stops honouring an inactive user's role immediately,
  /// even if their device still holds a valid session.
  /// Actually deleting the Firebase Auth user requires the Admin SDK.
  Future<void> setAccountActive(String uid, bool isActive) async {
    _requireActiveOwner();
    // The database's staff registry first (it is what blocks data access
    // immediately); a no-op for accounts that are not staff/owners.
    try {
      await StaffRepository.instance.setStaffActive(uid, isActive);
    } catch (e) {
      throw AuthException(e.toString());
    }
    // Drivers live in their own registry; "could not be found" just means
    // this account is not a driver.
    try {
      await DriverRepository.instance.setDriverStatus(uid, isActive ? 'active' : 'inactive');
    } catch (e) {
      if (!e.toString().contains('could not be found')) throw AuthException(e.toString());
    }
    await _firestore.collection(_usersCollection).doc(uid).update({
      'isActive': isActive,
    });
  }

  /// Live list of every managed (staff/owner/delivery) account, for the
  /// owner's User Management screen. Firestore rules only serve this to owners.
  Stream<List<AppUser>> watchManagedAccounts() {
    return _firestore
        .collection(_usersCollection)
        .where('role', whereIn: [
      UserRole.staff.name,
      UserRole.owner.name,
      UserRole.delivery.name,
    ])
        .snapshots()
        .map((snap) => snap.docs.map(AppUser.fromFirestore).toList());
  }

  /// Sends a password-reset email. To avoid revealing which emails have
  /// accounts, an unknown address behaves exactly like a known one.
  Future<void> sendPasswordResetEmail(String email) async {
    final key = email.trim().toLowerCase();
    final last = _lastResetRequest[key];
    if (last != null && DateTime.now().difference(last) < _resetCooldown) {
      throw const AuthException(
        'A reset link was just requested. Please wait a minute before trying again.',
      );
    }
    _lastResetRequest[key] = DateTime.now();
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') return; // do not reveal account existence
      _lastResetRequest.remove(key); // request failed; allow a retry
      throw AuthException(_messageFor(e));
    }
  }

  /// Changes the password of the currently signed-in user (used by the
  /// "Login & Security" > Change Password flow, as opposed to
  /// [sendPasswordResetEmail] which is for someone who's locked out).
  /// Firebase requires a *recent* sign-in for this; if the session is too
  /// old it throws an [AuthException] asking the person to sign in again.
  /// Changing a password also invalidates the user's other sessions.
  Future<void> changePassword(String newPassword) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('You need to be signed in to change your password.');
    }
    try {
      await user.updatePassword(newPassword);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        throw const AuthException(
          'For your security, please sign out and sign in again before changing your password.',
        );
      }
      throw AuthException(_messageFor(e));
    }
  }

  /// Signs out of Firebase and clears everything held in memory for the
  /// previous user. Queued offline writes are flushed first (while still
  /// authenticated) on a best-effort basis; the on-disk Firestore cache is
  /// wiped on the next app start (see [DataSyncService.initializeLocalDatabase]).
  Future<void> signOut() async {
    _userInitiatedSignOut = true;
    final signingOutStaffUid = StaffSessionStore.instance.ownerUid;
    // While the session is still valid: push any queued staff operations
    // (bounded, best effort — whatever cannot be sent stays queued on the
    // device for this staff member and is never deleted). Skipped when there
    // is nothing queued so a normal sign-out stays instant.
    if (StaffSessionStore.instance.isServerValidated && SyncService.instance.pendingCount > 0) {
      await SyncService.instance.flushBeforeSignOut();
    }
    _currentProfile = null;
    // Drop the staff member's profile, branch, permissions and every hook
    // registered by later staff stores, synchronously, before anything awaits.
    StaffSessionStore.instance.clear();
    // While the session is still valid: best-effort push of queued customer
    // changes, then wipe the durable per-customer state (unsent writes,
    // unconfirmed checkout, saved server responses) so a signed-out device
    // holds no customer data.
    final signingOutUid = _auth.currentUser?.uid;
    if (signingOutUid != null) {
      try {
        await CustomerDataStore.instance.prepareForSignOut(signingOutUid);
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'auth_service:753');
      }
    }
    CartController.instance.endSession();
    CustomerDataStore.instance.clear();
    StaffStore.instance.clear();
    BranchController.instance.clear();
    if (signingOutStaffUid != null) {
      // A signed-out device holds no staff authorization: delete the offline
      // copy of their context. Synced operations are tidied; unsent and
      // failed ones are kept for when this staff member signs in again.
      await SyncService.instance.tidyForSignOut(signingOutStaffUid);
      await StaffSessionStore.instance.forgetCachedContext(signingOutStaffUid);
    }
    await DataSyncService.instance.syncPendingWrites();
    await _auth.signOut();
  }

  Future<AppUser> _loadAndValidateProfile(
    String uid, {
    bool allowVerificationResume = false,
  }) async {
    final DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await _firestore.collection(_usersCollection).doc(uid).get();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied' || e.code == 'unauthenticated') {
        await signOut();
        throw const AuthException(
          'Your session is no longer valid. Please sign in again.',
        );
      }
      // Offline with nothing cached, timeouts, etc.: fail closed, keep session.
      throw const AuthException(
        'We could not verify your account right now. Please check your connection and try again.',
      );
    }

    if (!doc.exists) {
      final fbUser = _auth.currentUser;
      if (fbUser != null && fbUser.uid == uid && (fbUser.phoneNumber ?? '').isNotEmpty) {
        // Phone sign-in that never got its name step: no email to verify.
        await signOut();
        throw const AuthException(
          'Please sign in with your phone number again to finish creating your account.',
        );
      }
      if (allowVerificationResume &&
          fbUser != null &&
          fbUser.uid == uid &&
          !fbUser.emailVerified) {
        // Unfinished customer sign-up: keep the session so it can be completed.
        throw const EmailVerificationRequiredException();
      }
      await signOut();
      throw const AuthException(
        'No account profile found. Please contact your administrator.',
      );
    }

    final AppUser appUser;
    try {
      appUser = AppUser.fromFirestore(doc);
    } on FormatException {
      await signOut();
      throw const AuthException(
        'This account is misconfigured. Please contact your administrator.',
      );
    }

    if (!appUser.isActive) {
      await signOut();
      throw const AuthException(
        'This account has been deactivated. Please contact your administrator.',
      );
    }
    _currentProfile = appUser;

    if (appUser.role == UserRole.staff) {
      // Firebase UID -> Supabase staff profile, branch and permissions.
      await _bindStaffContext(appUser);
    } else if (StaffSessionStore.instance.ownerUid != appUser.uid) {
      // Never let a previous staff member's context outlive their session.
      // (An owner's own session is kept: it loads on demand and is bound to
      // this uid, so it is never shown to anyone else.)
      StaffSessionStore.instance.clear();
    }

    if (appUser.role == UserRole.customer) {
      // Business data lives in Supabase, keyed by this same Firebase UID.
      // Best-effort: a slow/offline connection here must not block sign-in
      // itself (the screens that need this data load it themselves too).
      CustomerDataStore.instance.rememberCustomer(
        firebaseUid: appUser.uid,
        fallbackName: appUser.name,
        fallbackEmail: appUser.email,
      );
      try {
        await CustomerDataStore.instance.ensureProfile(
          firebaseUid: appUser.uid,
          fallbackName: appUser.name,
          fallbackEmail: appUser.email,
        );
        await Future.wait([
          CartController.instance.hydrate(appUser.uid),
          CustomerDataStore.instance.loadForCustomer(appUser.uid),
        ]);
        // Needs CustomerDataStore.profile (just loaded above) to restore
        // the customer's saved default branch.
        unawaited(BranchController.instance.hydrate());
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'auth_service:862');
        // Non-fatal — never block sign-in. But make sure a load is still
        // attempted and its outcome recorded, so customer screens show an
        // error state with a Retry button instead of staying silently empty.
        unawaited(CustomerDataStore.instance.loadForCustomer(appUser.uid));
        unawaited(BranchController.instance.hydrate());
      }
    }

    return appUser;
  }

  /// Loads the signed-in staff member's Supabase profile, branch and
  /// permissions ([StaffSessionStore]) and refuses the session when the server
  /// says the account may not work: no staff profile yet, or deactivated.
  ///
  /// A *transient* failure (offline, timeout) does NOT sign the person out —
  /// the store stays locked ([StaffSessionStatus.failed]) and `RouteGuard`
  /// shows a Retry screen instead of the staff portal (fail closed).
  Future<void> _bindStaffContext(AppUser appUser) async {
    final status = await StaffSessionStore.instance.loadForStaff(appUser.uid);
    if (status == StaffSessionStatus.notProvisioned) {
      await signOut();
      throw const AuthException(
        'This staff account has not been assigned to a branch yet. '
        'Please contact your administrator.',
      );
    }
    if (status == StaffSessionStatus.inactive) {
      await signOut();
      throw const AuthException(
        'This account has been deactivated. Please contact your administrator.',
      );
    }
    if (status == StaffSessionStatus.suspended) {
      await signOut();
      throw const AuthException(
        'This account has been suspended. Please contact your administrator.',
      );
    }
    if (status == StaffSessionStatus.invalidRole) {
      await signOut();
      throw const AuthException(
        'This account has a role the app does not recognise. Please contact your administrator.',
      );
    }
    if (status == StaffSessionStatus.invalidBranch) {
      await signOut();
      throw const AuthException(
        'This account is not assigned to a valid branch. Please contact your administrator.',
      );
    }
  }

  void _requireActiveOwner() {
    final caller = _currentProfile;
    if (caller == null || caller.role != UserRole.owner || !caller.isActive) {
      throw const AuthException('Only an active owner can do this.');
    }
  }

  void _throwIfBraked(_FailureBrake brake) {
    final left = brake.remaining;
    if (left != null) {
      final secs = left.inSeconds + 1;
      final wait = secs >= 60 ? '${(secs / 60).ceil()} minute(s)' : '$secs seconds';
      throw AuthException('Too many attempts. Please wait $wait and try again.');
    }
  }

  String _messageFor(FirebaseAuthException e) {
    // Debug builds only: log the code and Firebase's error text (which names
    // console/config problems such as CONFIGURATION_NOT_FOUND). Never logged
    // in release, and never includes the email or password.
    if (kDebugMode) {
      debugPrint('FirebaseAuthException code: ${e.code} | ${e.message}');
    }
    switch (e.code) {
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled. Please contact your administrator.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'weak-password':
        return 'That password is too weak. Please choose a stronger one.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'Network error. Please check your connection and try again.';
      case 'user-token-expired':
      case 'requires-recent-login':
        return 'Your session has expired. Please sign in again.';
      case 'invalid-phone-number':
      case 'missing-phone-number':
        return 'That mobile number is not valid. Please check it and try again.';
      case 'invalid-verification-code':
        return 'That code is not correct. Please check the SMS and try again.';
      case 'invalid-verification-id':
      case 'session-expired':
      case 'code-expired':
        return 'That code has expired. Please request a new code.';
      case 'quota-exceeded':
        return 'We have sent too many codes right now. Please try again later.';
      case 'captcha-check-failed':
        return 'Security check failed. Please try again.';
      case 'app-not-authorized':
      case 'missing-client-identifier':
      case 'invalid-app-credential':
        return 'Phone sign-in is not set up for this build of the app yet. '
            'Add the Android SHA-1 and SHA-256 fingerprints in the Firebase '
            'project settings and re-download google-services.json.';
      case 'internal-error':
        // The sign-in blocking function (functions/index.js) refuses deactivated
        // accounts; Firebase reports that as `internal-error` with the function's
        // message inside. Keep the marker in sync with functions/lib/handlers.js.
        if ((e.message ?? '').contains('ACCOUNT_DEACTIVATED')) {
          return 'This account has been deactivated. Please contact your administrator.';
        }
        return 'This sign-in method is not available right now. Please try again later.';
      case 'operation-not-allowed':
        return 'This sign-in method is not available right now. Please try again later.';
      default:
        // Never surface raw SDK messages: they can contain internal details.
        return 'Something went wrong. Please try again.';
    }
  }
}
