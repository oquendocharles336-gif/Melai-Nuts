import 'package:flutter/material.dart';

import '../../../core/services/branch_choice.dart';
import '../../../core/services/branch_controller.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/branch.dart';
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

/// Location is off, denied or slow: "Use my location" (turn it on) and a list
/// to choose the branch by hand, so checkout never depends on location.
class LocationNeededNotice extends StatelessWidget {
  const LocationNeededNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _NoticeBox(
      children: [
        Text(t.branchLocationNeeded, style: AppTextStyles.bodySm),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            FilledButton.icon(
              onPressed: () => turnOnLocationForBranch(context),
              icon: const Icon(Icons.my_location_rounded, size: 18),
              label: Text(t.branchUseMyLocation),
            ),
            OutlinedButton.icon(
              onPressed: () => showBranchPicker(context),
              icon: const Icon(Icons.storefront_rounded, size: 18),
              label: Text(t.branchChooseManually),
            ),
          ],
        ),
      ],
    );
  }
}

/// Bottom sheet listing the open pickup branches; the choice moves the cart.
Future<void> showBranchPicker(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final open = kBranches.where((b) => b.isOpenForPickup).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final current = BranchController.instance.selectedBranch?.id;
  final picked = await showModalBottomSheet<Branch>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
              child: Semantics(header: true, child: Text(t.branchPickerTitle, style: AppTextStyles.titleMd)),
            ),
            if (open.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(t.branchPickerEmpty, style: AppTextStyles.bodySm),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final branch in open)
                      ListTile(
                        minVerticalPadding: AppSpacing.sm,
                        leading: Icon(
                          branch.id == current ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                          color: AppColors.primary,
                        ),
                        title: Text(branch.name, style: AppTextStyles.labelLg),
                        subtitle: branch.address.isEmpty ? null : Text(branch.address, style: AppTextStyles.bodySm),
                        selected: branch.id == current,
                        onTap: () => Navigator.of(sheetContext).pop(branch),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    ),
  );
  if (picked != null) await BranchController.instance.chooseManually(picked);
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
