/// The customer's own Golden Kernel Club card, as the database reports it
/// (`get_my_loyalty_card`, migration 20261011000000). [status] is
/// [LoyaltyCardStatus.active] ONLY when a card is really linked to this account.
enum LoyaltyCardStatus { none, active, blocked, replaced }

class MyLoyaltyCard {
  final LoyaltyCardStatus status;
  final String? label;
  final DateTime? issuedAt;
  final DateTime? blockedAt;

  const MyLoyaltyCard({required this.status, this.label, this.issuedAt, this.blockedAt});

  static const MyLoyaltyCard none = MyLoyaltyCard(status: LoyaltyCardStatus.none);

  bool get isActive => status == LoyaltyCardStatus.active && (label ?? '').isNotEmpty;
  bool get isBlocked => status == LoyaltyCardStatus.blocked;

  /// A card the customer can still block or remove.
  bool get canBeRemoved => status == LoyaltyCardStatus.active || status == LoyaltyCardStatus.blocked;

  /// `null` (no card at all) or the RPC's JSON.
  factory MyLoyaltyCard.fromJson(Object? raw) {
    if (raw is! Map) return none;
    final j = Map<String, dynamic>.from(raw);
    final status = switch (j['status']) {
      'active' => LoyaltyCardStatus.active,
      'blocked' => LoyaltyCardStatus.blocked,
      'replaced' => LoyaltyCardStatus.replaced,
      _ => LoyaltyCardStatus.none,
    };
    return MyLoyaltyCard(
      status: status,
      label: (j['label'] as String?)?.trim(),
      issuedAt: DateTime.tryParse('${j['issued_at'] ?? ''}')?.toLocal(),
      blockedAt: DateTime.tryParse('${j['blocked_at'] ?? ''}')?.toLocal(),
    );
  }
}

/// A Wi-Fi card reader at a branch counter (`customer_list_card_readers`).
class CardReader {
  final String id;
  final String name;
  final String? branchName;

  const CardReader({required this.id, required this.name, this.branchName});

  factory CardReader.fromJson(Map<String, dynamic> j) => CardReader(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Card reader',
        branchName: j['branch_name'] as String?,
      );

  String get displayName => branchName == null || branchName!.isEmpty ? name : '$branchName · $name';

  // Same reader after a reload (the picker keeps its selection).
  @override
  bool operator ==(Object other) => other is CardReader && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// One "Link my card" request (`rfid_pairing_sessions`).
class CardPairing {
  final String id;
  final String status; // waiting | linked | already_linked | failed | expired | cancelled
  final String? resultCode;
  final String? message;
  final String? cardLabel;
  final int? pointsBalance;
  final DateTime expiresAt;
  final String? deviceName;

  const CardPairing({
    required this.id,
    required this.status,
    required this.expiresAt,
    this.resultCode,
    this.message,
    this.cardLabel,
    this.pointsBalance,
    this.deviceName,
  });

  factory CardPairing.fromJson(Map<String, dynamic> j) {
    final secondsLeft = (j['seconds_left'] as num?)?.toInt();
    // The server's own countdown, so a phone clock that is off does not matter.
    final expires = secondsLeft != null
        ? DateTime.now().add(Duration(seconds: secondsLeft))
        : (DateTime.tryParse('${j['expires_at'] ?? ''}')?.toLocal() ?? DateTime.now());
    return CardPairing(
      id: j['id'] as String,
      status: (j['status'] as String?) ?? 'failed',
      resultCode: j['result_code'] as String?,
      message: j['message'] as String?,
      cardLabel: j['card_label'] as String?,
      pointsBalance: (j['points_balance'] as num?)?.toInt(),
      expiresAt: expires,
      deviceName: j['device_name'] as String?,
    );
  }

  /// A realtime row update (no seconds_left): keeps the known countdown.
  CardPairing mergeRow(Map<String, dynamic> row) => CardPairing(
        id: id,
        status: (row['status'] as String?) ?? status,
        resultCode: row['result_code'] as String? ?? resultCode,
        message: row['message'] as String? ?? message,
        cardLabel: row['card_label'] as String? ?? cardLabel,
        pointsBalance: (row['points_balance'] as num?)?.toInt() ?? pointsBalance,
        expiresAt: expiresAt,
        deviceName: deviceName,
      );

  bool get isWaiting => status == 'waiting';
  bool get isSuccess => status == 'linked' || status == 'already_linked';
  int get secondsLeft => isWaiting ? expiresAt.difference(DateTime.now()).inSeconds.clamp(0, 60) : 0;
}

class LoyaltyPinStatus {
  final bool hasPin;
  final DateTime? lockedUntil;

  const LoyaltyPinStatus({required this.hasPin, this.lockedUntil});

  factory LoyaltyPinStatus.fromJson(Object? raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return LoyaltyPinStatus(
      hasPin: j['has_pin'] == true,
      lockedUntil: DateTime.tryParse('${j['locked_until'] ?? ''}')?.toLocal(),
    );
  }
}
