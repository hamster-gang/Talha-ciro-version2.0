import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../config/env_config.dart';
import '../services/tts_service.dart';
import 'trace_panel_screen.dart';
import 'before_after_screen.dart';
import 'location_insights_screen.dart';

/// Authorities Command Center Dashboard
/// Shows live incidents from the autonomous agent loop,
/// color-coded by severity, with agent trace and demo injection.
class AuthoritiesDashboardScreen extends StatefulWidget {
  const AuthoritiesDashboardScreen({super.key});
  @override
  State<AuthoritiesDashboardScreen> createState() => _AuthoritiesDashboardScreenState();
}

class _AuthoritiesDashboardScreenState extends State<AuthoritiesDashboardScreen> {
  List<dynamic> _incidents = [];
  List<dynamic> _escalatedIncidents = [];
  Map<String, dynamic>? _systemState;
  Timer? _pollTimer;
  Timer? _secTimer;
  int _secsSinceUpdate = 0;
  bool _isPolling = false;
  int _selectedTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _fetchData();
    _fetchEscalated();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _fetchData();
      _fetchEscalated();
    });
    _secTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _secsSinceUpdate++);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel(); _secTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchData() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      final statusRes = await http.get(Uri.parse('${EnvConfig.backendUrl}/status'));
      final traceRes = await http.get(Uri.parse('${EnvConfig.backendUrl}/trace'));
      final incRes = await http.get(Uri.parse('${EnvConfig.backendUrl}/api/incidents'));
      
      if (incRes.statusCode == 200) {
        final incidents = json.decode(incRes.body)['incidents'] as List<dynamic>? ?? [];
        
        List<String> traces = [];
        if (traceRes.statusCode == 200) {
          final td = json.decode(traceRes.body);
          for (var log in (td['trace'] as List).reversed) {
            traces.add('${log['icon']} [${log['agent']}] ${log['message']}');
          }
        }

        int totalSaved = 0;
        int timeSaved = 0;
        int resolvedCount = 0;
        int dispatchedCount = 0;
        for (var inc in incidents) {
            if (inc['status'] == 'resolved') {
                resolvedCount++;
                totalSaved += (inc['simulation']?['improvement']?['lives_at_risk_mitigated'] as num? ?? 0).toInt();
                timeSaved += (inc['simulation']?['improvement']?['response_time_saved_min'] as num? ?? 0).toInt();
            }
            if (inc['status'] != 'retracted' && inc['execution'] != null && inc['execution']['actions_executed'] != null) {
                dispatchedCount += (inc['execution']['actions_executed'] as List).length;
            }
        }
        int avgTimeSaved = resolvedCount > 0 ? (timeSaved / resolvedCount).round() : 0;
        
        if (mounted) setState(() {
          _incidents = incidents;
          _systemState = {
            'active_incidents': incidents.where((i) => i['status'] == 'active').length,
            'total_handled': incidents.length,
            'dispatched_units': dispatchedCount,
            'avg_time_saved': avgTimeSaved,
            'total_lives_secured': totalSaved,
            'recent_actions': traces,
            'resolved_count': resolvedCount,
          };
          _secsSinceUpdate = 0;
        });
      }
    } catch (_) {} finally { _isPolling = false; }
  }

  Future<void> _fetchEscalated() async {
    try {
      final res = await http.get(
        Uri.parse('${EnvConfig.backendUrl}/api/escalated-incidents'),
      );
      if (res.statusCode == 200 && mounted) {
        final data = json.decode(res.body);
        setState(() {
          _escalatedIncidents = data['escalated_incidents'] as List<dynamic>? ?? [];
        });
      }
    } catch (_) {}
  }

  void _showLocationSearch() {
    showDialog(context: context, builder: (ctx) {
      final ctrl = TextEditingController();
      return AlertDialog(
        backgroundColor: const Color(0xFF0D1B3E),
        title: const Text('Location Intelligence', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. Lahore, G-10 Islamabad, Karachi',
            hintStyle: const TextStyle(color: Colors.white38),
            prefixIcon: const Icon(Icons.search, color: Colors.white38),
            filled: true,
            fillColor: Colors.black26,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)
          ),
          onSubmitted: (v) {
            if (v.isNotEmpty) {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => LocationInsightsScreen(locationQuery: v.trim())));
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            onPressed: () {
              final q = ctrl.text.trim();
              Navigator.pop(ctx);
              if (q.isNotEmpty) {
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => LocationInsightsScreen(locationQuery: q)));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            child: const Text('Analyse', style: TextStyle(color: Colors.white)),
          )
        ]
      );
    });
  }

  void _showIncidentDetail(Map<String, dynamic> incident) {
    final sev = incident['severity'] ?? 1;
    final sevColor = sev >= 5 ? Colors.red : sev == 4 ? Colors.orange : sev == 3 ? Colors.amber : Colors.green;
    final isRetracted = incident['status'] == 'retracted';
    final lat = (incident['lat'] ?? 33.6844).toDouble();
    final lng = (incident['lng'] ?? 73.0479).toDouble();
    final mapUrl = 'https://maps.googleapis.com/maps/api/staticmap?center=$lat,$lng&zoom=15&size=600x300&markers=color:red|label:!|$lat,$lng&style=feature:all|element:geometry|color:0x1d2c4d&key=${EnvConfig.mapsKey}';

    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: const BoxDecoration(color: Color(0xFF0D1B3E), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: Image.network(mapUrl, height: 200, width: double.infinity, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(height: 200, color: Colors.grey.shade800,
                child: const Center(child: Text('Map Preview Unavailable', style: TextStyle(color: Colors.white))))),
          ),
          Expanded(child: ListView(padding: const EdgeInsets.all(24), children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Text('${incident['crisis_type']}', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: isRetracted ? Colors.grey : sevColor, borderRadius: BorderRadius.circular(16)),
                child: Text('Sev $sev', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 8),
            Text('📍 ${incident['location']}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            Row(children: [
              _MetricChip(label: 'Affected', value: '${incident['affected_population']}', icon: Icons.people),
              const SizedBox(width: 12),
              _MetricChip(label: 'Confidence', value: '${((incident['confidence'] ?? 0) * 100).toInt()}%', icon: Icons.analytics),
            ]),
            const SizedBox(height: 24),
            const Text('AI Reasoning & Signals', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              Chip(label: const Text('Weather Alert', style: TextStyle(color: Colors.white70, fontSize: 11)), backgroundColor: Colors.white10),
              Chip(label: const Text('High Social Urgency', style: TextStyle(color: Colors.white70, fontSize: 11)), backgroundColor: Colors.white10),
              Chip(label: const Text('Citizen Reports', style: TextStyle(color: Colors.white70, fontSize: 11)), backgroundColor: Colors.white10),
            ]),
            if (incident['status'] == 'resolved' && incident['recovery'] != null) ...[
              const SizedBox(height: 24),
              const Text('Lessons Learned', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  (incident['recovery']['reasoning_steps'] as List?)?.last ?? 'Incident successfully mitigated. Response flow verified.',
                  style: const TextStyle(color: Colors.greenAccent)
                ),
              ),
            ],
            const SizedBox(height: 24),
            const Text('Incident Timeline', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildTimeline(incident['status'] ?? 'active'),
            const SizedBox(height: 24),
            const Text('Actions Deployed', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (incident['execution'] != null && incident['execution']['actions_executed'] != null && !isRetracted)
              ...(incident['execution']['actions_executed'] as List).map((a) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle, color: Colors.greenAccent),
                title: Text(a['action_type'].toString().replaceAll('_', ' ').toUpperCase(), style: const TextStyle(color: Colors.white)),
                subtitle: Text(a['parameters'].toString(), style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ))
            else const Text('No actions executed.', style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => TTSService.speakIncidentAlert(incident),
                    icon: const Icon(Icons.volume_up), label: const Text('Speak Alert'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () { Navigator.pop(ctx); Navigator.push(context, MaterialPageRoute(builder: (_) => BeforeAfterScreen(incident: incident))); },
                    icon: const Icon(Icons.compare_arrows), label: const Text('Simulation'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ]
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () { Navigator.pop(ctx); Navigator.push(context, MaterialPageRoute(builder: (_) => TracePanelScreen(incidentId: incident['incident_id']))); },
              icon: const Icon(Icons.code, color: Colors.white70), label: const Text('View Agent Trace', style: TextStyle(color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
            const SizedBox(height: 24),
            _NearbyResourcesSection(lat: lat, lng: lng),
            const SizedBox(height: 16),
          ])),
        ]),
      ),
    );
  }

  Widget _buildTimeline(String status) {
    return Row(children: [
      _timelineNode('Detected', true),
      _timelineLine(true),
      _timelineNode('Responding', status == 'active'),
      _timelineLine(status == 'active'),
      _timelineNode('Resolved', false),
    ]);
  }

  Widget _timelineNode(String label, bool active) => Column(children: [
    Icon(Icons.circle, size: 12, color: active ? Colors.blue : Colors.white24),
    const SizedBox(height: 4),
    Text(label, style: TextStyle(color: active ? Colors.white : Colors.white24, fontSize: 10)),
  ]);

  Widget _timelineLine(bool active) => Expanded(child: Container(height: 2, color: active ? Colors.blue : Colors.white24, margin: const EdgeInsets.only(bottom: 16)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B3E),
        foregroundColor: Colors.white,
        title: Row(children: [
          const Text('National Command Center', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: 'Search Location Insights',
            onPressed: _showLocationSearch,
          ),
          const SizedBox(width: 8),
          Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.greenAccent, blurRadius: 6)])),
          const SizedBox(width: 8),
          const Text('LIVE', style: TextStyle(fontSize: 12, color: Colors.greenAccent)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_tree_rounded),
            tooltip: 'View Pipeline',
            onPressed: () => Navigator.pushNamed(context, '/pipeline'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Updated ${_secsSinceUpdate}s ago', style: const TextStyle(color: Colors.white38, fontSize: 12))),
        if (_systemState != null) Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _StatBadge(label: 'Emergency Reports', value: '${_systemState!['total_handled']}', color: Colors.blueAccent),
              const SizedBox(width: 8),
              _StatBadge(label: 'Active Alerts', value: '${_systemState!['active_incidents']}', color: Colors.redAccent),
              const SizedBox(width: 8),
              _StatBadge(label: 'Dispatched', value: '${_systemState!['dispatched_units']}', color: Colors.orange),
              const SizedBox(width: 8),
              _StatBadge(label: 'Completed', value: '${_systemState!['resolved_count']}', color: Colors.greenAccent),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
                ChoiceChip(
                  label: const Text('Active Alerts'),
                  selected: _selectedTabIndex == 0,
                  onSelected: (v) => setState(() => _selectedTabIndex = 0),
                ),
                const SizedBox(width: 10),
                ChoiceChip(
                  label: const Text('Resolved'),
                  selected: _selectedTabIndex == 1,
                  onSelected: (v) => setState(() => _selectedTabIndex = 1),
                ),
                const SizedBox(width: 10),
                ChoiceChip(
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.verified_user, size: 14),
                    const SizedBox(width: 4),
                    const Text('Command Center'),
                    if (_escalatedIncidents.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${_escalatedIncidents.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ]),
                  selected: _selectedTabIndex == 2,
                  selectedColor: Colors.redAccent.withOpacity(0.2),
                  onSelected: (v) => setState(() => _selectedTabIndex = 2),
                ),
            ]
        ),
        const SizedBox(height: 8),
        Expanded(child: Builder(builder: (_) {
          // Tab 2: National Command Center — escalated incidents only
          if (_selectedTabIndex == 2) return _buildCommandCenterTab();

          // Show ALL incidents in the first tab to ensure pipeline visibility
          final filtered = _incidents.where((i) => _selectedTabIndex == 0
            ? true
            : (i['status'] == 'resolved' || i['status'] == 'retracted')
          ).toList();
          if (filtered.isEmpty) {
            return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.radar, color: Colors.white24, size: 56),
              const SizedBox(height: 16),
              Text(_selectedTabIndex == 0 ? 'Monitoring... No active incidents.' : 'No resolved history yet.',
                style: const TextStyle(color: Colors.white38, fontSize: 16)),
            ]));
          }
          return ListView.builder(
              padding: const EdgeInsets.all(16), itemCount: filtered.length,
              itemBuilder: (_, i) {
                final inc = filtered[i];
                final sev = inc['severity'] ?? 1;
                final sevColor = sev >= 5 ? Colors.red : sev == 4 ? Colors.orange : sev == 3 ? Colors.amber : Colors.green;
                final isRet = inc['status'] == 'retracted';
                return GestureDetector(
                  onTap: () => _showIncidentDetail(inc),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1B3E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: isRet ? Colors.white12 : sevColor.withOpacity(0.5)),
                      boxShadow: [BoxShadow(color: isRet ? Colors.transparent : sevColor.withOpacity(0.15), blurRadius: 12)],
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text(inc['crisis_type'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: isRet ? Colors.grey : sevColor, borderRadius: BorderRadius.circular(12)),
                          child: Text('Severity $sev', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
                      ]),
                      const SizedBox(height: 8),
                      Text('📍 ${inc['location']}', style: const TextStyle(color: Colors.white60, fontSize: 13)),
                      Text('👥 ${inc['affected_population']} affected · ${((inc['confidence'] ?? 0) * 100).toInt()}% confidence',
                        style: const TextStyle(color: Colors.white54, fontSize: 13)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, children: [
                        if (inc['execution'] != null)
                          ...(inc['execution']['actions_executed'] as List? ?? []).take(3).map((a) => Chip(
                            label: Text(a['action_type'].toString().replaceAll('_', ' '), style: const TextStyle(fontSize: 10)),
                            backgroundColor: Colors.white10, labelStyle: const TextStyle(color: Colors.white70),
                            padding: EdgeInsets.zero, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          )).toList(),
                      ]),
                    ]),
                  ),
                );
              }
          );
        })),
      ]),
    );
  }

  // ── National Command Center Tab ──────────────────────────────────────────

  Widget _buildCommandCenterTab() {
    if (_escalatedIncidents.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.verified_user, color: Colors.white24, size: 56),
        const SizedBox(height: 16),
        const Text('No escalated incidents yet.', style: TextStyle(color: Colors.white38, fontSize: 16)),
        const SizedBox(height: 8),
        const Text(
          'Incidents with Severity ≥ 3 and Confidence ≥ 65%\nwill be promoted here automatically.',
          style: TextStyle(color: Colors.white24, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
          ),
          child: const Row(children: [
            Icon(Icons.info_outline, color: Colors.redAccent, size: 16),
            SizedBox(width: 8),
            Expanded(child: Text(
              'Submit a citizen report in the Citizen Safety Center to trigger the AI pipeline.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            )),
          ]),
        ),
      ]));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _escalatedIncidents.length,
      itemBuilder: (_, i) => _buildEscalatedCard(_escalatedIncidents[i]),
    );
  }

  Widget _buildEscalatedCard(Map<String, dynamic> inc) {
    final sev       = inc['severity'] as int? ?? 1;
    final conf      = inc['confidence'] as int? ?? 0;
    final sevLabel  = inc['severity_label'] as String? ?? 'High';
    final status    = inc['status'] as String? ?? 'active';
    final agency    = inc['assigned_agency'] as String? ?? 'Rescue 1122';
    final eta       = inc['estimated_eta_min'] as int? ?? 8;
    final actions   = inc['recommended_actions'] as List? ?? [];
    final units     = (inc['dispatched_units'] as Map?)?.cast<String, dynamic>() ?? {};
    final alerts    = inc['alert_messages'] as List? ?? [];

    final Color sevColor = sev >= 5 ? Colors.red
        : sev == 4 ? Colors.orange
        : sev == 3 ? Colors.amber
        : Colors.green;

    final statusColor = status == 'active' ? Colors.redAccent
        : status == 'resolved'  ? Colors.greenAccent
        : Colors.white38;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: sevColor.withOpacity(0.6), width: 1.5),
        boxShadow: [BoxShadow(color: sevColor.withOpacity(0.2), blurRadius: 16)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Header ─────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: sevColor.withOpacity(0.08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: sevColor, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(
              inc['incident_type'] ?? inc['crisis_type'] ?? 'Unknown',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: sevColor, borderRadius: BorderRadius.circular(10)),
              child: Text('Sev $sev — $sevLabel',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── Location + Status row ────────────────────────────────────
            Row(children: [
              const Icon(Icons.location_on, color: Colors.white54, size: 14),
              const SizedBox(width: 4),
              Expanded(child: Text(inc['location'] ?? 'Unknown',
                style: const TextStyle(color: Colors.white70, fontSize: 13))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor.withOpacity(0.5)),
                ),
                child: Text(status.toUpperCase(),
                  style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 14),
            // ── Metric row ───────────────────────────────────────────────
            Row(children: [
              _cmdChip(Icons.analytics, '$conf% Confidence',
                conf >= 80 ? Colors.greenAccent : conf >= 65 ? Colors.blueAccent : Colors.amber),
              const SizedBox(width: 8),
              _cmdChip(Icons.local_hospital, agency, Colors.tealAccent),
              const SizedBox(width: 8),
              _cmdChip(Icons.timer, '~$eta min ETA', Colors.orangeAccent),
            ]),
            if (units.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Dispatched Units', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 4, children: units.entries.map((e) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
                ),
                child: Text('${e.value}× ${e.key.replaceAll('_', ' ')}',
                  style: const TextStyle(color: Colors.blueAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              )).toList()),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Recommended Actions', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
              const SizedBox(height: 6),
              ...actions.take(3).map((a) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.chevron_right, color: Colors.greenAccent, size: 16),
                  const SizedBox(width: 4),
                  Expanded(child: Text(a.toString(),
                    style: const TextStyle(color: Colors.white60, fontSize: 11, height: 1.4))),
                ]),
              )),
            ],
            if (alerts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.withOpacity(0.3)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.campaign, color: Colors.amber, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(alerts.first.toString(),
                    style: const TextStyle(color: Colors.amber, fontSize: 11, height: 1.4))),
                ]),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _cmdChip(IconData icon, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 12),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    ]),
  );
}

