// lib/services/pedestrian_manager.dart
import 'package:latlong2/latlong.dart';
import 'dart:math' as math;
import '../models/Pedestrian.dart';
import '../utils/astar_pathfinder.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

class AlertData {
  final String pedestrianId;
  final LatLng pedestrianLocation;
  final double distanceMeters;
  final DateTime timestamp;

  AlertData({
    required this.pedestrianId,
    required this.pedestrianLocation,
    required this.distanceMeters,
    required this.timestamp,
  });
}

class PedestrianManager {
  final List<Pedestrian> pedestrians = [];
  final double mapBoundsLatMin;
  final double mapBoundsLatMax;
  final double mapBoundsLonMin;
  final double mapBoundsLonMax;
  final double proximityThresholdMeters;

  // Callbacks
  Function(AlertData)? onAlertGenerated;
  Function(List<Pedestrian>)? onPedestriansUpdated;

  Timer? _updateTimer;
  static const int updateIntervalMs = 200; // 5 updates per second

  PedestrianManager({
    required this.mapBoundsLatMin,
    required this.mapBoundsLatMax,
    required this.mapBoundsLonMin,
    required this.mapBoundsLonMax,
    this.proximityThresholdMeters = 50.0, // 50 meters default alert distance
  });

  /// Spawn random pedestrians at map boundaries
  void spawnPedestrians(int count) {
    final random = math.Random();
    for (int i = 0; i < count; i++) {
      final id = 'ped_${DateTime.now().millisecondsSinceEpoch}_$i';

      // Random spawn location (preferably at map edges)
      final isOnHorizontalEdge = random.nextBool();
      final isOnStartEdge = random.nextBool();

      final spawnLat = isOnHorizontalEdge
          ? (isOnStartEdge ? mapBoundsLatMin : mapBoundsLatMax)
          : mapBoundsLatMin +
              (mapBoundsLatMax - mapBoundsLatMin) * random.nextDouble();

      final spawnLon = isOnHorizontalEdge
          ? mapBoundsLonMin +
              (mapBoundsLonMax - mapBoundsLonMin) * random.nextDouble()
          : (isOnStartEdge ? mapBoundsLonMin : mapBoundsLonMax);

      final spawnLocation = LatLng(spawnLat, spawnLon);

      // Random target location inside map
      final targetLat = mapBoundsLatMin +
          (mapBoundsLatMax - mapBoundsLatMin) * random.nextDouble();
      final targetLon = mapBoundsLonMin +
          (mapBoundsLonMax - mapBoundsLonMin) * random.nextDouble();
      final targetLocation = LatLng(targetLat, targetLon);

      final ped = Pedestrian(
        id: id,
        currentLocation: spawnLocation,
        targetLocation: targetLocation,
        speed: 1.3 + random.nextDouble() * 0.5, // 1.3-1.8 m/s
      );

      // Generate A* path asynchronously
      _generatePedestrianPath(ped);

      pedestrians.add(ped);
    }

    onPedestriansUpdated?.call(pedestrians);
  }

  /// Generate path for pedestrian using OSRM A*
  void _generatePedestrianPath(Pedestrian ped) async {
    ped.pathCalculating = true;
    try {
      final route = await AStarPathfinder.getRoute(
        ped.currentLocation,
        ped.targetLocation,
      );
      
      ped.path = route.waypoints;
      ped.state = PedestrianState.walking;
      
      debugPrint('🚶 ${ped.id}: Route generated - ${route.distanceMeters.toStringAsFixed(1)}m, ${route.durationSeconds.toStringAsFixed(1)}s');
    } catch (e) {
      debugPrint('⚠️ Error generating route for ${ped.id}: $e');
      ped.path = [ped.currentLocation, ped.targetLocation]; // Fallback
    }
    ped.pathCalculating = false;
    onPedestriansUpdated?.call(pedestrians);
  }

