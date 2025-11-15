// lib/services/static_pedestrian_manager.dart
import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import 'dart:math' as math;
import 'dart:async';
import '../models/StaticPedestrian.dart';
import '../models/RealWorldRoadNetwork.dart';
import '../utils/realistic_astar_pathfinder.dart';

class PedestrianAlert {
  final String pedestrianId;
  final LatLng pedestrianLocation;
  final double distanceMetersToCollision;
  final DateTime detectionTime;
  final bool isNewAlert;

  PedestrianAlert({
    required this.pedestrianId,
    required this.pedestrianLocation,
    required this.distanceMetersToCollision,
    required this.detectionTime,
    required this.isNewAlert,
  });
}

class StaticPedestrianManager {
  final List<StaticPedestrian> pedestrians = [];
  final RealWorldRoadNetwork roadNetwork;
  final double mapBoundsLatMin;
  final double mapBoundsLatMax;
  final double mapBoundsLonMin;
  final double mapBoundsLonMax;
  final double collisionThresholdMeters;

  Function(PedestrianAlert)? onAlertTriggered;
  Function(List<StaticPedestrian>)? onPedestriansUpdated;

  StaticPedestrianManager({
    required this.roadNetwork,
    required this.mapBoundsLatMin,
    required this.mapBoundsLatMax,
    required this.mapBoundsLonMin,
    required this.mapBoundsLonMax,
    this.collisionThresholdMeters = 2000.0,
  });

  /// Spawn random pedestrians on road network
  void spawnStaticPedestrians(int count) {
    debugPrint('👥 Spawning $count pedestrians...');
    final random = math.Random();

    final nodeIds = roadNetwork.nodes.keys.toList();
    if (nodeIds.isEmpty) {
      debugPrint('⚠️ No nodes in road network');
      return;
    }

    for (int i = 0; i < count; i++) {
      final randomNodeId = nodeIds[random.nextInt(nodeIds.length)];
      final node = roadNetwork.nodes[randomNodeId]!;

      final ped = StaticPedestrian(
        id: 'ped_${DateTime.now().millisecondsSinceEpoch}_$i',
        roadLocation: node.location,
        isDetected: false,
      );

      pedestrians.add(ped);
      debugPrint('✅ Spawned ${ped.id} at ${node.name}');
    }

    onPedestriansUpdated?.call(pedestrians);
    debugPrint('✓ Total pedestrians: ${pedestrians.length}');
  }

  /// MAIN DETECTION: Calculate REAL road distance using A*
  Future<void> detectPedestriansFromVehicle(LatLng vehicleLocation) async {
    if (pedestrians.isEmpty) {
      debugPrint('⚠️ No pedestrians to detect');
      return;
    }

    try {
      // Find vehicle's nearest road node
      final vehicleNodeId = RealisticAStarPathfinder.findNearestNode(
        roadNetwork,
        vehicleLocation,
      );
      
      final vehicleNode = roadNetwork.nodes[vehicleNodeId];
      debugPrint('🚗 Vehicle at: ${vehicleNode?.name ?? vehicleNodeId}');

      for (final ped in pedestrians) {
        try {
          // Find pedestrian's nearest road node
          final pedNodeId = RealisticAStarPathfinder.findNearestNode(
            roadNetwork,
            ped.roadLocation,
          );

          // Calculate REAL driving distance using A*
          final pathResult = RealisticAStarPathfinder.findOptimalRoute(
            roadNetwork,
            vehicleNodeId,
            pedNodeId,
          );

          if (pathResult.found) {
            // Store REAL distance
            ped.lastDetectionDistance = pathResult.totalDistanceMeters;

            final distKm = pathResult.totalDistanceMeters / 1000.0;
            debugPrint(
              '📍 ${ped.id}: ${pathResult.totalDistanceMeters.toStringAsFixed(0)}m (${distKm.toStringAsFixed(2)}km) via ${pathResult.nodeSequence.length} nodes'
            );

            // Check if within collision threshold
            if (pathResult.totalDistanceMeters <= collisionThresholdMeters) {
              final isNewAlert = !ped.isDetected;
              ped.isDetected = true;

              final alert = PedestrianAlert(
                pedestrianId: ped.id,
                pedestrianLocation: ped.roadLocation,
                distanceMetersToCollision: pathResult.totalDistanceMeters,
                detectionTime: DateTime.now(),
                isNewAlert: isNewAlert,
              );

              debugPrint('🚨 ALERT: ${ped.id} at ${pathResult.totalDistanceMeters.toStringAsFixed(0)}m');
              onAlertTriggered?.call(alert);
            } else if (ped.isDetected) {
              // Clear alert if pedestrian moves out of range
              ped.isDetected = false;
              debugPrint('✓ ${ped.id} out of range');
            }
          } else {
            debugPrint('⚠️ ${ped.id}: No route found');
            ped.lastDetectionDistance = null;
            if (ped.isDetected) {
              ped.isDetected = false;
            }
          }
        } catch (e) {
          debugPrint('❌ Error with ${ped.id}: $e');
        }
      }

      onPedestriansUpdated?.call(pedestrians);
    } catch (e) {
      debugPrint('❌ Detection error: $e');
    }
  }

  /// Get detected pedestrians
  List<StaticPedestrian> getDetectedPedestrians() {
    return pedestrians.where((ped) => ped.isDetected).toList();
  }

  /// Clear all pedestrians
  void clearPedestrians() {
    pedestrians.clear();
    onPedestriansUpdated?.call(pedestrians);
    debugPrint('🗑️ Cleared all pedestrians');
  }

  void dispose() {
    // Nothing to dispose
  }
}