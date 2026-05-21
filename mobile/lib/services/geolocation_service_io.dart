import 'package:geolocator/geolocator.dart';

import 'geolocation_service.dart';

Future<GeoPosition?> getCurrentPosition({
  bool enableHighAccuracy = true,
  Duration? timeout,
}) async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) return null;

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }

  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return null;
  }

  final position = await Geolocator.getCurrentPosition(
    desiredAccuracy:
        enableHighAccuracy ? LocationAccuracy.high : LocationAccuracy.medium,
    timeLimit: timeout,
  );

  return GeoPosition(position.latitude, position.longitude);
}
