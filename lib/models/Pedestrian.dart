// lib/models/Pedestrian.dart
import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import 'dart:math' as math;

enum PedestrianState { idle, walking, alert }

class Pedestrian {
  final String id;
  LatLng currentLocation;
  LatLng targetLocation;
  List<LatLng> path; // A* calculated path
  int pathIndex; // current position in path
  PedestrianState state;
  double speed; // meters per second
  DateTime lastUpdate;
  bool pathCalculating; // Track if path is being calculated

  Pedestrian({
    required this.id,
    required this.currentLocation,
    required this.targetLocation,
    this.path = const [],
    this.pathIndex = 0,
    this.state = PedestrianState.idle,
    this.speed = 1.5, // ~5.4 km/h typical pedestrian speed
    DateTime? lastUpdate,
    this.pathCalculating = false,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

  // Factory for API response
  factory Pedestrian.fromApiResponse(Map<String, dynamic> map) {
    final loc = map['location'] ?? {};
    final rawLat = loc['latitude'] ?? map['lat'] ?? 0.0;
    final rawLon = loc['longitude'] ?? map['lon'] ?? 0.0;

    return Pedestrian(
      id: (map['id'] ?? 'ped_${DateTime.now().millisecondsSinceEpoch}').toString(),
      currentLocation: LatLng(
        rawLat is num ? rawLat.toDouble() : double.parse(rawLat.toString()),
        rawLon is num ? rawLon.toDouble() : double.parse(rawLon.toString()),
      ),
      targetLocation: LatLng(
        rawLat is num ? rawLat.toDouble() : double.parse(rawLat.toString()),
        rawLon is num ? rawLon.toDouble() : double.parse(rawLon.toString()),
      ),
    );
  }

  /// Update pedestrian position along the path
  void updatePosition() {
    final now = DateTime.now();
    final deltaSeconds = now.difference(lastUpdate).inMilliseconds / 1000.0;
    lastUpdate = now;

    if (path.isEmpty || pathIndex >= path.length) {
      state = PedestrianState.idle;
      return;
    }

    // Calculate distance traveled in this time step
    final distTraveled = speed * deltaSeconds;

    // Move along the path
    var remainingDist = distTraveled;
    while (pathIndex < path.length && remainingDist > 0) {
      final nextPoint = path[pathIndex];
      final distToNext = _haversineDistance(currentLocation, nextPoint);

      if (remainingDist >= distToNext) {
        // Reached the next point, move to it
        remainingDist -= distToNext;
        currentLocation = nextPoint;
        pathIndex++;
      } else {
        // Interpolate between current and next point
        currentLocation = _interpolateLocation(
          currentLocation,
          nextPoint,
          remainingDist / distToNext,
        );
        break;
      }
    }

    if (pathIndex >= path.length) {
      state = PedestrianState.idle;
    }
  }

  /// Haversine distance in meters
  double _haversineDistance(LatLng p1, LatLng p2) {
    const earthRadiusMeters = 6371000.0;
    final dLat = (p2.latitude - p1.latitude) * math.pi / 180.0;
    final dLon = (p2.longitude - p1.longitude) * math.pi / 180.0;
    final lat1Rad = p1.latitude * math.pi / 180.0;
    final lat2Rad = p2.latitude * math.pi / 180.0;
    
    final sinHalfDLat = math.sin(dLat / 2.0);
    final sinHalfDLon = math.sin(dLon / 2.0);
    
    final a = sinHalfDLat * sinHalfDLat +
        math.cos(lat1Rad) * math.cos(lat2Rad) * sinHalfDLon * sinHalfDLon;
    final c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Linear interpolation between two lat/lon points
  LatLng _interpolateLocation(LatLng from, LatLng to, double t) {
    return LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'current_location': {
        'latitude': currentLocation.latitude,
        'longitude': currentLocation.longitude,
      },
      'target_location': {
        'latitude': targetLocation.latitude,
        'longitude': targetLocation.longitude,
      },
      'state': state.toString(),
      'speed': speed,
      'path_nodes': path.length,
      'path_progress': '${pathIndex}/${path.length}',
    };
  }
}
