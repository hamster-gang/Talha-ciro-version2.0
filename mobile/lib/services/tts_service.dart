import 'dart:convert';
import 'package:http/http.dart' as http;
// import 'package:audioplayers/audioplayers.dart';
import '../config/env_config.dart';

class TTSService {
  // static final AudioPlayer _audioPlayer = AudioPlayer();

  static Future<void> speakIncidentAlert(Map<String, dynamic> incident) async {
    try {
      final severity = incident['severity'] ?? 'Unknown';
      final type = incident['crisis_type'] ?? incident['type'] ?? 'Incident';
      final zone = incident['location'] ?? incident['zone'] ?? 'Unknown location';
      
      final confidenceRaw = incident['confidence'];
      int confidencePercent = 0;
      if (confidenceRaw is num) {
        confidencePercent = confidenceRaw <= 1.0 
            ? (confidenceRaw * 100).toInt() 
            : confidenceRaw.toInt();
      }

      final allocatedResources = incident['actions_executed'] ?? incident['allocated_resources'];
      int resourceCount = 0;
      if (allocatedResources is List) {
        resourceCount = allocatedResources.length;
      }

      final textToSpeak = "Severity $severity alert. $type detected in $zone. Confidence $confidencePercent percent. $resourceCount emergency units deployed autonomously by CIRO.";

      final url = Uri.parse('https://texttospeech.googleapis.com/v1/text:synthesize?key=${EnvConfig.ttsKey}');

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "input": {"text": textToSpeak},
          "voice": {
            "languageCode": "en-US",
            "name": "en-US-Neural2-D",
            "ssmlGender": "MALE"
          },
          "audioConfig": {"audioEncoding": "MP3"}
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final audioContent = data['audioContent'] as String;
        final _ = base64Decode(audioContent); // audio generated but web playback disabled
        
        // final tempDir = Directory.systemTemp;
        // final file = File('${tempDir.path}/incident_alert.mp3');
        // await file.writeAsBytes(bytes);

        // await _audioPlayer.play(DeviceFileSource(file.path));
        print('[TTS] Audio generated successfully - playback disabled on web');
      } else {
        print("TTS Error: ${response.statusCode} - ${response.body}");
      }
    } catch (e) {
      print("TTS Exception: $e");
    }
  }
}
