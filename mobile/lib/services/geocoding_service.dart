import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/env_config.dart';

/// GeocodingService — wraps Google Geocoding API
/// Used for live location search (Issue #2)
class GeocodingService {
  static Future<List<GeocodingResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    
    final key = EnvConfig.geocodingKey;
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?address=${Uri.encodeComponent(query)}'
      '&key=$key'
    );

    try {
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return [];
      
      final data = json.decode(res.body);
      if (data['status'] != 'OK') return [];
      
      final results = data['results'] as List<dynamic>;
      return results.take(5).map((r) => GeocodingResult.fromJson(r)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<String?> reverseGeocode(double lat, double lng) async {
    final key = EnvConfig.geocodingKey;
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?latlng=$lat,$lng'
      '&key=$key'
    );

    try {
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final data = json.decode(res.body);
      if (data['status'] != 'OK') return null;
      final results = data['results'] as List<dynamic>;
      if (results.isEmpty) return null;
      return results.first['formatted_address'] as String?;
    } catch (_) {
      return null;
    }
  }
}

class GeocodingResult {
  final String formattedAddress;
  final double lat;
  final double lng;
  final String? city;
  final String? country;

  GeocodingResult({
    required this.formattedAddress,
    required this.lat,
    required this.lng,
    this.city,
    this.country,
  });

  factory GeocodingResult.fromJson(Map<String, dynamic> json) {
    final loc = json['geometry']['location'];
    String? city;
    String? country;
    for (final comp in (json['address_components'] as List? ?? [])) {
      final types = List<String>.from(comp['types'] ?? []);
      if (types.contains('locality')) city = comp['long_name'];
      if (types.contains('country')) country = comp['long_name'];
    }
    return GeocodingResult(
      formattedAddress: json['formatted_address'] ?? '',
      lat: (loc['lat'] as num).toDouble(),
      lng: (loc['lng'] as num).toDouble(),
      city: city,
      country: country,
    );
  }
}

/// LocationSearchDialog — reusable search widget using Geocoding API
class LocationSearchDialog extends StatefulWidget {
  final Function(GeocodingResult) onSelected;
  const LocationSearchDialog({super.key, required this.onSelected});

  @override
  State<LocationSearchDialog> createState() => _LocationSearchDialogState();
}

class _LocationSearchDialogState extends State<LocationSearchDialog> {
  final _ctrl = TextEditingController();
  List<GeocodingResult> _results = [];
  bool _searching = false;

  Future<void> _search(String q) async {
    if (q.trim().length < 3) { setState(() => _results = []); return; }
    setState(() => _searching = true);
    final results = await GeocodingService.search(q);
    if (mounted) setState(() { _results = results; _searching = false; });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D1B3E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Search Location', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ctrl,
              style: const TextStyle(color: Colors.white),
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'e.g. G-10 Islamabad, Lahore...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                suffixIcon: _searching ? const SizedBox(
                  width: 20, height: 20,
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                  ),
                ) : null,
                filled: true,
                fillColor: Colors.black26,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF42A5F5), width: 2)),
              ),
              onChanged: (v) => _search(v),
            ),
            const SizedBox(height: 12),
            if (_results.isEmpty && !_searching && _ctrl.text.length >= 3)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No locations found. Try a different search.', style: TextStyle(color: Colors.white54)),
              ),
            ..._results.map((r) => ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              leading: const Icon(Icons.location_on, color: Colors.blueAccent, size: 20),
              title: Text(r.formattedAddress, style: const TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: r.city != null
                  ? Text('${r.city ?? ''}, ${r.country ?? ''}  •  ${r.lat.toStringAsFixed(4)}, ${r.lng.toStringAsFixed(4)}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11))
                  : null,
              onTap: () {
                Navigator.pop(context);
                widget.onSelected(r);
              },
            )),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }
}