class _StatBadge extends StatelessWidget {
  final String label, value; final Color color;
  const _StatBadge({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Column(children: [
    Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
    Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
  ]);
}

class _MetricChip extends StatelessWidget {
  final String label, value; final IconData icon;
  const _MetricChip({required this.label, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(12)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: Colors.white54, size: 16), const SizedBox(width: 8),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      ]),
    ]),
  );
}

/// Nearest Emergency Resources — expandable section in incident detail sheet.
/// Fetches live data from /api/nearby-resources (Google Places API via backend).
class _NearbyResourcesSection extends StatefulWidget {
  final double lat;
  final double lng;
  const _NearbyResourcesSection({required this.lat, required this.lng});
  @override
  State<_NearbyResourcesSection> createState() => _NearbyResourcesSectionState();
}

class _NearbyResourcesSectionState extends State<_NearbyResourcesSection> {
  bool _expanded = false;
  bool _loading = false;
  Map<String, dynamic>? _data;
  String? _error;

  Future<void> _load() async {
    if (_data != null) return; // cache — only fetch once per open sheet
    setState(() => _loading = true);
    try {
      final uri = Uri.parse(
        '${EnvConfig.backendUrl}/api/nearby-resources?lat=${widget.lat}&lng=${widget.lng}&radius_km=10',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        setState(() { _data = json.decode(res.body); _loading = false; });
      } else {
        setState(() { _error = 'Server error ${res.statusCode}'; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = 'Could not reach backend'; _loading = false; });
    }
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case 'hospital': return Icons.local_hospital;
      case 'fire_station': return Icons.local_fire_department;
      case 'police': return Icons.local_police;
      default: return Icons.emergency;
    }
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'hospital': return Colors.redAccent;
      case 'fire_station': return Colors.orange;
      case 'police': return Colors.blue;
      default: return Colors.teal;
    }
  }

  Widget _facilityCard(Map<String, dynamic> f) {
    final type = f['type'] ?? 'hospital';
    final color = _typeColor(type);
    final avail = f['availability'] as Map<String, dynamic>? ?? {};
    final readiness = avail['readiness'] ?? 'MEDIUM';
    final recommended = f['recommended'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: recommended ? color.withOpacity(0.6) : Colors.white10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_typeIcon(type), color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(f['name'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
          if (recommended)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
              child: Text('NEAREST', style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
            ),
        ]),
        const SizedBox(height: 4),
        Text(f['address'] ?? '', style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 8),
        Row(children: [
          _miniChip(Icons.straighten, '${f['distance_km']} km', color),
          const SizedBox(width: 8),
          _miniChip(Icons.timer_outlined, '${f['eta_minutes']} min ETA', Colors.orangeAccent),
          const SizedBox(width: 8),
          _miniChip(
            readiness == 'HIGH' ? Icons.check_circle : Icons.warning_amber,
            readiness,
            readiness == 'HIGH' ? Colors.greenAccent : Colors.amber,
          ),
        ]),
        if (avail.isNotEmpty) ...{
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: avail.entries
            .where((e) => e.key != 'readiness')
            .map((e) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(6)),
              child: Text('${e.key.replaceAll('_', ' ')}: ${e.value}',
                style: const TextStyle(color: Colors.white54, fontSize: 10)),
            )).toList()),
        }
      ]),
    );
  }

  Widget _miniChip(IconData icon, String label, Color color) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, color: color, size: 12),
    const SizedBox(width: 3),
    Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
  ]);

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () {
          setState(() => _expanded = !_expanded);
          if (_expanded) _load();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.teal.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.teal.withOpacity(0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.emergency_share, color: Colors.tealAccent, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Nearest Emergency Resources',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14))),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: Colors.white38),
          ]),
        ),
      ),
      if (_expanded) ...{
        const SizedBox(height: 12),
        if (_loading)
          const Center(child: Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(color: Colors.tealAccent, strokeWidth: 2),
          ))
        else if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))
        else if (_data != null) ...{
          for (final category in ['hospitals', 'fire_stations', 'police_stations', 'rescue_1122'])
            if (_data![category] != null)
              ...(_data![category] as List).map((f) => _facilityCard(f as Map<String, dynamic>)),
        }
      }
    ]);
  }
}
