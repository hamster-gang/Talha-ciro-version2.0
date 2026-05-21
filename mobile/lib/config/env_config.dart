import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static Future<void> init() async {
    await dotenv.load(fileName: ".env");
  }

  static String get backendUrl => 
      dotenv.env['API_BASE_URL'] ?? 'http://localhost:8000';
  static String get mapsKey => 
      dotenv.env['GOOGLE_MAPS_KEY'] ?? '';
  static String get placesKey => 
      dotenv.env['GOOGLE_PLACES_KEY'] ?? '';
  static String get geocodingKey => 
      dotenv.env['GOOGLE_GEOCODING_KEY'] ?? '';
  static String get ttsKey => 
      dotenv.env['GOOGLE_TTS_KEY'] ?? '';
}
