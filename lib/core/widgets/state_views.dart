import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_error.dart';
import 'motion.dart';

/// Shared building blocks for the four states every real-backend screen must
/// handle: **loading**, **empty**, **error (with retry)** and **success**.
///
/// Use [DataStateView] to wire all four in one place. The individual views
/// ([StateLoadingView], [StateEmptyView], [StateErrorView]) are exported for
/// screens that need only one of them (e.g. inside a fixed-height strip).
///
/// All views are scrollable when not [compact], so a surrounding
/// `RefreshIndicator` (pull-to-refresh) still works on an empty or failed
/// screen.

/// Centered spinner with an optional caption.
class StateLoadingView extends StatelessWidget {
  final String? message;
  final bool compact;

  const StateLoadingView({super.key, this.message, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: compact ? 24 : 32,
          height: compact ? 24 : 32,
          child: const CircularProgressIndicator(strokeWidth: 3),
        ),
        if (message != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySm.copyWith(color: AppColors.textMuted),
          ),
        ],
      ],
    );
    return _StateFrame(compact: compact, child: body);
  }
}

/// "Nothing here yet" state, with an optional call-to-action.
class StateEmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  const StateEmptyView({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return _StateFrame(
      compact: compact,
      child: FadeSlideIn(
        offsetY: 10,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IconBadge(
              icon: icon,
              color: AppColors.primary,
              size: compact ? 52 : 92,
            ),
            SizedBox(height: compact ? AppSpacing.xs : AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: (compact ? AppTextStyles.labelLg : AppTextStyles.headlineSm)
                  .copyWith(color: AppColors.darkBrown),
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.md),
              ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Failure state with a retry button. [error] can be any thrown object — it is
/// converted to a customer-safe message through [AppErrors.from], so raw
/// backend details are never shown.
class StateErrorView extends StatelessWidget {
  final Object? error;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final ErrorScope scope;
  final bool compact;

  const StateErrorView({
    super.key,
    this.error,
    this.message,
    this.onRetry,
    this.retryLabel = 'Try Again',
    this.scope = ErrorScope.general,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final appError = error == null ? null : AppErrors.from(error!, scope: scope);
    final text = message ??
        appError?.message ??
        'Something went wrong. Please try again.';
    final offline = appError?.isConnectivity ?? false;
    final denied = appError?.kind == AppErrorKind.permissionDenied ||
        appError?.kind == AppErrorKind.authExpired;

    final IconData icon;
    final Color color;
    if (offline) {
      icon = Icons.wifi_off_rounded;
      color = AppColors.warning;
    } else if (denied) {
      icon = Icons.lock_outline_rounded;
      color = AppColors.secondaryBrown;
    } else {
      icon = Icons.sentiment_dissatisfied_rounded;
      color = AppColors.error;
    }

    return _StateFrame(
      compact: compact,
      child: FadeSlideIn(
        offsetY: 10,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IconBadge(icon: icon, color: color, size: compact ? 52 : 92),
            SizedBox(height: compact ? AppSpacing.xs : AppSpacing.md),
            Text(
              text,
              textAlign: TextAlign.center,
              style: (compact ? AppTextStyles.labelLg : AppTextStyles.titleMd)
                  .copyWith(color: AppColors.darkBrown),
            ),
            // Most permission errors right after sign-in are a stale session.
            if (denied && !compact) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'If this keeps happening, sign out and sign in again to refresh your access.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
              ),
            ],
            if (onRetry != null) ...[
              SizedBox(height: compact ? AppSpacing.xs : AppSpacing.md),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(retryLabel),
                style: OutlinedButton.styleFrom(
                  minimumSize: Size(compact ? 0 : 64, compact ? 40 : 48),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Slim banner shown above real content when a *refresh* failed but the last
/// good data is still on screen. Makes it clear the list may be out of date
/// and offers a retry.
class StaleDataBanner extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  final ErrorScope scope;

  /// Text shown before the error message.
  final String leadIn;

  const StaleDataBanner({
    super.key,
    required this.error,
    this.onRetry,
    this.scope = ErrorScope.general,
    this.leadIn = 'Showing last saved data.',
  });

  @override
  Widget build(BuildContext context) {
    final message = AppErrors.from(error, scope: scope).message;
    return Container(
      width: double.infinity,
      color: AppColors.warningBg,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              '$leadIn $message',
              style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

/// One widget that picks the right state:
///
/// * no data yet **and** loading            -> loading spinner
/// * no data **and** the load failed         -> error + retry
/// * no data, load finished OK               -> empty state
/// * data present                            -> [builder] (success), with a
///   [StaleDataBanner] on top if the latest refresh failed
///
/// It never shows the empty state while a load is in flight or after a failed
/// load, so a slow/failed request can no longer masquerade as "you have no
/// orders / no products / no notifications".
///
/// Must be placed where it has a bounded height (e.g. a Scaffold body or an
/// `Expanded`), because the stale banner is stacked above [builder] in a Column.
class DataStateView extends StatelessWidget {
  final bool isLoading;
  final Object? error;
  final bool isEmpty;
  final VoidCallback? onRetry;
  final WidgetBuilder builder;

  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptyMessage;
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  final String? loadingMessage;
  final ErrorScope errorScope;

  /// Compact variants for fixed-height strips (no scrolling, smaller icons,
  /// no stale banner).
  final bool compact;

  const DataStateView({
    super.key,
    required this.isLoading,
    required this.error,
    required this.isEmpty,
    required this.builder,
    this.onRetry,
    this.emptyIcon = Icons.inbox_outlined,
    required this.emptyTitle,
    this.emptyMessage,
    this.emptyActionLabel,
    this.onEmptyAction,
    this.loadingMessage,
    this.errorScope = ErrorScope.general,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isEmpty) {
      if (isLoading) {
        return StateLoadingView(message: loadingMessage, compact: compact);
      }
      if (error != null) {
        return StateErrorView(
          error: error,
          onRetry: onRetry,
          scope: errorScope,
          compact: compact,
        );
      }
      return StateEmptyView(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
        actionLabel: emptyActionLabel,
        onAction: onEmptyAction,
        compact: compact,
      );
    }

    final content = builder(context);
    if (error != null && !isLoading && !compact) {
      return Column(
        children: [
          StaleDataBanner(error: error!, onRetry: onRetry, scope: errorScope),
          Expanded(child: content),
        ],
      );
    }
    return content;
  }
}

/// Soft round badge that holds the icon of an empty/error state.
class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _IconBadge({required this.icon, required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.07),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Icon(icon, size: size * 0.46, color: color),
    );
  }
}

/// Centers [child]; scrollable (so pull-to-refresh works) unless [compact].
class _StateFrame extends StatelessWidget {
  final Widget child;
  final bool compact;

  const _StateFrame({required this.child, required this.compact});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: child,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final padded = Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: child,
        );
        // Inside an unbounded parent (e.g. a ListView) there is nothing to
        // center against or scroll, so just render it in flow.
        if (!constraints.hasBoundedHeight) return Center(child: padded);
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: padded),
          ),
        );
      },
    );
  }
}
