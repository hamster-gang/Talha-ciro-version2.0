import 'package:flutter/material.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/env_config.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late AnimationController _fadeCtrl;
  bool _loopRunning = false;
  int _cycleCount = 0;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
    _fetchStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 8), (_) => _fetchStatus());
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchStatus() async {
    try {
      final res = await http.get(Uri.parse('${EnvConfig.backendUrl}/status')).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200 && mounted) {
        final d = json.decode(res.body);
        setState(() { _loopRunning = d['running'] ?? false; _cycleCount = d['cycle_count'] ?? 0; });
      }
    } catch (_) { if (mounted) setState(() => _loopRunning = false); }
  }

  @override
  Widget build(BuildContext context) {
    final pulse = Tween<double>(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    final fade = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut));
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF0A0E21), Color(0xFF0D1B3E), Color(0xFF1A1040)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: SafeArea(child: FadeTransition(opacity: fade, child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(height: 48),
            ScaleTransition(scale: pulse, child: Container(
              width: 90, height: 90,
              decoration: BoxDecoration(shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF7B1FA2)]),
                boxShadow: [BoxShadow(color: const Color(0xFF1565C0).withOpacity(0.5), blurRadius: 24, spreadRadius: 4)]),
              child: const Icon(Icons.shield_outlined, color: Colors.white, size: 48),
            )),
            const SizedBox(height: 20),
            const Text('CIRO', style: TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 6)),
            const Text('Crisis Intelligence & Response Orchestrator', textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13, letterSpacing: 1.2)),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AnimatedBuilder(animation: pulse, builder: (_, __) => Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _loopRunning ? Colors.greenAccent : Colors.redAccent,
                    boxShadow: [BoxShadow(color: (_loopRunning ? Colors.greenAccent : Colors.redAccent).withOpacity(pulse.value), blurRadius: 8)]),
                )),
                const SizedBox(width: 10),
                Text(_loopRunning ? 'AI Agents Active — Monitoring Live' : 'Backend Offline',
                  style: TextStyle(color: _loopRunning ? Colors.greenAccent : Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
            const SizedBox(height: 48),
            const Align(alignment: Alignment.centerLeft, child: Text('SELECT YOUR ROLE',
              style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2.5, fontWeight: FontWeight.bold))),
            const SizedBox(height: 16),
            _RoleCard(icon: Icons.admin_panel_settings_rounded, title: 'Authorities Command Center',
              subtitle: 'Live incidents, agent traces, resource deployment',
              gradient: const LinearGradient(colors: [Color(0xFF0D47A1), Color(0xFF1565C0)]),
              accentColor: const Color(0xFF42A5F5), onTap: () => Navigator.pushNamed(context, '/authorities')),
            const SizedBox(height: 16),
            _RoleCard(icon: Icons.people_alt_rounded, title: 'Citizen Safety Center',
              subtitle: 'Report incidents, track submissions, view alerts',
              gradient: const LinearGradient(colors: [Color(0xFF1B5E20), Color(0xFF2E7D32)]),
              accentColor: const Color(0xFF66BB6A), onTap: () => Navigator.pushNamed(context, '/citizen')),
            const SizedBox(height: 48),
            Padding(padding: const EdgeInsets.only(bottom: 24),
              child: Text('Google AI Seekho 2026 · Challenge 3 · Powered by Gemini 2.0 Flash',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 10, letterSpacing: 0.8))),
          ]),
        ))),
      ),
    );
  }
}

class _RoleCard extends StatefulWidget {
  final IconData icon; final String title; final String subtitle;
  final LinearGradient gradient; final Color accentColor; final VoidCallback onTap;
  const _RoleCard({required this.icon, required this.title, required this.subtitle,
    required this.gradient, required this.accentColor, required this.onTap});
  @override State<_RoleCard> createState() => _RoleCardState();
}

class _RoleCardState extends State<_RoleCard> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override void initState() { super.initState(); _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 120)); }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final scale = Tween<double>(begin: 1.0, end: 0.97).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(), onTapCancel: () => _ctrl.reverse(),
      onTapUp: (_) { _ctrl.reverse(); widget.onTap(); },
      child: ScaleTransition(scale: scale, child: Container(
        width: double.infinity, padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(gradient: widget.gradient, borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: widget.accentColor.withOpacity(0.25), blurRadius: 20, offset: const Offset(0, 8))]),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(14)),
            child: Icon(widget.icon, color: Colors.white, size: 32)),
          const SizedBox(width: 20),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(widget.subtitle, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
          ])),
          Icon(Icons.arrow_forward_ios_rounded, color: Colors.white.withOpacity(0.6), size: 16),
        ]),
      )),
    );
  }
}
