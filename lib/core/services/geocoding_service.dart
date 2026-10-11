import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/geo_utils.dart';

/// An address found by search, or the address under a pin.
class AddressSuggestion {
  final String displayName;
  final double latitude;
  final double longitude;
  final String? line1;
  final String? city;
  final String? province;
  final String? postalCode;

  const AddressSuggestion({
    required this.displayName,
    required this.latitude,
    required this.longitude,
    this.line1,
    this.city,
    this.province,
    this.postalCode,
  });
}

/// Turns text into places and places into text. Optional everywhere: a pin
/// always works without it (offline, rate-limited, service down).
abstract class Geocoder {
  Future<List<AddressSuggestion>> search(String query);
  Future<AddressSuggestion?> reverse(double latitude, double longitude);
}

/// OpenStreetMap's Nominatim (free, no API key). Its usage policy asks for an
/// identifying User-Agent, at most one request per second and no bulk use:
/// the picker only searches after the customer stops typing (debounced) and
/// reverse-geocodes once, when a pin is confirmed. Every failure answers
/// "nothing found" — never an exception — and coordinates are never logged.
class NominatimGeocoder implements Geocoder {
  NominatimGeocoder({http.Client? client}) : _client = client ?? http.Client();

  static const String host = 'nominatim.openstreetmap.org';
  static const String userAgent = 'MelaiNutsApp/1.0 (com.example.melai_nuts)';
  static const Duration timeout = Duration(seconds: 8);

  final http.Client _client;

  /// Browsers do not let a page set User-Agent; they send their own plus the
  /// Referer, which Nominatim accepts for web apps.
  Map<String, String> get _headers => {
        if (!kIsWeb) 'User-Agent': userAgent,
        'Accept': 'application/json',
        'Accept-Language': 'en',
      };

  @override
  Future<List<AddressSuggestion>> search(String query) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    try {
      final uri = Uri.https(host, '/search', {
        'q': q,
        'format': 'jsonv2',
        'addressdetails': '1',
        'countrycodes': 'ph',
        'limit': '5',
      });
      final r = await _client.get(uri, headers: _headers).timeout(timeout);
      if (r.statusCode != 200) return const [];
      final body = jsonDecode(r.body);
      if (body is! List) return const [];
      return body.whereType<Map>().map((m) => _parse(Map<String, dynamic>.from(m))).whereType<AddressSuggestion>().toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<AddressSuggestion?> reverse(double latitude, double longitude) async {
    if (!GeoUtils.isValidPin(latitude, longitude)) return null;
    try {
      final uri = Uri.https(host, '/reverse', {
        'lat': latitude.toString(),
        'lon': longitude.toString(),
        'format': 'jsonv2',
        'addressdetails': '1',
        'zoom': '18',
      });
      final r = await _client.get(uri, headers: _headers).timeout(timeout);
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body);
      if (body is! Map) return null;
      return _parse(Map<String, dynamic>.from(body));
    } catch (_) {
      return null;
    }
  }

  /// Visible for tests: one Nominatim result (jsonv2 + addressdetails).
  static AddressSuggestion? parseResult(Map<String, dynamic> j) => _parse(j);

  static AddressSuggestion? _parse(Map<String, dynamic> j) {
    final lat = double.tryParse('${j['lat']}');
    final lng = double.tryParse('${j['lon']}');
    if (lat == null || lng == null || !GeoUtils.isValidPin(lat, lng)) return null;
    final a = j['address'] is Map ? Map<String, dynamic>.from(j['address'] as Map) : const <String, dynamic>{};
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = a[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    final street = [pick(['house_number']), pick(['road', 'pedestrian', 'street'])].whereType<String>().join(' ');
    final barangay = pick(['quarter', 'suburb', 'village', 'neighbourhood', 'hamlet']);
    final line1 = [if (street.isNotEmpty) street, ?barangay].join(', ');
    return AddressSuggestion(
      displayName: (j['display_name'] as String?)?.trim() ?? line1,
      latitude: lat,
      longitude: lng,
      line1: line1.isEmpty ? null : line1,
      city: pick(['city', 'town', 'municipality', 'city_district']),
      province: pick(['province', 'state', 'region']),
      postalCode: pick(['postcode']),
    );
  }
}
