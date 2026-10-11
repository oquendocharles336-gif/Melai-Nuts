import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// The one confirmation dialog used for every delete, remove, deactivate,
/// discard and "save changes?" question in the app, so they all look and
/// behave the same:
///
/// * a title and a message that names the record ("Delete Home address?"),
/// * **Cancel | (action)** — Cancel on the left and focused by default, so an
///   accidental Enter / tap does nothing destructive,
/// * the action button in the error colour when it is destructive.
///
/// Returns true only when the action button was pressed.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel,
    this.destructive = true,
    this.icon,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String? cancelLabel;
  final bool destructive;
  final IconData? icon;

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String? cancelLabel,
    bool destructive = true,
    IconData? icon,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
        icon: icon,
      ),
    );
    return ok ?? false;
  }

  /// "Delete {item}?" — Cancel | Delete.
  static Future<bool> delete(BuildContext context, String item) {
    final t = AppLocalizations.of(context);
    return show(
      context,
      title: t.confirmDeleteTitle(item),
      message: t.confirmDeleteMessage(item),
      confirmLabel: t.delete,
      icon: Icons.delete_outline_rounded,
    );
  }

  /// "Remove {item}?" — Cancel | Remove (e.g. a cart line).
  static Future<bool> remove(BuildContext context, String item) {
    final t = AppLocalizations.of(context);
    return show(
      context,
      title: t.confirmRemoveTitle(item),
      message: t.confirmRemoveMessage(item),
      confirmLabel: t.remove,
      icon: Icons.remove_circle_outline_rounded,
    );
  }

  /// "Save changes?" — Cancel | Save (not destructive).
  static Future<bool> save(BuildContext context, String item) {
    final t = AppLocalizations.of(context);
    return show(
      context,
      title: t.confirmSaveTitle,
      message: t.confirmSaveMessage(item),
      confirmLabel: t.save,
      destructive: false,
      icon: Icons.save_outlined,
    );
  }

  /// "Discard changes?" — Keep Editing | Discard.
  static Future<bool> discard(BuildContext context) {
    final t = AppLocalizations.of(context);
    return show(
      context,
      title: t.confirmDiscardTitle,
      message: t.confirmDiscardMessage,
      confirmLabel: t.discard,
      cancelLabel: t.keepEditing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      icon: icon == null
          ? null
          : Icon(icon, color: destructive ? AppColors.error : AppColors.primary, size: 32),
      title: Text(title),
      content: Text(message, style: AppTextStyles.bodyMd),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel ?? t.cancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.onPrimary,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// Wrap a form screen: when [hasUnsavedChanges] is true, leaving (back button,
/// system back, swipe) first asks "Discard changes?".
class UnsavedChangesGuard extends StatelessWidget {
  const UnsavedChangesGuard({super.key, required this.hasUnsavedChanges, required this.child});

  final bool hasUnsavedChanges;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await ConfirmDialog.discard(context)) navigator.pop(result);
      },
      child: child,
    );
  }
}
