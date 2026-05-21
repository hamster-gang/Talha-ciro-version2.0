import 'geolocation_service_stub.dart'
    if (dart.library.html) 'geolocation_service_web.dart' as impl;

class GeoPosition {
  final double latitude;
  final double longitude;

  const GeoPosition(this.latitude, this.longitude);
}

class GeolocationService {
  static Future<GeoPosition?> getCurrentPosition({
    bool enableHighAccuracy = true,
    Duration? timeout,
  }) {
    return impl.getCurrentPosition(
      enableHighAccuracy: enableHighAccuracy,
      timeout: timeout,
    );
  }
}
