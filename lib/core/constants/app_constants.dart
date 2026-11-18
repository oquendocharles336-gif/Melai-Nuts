class AppConstants {
  AppConstants._();

  static const String appName = 'Melai Nuts Retailing';
  static const String appTagline = 'Local Goodness.';

  /// A batch with stock that expires within this many days counts as
  /// "expiring soon" (Expiring Soon list, expiry alerts default window).
  static const int expiringSoonDays = 30;
  // Branch names are NOT constants: they come from the `branches` table
  // (BranchRepository -> kBranches).
}