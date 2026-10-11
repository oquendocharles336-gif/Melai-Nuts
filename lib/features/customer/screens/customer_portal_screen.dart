import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/offline_banner.dart';
import 'customer_home_screen.dart';
import 'product_catalog_screen.dart';
import 'order_history_screen.dart';
import 'customer_profile_screen.dart';

/// Customer portal shell: owns the bottom navigation bar (Store / Catalog /
/// My Orders / Account) and swaps between the four top-level tabs, matching
/// the prototype's bottom nav across every customer screen.
class CustomerPortalScreen extends StatefulWidget {
  const CustomerPortalScreen({super.key});

  @override
  State<CustomerPortalScreen> createState() => _CustomerPortalScreenState();
}

class _CustomerPortalScreenState extends State<CustomerPortalScreen> {
  int _index = 0;

  bool get _isSignedIn => AuthService.instance.currentFirebaseUser != null;

  static const _tabs = [
    CustomerHomeScreen(),
    ProductCatalogScreen(),
    OrderHistoryScreen(),
    CustomerProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Guests may browse the Store and Catalog. The account-specific tabs
      // (My Orders, Account) are not even built until someone is signed in.
      body: OfflineBanner(
        child: IndexedStack(
          index: _index,
          children: [
            _tabs[0],
            _tabs[1],
            _isSignedIn ? _tabs[2] : const SizedBox.shrink(),
            _isSignedIn ? _tabs[3] : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: const Border(top: BorderSide(color: AppColors.border)),
          boxShadow: [
            BoxShadow(
              color: AppColors.darkBrown.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.white,
          elevation: 0,
          height: 68,
          indicatorColor: AppColors.primaryContainer.withValues(alpha: 0.7),
          surfaceTintColor: Colors.transparent,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return AppTextStyles.labelMd.copyWith(color: AppColors.primary);
            }
            return AppTextStyles.labelMd;
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: AppColors.primary, size: 26);
            }
            return const IconThemeData(color: AppColors.textSecondary, size: 24);
          }),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            if (i >= 2 && !_isSignedIn) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Please sign in to view your orders and account.'),
                ),
              );
              Navigator.of(context).pushNamed(AppRoutes.login);
              return;
            }
            setState(() => _index = i);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.storefront_outlined),
              selectedIcon: Icon(Icons.storefront_rounded),
              label: 'Store',
            ),
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'Catalog',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long_rounded),
              label: 'My Orders',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Account',
            ),
          ],
        ),
      ),
      ),
    );
  }
}
