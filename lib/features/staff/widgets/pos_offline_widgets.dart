import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/sync_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/format_utils.dart';
import '../../../data/models/sync_operation.dart';
import '../pos_sale_queue.dart';
import '../staff_offline_sync.dart';
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

/// App-bar button for the offline sync queue (sales, products, received and
/// adjusted stock saved on this device). Hidden while nothing is waiting, so
/// it takes no space; a badge shows how many changes are waiting / failed.
/// Replaces the old permanent queue banner: connection and sync changes are
/// announced as notifications instead (see `AppNotices`).
class SyncQueueButton extends StatelessWidget {
  const SyncQueueButton({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final waiting = sync.pendingCount;
        final failed = sync.failedCount;
        if (waiting == 0 && failed == 0) return const SizedBox.shrink();
        return IconButton(
          tooltip: failed > 0 ? '$failed change(s) need attention' : '$waiting change(s) waiting to sync',
          icon: Badge(
            backgroundColor: failed > 0 ? AppColors.error : AppColors.warning,
            label: Text('${waiting + failed}'),
            child: Icon(failed > 0 ? Icons.sync_problem_rounded : Icons.cloud_upload_outlined),
          ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => const _QueueSheet(),
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

  Future<List<List<SyncOperation>>> _read() => Future.wait([
        SyncService.instance.operations(SyncStatus.pending),
        SyncService.instance.operations(SyncStatus.syncing),
        SyncService.instance.operations(SyncStatus.failed),
      ]).then((r) => [
            [...r[1], ...r[0]],
            r[2],
          ]);

  void _reload() => setState(() => _load = _read());

  static String _summary(SyncOperation op) {
    final p = op.payload;
    switch (op.operationType) {
      case PosSaleQueue.operationType:
        final items = Map<String, dynamic>.from(p['items'] as Map? ?? const {});
        final count = items.values.fold<int>(0, (sum, v) => sum + (v as num).toInt());
        final total = (p['displayed_total'] as num?)?.toDouble();
        return 'Sale: $count item(s) · ${p['payment_method']}${total == null ? '' : ' · ${peso(total)}'}';
      case StaffOfflineSync.productCreate:
        return 'New product: ${p['name']}';
      case StaffOfflineSync.productSave:
        return 'Product changes: ${p['name']}';
      case StaffOfflineSync.inventoryReceive:
        return 'Receive stock: ${p['quantity']} pack(s) · batch ${p['batch_code']}';
      case StaffOfflineSync.inventoryAdjust:
        final delta = (p['delta'] as num?)?.toInt() ?? 0;
        return 'Stock adjustment: ${delta > 0 ? '+' : ''}$delta · ${p['reason']}';
      default:
        return op.entityType;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<List<SyncOperation>>>(
        future: _load,
        builder: (context, snap) {
          final t = AppLocalizations.of(context);
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('The saved changes could not be read.', style: AppTextStyles.bodyMd),
                  TextButton(onPressed: _reload, child: Text(t.retry)),
                ],
              ),
            );
          }
          if (!snap.hasData) {
            return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          }
          final pending = snap.data![0];
          final failed = snap.data![1];
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Text('Saved on this device', style: AppTextStyles.headlineSm),
              const SizedBox(height: 4),
              Text(
                'Changes made while offline. Each one is sent once, with its own key, so it can never be '
                'applied twice.',
                style: AppTextStyles.bodySm,
              ),
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
                          await StaffOfflineSync.instance.retry(op);
                          if (mounted) _reload();
                        },
                        child: Text(t.retry),
                      ),
                      TextButton(
                        onPressed: () async {
                          final isSale = op.operationType == PosSaleQueue.operationType;
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(isSale ? t.discardSaleQuestion : 'Discard this change?'),
                              content: Text(isSale
                                  ? t.discardSaleMessage
                                  : 'It will not be sent to the server and is removed from this device.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.keep)),
                                FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t.discard)),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await StaffOfflineSync.instance.discard(op);
                            if (mounted) _reload();
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
