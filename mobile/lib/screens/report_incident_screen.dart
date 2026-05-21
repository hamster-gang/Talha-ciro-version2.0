import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/env_config.dart';
import '../services/geocoding_service.dart';
import '../services/geolocation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Report Incident Screen
/// Captures real browser GPS coordinates, reverse geocodes to address.
/// Submits to backend with real lat/lng.
class ReportIncidentScreen extends StatefulWidget {
  const ReportIncidentScreen({super.key});
  @override
  State<ReportIncidentScreen> createState() => _ReportIncidentScreenState();
}

class _ReportIncidentScreenState extends State<ReportIncidentScreen>
    with SingleTickerProviderStateMixin {
  final _descCtrl = TextEditingController();
  final _locCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String _selectedType = 'Flooding';
  bool _isSubmitting = false;
  bool _submitted = false;
  bool _gpsLoading = false;
  String? _trackingId;
  double _lat = 33.6844;
  double _lng = 73.0479;
  bool _gpsConfirmed = false;

  late AnimationController _successCtrl;
  late Animation<double> _successScale;

  static const _types = [
    'Flooding',
    'Fire',
    'Heatwave',
    'Infrastructure Failure',
    'Medical Emergency',
    'Road Accident',
    'Power Outage',
    'Other',
  ];

  static const _typeIcons = {
    'Flooding': Icons.water,
    'Fire': Icons.local_fire_department,
    'Heatwave': Icons.thermostat,
    'Infrastructure Failure': Icons.electrical_services,
    'Medical Emergency': Icons.local_hospital,
    'Road Accident': Icons.car_crash,
    'Power Outage': Icons.power_off,
    'Other': Icons.report_problem,
  };

  @override
  void initState() {
    super.initState();
    _successCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _successScale = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _successCtrl, curve: Curves.elasticOut));
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _locCtrl.dispose();
    _nameCtrl.dispose();
    _successCtrl.dispose();
    super.dispose();
  }

  /// Use browser Geolocation API to get real GPS coordinates
  Future<void> _getCurrentLocation() async {
    setState(() => _gpsLoading = true);
    try {
      final position = await GeolocationService.getCurrentPosition(
        enableHighAccuracy: true,
        timeout: const Duration(seconds: 10),
      );
      if (position == null) {
        if (mounted) {
          setState(() => _gpsLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Location access denied. Please type your location manually.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final lat = position.latitude;
      final lng = position.longitude;

      // Reverse geocode to get human-readable address
      final address = await GeocodingService.reverseGeocode(lat, lng);

      if (mounted) {
        setState(() {
          _lat = lat;
          _lng = lng;
          _gpsConfirmed = true;
          _locCtrl.text =
              address ?? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
          _gpsLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📍 Location captured via GPS'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _gpsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Location access denied. Please type your location manually.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      final body = json.encode({
        'incident_type': _selectedType,
        'description': _descCtrl.text.trim(),
        'location': _locCtrl.text.trim(),
        'reporter_name':
            _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
        'lat': _lat,
        'lng': _lng,
      });
      final res = await http
          .post(
            Uri.parse('${EnvConfig.backendUrl}/api/citizen-report'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final rId = data['report_id'];

        final prefs = await SharedPreferences.getInstance();
        final myReports = prefs.getStringList('myReportIds') ?? [];
        if (!myReports.contains(rId)) {
          myReports.add(rId);
          await prefs.setStringList('myReportIds', myReports);
        }

        if (mounted) {
          setState(() {
            _submitted = true;
            _trackingId = rId;
            _isSubmitting = false;
          });
          _successCtrl.forward();
        }
      } else {
        throw Exception('Server error ${res.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to submit: $e'),
            backgroundColor: Colors.redAccent));
      }
    }
  }

  Widget _buildSuccessView() {
    return Center(
        child: ScaleTransition(
            scale: _successScale,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32.0),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [Color(0xFF1B5E20), Color(0xFF43A047)])),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.white, size: 56),
                ),
                const SizedBox(height: 28),
                const Text('Report Submitted!',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text(
                    'CIRO agents have received your report and will prioritize response.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 14)),
                const SizedBox(height: 28),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12)),
                  child: Column(children: [
                    const Text('YOUR TRACKING ID',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            letterSpacing: 2)),
                    const SizedBox(height: 6),
                    Text(_trackingId ?? '—',
                        style: const TextStyle(
                            color: Color(0xFF42A5F5),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2)),
                    const SizedBox(height: 6),
                    const Text(
                        'Use this ID in the Safety Center to track your report.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ]),
                ),
                const SizedBox(height: 32),
                SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Back to Safety Center',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    )),
              ]),
            )));
  }

  Widget _buildForm() {
    return Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('INCIDENT TYPE',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _types.map((type) {
                final selected = type == _selectedType;
                return GestureDetector(
                  onTap: () => setState(() => _selectedType = type),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF1565C0)
                          : Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                          color: selected
                              ? const Color(0xFF42A5F5)
                              : Colors.white12),
                      boxShadow: selected
                          ? [
                              const BoxShadow(
                                  color: Color(0x331565C0), blurRadius: 8)
                            ]
                          : [],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_typeIcons[type] ?? Icons.report_problem,
                          color: selected ? Colors.white : Colors.white54,
                          size: 16),
                      const SizedBox(width: 6),
                      Text(type,
                          style: TextStyle(
                              color: selected ? Colors.white : Colors.white60,
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal)),
                    ]),
                  ),
                );
              }).toList()),
          const SizedBox(height: 28),
          const Text('DESCRIPTION',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          TextFormField(
            controller: _descCtrl,
            style: const TextStyle(color: Colors.white),
            maxLines: 4,
            decoration: _inputDecoration(
                'Describe what you see... (e.g. "Street flooded near G-10 Markaz")'),
            validator: (v) => (v == null || v.trim().length < 10)
                ? 'Please describe the incident (min 10 chars)'
                : null,
          ),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('LOCATION',
                style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            if (_gpsConfirmed)
              Row(children: [
                Icon(Icons.gps_fixed, color: Colors.greenAccent, size: 12),
                const SizedBox(width: 4),
                const Text('GPS Confirmed',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 10)),
              ]),
          ]),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _locCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration('e.g. G-10 Markaz, Islamabad'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Location is required'
                      : null,
                  onChanged: (v) {
                    // If user types manually, clear GPS confirmation
                    if (_gpsConfirmed) setState(() => _gpsConfirmed = false);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Use Current Location',
                child: InkWell(
                  onTap: _gpsLoading ? null : _getCurrentLocation,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _gpsConfirmed
                          ? Colors.green.withOpacity(0.15)
                          : Colors.blueAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _gpsConfirmed
                              ? Colors.green.withOpacity(0.4)
                              : Colors.blueAccent.withOpacity(0.3)),
                    ),
                    child: _gpsLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.blueAccent))
                        : Icon(
                            _gpsConfirmed ? Icons.gps_fixed : Icons.my_location,
                            color: _gpsConfirmed
                                ? Colors.greenAccent
                                : Colors.blueAccent,
                            size: 24,
                          ),
                  ),
                ),
              )
            ],
          ),
          const SizedBox(height: 6),
          const Text('Tap 📍 to auto-fill your GPS location',
              style: TextStyle(color: Colors.white24, fontSize: 10)),
          const SizedBox(height: 20),
          const Text('YOUR NAME (OPTIONAL)',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          TextFormField(
            controller: _nameCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration('Anonymous if left blank'),
          ),
          const SizedBox(height: 36),
          SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 6,
                  shadowColor: Colors.red.withOpacity(0.4),
                  disabledBackgroundColor: Colors.red.withOpacity(0.3),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Submit Report',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
              )),
        ]));
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24),
        filled: true,
        fillColor: Colors.white.withOpacity(0.06),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF42A5F5), width: 2)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.redAccent)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.redAccent, width: 2)),
        errorStyle: const TextStyle(color: Colors.redAccent),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B3E),
        foregroundColor: Colors.white,
        title: const Text('Report an Incident',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _submitted ? _buildSuccessView() : _buildForm(),
    );
  }
}
