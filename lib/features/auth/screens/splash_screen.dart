import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/page_transitions.dart';
import 'email_verification_screen.dart';
import 'welcome_screen.dart';
import '../../../core/utils/app_error.dart';

/// First screen shown on launch: a short logo reveal while checking whether
/// someone is already signed in (Firebase persists sessions across app
/// restarts), so returning users land straight back in their portal and
/// everyone else on the Welcome screen. It waits only for that check and the
/// reveal itself.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final Animation<double> _logo = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0, 0.7, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _wordmark = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0.35, 1, curve: Curves.easeOut),
  );

  /// Set once the session check knows where to go; runs when the reveal ends.
  VoidCallback? _destination;

  @override
  void initState() {
    super.initState();
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed) _goIfReady();
    });
    _reveal.forward();
    _resolveSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Reduce motion": no reveal to wait for.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) _reveal.value = 1;
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  void _goIfReady() {
    if (!mounted || !_reveal.isCompleted) return;
    final destination = _destination;
    _destination = null;
    destination?.call();
  }

  Future<void> _resolveSession() async {
    VoidCallback destination = () {
      Navigator.of(context).pushReplacement(FadeSlideRoute.fade(builder: (_) => const WelcomeScreen()));
    };
    try {
      final profile = await AuthService.instance.loadCurrentProfile(
        allowVerificationResume: true,
      );
      if (!mounted) return;
      if (profile != null) {
        final route = AppRoutes.homeFor(profile.role);
        destination = () => Navigator.of(context).pushReplacementNamed(route);
      }
    } on EmailVerificationRequiredException {
      if (!mounted) return;
      destination = () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const EmailVerificationScreen()),
          );
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'splash_screen:50');
      // Ignore — e.g. no network on first launch. Fall through to Welcome;
      // Sign In will surface a clearer error on the actual attempt.
    }
    if (!mounted) return;
    _destination = destination;
    _goIfReady();
  }

  @override
  Widget build(BuildContext context) {
    return LuxeDarkBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeTransition(
                    opacity: _logo,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.86, end: 1).animate(_logo),
                      child: const LuxeCrest(size: 128),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FadeTransition(
                    opacity: _wordmark,
                    child: Column(
                      children: [
                        Text(
                          AppConstants.appName,
                          textAlign: TextAlign.center,
                          style: AppTextStyles.headlineLg.copyWith(color: Colors.white),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const LuxeDivider(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
