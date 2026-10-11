import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/order.dart';
import '../../../data/models/refund.dart';
import 'refund_review_screen.dart';

class RefundRequestScreen extends StatefulWidget {
  final Order order;

  const RefundRequestScreen({
    super.key,
    required this.order,
  });

  @override
  State<RefundRequestScreen> createState() => _RefundRequestScreenState();
}

class _RefundRequestScreenState extends State<RefundRequestScreen> {
  final Map<int, bool> _selected = {};
  String _reason = kRefundReasons.first;
  final _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();

    for (int i = 0; i < widget.order.items.length; i++) {
      _selected[i] = true;
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  List<OrderItem> get _chosenItems => [
        for (int i = 0; i < widget.order.items.length; i++)
          if (_selected[i] == true) widget.order.items[i],
      ];

  double get _chosenAmount =>
      _chosenItems.fold(0, (sum, item) => sum + item.total);

  @override
  Widget build(BuildContext context) {
    final canContinue = _chosenItems.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(
        title: 'Request a Refund',
        showBack: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.receipt_long_rounded,
                    color: AppColors.darkBrown,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Order ${widget.order.id}',
                          style: AppTextStyles.titleMd,
                        ),
                        Text(
                          '${widget.order.branch} • ₱${widget.order.total.toStringAsFixed(0)}',
                          style: AppTextStyles.bodySm,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Select Item(s) to Refund',
              style: AppTextStyles.titleMd,
            ),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < widget.order.items.length; i++)
              CheckboxListTile(
                value: _selected[i] ?? false,
                onChanged: (value) {
                  setState(() {
                    _selected[i] = value ?? false;
                  });
                },
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  widget.order.items[i].productName,
                  style: AppTextStyles.labelLg,
                ),
                subtitle: Text(
                  '${widget.order.items[i].variantLabel} • ${widget.order.items[i].quantity}x',
                  style: AppTextStyles.bodySm,
                ),
                secondary: Text(
                  '₱${widget.order.items[i].total.toStringAsFixed(0)}',
                  style: AppTextStyles.labelLg,
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Reason for Refund',
              style: AppTextStyles.titleMd,
            ),
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(color: AppColors.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _reason,
                  isExpanded: true,
                  items: [
                    for (final reason in kRefundReasons)
                      DropdownMenuItem(
                        value: reason,
                        child: Text(reason),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _reason = value ?? _reason;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Additional Notes (optional)',
              style: AppTextStyles.titleMd,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Describe the issue in a few words…',
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: PrimaryButton(
            label: 'Review Request (₱${_chosenAmount.toStringAsFixed(0)})',
            icon: Icons.arrow_forward_rounded,
            onPressed: canContinue
                ? () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RefundReviewScreen(
                          order: widget.order,
                          items: _chosenItems,
                          reason: _reason,
                          notes: _notesController.text,
                          amount: _chosenAmount,
                        ),
                      ),
                    )
                : null,
          ),
        ),
      ),
    );
  }
}
