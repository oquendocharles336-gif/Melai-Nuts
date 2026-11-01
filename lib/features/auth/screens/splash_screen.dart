import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/page_transitions.dart';
import 'email_verification_screen.dart';
import 'welcome_screen.dart';
import '../../../core/utils/app_error.dart';

/// First screen shown on launch. The logo bounces in with a burst of sparkles
/// and the name appears letter by letter, while checking whether someone is
/// already signed in (Firebase persists sessions across app restarts), so
/// returning users land straight back in their portal and everyone else on the
/// Welcome screen. It waits only for that check and the animation itself.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));

  /// A gentle bob if the session check takes longer than the reveal.
  late final AnimationController _idle =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  late final Animation<double> _logo = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0, 0.5, curve: Curves.elasticOut),
  );
  late final Animation<double> _wiggle = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0.05, 0.6, curve: Curves.easeOut),
  );
  late final Animation<double> _burst = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0.12, 0.72, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _tagline = CurvedAnimation(
    parent: _reveal,
    curve: const Interval(0.78, 1, curve: Curves.easeOut),
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
    _idle.dispose();
    super.dispose();
  }

  void _goIfReady() {
    if (!mounted || !_reveal.isCompleted) return;
    final destination = _destination;
    if (destination == null) {
      if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) _idle.repeat(reverse: true);
      return;
    }
    _destination = null;
    _idle.stop();
    destination();
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

  /// One letter sliding up into place, each a little after the last.
  Widget _letter(String char, int index, int count) {
    final start = 0.42 + 0.34 * index / count;
    final letter = CurvedAnimation(
      parent: _reveal,
      curve: Interval(start, math.min(start + 0.22, 1), curve: Curves.easeOutBack),
    );
    return AnimatedBuilder(
      animation: letter,
      builder: (context, child) => Opacity(
        opacity: letter.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 22 * (1 - letter.value)), child: child),
      ),
      child: Text(
        char == ' ' ? ' ' : char,
        style: AppTextStyles.display.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const name = AppConstants.appName;
    return LuxeSunBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 300,
                    height: 260,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(painter: _BurstPainter(_burst)),
                          ),
                        ),
                        AnimatedBuilder(
                          animation: Listenable.merge([_logo, _wiggle, _idle]),
                          builder: (context, child) {
                            final wobble = math.sin(_wiggle.value * math.pi * 3) * 0.16 * (1 - _wiggle.value);
                            final bob = Curves.easeInOut.transform(_idle.value);
                            return Transform.translate(
                              offset: Offset(0, -8 * bob),
                              child: Transform.rotate(
                                angle: wobble,
                                child: Transform.scale(scale: _logo.value, child: child),
                              ),
                            );
                          },
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(color: Color(0x55C2410C), blurRadius: 44, offset: Offset(0, 14))],
                            ),
                            child: AppLogo(size: 168),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // The name is read once as a whole, not letter by letter.
                  Semantics(
                    label: name,
                    excludeSemantics: true,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < name.length; i++) _letter(name[i], i, name.length),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  FadeTransition(
                    opacity: _tagline,
                    child: Text(
                      AppConstants.appTagline.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: AppTextStyles.labelMd.copyWith(color: AppColors.primaryDark, letterSpacing: 3),
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

/// Two rings and a ring of sparkles spreading out from behind the logo.
class _BurstPainter extends CustomPainter {
  final Animation<double> progress;

  _BurstPainter(this.progress) : super(repaint: progress);

  static const _sparkles = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1) return;
    final center = size.center(Offset.zero);
    final fade = 1 - t;

    for (final ring in const [0.0, 0.18]) {
      final r = (t - ring).clamp(0.0, 1.0);
      if (r <= 0) continue;
      canvas.drawCircle(
        center,
        70 + 80 * r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * (1 - r) + 0.5
          ..color = AppColors.primary.withValues(alpha: 0.55 * (1 - r)),
      );
    }

    final dot = Paint();
    for (var i = 0; i < _sparkles; i++) {
      final angle = i * 2 * math.pi / _sparkles + 0.2;
      final reach = 80 + (i.isEven ? 66 : 44) * t;
      final at = center + Offset(math.cos(angle), math.sin(angle)) * reach;
      dot.color = (i % 3 == 0 ? AppColors.primary : AppColors.honeyDeep).withValues(alpha: fade);
      canvas.drawCircle(at, (i.isEven ? 5.0 : 3.5) * fade + 0.5, dot);
    }
  }

  @override
  bool shouldRepaint(_BurstPainter oldDelegate) => oldDelegate.progress != progress;
}
