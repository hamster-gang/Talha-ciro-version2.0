import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/authorities_dashboard_screen.dart';
import 'screens/citizen_dashboard_screen.dart';
import 'screens/report_incident_screen.dart';
import 'screens/trace_panel_screen.dart';
import 'screens/pipeline_screen.dart';
import 'config/env_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EnvConfig.init();
  runApp(const CiroApp());
}

class CiroApp extends StatelessWidget {
  const CiroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CIRO — Crisis Intelligence & Response Orchestrator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D47A1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/authorities': (context) => const AuthoritiesDashboardScreen(),
        '/citizen': (context) => const CitizenDashboardScreen(),
        '/report': (context) => const ReportIncidentScreen(),
        '/trace': (context) => const TracePanelScreen(),
        '/pipeline': (context) => const PipelineScreen(),
      },
    );
  }
}
