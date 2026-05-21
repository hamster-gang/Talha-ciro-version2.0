import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../config/env_config.dart';
import '../services/geocoding_service.dart';
import '../services/geolocation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'report_incident_screen.dart';

/// Citizen Safety Center
/// Shows safety status, full 8-stage report lifecycle, Nearby Alerts,
/// tracking ID search, and prominent report button.
class CitizenDashboardScreen extends StatefulWidget {
  const CitizenDashboardScreen({super.key});
  @override
  State<CitizenDashboardScreen> createState() => _CitizenDashboardScreenState();
}

class _CitizenDashboardScreenState extends State<CitizenDashboardScreen> {
  List<dynamic> _allReports = [];
  List<dynamic> _myReports = [];
  List<dynamic> _alerts = [];
  bool _safeStatus = true;
  String? _rerouteMsg;
  bool _loading = true;
  Timer? _pollTimer;
  final _searchCtrl = TextEditingController();

  // 4-stage simplified lifecycle mapping is done dynamically

  @override
  void initState() {
    super.initState();
    _fetchAll();
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) => _fetchAll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchAll() async {
    try {
      final rFuture =
          http.get(Uri.parse('${EnvConfig.backendUrl}/api/citizen-reports'));
      final aFuture = http.get(Uri.parse('${EnvConfig.backendUrl}/api/alerts'));
      final sFuture = http.get(Uri.parse('${EnvConfig.backendUrl}/status'));
      final results = await Future.wait([rFuture, aFuture, sFuture]);

      List<dynamic> reports = [];
      if (results[0].statusCode == 200)
        reports = json.decode(results[0].body)['reports'] ?? [];

      List<dynamic> alerts = [];
      if (results[1].statusCode == 200)
        alerts = json.decode(results[1].body)['alerts'] ?? [];

      bool safe = true;
      String? rerouteMsg;
      if (results[2].statusCode == 200) {
        final latest = json.decode(results[2].body)['latest'] ?? {};
        if (latest.isNotEmpty && latest['status'] != 'monitoring') {
          final sev = latest['classification']?['severity'] ?? 0;
          if (sev >= 3) safe = false;
          final actions = latest['execution']?['actions_executed'] ?? [];
          for (var a in actions) {
            if (a['action_type'] == 'traffic_reroute') {
              rerouteMsg =
                  "Avoid ${a['parameters']['zone'] ?? 'affected area'}. Use ${a['parameters']['alternate_route']}.";
            }
          }
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final myReportIds = prefs.getStringList('myReportIds') ?? [];

      if (mounted)
        setState(() {
          _allReports = reports;
          _myReports = reports
              .where((r) => myReportIds.contains(r['report_id']))
              .toList();
          _alerts = alerts;
          _safeStatus = safe;
          _rerouteMsg = rerouteMsg;
          _loading = false;
        });
      _applySearch(_searchCtrl.text);
      // Re-check nearby incidents if location is available
      if (_userLat != null) _checkNearbyIncidents();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applySearch(String val) {
    setState(() {
      final prefs = SharedPreferences.getInstance().then((prefs) {
        final myReportIds = prefs.getStringList('myReportIds') ?? [];
        final baseReports = _allReports
            .where((r) => myReportIds.contains(r['report_id']))
            .toList();
        setState(() {
          if (val.trim().isEmpty) {
            _myReports = List.from(baseReports);
          } else {
            _myReports = baseReports
                .where((r) =>
                    (r['report_id'] ?? '')
                        .toString()
                        .toLowerCase()
                        .contains(val.toLowerCase()) ||
                    (r['incident_type'] ?? '')
                        .toString()
                        .toLowerCase()
                        .contains(val.toLowerCase()))
                .toList();
          }
        });
      });
    });
  }

  Future<void> _submitFeedback(String reportId, bool resolved) async {
    try {
      await http.post(
        Uri.parse('${EnvConfig.backendUrl}/api/citizen-feedback/$reportId'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'resolved': resolved, 'comments': ''}),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(resolved
              ? '✅ Thank you! Report closed.'
              : '⚠️ Noted. Authorities will follow up.'),
          backgroundColor: resolved ? Colors.green : Colors.orange,
        ));
        _fetchAll();
      }
    } catch (_) {}
  }

  Color _stageColor(String status) {
    switch (status) {
      case 'submitted':
        return Colors.blueGrey;
      case 'under_review':
        return Colors.deepPurple;
      case 'dispatched':
        return Colors.blue;
      case 'resolved':
        return Colors.green;
      // legacy support
      case 'queued_for_analysis':
        return Colors.indigo;
      case 'location_verified':
        return Colors.purple;
      case 'incident_classified':
        return Colors.deepPurple;
      case 'severity_assessed':
        return Colors.orange;
      case 'confidence_score_calculated':
        return Colors.deepOrange;
      case 'resources_identified':
        return Colors.amber;
      case 'response_strategy_generated':
        return Colors.cyan;
      case 'authorities_notified':
        return Colors.blueAccent;
      case 'rescue_units_dispatched':
        return Colors.blue;
      case 'in_progress':
        return Colors.lightBlue;
      case 'closed':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  IconData _stageIcon(String status) {
    switch (status) {
      case 'submitted':
        return Icons.send;
      case 'under_review':
        return Icons.analytics;
      case 'dispatched':
        return Icons.local_shipping;
      case 'resolved':
        return Icons.check_circle;
      // legacy support
      case 'queued_for_analysis':
        return Icons.queue;
      case 'location_verified':
        return Icons.location_on;
      case 'incident_classified':
        return Icons.category;
      case 'severity_assessed':
        return Icons.warning;
      case 'confidence_score_calculated':
        return Icons.analytics;
      case 'resources_identified':
        return Icons.inventory;
      case 'response_strategy_generated':
        return Icons.lightbulb;
      case 'authorities_notified':
        return Icons.campaign;
      case 'rescue_units_dispatched':
        return Icons.local_shipping;
      case 'in_progress':
        return Icons.directions_run;
      case 'closed':
        return Icons.archive;
      default:
        return Icons.inbox;
    }
  }

  String _stageLabel(String status) {
    switch (status) {
      case 'submitted':
        return 'Submitted';
      case 'under_review':
        return 'Under Review';
      case 'dispatched':
        return 'Dispatched';
      case 'resolved':
        return 'Resolved';
      // legacy support
      case 'queued_for_analysis':
        return 'Queued';
      case 'location_verified':
        return 'Location Verified';
      case 'incident_classified':
        return 'Classified';
      case 'severity_assessed':
        return 'Severity Assessed';
      case 'confidence_score_calculated':
        return 'Confidence Scored';
      case 'resources_identified':
        return 'Resources Found';
      case 'response_strategy_generated':
        return 'Strategy Gen';
      case 'authorities_notified':
        return 'Authorities Notified';
      case 'rescue_units_dispatched':
        return 'Dispatched';
      case 'in_progress':
        return 'In Progress';
      default:
        return status.isEmpty
            ? ''
            : status[0].toUpperCase() +
                status.substring(1).replaceAll('_', ' ');
    }
  }

  Color _priorityColor(String? priority) {
    switch (priority) {
      case 'critical':
        return Colors.red;
      case 'high':
        return Colors.orange;
      case 'low':
        return Colors.green;
      default:
        return Colors.blueAccent;
    }
  }

  // Geolocation state
  double? _userLat;
  double? _userLng;
  bool _locationRequested = false;
  bool _locationDenied = false;
  bool _nearbyAlert = false;
  String _nearbyAlertMsg = '';

  void _requestGeolocation() {
    setState(() => _locationRequested = true);
    GeolocationService.getCurrentPosition().then((pos) {
      if (!mounted) return;
      if (pos == null) {
        setState(() => _locationDenied = true);
        return;
      }
      setState(() {
        _userLat = pos.latitude;
        _userLng = pos.longitude;
      });
      _checkNearbyIncidents();
    }).catchError((_) {
      if (mounted) setState(() => _locationDenied = true);
    });
  }

  Future<void> _checkNearbyIncidents() async {
    if (_userLat == null || _userLng == null) return;
    try {
      final res =
          await http.get(Uri.parse('${EnvConfig.backendUrl}/api/incidents'));
      if (res.statusCode == 200) {
        final incidents = json.decode(res.body)['incidents'] as List? ?? [];
        for (var inc in incidents) {
          if (inc['status'] != 'active') continue;
          final lat = (inc['lat'] as num?)?.toDouble() ?? 0;
          final lng = (inc['lng'] as num?)?.toDouble() ?? 0;
          // Simple radius check (~5km ≈ 0.045 degrees)
          final dist = ((_userLat! - lat) * (_userLat! - lat) +
              (_userLng! - lng) * (_userLng! - lng));
          if (dist < 0.045 * 0.045) {
            if (mounted)
              setState(() {
                _nearbyAlert = true;
                _safeStatus = false;
                _nearbyAlertMsg =
                    '⚠️ ${inc['crisis_type'] ?? 'Incident'} reported near your location. Take precautions.';
              });
            return;
          }
        }
        if (mounted)
          setState(() {
            _nearbyAlert = false;
            _safeStatus = true;
          });
      }
    } catch (_) {}
  }

  Widget _buildAreaStatus() {
    // Not yet requested location
    if (!_locationRequested) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1565C0).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF42A5F5).withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.location_off,
                  color: Color(0xFF42A5F5), size: 28),
              const SizedBox(width: 12),
              const Expanded(
                  child: Text('Enable Location for Area Safety',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 12),
            const Text(
                'Grant location access so CIRO can check for nearby incidents and alert you in real time.',
                style: TextStyle(
                    color: Colors.white54, fontSize: 13, height: 1.4)),
            const SizedBox(height: 14),
            SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _requestGeolocation,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('Enable Location Access'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF42A5F5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                )),
          ],
        ),
      );
    }

    // Denied
    if (_locationDenied) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withOpacity(0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.location_disabled,
                color: Colors.orangeAccent, size: 28),
            const SizedBox(width: 12),
            const Expanded(
                child: Text('Location Access Denied',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 8),
          const Text(
              'Area safety status unavailable. Enable location in browser settings to receive proximity alerts.',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
        ]),
      );
    }

    // Waiting for coordinates
    if (_userLat == null) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(children: [
          SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF42A5F5))),
          SizedBox(width: 16),
          Text('Determining your location...',
              style: TextStyle(color: Colors.white54)),
        ]),
      );
    }

    // Alert detected nearby
    if (_nearbyAlert) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFFB71C1C), Color(0xFFC62828)]),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.red.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 6))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 32),
            const SizedBox(width: 12),
            const Expanded(
                child: Text('ALERT: Incident Nearby',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 12),
          Text(_nearbyAlertMsg,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4)),
        ]),
      );
    }

    // Safe
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF1B5E20), Color(0xFF2E7D32)]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.green.withOpacity(0.3),
              blurRadius: 16,
              offset: const Offset(0, 6))
        ],
      ),
      child: Row(children: [
        const Icon(Icons.verified_user, color: Colors.white, size: 32),
        const SizedBox(width: 16),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Area Status: SAFE',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
              'No active incidents within 5 km of your location (${_userLat!.toStringAsFixed(4)}, ${_userLng!.toStringAsFixed(4)}).',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ])),
      ]),
    );
  }

  Widget _buildReportButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ReportIncidentScreen()));
              _fetchAll();
            },
            icon: const Icon(Icons.add_alert_rounded, size: 24),
            label: const Text('Report an Incident',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 6,
              shadowColor: Colors.red.withOpacity(0.4),
            ),
          )),
    );
  }

  int _getCurrentStageIndex(String status) {
    if (status == 'resolved' || status == 'closed') return 3;
    if (status == 'dispatched' ||
        status == 'in_progress' ||
        status == 'authorities_notified' ||
        status == 'rescue_units_dispatched' ||
        status == 'responding' ||
        status == 'response_strategy_generated') return 2;
    if (status == 'under_review' ||
        status == 'queued_for_analysis' ||
        status == 'location_verified' ||
        status == 'incident_classified' ||
        status == 'severity_assessed' ||
        status == 'confidence_score_calculated' ||
        status == 'resources_identified' ||
        status == 'verified' ||
        status == 'assigned') return 1;
    return 0; // submitted or received
  }

  Widget _buildLifecycleTimeline(String currentStatus, List<dynamic> events) {
    final currentIdx = _getCurrentStageIndex(currentStatus);

    // 4 stages
    final stages = [
      {'status': 'submitted', 'label': 'Report Submitted', 'icon': Icons.send},
      {
        'status': 'under_review',
        'label': 'AI Analysis & Review',
        'icon': Icons.analytics
      },
      {
        'status': 'dispatched',
        'label': 'Authorities Dispatched',
        'icon': Icons.local_shipping
      },
      {
        'status': 'resolved',
        'label': 'Incident Resolved',
        'icon': Icons.check_circle
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(stages.length, (i) {
        final stageInfo = stages[i];
        final done = i < currentIdx;
        final active = i == currentIdx;
        final isLast = i == stages.length - 1;

        // Find latest event that corresponds to this stage's index
        dynamic matchingEvent;
        for (var e in events.reversed) {
          if (_getCurrentStageIndex(e['status']) == i) {
            matchingEvent = e;
            break;
          }
        }

        String timeStr = '';
        String noteStr =
            matchingEvent != null ? (matchingEvent['note'] ?? '') : '';
        if (matchingEvent != null && matchingEvent['timestamp'] != null) {
          try {
            final d = DateTime.parse(matchingEvent['timestamp']).toLocal();
            timeStr =
                '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
          } catch (_) {}
        }

        if (active && noteStr.isEmpty) {
          if (i == 1) noteStr = 'AI agents are processing signals.';
          if (i == 2) noteStr = 'Emergency response initiated.';
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done
                        ? Colors.green
                        : (active ? const Color(0xFF42A5F5) : Colors.white12),
                    boxShadow: active
                        ? [
                            const BoxShadow(
                                color: Color(0xFF42A5F5), blurRadius: 8)
                          ]
                        : null,
                  ),
                  child: Icon(
                    done
                        ? Icons.check
                        : (active
                            ? (stageInfo['icon'] as IconData)
                            : Icons.circle_outlined),
                    color: Colors.white,
                    size: 16,
                  ),
                ),
                if (!isLast)
                  Container(
                    width: 2,
                    height: 36,
                    color: done ? Colors.green : Colors.white12,
                  ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(stageInfo['label'] as String,
                            style: TextStyle(
                              color: done || active
                                  ? Colors.white
                                  : Colors.white38,
                              fontWeight:
                                  active ? FontWeight.bold : FontWeight.normal,
                              fontSize: 15,
                            )),
                        if (timeStr.isNotEmpty)
                          Text(timeStr,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                    if (noteStr.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(noteStr,
                            style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                height: 1.3)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildReportCard(Map<String, dynamic> report) {
    final status = report['status'] ?? 'submitted';
    final stageColor = _stageColor(status);
    final priority = report['priority'] ?? 'medium';
    final progressPct = report['progress_pct'] ?? 0;
    final agency = report['assigned_agency'];
    final etaMin = report['estimated_response_min'];
    final notes = report['authority_notes'] ?? '';
    final lifecycleEvents =
        (report['lifecycle_events'] as List? ?? []).reversed.take(3).toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: stageColor.withOpacity(0.4)),
        boxShadow: [
          BoxShadow(color: stageColor.withOpacity(0.1), blurRadius: 12)
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Progress bar
            LinearProgressIndicator(
              value: progressPct / 100,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(stageColor),
              minHeight: 4,
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row
                  Row(children: [
                    Icon(_stageIcon(status), color: stageColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(report['incident_type'] ?? 'Report',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14))),
                    Tooltip(
                      message:
                          "Initial severity estimate based on citizen report. Will be updated after AI analysis.",
                      triggerMode: TooltipTriggerMode.tap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _priorityColor(priority).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _priorityColor(priority).withOpacity(0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(priority.toUpperCase(),
                                style: TextStyle(
                                    color: _priorityColor(priority),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(width: 4),
                            Icon(Icons.info_outline,
                                color: _priorityColor(priority), size: 10),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: status == 'queued_for_analysis'
                          ? "Report successfully received. AI agents will begin processing shortly."
                          : "Current AI processing state.",
                      triggerMode: TooltipTriggerMode.tap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: stageColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_stageLabel(status).toUpperCase(),
                                style: TextStyle(
                                    color: stageColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(width: 4),
                            Icon(Icons.info_outline,
                                color: stageColor, size: 10),
                          ],
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text('📍 ${report['location'] ?? 'Unknown location'}',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Text('🪪 ID: ${report['report_id']}',
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 10)),
                    if (agency != null) ...[
                      const Spacer(),
                      Text('🏥 $agency',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 10)),
                    ]
                  ]),
                  if (etaMin != null && etaMin > 0) ...[
                    const SizedBox(height: 4),
                    Text('⏱ Estimated response: $etaMin min',
                        style: const TextStyle(
                            color: Colors.orangeAccent, fontSize: 11)),
                  ],
                  // Progress %
                  const SizedBox(height: 12),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Progress',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                        Text('$progressPct%',
                            style: TextStyle(
                                color: stageColor,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ]),
                  const SizedBox(height: 8),
                  const SizedBox(height: 12),
                  // Lifecycle timeline
                  _buildLifecycleTimeline(
                      status, report['lifecycle_events'] as List? ?? []),
                  // Feedback buttons for resolved status
                  if (status == 'resolved') ...[
                    const Divider(height: 24, color: Colors.white10),
                    const Text('Was this issue fully resolved?',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: () =>
                            _submitFeedback(report['report_id'], true),
                        icon: const Icon(Icons.check, size: 14),
                        label: const Text('Yes, resolved',
                            style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.green),
                          foregroundColor: Colors.greenAccent,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: () =>
                            _submitFeedback(report['report_id'], false),
                        icon: const Icon(Icons.close, size: 14),
                        label: const Text('Still an issue',
                            style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.orange),
                          foregroundColor: Colors.orangeAccent,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      )),
                    ])
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B3E),
        foregroundColor: Colors.white,
        title: const Text('Citizen Safety Center',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF42A5F5)))
          : RefreshIndicator(
              onRefresh: _fetchAll,
              color: const Color(0xFF42A5F5),
              child: ListView(children: [
                _buildAreaStatus(),
                _buildReportButton(),
                const SizedBox(height: 16),
                // Tracking ID Search
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search by Tracking ID or incident type...',
                      hintStyle: const TextStyle(color: Colors.white24),
                      prefixIcon:
                          const Icon(Icons.search, color: Colors.white54),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear,
                                  color: Colors.white38),
                              onPressed: () {
                                _searchCtrl.clear();
                                _applySearch('');
                              })
                          : null,
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
                          borderSide: const BorderSide(
                              color: Color(0xFF42A5F5), width: 2)),
                    ),
                    onChanged: _applySearch,
                  ),
                ),
                const SizedBox(height: 20),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('MY REPORTS',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold))),
                const SizedBox(height: 8),
                if (_myReports.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 32),
                    child: Column(children: [
                      Icon(Icons.inbox_outlined,
                          color: Colors.white24, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        _searchCtrl.text.isNotEmpty
                            ? 'No reports match your search.'
                            : 'No reports submitted yet.\nTap "Report an Incident" to get started.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 14, height: 1.5),
                      ),
                    ]),
                  )
                else
                  ..._myReports
                      .map((r) => _buildReportCard(r as Map<String, dynamic>)),
                const SizedBox(height: 24),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('NEARBY ALERTS',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold))),
                const SizedBox(height: 8),
                ..._alerts.map((a) => Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: a['severity'] == 'high'
                            ? Colors.red.withOpacity(0.12)
                            : Colors.amber.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: a['severity'] == 'high'
                                ? Colors.red.withOpacity(0.3)
                                : Colors.amber.withOpacity(0.2)),
                      ),
                      child: Row(children: [
                        Icon(
                            a['severity'] == 'high'
                                ? Icons.crisis_alert
                                : Icons.info_outline,
                            color: a['severity'] == 'high'
                                ? Colors.redAccent
                                : Colors.amber,
                            size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(a['message'] ?? '',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13)),
                              Text(a['time_ago'] ?? '',
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11)),
                            ])),
                      ]),
                    )),
                const SizedBox(height: 32),
              ]),
            ),
    );
  }
}
