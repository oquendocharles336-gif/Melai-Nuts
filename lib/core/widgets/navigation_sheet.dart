import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/geo_utils.dart';

/// Lets the driver (or staff) pick Google Maps, Waze or Apple Maps for
/// directions to a stop. Uses the customer's pinned coordinates; without a
/// valid pin it searches the address text and says so.
Future<void> showNavigationSheet(
  BuildContext context, {
  num? latitude,
  num? longitude,
  String? address,
  String title = 'Navigate with',
}) async {
  final pinned = GeoUtils.isValidPin(latitude, longitude);
  final targets = NavigationLinks.forDestination(lat: latitude, lng: longitude, address: address);
  if (targets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This stop has no map pin and no address to navigate to. Call the customer.')),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTextStyles.headlineSm),
            const SizedBox(height: 4),
            Text(
              pinned
                  ? 'To the exact spot the customer pinned.'
                  : 'The customer did not pin this address, so the address text is searched. Call them if unsure.',
              style: AppTextStyles.bodySm.copyWith(color: pinned ? AppColors.textSecondary : AppColors.warning),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final t in targets)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(t.label == 'Waze' ? Icons.directions_car_rounded : Icons.map_rounded, color: AppColors.primary),
                title: Text(t.label),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  final ok = await launchUrl(t.uri, mode: LaunchMode.externalApplication);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open ${t.label}.')));
                  }
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// Opens a single map pin (no route) in Google Maps — staff "Open in Maps".
Future<void> openPinInMaps(BuildContext context, {num? latitude, num? longitude, String? address}) async {
  final uri = NavigationLinks.showOnMap(lat: latitude, lng: longitude, address: address);
  if (uri == null) return;
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the map.')));
  }
}

/// Calls a phone number with the dialer.
Future<void> callNumber(BuildContext context, String? phone) async {
  final number = (phone ?? '').trim();
  if (number.isEmpty) return;
  final ok = await launchUrl(Uri(scheme: 'tel', path: number));
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start a call. The number is $number.')));
  }
}
