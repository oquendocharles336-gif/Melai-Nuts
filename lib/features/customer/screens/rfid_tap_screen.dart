  import 'package:flutter/material.dart';
  import '../../../core/services/auth_service.dart';
  import '../../../core/services/customer_data_store.dart';
  import '../../../core/theme/app_colors.dart';
  import '../../../core/theme/app_spacing.dart';
  import '../../../core/theme/app_text_styles.dart';
  import '../../../core/widgets/info_banner.dart';
  import '../../../core/widgets/melai_app_bar.dart';

  /// "Golden Kernel Club" membership card.
  ///
  /// Shows the customer's real card number (from `customer_profiles`) and
  /// real points balance. The physical card is read by the in-store reader at
  /// the counter, not by this phone, so this screen does not simulate a tap,
  /// fake reader diagnostics or auto-navigate anywhere.
  ///
  /// The status is "Active" ONLY when a card is registered to this account:
  /// `customer_profiles.rfid_card_number` is set by the database to the label of
  /// the customer's ACTIVE card (loyalty_cards, migration 20261011000000) and
  /// cleared when there is none or it was blocked. Otherwise the screen says
  /// "Inactive · No card linked" and shows how to get one linked (staff register
  /// cards at the counter; customers cannot link a card themselves).
  class RfidTapScreen extends StatelessWidget {
    const RfidTapScreen({super.key});

    @override
    Widget build(BuildContext context) {
      return ListenableBuilder(
        listenable: CustomerDataStore.instance,
        builder: (context, _) => _buildBody(context),
      );
    }

    Widget _buildBody(BuildContext context) {
      final profile = CustomerDataStore.instance.profile;
      final name = (profile != null && profile.fullName.isNotEmpty)
          ? profile.fullName
          : (AuthService.instance.currentProfile?.name ?? '—');
      final rawCard = profile?.rfidCardNumber?.trim();
      final hasCard = rawCard != null && rawCard.isNotEmpty;
      final cardNumber = hasCard ? rawCard : 'No card linked';
      final points = CustomerDataStore.instance.pointsBalance;

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
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Container(
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
                          Icon(hasCard ? Icons.contactless_rounded : Icons.link_off_rounded, size: 16, color: Colors.white),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(cardNumber, style: AppTextStyles.labelLg.copyWith(color: Colors.white)),
                      const SizedBox(height: 14),
                      Text('CLUB MEMBER', style: AppTextStyles.labelSm.copyWith(color: Colors.white70)),
                      Text(name.toUpperCase(), style: AppTextStyles.labelLg.copyWith(color: Colors.white)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _CardStatusTile(hasCard: hasCard),
              const SizedBox(height: AppSpacing.md),
              Text(
                hasCard ? 'Present your card at the counter' : 'No loyalty card linked yet',
                textAlign: TextAlign.center,
                style: AppTextStyles.headlineMd,
              ),
              const SizedBox(height: 8),
              Text(
                hasCard
                    ? 'Hold your physical Golden Kernel Club card against the reader at any Melai Nuts counter. Points are credited to your account automatically.'
                    : 'Ask a Melai Nuts staff member at any branch to link a physical Golden Kernel Club card to your account.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.md),
              if (hasCard)
                const InfoBanner(
                  icon: Icons.vpn_key_outlined,
                  title: 'Linked to your account',
                  text: 'This card is linked to your account, so purchases at the counter earn points to your balance.',
                )
              else ...[
                _LinkCardSteps(email: profile?.email ?? AuthService.instance.currentFirebaseUser?.email, phone: profile?.phone),
              ],
              const SizedBox(height: AppSpacing.sm),
              _StatTile(label: 'YOUR BALANCE', value: '$points Kernel Points', icon: Icons.card_giftcard_rounded),
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

  /// "Card status": Active only with a registered card, otherwise Inactive.
  class _CardStatusTile extends StatelessWidget {
    final bool hasCard;

    const _CardStatusTile({required this.hasCard});

    @override
    Widget build(BuildContext context) {
      final color = hasCard ? AppColors.success : AppColors.textMuted;
      return Semantics(
        label: hasCard ? 'Card status: active' : 'Card status: inactive, no card linked',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(hasCard ? Icons.verified_rounded : Icons.link_off_rounded, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(child: Text('Card status', style: AppTextStyles.labelLg)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  hasCard ? 'Active' : 'Inactive · No card linked',
                  style: AppTextStyles.labelMd.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// How to get a card linked: staff register it at the counter (the database
  /// only lets active staff register cards), so the customer brings their
  /// account details. Shown only while no card is linked.
  class _LinkCardSteps extends StatelessWidget {
    final String? email;
    final String? phone;

    const _LinkCardSteps({this.email, this.phone});

    @override
    Widget build(BuildContext context) {
      final who = [
        if ((phone ?? '').trim().isNotEmpty) phone!.trim(),
        if ((email ?? '').trim().isNotEmpty) email!.trim(),
      ].join(' or ');
      final steps = [
        'Visit any Melai Nuts branch and ask for a Golden Kernel Club card.',
        who.isEmpty
            ? 'Give the staff your mobile number or email so they can find your account.'
            : 'Give the staff your account: $who.',
        'They tap the card on the reader to link it. This screen then shows "Active".',
      ];
      return Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.add_link_rounded, color: AppColors.primary),
                const SizedBox(width: 8),
                Text('Link a card', style: AppTextStyles.titleMd.copyWith(color: AppColors.primaryDark)),
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 11,
                      backgroundColor: AppColors.primary,
                      child: Text('${i + 1}', style: AppTextStyles.labelSm.copyWith(color: Colors.white)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(steps[i], style: AppTextStyles.bodyMd)),
                  ],
                ),
              ),
          ],
        ),
      );
    }
  }
