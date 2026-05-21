import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/env_config.dart';

class BeforeAfterScreen extends StatefulWidget {
  final Map<String, dynamic> incident;
  
  const BeforeAfterScreen({super.key, required this.incident});

  @override
  State<BeforeAfterScreen> createState() => _BeforeAfterScreenState();
}

class _BeforeAfterScreenState extends State<BeforeAfterScreen> {
  Map<String, dynamic>? _simulationData;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchSimulationData();
  }

  Future<void> _fetchSimulationData() async {
    final incidentId = widget.incident['incident_id'];
    if (incidentId == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final res = await http.get(Uri.parse('${EnvConfig.backendUrl}/api/simulation/$incidentId'));
      if (res.statusCode == 200 && mounted) {
        setState(() {
          _simulationData = json.decode(res.body);
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0E21),
        appBar: AppBar(
          title: Text('Impact: ${widget.incident['crisis_type'] ?? 'Incident'}'),
          backgroundColor: const Color(0xFF0D1B3E),
          foregroundColor: Colors.white,
        ),
        body: const Center(child: CircularProgressIndicator(color: Colors.blue)),
      );
    }

    final before = _simulationData?['before'] ?? {};
    final after = _simulationData?['after'] ?? {};
    final improvement = _simulationData?['improvement'] ?? {};

    // Format Before data
    String beforeCongestion = "${before['traffic_congestion_pct'] ?? '87'}%";
    String beforeResources = "${before['resources_deployed'] ?? '0'} Active";
    String beforeAlerts = "${before['alerts_sent'] ?? '0'} Sent";
    String beforeResponse = "${before['estimated_response_min'] ?? '14'} mins";

    // Format After data
    String afterCongestion = "${after['traffic_congestion_pct'] ?? '35'}%";
    if (after['reroute_applied'] != null) {
      afterCongestion += "\n(Rerouted: ${after['reroute_applied']})";
    }
    
    String afterResources = "None";
    if (after['dispatched_units'] != null && (after['dispatched_units'] as Map).isNotEmpty) {
      List<String> resList = [];
      (after['dispatched_units'] as Map).forEach((k, v) => resList.add("$v ${k.replaceAll('_', ' ')}"));
      afterResources = resList.join('\n');
    }

    String afterAlerts = "None";
    if (after['alert_messages'] != null && (after['alert_messages'] as List).isNotEmpty) {
      afterAlerts = (after['alert_messages'] as List).join('\n');
    }

    String afterResponse = "${after['estimated_response_min'] ?? '8'} mins";

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        title: Text('Impact Simulation: ${widget.incident['crisis_type'] ?? 'Incident'}'),
        backgroundColor: const Color(0xFF0D1B3E),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (improvement.isNotEmpty) _buildImprovementBanner(improvement),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildColumn(
                      context, 
                      "BEFORE CIRO", 
                      const Color(0xFF3E1A1D), // Dark Red
                      congestion: beforeCongestion,
                      resources: beforeResources,
                      alerts: beforeAlerts,
                      responseEstimate: beforeResponse
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildColumn(
                      context, 
                      "AFTER CIRO", 
                      const Color(0xFF163E20), // Dark Green
                      congestion: afterCongestion,
                      resources: afterResources,
                      alerts: afterAlerts,
                      responseEstimate: afterResponse
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Text("Agent Decisions & Reasoning Trace", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1B3E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: (widget.incident['reasoning_trace'] as List? ?? []).map((trace) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        "> $trace",
                        style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12),
                      ),
                    );
                  }).toList(),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImprovementBanner(Map<String, dynamic> improvement) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF0D47A1)]),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.blue.withOpacity(0.3), blurRadius: 12)],
      ),
      child: Column(
        children: [
          const Text("ESTIMATED IMPACT", style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ImpactStat(value: "-${improvement['congestion_reduction_pct']}%", label: "Congestion"),
              _ImpactStat(value: "-${improvement['response_time_saved_min']}m", label: "Response Time"),
              _ImpactStat(value: "${improvement['lives_at_risk_mitigated']}", label: "Lives Secured"),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildColumn(BuildContext context, String title, Color bgColor, {
    required String congestion,
    required String resources,
    required String alerts,
    required String responseEstimate,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 32, thickness: 1, color: Colors.white24),
          const Text('Traffic Congestion', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white54)),
          Text(congestion, style: const TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(height: 16),
          const Text('Resources Deployed', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white54)),
          Text(resources, style: const TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(height: 16),
          const Text('Alerts Dispatched', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white54)),
          Text(alerts, style: const TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(height: 16),
          const Text('Response Time', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white54)),
          Text(responseEstimate, style: const TextStyle(color: Colors.greenAccent, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _ImpactStat extends StatelessWidget {
  final String value, label;
  const _ImpactStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
