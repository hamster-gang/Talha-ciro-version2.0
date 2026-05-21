import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../config/env_config.dart';

/// Agentic Workflow Visualizer
/// Shows the 10-step Live Agent Activity execution trace in real time.
class PipelineScreen extends StatefulWidget {
  const PipelineScreen({super.key});

  @override
  State<PipelineScreen> createState() => _PipelineScreenState();
}

class _PipelineScreenState extends State<PipelineScreen> {
  Map<String, dynamic>? _pipelineData;
  Map<String, dynamic>? _signalsData;
  Map<String, dynamic>? _liveActivity;
  bool _isLoading = true;
  Timer? _pollTimer;

  final List<String> _agentOrder = [
    'SIGNAL_FUSION', 'CRISIS_CLASSIFIER', 'RESOURCE_ALLOCATOR',
    'ACTION_EXECUTOR', 'RECOVERY_AGENT'
  ];

  final Map<String, String> _agentTitles = {
    'SIGNAL_FUSION':     '1. Signal Fusion Agent',
    'CRISIS_CLASSIFIER': '2. Crisis Classifier Agent',
    'RESOURCE_ALLOCATOR':'3. Resource Allocator Agent',
    'ACTION_EXECUTOR':   '4. Action Executor Agent',
    'RECOVERY_AGENT':    '5. Recovery & Verification Agent'
  };

  final Map<String, IconData> _agentIcons = {
    'SIGNAL_FUSION':     Icons.hub,
    'CRISIS_CLASSIFIER': Icons.analytics,
    'RESOURCE_ALLOCATOR':Icons.local_shipping,
    'ACTION_EXECUTOR':   Icons.bolt,
    'RECOVERY_AGENT':    Icons.verified_user
  };

  final Map<String, String> _agentDescriptions = {
    'SIGNAL_FUSION':     'Analyzing uploaded report and geolocation',
    'CRISIS_CLASSIFIER': 'Determining crisis type and severity score',
    'RESOURCE_ALLOCATOR':'Locating nearest Rescue stations and hospitals',
    'ACTION_EXECUTOR':   'Preparing dispatch and safety recommendations',
    'RECOVERY_AGENT':    'Updating National Command Center metrics'
  };

