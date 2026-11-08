import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/page_transitions.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../cart_controller.dart';
import '../screens/cart_screen.dart';

/// Small storefront pieces shared by Store, Catalog, Search, Cart and
/// Checkout. Colours come from [AppColors] only (docs/DESIGN_GUIDE.md).

/// Whether [product] matches what the customer typed in a storefront search
/// box. Every word must appear somewhere in the name, tags, category name or
/// description; case and word order don't matter ("spicy garlic" finds
/// "Garlic Peanuts, Spicy").
bool productMatchesSearch(Product product, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  String? categoryName;
  for (final category in kProductCategories) {
    if (category.id == product.categoryId) categoryName = category.name;
  }
  final haystack = [
    product.name,
    ...product.tags,
    ?categoryName,
    product.description,
  ].join(' ').toLowerCase();
  return words.every(haystack.contains);
}

/// Wraps [child] in a count badge that gives a short "bump" each time
/// [count] changes, so adding to the cart is visible from anywhere.
class BumpingCountBadge extends StatefulWidget {
  final int count;
  final Widget child;
  final Color background;
  final Color foreground;

  const BumpingCountBadge({
    super.key,
    required this.count,
    required this.child,
    this.background = AppColors.honey,
    this.foreground = AppColors.ink,
  });

  @override
  State<BumpingCountBadge> createState() => _BumpingCountBadgeState();
}

class _BumpingCountBadgeState extends State<BumpingCountBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _bump = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween<double>(begin: 1, end: 1.35).chain(CurveTween(curve: Curves.easeOut)), weight: 40),
    TweenSequenceItem(tween: Tween<double>(begin: 1.35, end: 1).chain(CurveTween(curve: Curves.elasticOut)), weight: 60),
  ]).animate(_bump);

  @override
  void didUpdateWidget(BumpingCountBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (oldWidget.count != widget.count && widget.count > 0 && !reduceMotion) {
      _bump.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _bump.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: widget.count > 0,
      backgroundColor: widget.background,
      textColor: widget.foreground,
      label: ScaleTransition(
        scale: _scale,
        child: Text(widget.count > 99 ? '99+' : '${widget.count}'),
      ),
      child: widget.child,
    );
  }
}

/// App-bar cart button with the live item count. Opens the cart.
class CartIconButton extends StatelessWidget {
  final Color? iconColor;

  const CartIconButton({super.key, this.iconColor});

  @override
  Widget build(BuildContext context) {
    final cart = CartController.instance;
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        final count = cart.itemCount;
        return IconButton(
          tooltip: count > 0 ? 'Cart, $count items' : 'Cart',
          onPressed: () => Navigator.of(context).push(FadeSlideRoute(builder: (_) => const CartScreen())),
          // Honey with dark text, like the Store header's badge: it stays
          // readable on the orange app bar (orange on orange didn't).
          icon: BumpingCountBadge(
            count: count,
            child: Icon(Icons.shopping_bag_outlined, color: iconColor),
          ),
        );
      },
    );
  }
}

/// Cart → Checkout → Confirmed, with the current step highlighted. Each step
/// has an icon and a label, so the state never relies on colour alone.
class CheckoutSteps extends StatelessWidget {
  /// 0 = Cart, 1 = Checkout, 2 = Confirmed.
  final int current;

  const CheckoutSteps({super.key, required this.current});

  static const _steps = [
    (label: 'Cart', icon: Icons.shopping_bag_outlined),
    (label: 'Checkout', icon: Icons.storefront_outlined),
    (label: 'Confirmed', icon: Icons.check_circle_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < _steps.length; i++) {
      final step = _steps[i];
      final done = i < current;
      final active = i == current;
      if (i > 0) {
        children.add(
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 2,
              margin: const EdgeInsets.only(bottom: 18),
              color: i <= current ? AppColors.primary : AppColors.border,
            ),
          ),
        );
      }
      children.add(
        Semantics(
          label: '${step.label}${active ? ', current step' : done ? ', done' : ''}',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? AppColors.primary
                      : done
                          ? AppColors.primaryContainer
                          : AppColors.surfaceContainer,
                  border: Border.all(color: active || done ? AppColors.primary : AppColors.border),
                ),
                child: Icon(
                  done ? Icons.check_rounded : step.icon,
                  size: 18,
                  color: active ? AppColors.onPrimary : done ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xs2),
              Text(
                step.label,
                style: AppTextStyles.labelSm.copyWith(
                  color: active ? AppColors.primary : AppColors.textSecondary,
                  fontWeight: active ? FontWeight.w700 : null,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
    );
  }
}

/// Full-width − qty + control for product cards. The − and + halves each
/// take the remaining width, so both are wide, easy targets.
class QuantityStepper extends StatelessWidget {
  static const double height = 44;

  final int quantity;
  final VoidCallback onDecrease;

  /// Null when no more can be added (out of stock).
  final VoidCallback? onIncrease;
  final String itemName;

  const QuantityStepper({
    super.key,
    required this.quantity,
    required this.onDecrease,
    required this.onIncrease,
    required this.itemName,
  });

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tooltip, VoidCallback? onTap) => Expanded(
          child: Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                height: height,
                child: Icon(
                  icon,
                  size: 20,
                  color: onTap == null ? AppColors.onPrimary.withValues(alpha: 0.45) : AppColors.onPrimary,
                ),
              ),
            ),
          ),
        );
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm + 4),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          button(quantity <= 1 ? Icons.delete_outline_rounded : Icons.remove_rounded,
              quantity <= 1 ? 'Remove $itemName' : 'One less $itemName', onDecrease),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
            child: Semantics(
              key: ValueKey(quantity),
              label: '$quantity in cart',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 18),
                child: Text(
                  '$quantity',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.labelLg.copyWith(color: AppColors.onPrimary),
                ),
              ),
            ),
          ),
          button(Icons.add_rounded, 'One more $itemName', onIncrease),
        ],
      ),
    );
  }
}
