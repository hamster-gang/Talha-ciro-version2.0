import 'dart:html' as html;

import 'geolocation_service.dart';

Future<GeoPosition?> getCurrentPosition({
  bool enableHighAccuracy = true,
  Duration? timeout,
}) async {
  final geolocation = html.window.navigator.geolocation;
  final position = await geolocation.getCurrentPosition(
    enableHighAccuracy: enableHighAccuracy,
    timeout: timeout,
  );

  final lat = position.coords?.latitude?.toDouble();
  final lng = position.coords?.longitude?.toDouble();
  if (lat == null || lng == null) return null;

  return GeoPosition(lat, lng);
}
