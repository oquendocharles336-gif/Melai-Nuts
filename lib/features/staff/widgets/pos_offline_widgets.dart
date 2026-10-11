import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/sync_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/format_utils.dart';
import '../../../data/models/sync_operation.dart';
import '../pos_sale_queue.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Asks whether a sale that could not reach the server should be saved on this
/// device and sent automatically later. Returns true when it was queued.
Future<bool> offerOfflineSave(
  BuildContext context, {
  required String branchId,
  required Map<String, int> cart,
  required String paymentMethod,
  required String idempotencyKey,
  required double displayedTotal,
  String? reference,
  double? cashReceived,
  String? customerUid,
}) async {
  final t = AppLocalizations.of(context);
  final save = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.noConnectionTitle),
      content: Text(t.saveOfflineQuestion),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.notNow)),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t.saveOffline)),
      ],
    ),
  );
  if (save != true) return false;
  try {
    await PosSaleQueue.instance.enqueue(
      branchId: branchId,
      quantitiesByVariant: cart,
      paymentMethod: paymentMethod,
      idempotencyKey: idempotencyKey,
      paymentReference: reference,
      cashReceived: cashReceived,
      customerUid: customerUid,
      displayedTotal: displayedTotal,
    );
    return true;
  } catch (e, st) {
    final error = AppErrors.report(e, st, 'pos_offline:enqueue');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    return false;
  }
}

/// "N sales waiting to be sent · M need attention" with a sheet to retry or
/// discard. Hidden when the queue is empty.
class PosQueueBanner extends StatelessWidget {
  const PosQueueBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        if (sync.pendingCount == 0 && sync.failedCount == 0) return const SizedBox.shrink();
        final failed = sync.failedCount > 0;
        final t = AppLocalizations.of(context);
        final text = [
          if (sync.pendingCount > 0) t.offlineSalesWaiting(sync.pendingCount),
          if (failed) t.offlineSalesFailed(sync.failedCount),
        ].join(' · ');
        return Material(
          color: failed ? AppColors.errorBg : AppColors.warningBg,
          child: InkWell(
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) => const _QueueSheet(),
            ),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(failed ? Icons.error_outline_rounded : Icons.cloud_upload_outlined,
                      color: failed ? AppColors.error : AppColors.warning),
                  const SizedBox(width: 10),
                  Expanded(child: Text(t.offlineSalesBanner(text), style: AppTextStyles.labelMd)),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QueueSheet extends StatefulWidget {
  const _QueueSheet();

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  late Future<List<List<SyncOperation>>> _load = _read();

  Future<List<List<SyncOperation>>> _read() =>
      Future.wait([PosSaleQueue.instance.pending(), PosSaleQueue.instance.failed()]);

  void _reload() => setState(() => _load = _read());

  String _summary(SyncOperation op) {
    final items = Map<String, dynamic>.from(op.payload['items'] as Map? ?? const {});
    final count = items.values.fold<int>(0, (sum, v) => sum + (v as num).toInt());
    final total = (op.payload['displayed_total'] as num?)?.toDouble();
    return '$count item(s) · ${op.payload['payment_method']}${total == null ? '' : ' · ${peso(total)}'}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<List<SyncOperation>>>(
        future: _load,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          }
          final t = AppLocalizations.of(context);
          final pending = snap.data![0];
          final failed = snap.data![1];
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Text(t.offlineSalesTitle, style: AppTextStyles.headlineSm),
              const SizedBox(height: 4),
              Text(t.offlineSalesExplain, style: AppTextStyles.bodySm),
              const SizedBox(height: 12),
              if (pending.isEmpty && failed.isEmpty) Text(t.nothingWaiting, style: AppTextStyles.bodyMd),
              for (final op in pending)
                ListTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text(_summary(op)),
                  subtitle: Text(op.lastError == null ? t.waitingForConnection : '${t.waitingForConnection} · ${op.lastError}'),
                ),
              for (final op in failed)
                ListTile(
                  leading: const Icon(Icons.error_outline_rounded, color: AppColors.error),
                  title: Text(_summary(op)),
                  subtitle: Text(op.lastError ?? t.refusedByServer),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () async {
                          await PosSaleQueue.instance.retry(op.localOperationId);
                          _reload();
                        },
                        child: Text(t.retry),
                      ),
                      TextButton(
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(t.discardSaleQuestion),
                              content: Text(t.discardSaleMessage),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.keep)),
                                FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t.discard)),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await PosSaleQueue.instance.discard(op.localOperationId);
                            _reload();
                          }
                        },
                        child: Text(t.discard),
                      ),
                    ],
                  ),
                ),
              if (pending.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    onPressed: () {
                      unawaited(SyncService.instance.processPending().then((_) {
                        if (mounted) _reload();
                      }));
                    },
                    icon: const Icon(Icons.sync_rounded),
                    label: Text(t.sendNow),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
