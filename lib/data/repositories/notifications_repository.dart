import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/notification_item.dart';

/// Reads/updates the customer's notifications. Rows are only ever *created*
/// by the `notify_on_order_status` / `notify_on_refund_status` database
/// triggers (see supabase/schema.sql) — this repository is read + mark-read
/// + delete only, so nothing here is a client-fabricated notification.
class NotificationsRepository {
  NotificationsRepository._();
  static final NotificationsRepository instance = NotificationsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<List<NotificationItem>> fetchAll(String firebaseUid) async {
    final raw = await _client
        .from('notifications')
        .select()
        .eq('firebase_uid', firebaseUid)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(raw).map(NotificationItem.fromRow).toList();
  }

  /// Live view of this customer's notifications, newest first. Every event
  /// carries the customer's FULL current list, so a listener can simply
  /// replace what it shows. Realtime applies the table's RLS per subscriber.
  /// Errors are converted to [AppError]s (customer-safe messages).
  Stream<List<NotificationItem>> watchAll(String firebaseUid) {
    return _client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('firebase_uid', firebaseUid)
        .order('created_at', ascending: false)
        .map((rows) => rows.map(NotificationItem.fromRow).toList())
        .transform(StreamTransformer<List<NotificationItem>, List<NotificationItem>>.fromHandlers(
          handleError: (error, stackTrace, sink) => sink.addError(AppErrors.from(error), stackTrace),
        ));
  }

  Future<void> markRead(String id) async {
    await _client.from('notifications').update({'read': true}).eq('id', id);
  }

  Future<void> markAllRead(String firebaseUid) async {
    await _client
        .from('notifications')
        .update({'read': true})
        .eq('firebase_uid', firebaseUid)
        .eq('read', false);
  }

  Future<void> delete(String id) async {
    await _client.from('notifications').delete().eq('id', id);
  }

  Future<Map<String, dynamic>?> fetchPreferences(String firebaseUid) async {
    return _client
        .from('notification_preferences')
        .select()
        .eq('firebase_uid', firebaseUid)
        .maybeSingle();
  }

  Future<void> savePreferences(String firebaseUid, Map<String, bool> prefs) async {
    await _client.from('notification_preferences').upsert({
      'firebase_uid': firebaseUid,
      ...prefs,
    });
  }
}