  /// Start continuous update loop
  void startUpdateLoop() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(Duration(milliseconds: updateIntervalMs), (_) {
      _updatePedestrians();
    });
  }

  /// Stop update loop
  void stopUpdateLoop() {
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  /// Internal: update all pedestrian positions
  void _updatePedestrians() {
    for (final ped in pedestrians) {
      ped.updatePosition();

      // Regenerate path if reached target
      if (ped.state == PedestrianState.idle) {
        _generateNewTarget(ped);
      }
    }

    onPedestriansUpdated?.call(pedestrians);
  }

  /// Generate a new random target for an idle pedestrian using OSRM routing
  Future<void> _generateNewTarget(Pedestrian ped) async {
    final random = math.Random();

    // New random target
    final targetLat = mapBoundsLatMin +
        (mapBoundsLatMax - mapBoundsLatMin) * random.nextDouble();
    final targetLon = mapBoundsLonMin +
        (mapBoundsLonMax - mapBoundsLonMin) * random.nextDouble();

    ped.targetLocation = LatLng(targetLat, targetLon);
    
    // Get route from OSRM using A*
    ped.pathCalculating = true;
    try {
      final route = await AStarPathfinder.getRoute(
        ped.currentLocation,
        ped.targetLocation,
      );
      
      ped.path = route.waypoints;
      debugPrint(
          '📍 ${ped.id}: New route - ${route.distanceMeters.toStringAsFixed(1)}m');
    } catch (e) {
      debugPrint('⚠️ Route error for ${ped.id}: $e');
      ped.path = [ped.currentLocation, ped.targetLocation];
    }
    ped.pathCalculating = false;
    
    ped.pathIndex = 0;
    ped.state = PedestrianState.walking;
  }

  /// Check proximity between vehicle and all pedestrians using OSRM road distance
  Future<void> checkProximityAsync(LatLng vehicleLocation) async {
    for (final ped in pedestrians) {
      try {
        // Get actual road distance from OSRM (via A*)
        final roadDistance = await AStarPathfinder.calculateRoadDistance(
          vehicleLocation,
          ped.currentLocation,
        );

        if (roadDistance.isInfinite || roadDistance < 0) {
          // Route not available
          continue;
        }

        debugPrint(
            '📍 ${ped.id}: Road distance = ${roadDistance.toStringAsFixed(1)}m (threshold: ${proximityThresholdMeters.toStringAsFixed(0)}m)');

        if (roadDistance <= proximityThresholdMeters) {
          // Generate alert
          final alert = AlertData(
            pedestrianId: ped.id,
            pedestrianLocation: ped.currentLocation,
            distanceMeters: roadDistance,
            timestamp: DateTime.now(),
          );

          onAlertGenerated?.call(alert);
          ped.state = PedestrianState.alert;
        } else if (ped.state == PedestrianState.alert) {
          // Clear alert if pedestrian moves away
          ped.state = PedestrianState.walking;
        }
      } catch (e) {
        debugPrint('⚠️ Error checking proximity for ${ped.id}: $e');
      }
    }
  }

  /// Get pedestrians within a radius (using OSRM road distance)
  Future<List<Pedestrian>> getPedestriansNearby(
      LatLng location, double radiusMeters) async {
    final nearby = <Pedestrian>[];
    for (final ped in pedestrians) {
      try {
        final distance = await AStarPathfinder.calculateRoadDistance(
          location,
          ped.currentLocation,
        );
        if (!distance.isInfinite && distance <= radiusMeters) {
          nearby.add(ped);
        }
      } catch (e) {
        debugPrint('⚠️ Error calculating distance for ${ped.id}: $e');
      }
    }
    return nearby;
  }

  /// Spawn pedestrians near vehicle location (within specified radius in meters)
  void spawnPedestriansNearby(int count, LatLng vehicleLocation, double radiusMeters) {
    final random = math.Random();
    
    for (int i = 0; i < count; i++) {
      final id = 'ped_nearby_${DateTime.now().millisecondsSinceEpoch}_$i';

      // Generate random point within radius
      final angle = random.nextDouble() * 2 * math.pi;
      final distance = random.nextDouble() * radiusMeters;
      
      // Convert distance/angle to lat/lon offset
      final latOffset = (distance / 111000) * math.cos(angle);
      final lonOffset = (distance / (111000 * math.cos(vehicleLocation.latitude * math.pi / 180))) * math.sin(angle);
      
      final spawnLocation = LatLng(
        vehicleLocation.latitude + latOffset,
        vehicleLocation.longitude + lonOffset,
      );

      // Target somewhere else within map
      final targetLat = mapBoundsLatMin +
          (mapBoundsLatMax - mapBoundsLatMin) * random.nextDouble();
      final targetLon = mapBoundsLonMin +
          (mapBoundsLonMax - mapBoundsLonMin) * random.nextDouble();
      final targetLocation = LatLng(targetLat, targetLon);

      final ped = Pedestrian(
        id: id,
        currentLocation: spawnLocation,
        targetLocation: targetLocation,
        speed: 1.3 + random.nextDouble() * 0.5, // 1.3-1.8 m/s
      );

      // Generate A* path asynchronously
      _generatePedestrianPath(ped);

      pedestrians.add(ped);
    }

    onPedestriansUpdated?.call(pedestrians);
  }

  /// Spawn ONE pedestrian guaranteed within threshold for testing
  void spawnTestPedestrian(LatLng vehicleLocation) {
    final id = 'ped_test_${DateTime.now().millisecondsSinceEpoch}';
    final random = math.Random();

    // Place pedestrian at 80% of threshold distance to ensure alert triggers
    final testDistance = (proximityThresholdMeters * 0.8) * random.nextDouble();
    final angle = random.nextDouble() * 2 * math.pi;
    
    final latOffset = (testDistance / 111000) * math.cos(angle);
    final lonOffset = (testDistance / (111000 * math.cos(vehicleLocation.latitude * math.pi / 180))) * math.sin(angle);
    
    final spawnLocation = LatLng(
      vehicleLocation.latitude + latOffset,
      vehicleLocation.longitude + lonOffset,
    );

    // Target location (random in map)
    final targetLat = mapBoundsLatMin +
        (mapBoundsLatMax - mapBoundsLatMin) * random.nextDouble();
    final targetLon = mapBoundsLonMin +
        (mapBoundsLonMax - mapBoundsLonMin) * random.nextDouble();
    final targetLocation = LatLng(targetLat, targetLon);

    final ped = Pedestrian(
      id: id,
      currentLocation: spawnLocation,
      targetLocation: targetLocation,
      speed: 1.3 + random.nextDouble() * 0.5,
    );

    _generatePedestrianPath(ped);
    pedestrians.add(ped);
    
    debugPrint('🧪 Test pedestrian spawned ~${testDistance.toStringAsFixed(0)}m away');
    onPedestriansUpdated?.call(pedestrians);
  }

  /// Dispose resources
  void dispose() {
    stopUpdateLoop();
  }
}
