import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/auth_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/services/loyalty_card_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/info_banner.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/loyalty_card.dart';

/// "Golden Kernel Club" membership card.
///
/// The card status is read live from the database (`get_my_loyalty_card`):
/// "Active" ONLY while a card is really linked to this account.
///
/// With no active card the customer links one themselves: pick a counter
/// reader, press "Link my card" (60-second window) and tap the card on that
/// reader (ESP32 + RC522, Edge Function rfid-device-tap). The result arrives
/// over realtime. A linked card can be blocked (lost / stolen) or removed for
/// good; points always stay on the account. An optional loyalty PIN protects
/// point redemption at the counter.
class RfidTapScreen extends StatefulWidget {
  const RfidTapScreen({super.key});

  @override
  State<RfidTapScreen> createState() => _RfidTapScreenState();
}

class _RfidTapScreenState extends State<RfidTapScreen> {
  final LoyaltyCardStore _cards = LoyaltyCardStore.instance;
  CardReader? _reader;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: load() notifies listeners, which must not happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _cards.load();
      _cards.watchTaps();
    });
  }

  @override
  void dispose() {
    _cards.stopWatchingTaps();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([_cards.load(), CustomerDataStore.instance.refreshLoyalty()]);
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && done != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _block() async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Block this card?',
      message: 'Use this if the card is lost or stolen. It stops working at every branch right away. '
          'Your points stay on your account, and you can link a new card any time.',
      confirmLabel: 'Block card',
      icon: Icons.block_rounded,
    );
    if (!ok || !mounted) return;
    await _run(() => _cards.blockCard('Reported lost or stolen in the app'), done: 'Card blocked. Your points are safe.');
  }

  Future<void> _remove() async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Remove this card for good?',
      message: 'The card will never work again, on any account. Your points stay on your account.',
      confirmLabel: 'Remove card',
      icon: Icons.link_off_rounded,
    );
    if (!ok || !mounted) return;
    await _run(_cards.removeCard, done: 'Card removed. Your points are safe.');
  }

  Future<void> _editPin() async {
    final hasPin = _cards.pin?.hasPin ?? false;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _PinDialog(hasPin: hasPin),
    );
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_cards, CustomerDataStore.instance]),
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final profile = CustomerDataStore.instance.profile;
    final name = (profile != null && profile.fullName.isNotEmpty)
        ? profile.fullName
        : (AuthService.instance.currentProfile?.name ?? '—');
    final points = CustomerDataStore.instance.pointsBalance;
    final card = _cards.card;
    final loaded = _cards.loadedOnce;

    Widget content;
    if (!loaded && _cards.loading) {
      content = const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: StateLoadingView(message: 'Checking your card…'),
      );
    } else if (!loaded && _cards.error != null) {
      content = StateErrorView(error: _cards.error, onRetry: _cards.load);
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardStatusTile(card: card),
          const SizedBox(height: AppSpacing.md),
          if (loaded && _cards.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: StateErrorView(error: _cards.error, onRetry: _cards.load, compact: true),
            ),
          if (card.isActive) ..._activeSection(card) else ..._linkSection(card),
          const SizedBox(height: AppSpacing.md),
          _PinTile(status: _cards.pin, onTap: _busy ? null : _editPin),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Golden Kernel Club',
        showBack: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('$points pts', style: AppTextStyles.labelMd.copyWith(color: AppColors.primaryDark)),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              _MemberCard(name: name, card: card),
              const SizedBox(height: AppSpacing.md),
              content,
              const SizedBox(height: AppSpacing.sm),
              _StatTile(label: 'YOUR BALANCE', value: '$points Kernel Points', icon: Icons.card_giftcard_rounded),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _activeSection(MyLoyaltyCard card) => [
        Text('Present your card at the counter', textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
        const SizedBox(height: 8),
        Text(
          'Staff tap your card to find your account, add points for the order, and use points if you ask. '
          'Tapping it on a Melai Nuts card reader also refreshes the points shown here.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMd,
        ),
        const SizedBox(height: AppSpacing.md),
        const InfoBanner(
          icon: Icons.shield_outlined,
          title: 'Lost or stolen?',
          text: 'Block the card at once. Your points are kept on your account, not on the card.',
        ),
        const SizedBox(height: AppSpacing.sm),
        SecondaryButton(label: 'Block card (lost / stolen)', icon: Icons.block_rounded, onPressed: _busy ? null : _block),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy ? null : _remove,
          icon: const Icon(Icons.link_off_rounded, color: AppColors.error),
          label: Text('Remove this card', style: AppTextStyles.labelLg.copyWith(color: AppColors.error)),
        ),
      ];

  List<Widget> _linkSection(MyLoyaltyCard card) {
    final pairing = _cards.pairing;
    return [
      if (card.isBlocked) ...[
        InfoBanner(
          icon: Icons.block_rounded,
          background: AppColors.warningBg,
          foreground: AppColors.warning,
          title: 'Card ${card.label ?? ''} is blocked',
          text: 'It no longer works. Link a new card below; the blocked one is then retired. Your points are safe.',
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy ? null : _remove,
          icon: const Icon(Icons.link_off_rounded, color: AppColors.error),
          label: Text('Remove the blocked card', style: AppTextStyles.labelLg.copyWith(color: AppColors.error)),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
      Text('Link your card', textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
      const SizedBox(height: 8),
      Text(
        'At a Melai Nuts counter, choose the card reader in front of you, press "Link my card", '
        'then tap your Golden Kernel Club card on it within 60 seconds.',
        textAlign: TextAlign.center,
        style: AppTextStyles.bodyMd,
      ),
      const SizedBox(height: AppSpacing.md),
      if (pairing != null)
        _PairingPanel(
          pairing: pairing,
          onCancel: _cards.cancelPairing,
          onDone: _cards.clearPairing,
        )
      else
        _readerPicker(),
      const SizedBox(height: AppSpacing.sm),
      Text(
        'No reader at your branch? Staff can also link a card for you at the counter.',
        textAlign: TextAlign.center,
        style: AppTextStyles.bodySm,
      ),
    ];
  }

  Widget _readerPicker() {
    final readers = _cards.readers;
    if (_cards.readersError != null && readers.isEmpty) {
      return StateErrorView(error: _cards.readersError, onRetry: _cards.load, compact: true);
    }
    if (readers.isEmpty) {
      return const StateEmptyView(
        icon: Icons.contactless_outlined,
        title: 'No card readers yet',
        message: 'No branch has a self-service card reader set up. Ask staff at the counter to link your card.',
        compact: true,
      );
    }
    final selected = readers.contains(_reader) ? _reader : (readers.length == 1 ? readers.first : null);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Card reader', style: AppTextStyles.labelLg),
          const SizedBox(height: 6),
          DropdownButtonFormField<CardReader>(
            initialValue: selected,
            isExpanded: true,
            hint: const Text('Choose the reader at your counter'),
            items: [
              for (final r in readers) DropdownMenuItem(value: r, child: Text(r.displayName, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (r) => setState(() => _reader = r),
          ),
          if (_cards.pairingError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_cards.pairingError!.message, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
            ),
          const SizedBox(height: AppSpacing.md),
          PrimaryButton(
            label: 'Link my card',
            icon: Icons.add_link_rounded,
            loading: _cards.startingPairing,
            onPressed: selected == null ? null : () => _cards.startPairing(selected),
          ),
        ],
      ),
    );
  }
}

/// The physical-card look, kept from the original screen.
class _MemberCard extends StatelessWidget {
  final String name;
  final MyLoyaltyCard card;

  const _MemberCard({required this.name, required this.card});

  @override
  Widget build(BuildContext context) {
    final active = card.isActive;
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: AppColors.border),
      ),
      child: Container(
        width: 260,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.darkBrown, AppColors.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('MELAI GOLDEN KERNEL', style: AppTextStyles.labelSm.copyWith(color: Colors.white)),
                Icon(active ? Icons.contactless_rounded : Icons.link_off_rounded, size: 16, color: Colors.white),
              ],
            ),
            const SizedBox(height: 18),
            Text(active ? card.label! : 'No card linked', style: AppTextStyles.labelLg.copyWith(color: Colors.white)),
            const SizedBox(height: 14),
            Text('CLUB MEMBER', style: AppTextStyles.labelSm.copyWith(color: Colors.white70)),
            Text(name.toUpperCase(), style: AppTextStyles.labelLg.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// Waiting (countdown) → linked / refused / expired.
class _PairingPanel extends StatelessWidget {
  final CardPairing pairing;
  final Future<void> Function() onCancel;
  final VoidCallback onDone;

  const _PairingPanel({required this.pairing, required this.onCancel, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String title;
    final String text;
    if (pairing.isWaiting) {
      color = AppColors.primary;
      icon = Icons.contactless_rounded;
      title = 'Tap your card now';
      text = 'Hold your card on ${pairing.deviceName ?? 'the reader'} until it beeps. ${pairing.secondsLeft} s left.';
    } else if (pairing.isSuccess) {
      color = AppColors.success;
      icon = Icons.verified_rounded;
      title = pairing.status == 'linked' ? 'Card linked' : 'Card already linked';
      text = 'Card ${pairing.cardLabel ?? ''} is linked to your account.'
          '${pairing.pointsBalance == null ? '' : ' Balance: ${pairing.pointsBalance} points.'}';
    } else if (pairing.status == 'expired') {
      color = AppColors.warning;
      icon = Icons.timer_off_outlined;
      title = 'Time is up';
      text = 'No card was tapped within 60 seconds. Try again.';
    } else if (pairing.status == 'cancelled') {
      color = AppColors.textMuted;
      icon = Icons.close_rounded;
      title = 'Cancelled';
      text = pairing.message ?? 'The link request was cancelled.';
    } else {
      color = AppColors.error;
      icon = Icons.error_outline_rounded;
      title = 'Card not linked';
      text = pairing.message ?? 'The card could not be linked. Try again.';
    }
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (pairing.isWaiting)
                  const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                else
                  Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: AppTextStyles.titleMd.copyWith(color: color))),
              ],
            ),
            const SizedBox(height: 8),
            Text(text, style: AppTextStyles.bodyMd),
            if (pairing.isWaiting) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: pairing.secondsLeft / 60, color: color),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: pairing.isWaiting
                  ? TextButton(onPressed: () => onCancel(), child: const Text('Cancel'))
                  : TextButton(onPressed: onDone, child: Text(pairing.isSuccess ? 'Done' : 'Try again')),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatTile({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.labelSm),
                Text(value, style: AppTextStyles.labelMd),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Card status": Active only with a linked card (read from the server).
class _CardStatusTile extends StatelessWidget {
  final MyLoyaltyCard card;

  const _CardStatusTile({required this.card});

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String text) = switch (card.status) {
      LoyaltyCardStatus.active when card.isActive => (AppColors.success, Icons.verified_rounded, 'Active'),
      LoyaltyCardStatus.blocked => (AppColors.warning, Icons.block_rounded, 'Blocked'),
      LoyaltyCardStatus.replaced => (AppColors.textMuted, Icons.link_off_rounded, 'Inactive · Card removed'),
      _ => (AppColors.textMuted, Icons.link_off_rounded, 'Inactive · No card linked'),
    };
    return Semantics(
      label: 'Card status: $text',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text('Card status', style: AppTextStyles.labelLg)),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(text, style: AppTextStyles.labelMd.copyWith(color: color), overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinTile extends StatelessWidget {
  final LoyaltyPinStatus? status;
  final VoidCallback? onTap;

  const _PinTile({required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasPin = status?.hasPin ?? false;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
        leading: Icon(hasPin ? Icons.lock_rounded : Icons.lock_open_rounded, color: AppColors.primary),
        title: Text('Loyalty PIN', style: AppTextStyles.labelLg),
        subtitle: Text(
          status == null
              ? 'Could not check your PIN. Pull down to refresh.'
              : hasPin
                  ? 'On · needed to use points at the counter'
                  : 'Off · add a 4–6 digit PIN so only you can use your points at the counter',
          style: AppTextStyles.bodySm,
        ),
        trailing: Text(hasPin ? 'Change' : 'Set', style: AppTextStyles.labelMd.copyWith(color: AppColors.primary)),
        onTap: status == null ? null : onTap,
      ),
    );
  }
}

/// Set / change / turn off the loyalty PIN. Pops with a confirmation text.
class _PinDialog extends StatefulWidget {
  final bool hasPin;
  const _PinDialog({required this.hasPin});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    super.dispose();
  }

  static final _pinRule = RegExp(r'^\d{4,6}$');

  Future<void> _save() async {
    if (widget.hasPin && !_pinRule.hasMatch(_current.text)) {
      setState(() => _message = 'Enter your current PIN.');
      return;
    }
    if (!_pinRule.hasMatch(_next.text)) {
      setState(() => _message = 'The new PIN must be 4 to 6 digits.');
      return;
    }
    if (_next.text != _again.text) {
      setState(() => _message = 'The two new PINs do not match.');
      return;
    }
    await _submit(() => LoyaltyCardStore.instance
        .setPin(_next.text, currentPin: widget.hasPin ? _current.text : null), 'Loyalty PIN saved.');
  }

  Future<void> _turnOff() async {
    if (!_pinRule.hasMatch(_current.text)) {
      setState(() => _message = 'Enter your current PIN to turn it off.');
      return;
    }
    await _submit(() => LoyaltyCardStore.instance.clearPin(_current.text), 'Loyalty PIN turned off.');
  }

  Future<void> _submit(Future<String?> Function() action, String done) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final problem = await action();
      if (!mounted) return;
      if (problem == null) {
        Navigator.pop(context, done);
      } else {
        setState(() {
          _busy = false;
          _message = problem;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = AppErrors.from(e).message;
      });
    }
  }

  Widget _field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          enabled: !_busy,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: label, counterText: ''),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.hasPin ? 'Change loyalty PIN' : 'Set a loyalty PIN'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Staff ask for this PIN before using your points at the counter. Earning points never needs it.',
              style: AppTextStyles.bodySm,
            ),
            const SizedBox(height: 12),
            if (widget.hasPin) _field(_current, 'Current PIN'),
            _field(_next, 'New PIN (4–6 digits)'),
            _field(_again, 'New PIN again'),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: CircularProgressIndicator()),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_message!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.hasPin) TextButton(onPressed: _busy ? null : _turnOff, child: const Text('Turn off')),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
