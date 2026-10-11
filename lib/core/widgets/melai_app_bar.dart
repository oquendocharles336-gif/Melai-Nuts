import 'package:flutter/material.dart';

/// Reusable app bar used across every screen so title style, back button
/// behavior, and trailing action layout stay consistent.
class MelaiAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool showBack;

  const MelaiAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.showBack = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      leading: leading ?? (showBack ? const BackButton() : null),
      actions: actions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