  @override
  void initState() {
    super.initState();
    _fetchData();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _fetchData());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchData() async {
    try {
      final results = await Future.wait([
        http.get(Uri.parse('${EnvConfig.backendUrl}/api/pipeline-status')),
        http.get(Uri.parse('${EnvConfig.backendUrl}/api/signals')),
        http.get(Uri.parse('${EnvConfig.backendUrl}/api/live-activity')),
      ]);

      if (mounted) {
        setState(() {
          if (results[0].statusCode == 200) _pipelineData = json.decode(results[0].body);
          if (results[1].statusCode == 200) _signalsData  = json.decode(results[1].body);
          if (results[2].statusCode == 200) _liveActivity = json.decode(results[2].body);
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        title: const Text('Agentic Workflow', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF0D1B3E),
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.circle, color: Colors.greenAccent, size: 8),
                  SizedBox(width: 6),
                  Text('LIVE', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
            )),
          ),
        ],
      ),
      body: _isLoading
        ? const Center(child: CircularProgressIndicator(color: Colors.blue))
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSignalsBox(),
                const SizedBox(height: 16),
                _buildPipelineAgents(),
                const SizedBox(height: 16),
                _buildLiveAgentActivity(),
              ],
            ),
          ),
    );
  }

  Widget _buildSignalsBox() {
    final sources = _signalsData?['sources'] ?? {};
    final total   = _signalsData?['total_signals'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF42A5F5).withOpacity(0.5), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.input, color: Colors.blueAccent),
            const SizedBox(width: 8),
            const Text("LIVE SIGNAL INPUTS",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
              child: Text("Total: $total",
                style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
            )
          ]),
          const Divider(color: Colors.white12, height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SignalItem(icon: Icons.chat_bubble, label: "Social",
                val: "${sources['social_media']?['post_count'] ?? 0}"),
              _SignalItem(icon: Icons.person_pin, label: "Citizen",
                val: "${sources['citizen_reports']?['count'] ?? 0}"),
              _SignalItem(icon: Icons.cloud, label: "Weather",
                val: "${sources['weather']?['alert_level'] ?? 'N/A'}"),
              _SignalItem(icon: Icons.traffic, label: "Traffic",
                val: "${sources['traffic']?['max_congestion_pct'] ?? 0}%"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPipelineAgents() {
    final completed = List<String>.from(_pipelineData?['agents_completed'] ?? []);
    final cycle     = _pipelineData?['cycle'] ?? 0;
    final isIdle    = _pipelineData?['pipeline_stage'] == 'monitoring';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("AI ORCHESTRATOR",
              style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2)),
            // Only show cycle count when the pipeline is actively running — not in idle state
            if (!isIdle)
              Text("Cycle #$cycle", style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 12),
        if (isIdle)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: const Row(children: [
              Icon(Icons.access_time, color: Colors.blueAccent, size: 32),
              SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("Waiting for new incidents...",
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Submit a report in the Citizen Safety Center to trigger the pipeline.",
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              ])),
            ]),
          )
        else
          ...(_agentOrder.map((agent) {
            final isDone    = completed.contains(agent);
            final isCurrent = !isIdle && completed.isNotEmpty &&
              agent == _agentOrder[completed.length % _agentOrder.length] &&
              completed.length < _agentOrder.length;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isCurrent ? const Color(0xFF1565C0).withOpacity(0.2)
                  : (isDone ? Colors.green.withOpacity(0.08) : Colors.transparent),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isCurrent ? Colors.blue : (isDone ? Colors.green : Colors.white12)),
              ),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isDone ? Colors.green : (isCurrent ? Colors.blue : Colors.white12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_agentIcons[agent], color: Colors.white, size: 18),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_agentTitles[agent]!,
                    style: TextStyle(color: Colors.white, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                  if (isCurrent || isDone) ...[
                    const SizedBox(height: 3),
                    Text(_agentDescriptions[agent]!, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    if (isCurrent) const Text("Processing...", style: TextStyle(color: Colors.blueAccent, fontSize: 11)),
                    if (isDone)    const Text("✓ Completed",   style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
                  ],
                ])),
                if (isCurrent) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent)),
                if (isDone)    const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
              ]),
            );
          })).toList(),
      ],
    );
  }

  Widget _buildLiveAgentActivity() {
    final steps       = (_liveActivity?['steps'] as List?) ?? [];
    final pipelineRan = _liveActivity?['pipeline_ran'] ?? false;
    final hasCitizen  = _liveActivity?['has_citizen_report'] ?? false;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              border: const Border(bottom: BorderSide(color: Colors.white12)),
            ),
            child: Row(children: [
              const Icon(Icons.sensors, color: Colors.redAccent, size: 18),
              const SizedBox(width: 8),
              const Text("🔴  LIVE AGENT ACTIVITY",
                style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const Spacer(),
              if (!pipelineRan)
                const Text("Idle — awaiting report",
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
              if (pipelineRan && hasCitizen)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text("Citizen Report Active",
                    style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ]),
          ),

          // Empty idle state
          if (!pipelineRan)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                Icon(Icons.hourglass_empty, color: Colors.white24, size: 48),
                const SizedBox(height: 12),
                const Text("No active pipeline execution.",
                  style: TextStyle(color: Colors.white38, fontSize: 14)),
                const SizedBox(height: 4),
                const Text("Submit a citizen report to see real-time agent activity here.",
                  style: TextStyle(color: Colors.white24, fontSize: 12), textAlign: TextAlign.center),
              ]),
            )
          else
            // 10 structured steps
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: steps.map<Widget>((step) => _buildActivityStep(step)).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActivityStep(Map<String, dynamic> step) {
    final status    = step['status'] as String? ?? 'pending';
    final label     = step['label'] as String? ?? '';
    final agent     = step['agent'] as String? ?? '';
    final summary   = step['summary'] as String? ?? '';
    final tsRaw     = step['timestamp'] as String? ?? '';
    final stepId    = step['id'] as int? ?? 0;
    final isLast    = stepId == 10;

    Color statusColor;
    IconData statusIcon;
    String statusLabel;

    switch (status) {
      case 'completed':
        statusColor = Colors.greenAccent;
        statusIcon  = Icons.check_circle;
        statusLabel = 'Completed';
        break;
      case 'running':
        statusColor = Colors.blueAccent;
        statusIcon  = Icons.sync;
        statusLabel = 'Running';
        break;
      case 'failed':
        statusColor = Colors.redAccent;
        statusIcon  = Icons.error;
        statusLabel = 'Failed';
        break;
      default:
        statusColor = Colors.white24;
        statusIcon  = Icons.radio_button_unchecked;
        statusLabel = 'Pending';
    }

    // Format timestamp
    String timeStr = '';
    if (tsRaw.isNotEmpty) {
      try {
        final d = DateTime.parse(tsRaw).toLocal();
        timeStr = '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}:${d.second.toString().padLeft(2,'0')}';
      } catch (_) {}
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left: step indicator and connector line
        Column(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withOpacity(0.15),
              border: Border.all(color: statusColor.withOpacity(0.6), width: 1.5),
            ),
            child: status == 'running'
              ? Padding(
                  padding: const EdgeInsets.all(6),
                  child: CircularProgressIndicator(strokeWidth: 2, color: statusColor),
                )
              : Icon(statusIcon, color: statusColor, size: 16),
          ),
          if (!isLast)
            Container(width: 2, height: 36,
              color: status == 'completed' ? Colors.greenAccent.withOpacity(0.4) : Colors.white12),
        ]),
        const SizedBox(width: 14),
        // Right: content
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(label,
                    style: TextStyle(
                      color: status == 'pending' ? Colors.white38 : Colors.white,
                      fontSize: 13,
                      fontWeight: status == 'running' ? FontWeight.bold : FontWeight.normal,
                    ))),
                  if (timeStr.isNotEmpty)
                    Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(statusLabel,
                      style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(agent,
                    style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace'))),
                ]),
                if (summary.isNotEmpty && status != 'pending') ...[
                  const SizedBox(height: 6),
                  Text(summary,
                    style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SignalItem extends StatelessWidget {
  final IconData icon; final String label; final String val;
  const _SignalItem({required this.icon, required this.label, required this.val});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, color: Colors.white54, size: 20),
      const SizedBox(height: 6),
      Text(val, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
    ]);
  }
}
