import 'package:flutter/material.dart';

import '../../../core/services/branch_choice.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../cart_controller.dart';

/// "Ordering from: Santa Cruz (nearest to you)".
String orderingFromText(AppLocalizations t, BranchChoice choice) {
  final name = choice.branch.name;
  return switch (choice.reason) {
    BranchChoiceReason.nearest => t.orderingFromNearest(name),
    BranchChoiceReason.lastOrder => t.orderingFromLastOrder(name),
    _ => t.orderingFrom(name),
  };
}

/// What happened to one cart line when the cart moved.
String shortfallText(AppLocalizations t, StockShortfall shortfall) {
  if (shortfall.available <= 0) return t.cartItemRemoved(shortfall.name);
  return t.cartItemLowered(shortfall.name, shortfall.available.toString());
}

/// Every line of the notice about a move that changed the cart.
List<String> moveNoticeLines(AppLocalizations t, CartMoveNotice notice) => [
      t.cartMovedTo(notice.branchName),
      for (final shortfall in notice.shortfalls) shortfallText(t, shortfall),
      if (notice.droppedDiscounts) t.cartDiscountsRemoved,
    ];

/// Tells the customer what a move to another branch changed in their cart.
class CartMoveNoticeCard extends StatelessWidget {
  final CartMoveNotice notice;

  const CartMoveNoticeCard({super.key, required this.notice});

  @override
  Widget build(BuildContext context) {
    final lines = moveNoticeLines(AppLocalizations.of(context), notice);
    return _NoticeBox(
      children: [
        Text(lines.first, style: AppTextStyles.labelLg),
        for (final line in lines.skip(1))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(line, style: AppTextStyles.bodySm),
          ),
      ],
    );
  }
}

/// Location is off or denied: asks the customer to turn it on.
class LocationNeededNotice extends StatelessWidget {
  const LocationNeededNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _NoticeBox(
      children: [
        Text(t.branchLocationNeeded, style: AppTextStyles.bodySm),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () => turnOnLocationForBranch(context),
          child: Text(t.branchTurnOnLocation),
        ),
      ],
    );
  }
}

class _NoticeBox extends StatelessWidget {
  final List<Widget> children;

  const _NoticeBox({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
