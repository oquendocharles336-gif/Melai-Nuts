import 'package:flutter/material.dart';

import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/utils/request_key.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/repositories/staff_repository.dart';

/// The cashier's drawer: open a shift with the starting cash, record cash
/// paid in / out, see the expected cash live, and close with a count.
///
/// The database computes every total (expected cash = opening + cash sales -
/// cash refunds + paid in - paid out) and refuses a close whose count differs
/// without a note. Each action carries a request key so a retry after a
/// timeout is applied once.
class CashDrawerScreen extends StatefulWidget {
  const CashDrawerScreen({super.key});

  @override
  State<CashDrawerScreen> createState() => _CashDrawerScreenState();
}

class _CashDrawerScreenState extends State<CashDrawerScreen> {
  final _repo = StaffRepository.instance;
  final _openKey = RequestKeyHolder();
  final _moveKey = RequestKeyHolder();
  final _closeKey = RequestKeyHolder();

  Map<String, dynamic>? _shift;
  Map<String, dynamic>? _today;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _n(Object? v) => (v as num?)?.toDouble() ?? 0;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shift = await _repo.currentShift();
      final branchId = StaffStore.instance.activeBranchId;
      final today = branchId == null ? null : await _repo.cashierDailySummary(branchId);
      if (!mounted) return;
      setState(() {
        _shift = shift;
        _today = today;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppErrors.from(e).message;
        _loading = false;
      });
    }
  }

  Future<void> _act(Future<void> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _open() async {
    final branchId = StaffStore.instance.activeBranchId;
    if (branchId == null) return;
    final values = await _askAmount(title: 'Open shift', amountLabel: 'Cash in the drawer now (₱)', withReason: false);
    if (values == null) return;
    await _act(
      () => _repo.openShift(branchId, values.amount, requestKey: _openKey.keyFor('$branchId|${values.amount}')),
      'Shift opened.',
    );
  }

  Future<void> _move(String type) async {
    final id = _shift?['session_id'] as String?;
    if (id == null) return;
    final values = await _askAmount(
      title: type == 'paid_in' ? 'Cash paid in' : 'Cash paid out',
      amountLabel: 'Amount (₱)',
      withReason: true,
    );
    if (values == null) return;
    await _act(
      () => _repo.recordCashMovement(id, type, values.amount, values.text,
          requestKey: _moveKey.keyFor('$id|$type|${values.amount}|${values.text}')),
      'Recorded.',
    );
  }

  Future<void> _close() async {
    final id = _shift?['session_id'] as String?;
    if (id == null) return;
    final expected = _n(_shift?['expected_cash']);
    final values = await _askAmount(
      title: 'Close shift',
      amountLabel: 'Cash you counted (₱)',
      withReason: true,
      reasonLabel: 'Note (required if the count is off)',
      reasonRequired: false,
      hint: 'Expected in the drawer: ${peso(expected)}',
    );
    if (values == null) return;
    await _act(
      () => _repo.closeShift(id, values.amount,
          notes: values.text.isEmpty ? null : values.text,
          requestKey: _closeKey.keyFor('$id|${values.amount}|${values.text}')),
      'Shift closed.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Cash Drawer', showBack: true),
      body: SafeArea(
        child: _loading && _shift == null && _today == null
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    _shift == null ? _noShift() : _shiftCard(_shift!),
                    const SizedBox(height: AppSpacing.md),
                    if (_today != null) _todayCard(_today!),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _noShift() => _card([
        Text('No open shift', style: AppTextStyles.titleMd),
        const SizedBox(height: 6),
        Text('Count the cash in the drawer and open your shift before ringing up sales.', style: AppTextStyles.bodySm),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(label: 'Open shift', icon: Icons.lock_open_rounded, loading: _busy, onPressed: _open),
      ]);

  Widget _shiftCard(Map<String, dynamic> s) {
    final methods = s['by_method'] is Map ? Map<String, dynamic>.from(s['by_method'] as Map) : const <String, dynamic>{};
    return _card([
      Row(
        children: [
          Expanded(child: Text('Shift ${s['session_id']}', style: AppTextStyles.titleMd)),
          Text('Open', style: AppTextStyles.labelMd.copyWith(color: AppColors.success)),
        ],
      ),
      Text('Opened ${friendlyTime(DateTime.parse(s['opened_at'] as String).toLocal())}', style: AppTextStyles.bodySm),
      const Divider(height: 24),
      _row('Opening cash', peso(_n(s['opening_cash']))),
      _row('Cash sales', '+ ${peso(_n(s['cash_sales']))}'),
      _row('Cash refunds and voids', '- ${peso(_n(s['cash_refunds']))}'),
      _row('Paid in', '+ ${peso(_n(s['paid_in']))}'),
      _row('Paid out', '- ${peso(_n(s['paid_out']))}'),
      const Divider(height: 24),
      _row('Expected in drawer', peso(_n(s['expected_cash'])), bold: true),
      const SizedBox(height: 8),
      _row('Transactions', '${s['transaction_count'] ?? 0}'),
      for (final e in methods.entries)
        _row('  ${e.key.toUpperCase()}', peso(_n((e.value as Map)['amount']))),
      if ((s['void_count'] as num? ?? 0) > 0) _row('Voids', '${s['void_count']} (${peso(_n(s['void_amount']))})'),
      const SizedBox(height: AppSpacing.md),
      Row(
        children: [
          Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _move('paid_in'), child: const Text('Paid in'))),
          const SizedBox(width: AppSpacing.xs),
          Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _move('paid_out'), child: const Text('Paid out'))),
        ],
      ),
      const SizedBox(height: AppSpacing.sm),
      SecondaryButton(label: 'Close shift', icon: Icons.lock_outline_rounded, onPressed: _busy ? null : _close),
    ]);
  }

  Widget _todayCard(Map<String, dynamic> d) {
    final t = d['totals'] is Map ? Map<String, dynamic>.from(d['totals'] as Map) : const <String, dynamic>{};
    return _card([
      Text('Branch today', style: AppTextStyles.titleMd),
      const SizedBox(height: 8),
      _row('Transactions', '${t['transaction_count'] ?? 0}'),
      _row('Gross sales', peso(_n(t['gross_sales']))),
      // Same definition as every other screen: net = gross − discounts − refunds
      // completed today (a refund counts against the cashier who made the sale).
      _row('Discounts', '- ${peso(_n(t['discounts']))}'),
      _row('Refunds and voids', '- ${peso(_n(t['refunds']))}'),
      _row('Net sales', peso(_n(t['net_sales'])), bold: true),
      _row('Cash / non-cash', '${peso(_n(t['cash_sales']))} / ${peso(_n(t['non_cash_sales']))}'),
    ]);
  }

  Future<({double amount, String text})?> _askAmount({
    required String title,
    required String amountLabel,
    required bool withReason,
    String reasonLabel = 'Reason',
    bool reasonRequired = true,
    String? hint,
  }) async {
    final amountCtrl = TextEditingController();
    final textCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hint != null) Text(hint, style: AppTextStyles.bodySm),
              TextFormField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: InputRules.decimal(),
                decoration: InputDecoration(labelText: amountLabel, prefixText: '₱ '),
                validator: (v) => ValidationUtils.validateNumber(v, fieldName: amountLabel, min: 0, max: 1000000),
              ),
              if (withReason)
                TextFormField(
                  controller: textCtrl,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: reasonLabel),
                  validator: (v) => reasonRequired
                      ? ValidationUtils.validateReason(v, fieldName: reasonLabel, minLength: 3, maxLength: 200)
                      : ValidationUtils.validateText(v, fieldName: reasonLabel, maxLength: 200),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final result = (amount: double.tryParse(amountCtrl.text.trim()) ?? 0, text: textCtrl.text.trim());
    disposeAfterDialog([amountCtrl, textCtrl]);
    if (ok != true) return null;
    return result;
  }

  Widget _card(List<Widget> children) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppTextStyles.bodyMd),
            Text(value, style: bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd),
          ],
        ),
      );
}
