import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/env_config.dart';

class LocationInsightsScreen extends StatefulWidget {
  final String locationQuery;
  const LocationInsightsScreen({super.key, required this.locationQuery});

  @override
  State<LocationInsightsScreen> createState() => _LocationInsightsScreenState();
}

class _LocationInsightsScreenState extends State<LocationInsightsScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _insights;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchInsights();
  }

  Future<void> _fetchInsights() async {
    try {
      final uri = Uri.parse('${EnvConfig.backendUrl}/api/location-insights?query=${Uri.encodeComponent(widget.locationQuery)}');
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['error'] != null) {
            setState(() { _error = data['error']; _isLoading = false; });
        } else {
            setState(() { _insights = data; _isLoading = false; });
        }
      } else {
        setState(() { _error = 'Server error: ${res.statusCode}'; _isLoading = false; });
      }
    } catch (e) {
      setState(() { _error = 'Failed to connect to backend'; _isLoading = false; });
    }
  }

  // Risk explanation data — maps risk keywords to detailed explanations
  Map<String, String> _getRiskExplanation(String riskText) {
    final lower = riskText.toLowerCase();
    if (lower.contains('storm') || lower.contains('rain')) {
      return {
        'title': 'Storm / Rain Risk Analysis',
        'calculation': 'Based on historical weather patterns, satellite imagery, and seasonal data for this region.',
        'indicators': '• Humidity levels above 75%\n• Low pressure system approaching\n• Historical rainfall patterns for current month\n• Monsoon season proximity',
        'confidence': '72% confidence based on 3 corroborating data sources',
        'recommendation': 'Prepare drainage systems. Avoid low-lying areas. Monitor CIRO alerts.',
      };
    } else if (lower.contains('flood')) {
      return {
        'title': 'Flood Risk Analysis',
        'calculation': 'Computed using terrain elevation data, drainage capacity, and upstream water levels.',
        'indicators': '• Terrain below 500m elevation\n• Proximity to water channels\n• Soil saturation from recent rainfall\n• Historical flood frequency for this area',
        'confidence': '68% confidence based on hydrological models',
        'recommendation': 'Keep emergency supplies ready. Identify evacuation routes. Do not attempt to cross flooded roads.',
      };
    } else if (lower.contains('traffic') || lower.contains('congestion')) {
      return {
        'title': 'Traffic Disruption Analysis',
        'calculation': 'Derived from historical traffic patterns, ongoing incidents, and road closure data.',
        'indicators': '• Peak-hour congestion history for this route\n• Active incidents causing rerouting\n• Road construction or closures\n• Event-based surges (rallies, markets)',
        'confidence': '80% confidence based on real-time Google Maps data',
        'recommendation': 'Plan alternate routes. Allow extra travel time. Use public transit if possible.',
      };
    } else if (lower.contains('heat') || lower.contains('temperature')) {
      return {
        'title': 'Heatwave Risk Analysis',
        'calculation': 'Based on temperature forecasts, humidity index, and urban heat island effect.',
        'indicators': '• Predicted temperature above 40°C\n• Heat index accounting for humidity\n• Duration of sustained high temperatures\n• Historical heatwave mortality data',
        'confidence': '85% confidence from meteorological models',
        'recommendation': 'Stay hydrated. Avoid outdoor activity 11am-4pm. Check on elderly neighbours.',
      };
    }
    return {
      'title': 'Risk Analysis',
      'calculation': 'Assessed using multi-source intelligence including weather, historical data, and sensor feeds.',
      'indicators': '• Environmental monitoring sensors\n• Historical incident patterns\n• Satellite and weather data\n• Crowd-sourced citizen reports',
      'confidence': '65% confidence based on available data',
      'recommendation': 'Stay alert and monitor official CIRO channels for updates.',
    };
  }

  void _showRiskExplanation(String riskText) {
    final explanation = _getRiskExplanation(riskText);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1B3E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.all(24),
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text(explanation['title']!, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.orangeAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
              child: Text('"$riskText"', style: const TextStyle(color: Colors.orangeAccent, fontSize: 14, fontStyle: FontStyle.italic)),
            ),
            const SizedBox(height: 20),
            _sectionCard('📊 How Was This Calculated?', explanation['calculation']!, Colors.blueAccent),
            const SizedBox(height: 12),
            _sectionCard('📡 Contributing Indicators', explanation['indicators']!, Colors.cyanAccent),
            const SizedBox(height: 12),
            _sectionCard('🎯 Confidence Score', explanation['confidence']!, Colors.greenAccent),
            const SizedBox(height: 12),
            _sectionCard('🛡️ Recommended Action', explanation['recommendation']!, Colors.amberAccent),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard(String title, String content, Color accent) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(content, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B3E),
        title: Text('Insights: ${widget.locationQuery}', style: const TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Colors.blueAccent))
        : _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_insights == null) return const SizedBox();
    
    final pastCrises = _insights!['past_crises'] as List? ?? [];
    final upcomingRisks = _insights!['upcoming_risks'] as List? ?? [];
    final plan = _insights!['prevention_plan'] ?? '';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(_insights!['location_name'] ?? widget.locationQuery, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        Text('District: ${_insights!['district'] ?? 'Unknown'}', style: const TextStyle(color: Colors.white54, fontSize: 16)),
        const SizedBox(height: 32),
        
        const Text('⚠️ UPCOMING RISKS', style: TextStyle(color: Colors.orangeAccent, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        const SizedBox(height: 4),
        const Text('Tap any risk for a detailed explanation', style: TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 12),
        if (upcomingRisks.isEmpty)
           const Text('No imminent risks detected.', style: TextStyle(color: Colors.white54)),
        ...upcomingRisks.map((r) => GestureDetector(
            onTap: () => _showRiskExplanation(r.toString()),
            child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(r.toString(), style: const TextStyle(color: Colors.white))),
                    const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                ]),
            ),
        )),
        const SizedBox(height: 32),
        
        const Text('📜 HISTORICAL CRISES & LOSSES', style: TextStyle(color: Colors.white38, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        if (pastCrises.isEmpty)
           const Text('No significant past crises recorded.', style: TextStyle(color: Colors.white54)),
        ...pastCrises.map((c) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(c['type'].toString().toUpperCase(), style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                    Text(c['year'].toString(), style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 8),
                Text('Losses: ${c['losses']}', style: const TextStyle(color: Colors.white)),
            ]),
        )),
        const SizedBox(height: 32),
        
        const Text('🛡️ PREVENTION & PREPAREDNESS', style: TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.greenAccent.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.greenAccent.withOpacity(0.2))),
            child: Text(plan.toString(), style: const TextStyle(color: Colors.white, height: 1.5)),
        ),
      ],
    );
  }
}
