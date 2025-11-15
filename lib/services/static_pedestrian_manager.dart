import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import 'dart:math' as math;
import '../models/StaticPedestrian.dart';
import '../models/RealWorldRoadNetwork.dart';
import '../utils/realistic_astar_pathfinder.dart';
import 'dart:async';

/// Alert triggered when pedestrian detected within threshold
class PedestrianAlert {
  final String pedestrianId;
  final LatLng pedestrianLocation;
  final double distanceMetersToCollision; // Distance via roads
  final DateTime detectionTime;
  final bool isNewAlert; // True if first detection this session

  PedestrianAlert({
    required this.pedestrianId,
    required this.pedestrianLocation,
    required this.distanceMetersToCollision,
    required this.detectionTime,
    required this.isNewAlert,
  });

  @override
  String toString() =>
      'Alert: $pedestrianId at ${distanceMetersToCollision.toStringAsFixed(1)}m';
}

/// Manages static pedestrians positioned on roads
/// Handles detection, distance calculation, and alert generation
class StaticPedestrianManager {
  final List<StaticPedestrian> pedestrians = [];
  final RealWorldRoadNetwork roadNetwork;
  final double mapBoundsLatMin;
  final double mapBoundsLatMax;
  final double mapBoundsLonMin;
  final double mapBoundsLonMax;
  final double collisionThresholdMeters; // Alert threshold

  // Callbacks
  Function(PedestrianAlert)? onAlertTriggered;
  Function(List<StaticPedestrian>)? onPedestriansUpdated;

  Timer? _detectionTimer;
  static const int detectionIntervalMs = 500; // Check every 500ms

  StaticPedestrianManager({
    required this.roadNetwork,
    required this.mapBoundsLatMin,
    required this.mapBoundsLatMax,
    required this.mapBoundsLonMin,
    required this.mapBoundsLonMax,
    this.collisionThresholdMeters = 2000.0, // 2km default for real roads
  });

  /// Spawn static pedestrians at random locations on the road network
  void spawnStaticPedestrians(int count) {
    debugPrint('👥 Spawning $count static pedestrians on road network...');
    final random = math.Random();

    // Pick random nodes from the road network
    final nodeIds = roadNetwork.nodes.keys.toList();
    if (nodeIds.isEmpty) {
      debugPrint('⚠️ No nodes in road network');
      return;
    }

    for (int i = 0; i < count && i < nodeIds.length; i++) {
      final randomNodeId = nodeIds[random.nextInt(nodeIds.length)];
      final node = roadNetwork.nodes[randomNodeId]!;

      final ped = StaticPedestrian(
        id: 'ped_static_${DateTime.now().millisecondsSinceEpoch}_$i',
        roadLocation: node.location,
        isDetected: false,
      );

      pedestrians.add(ped);
      debugPrint('🚨 $i: ${ped.id} spawned at ${node.name} (${node.location.latitude.toStringAsFixed(5)}, ${node.location.longitude.toStringAsFixed(5)})');
    }

    onPedestriansUpdated?.call(pedestrians);
    debugPrint('✓ Spawned ${pedestrians.length} static pedestrians on road network');
  }

  /// Spawn one guaranteed test pedestrian within threshold (for testing alerts)
  void spawnTestPedestrianNearby(LatLng vehicleLocation) {
    debugPrint('🧪 Spawning test pedestrian on road network...');

    final random = math.Random();
    final nodeIds = roadNetwork.nodes.keys.toList();

    if (nodeIds.isEmpty) {
      debugPrint('⚠️ No nodes in road network');
      return;
    }

    // Pick a random node from the network
    final selectedNode = nodeIds[random.nextInt(nodeIds.length)];
    final testNode = roadNetwork.nodes[selectedNode]!;

    final testPed = StaticPedestrian(
      id: 'ped_test_${DateTime.now().millisecondsSinceEpoch}',
      roadLocation: testNode.location,
      isDetected: false,
    );

    pedestrians.add(testPed);
    debugPrint(
        '✓ Test pedestrian spawned at ${testNode.name}');
    onPedestriansUpdated?.call(pedestrians);
  }

  /// Spawn pedestrians near your current location (within nearby nodes)
  void spawnPedestriansNearYourLocation(LatLng currentLocation, int count) {
    debugPrint('👥 Spawning $count pedestrians near your location (${currentLocation.latitude.toStringAsFixed(5)}, ${currentLocation.longitude.toStringAsFixed(5)})...');
    
    final random = math.Random();
    
    // Find the nearest node to your current location
    final nearestNodeId = RealisticAStarPathfinder.findNearestNode(roadNetwork, currentLocation);
    final nearestNode = roadNetwork.nodes[nearestNodeId];
    
    if (nearestNode == null) {
      debugPrint('⚠️ Could not find nearest node to your location');
      return;
    }
    
    debugPrint('📍 Your nearest node: $nearestNodeId = ${nearestNode.name} (lat: ${nearestNode.location.latitude.toStringAsFixed(5)}, lon: ${nearestNode.location.longitude.toStringAsFixed(5)})');
    
    // Get all outgoing segments from the nearest node
    final outgoingSegments = roadNetwork.getOutgoingSegments(nearestNodeId);
    
    if (outgoingSegments.isEmpty) {
      debugPrint('⚠️ No connected roads from your nearest node');
      return;
    }
    
    debugPrint('🛣️ Found ${outgoingSegments.length} connected roads from your node');
    
    // Spawn pedestrians at the end nodes of nearby roads
    for (int i = 0; i < count; i++) {
      try {
        // Pick a random connected road
        final randomSegment = outgoingSegments[random.nextInt(outgoingSegments.length)];
        final targetNodeId = randomSegment.toNodeId;
        final targetNode = roadNetwork.nodes[targetNodeId];
        
        if (targetNode != null) {
          final ped = StaticPedestrian(
            id: 'ped_nearby_${DateTime.now().millisecondsSinceEpoch}_$i',
            roadLocation: targetNode.location,
            isDetected: false,
          );
          
          pedestrians.add(ped);
          debugPrint(
            '🚨 [$i] ${ped.id}:');
          debugPrint(
            '    Location: ${targetNode.name} (${targetNode.location.latitude.toStringAsFixed(5)}, ${targetNode.location.longitude.toStringAsFixed(5)})');
          debugPrint(
            '    Expected distance via ${randomSegment.roadName}: ${randomSegment.distanceMeters.toStringAsFixed(0)}m');
          debugPrint(
            '    Segment: ${randomSegment.fromNodeId} -> ${randomSegment.toNodeId} (${randomSegment.speedLimitKmh} km/h, Traffic: ${randomSegment.trafficCondition})');
        }
      } catch (e) {
        debugPrint('⚠️ Error spawning pedestrian $i: $e');
      }
    }
    
    onPedestriansUpdated?.call(pedestrians);
    debugPrint('✓ Spawned ${pedestrians.length} pedestrians near your location');
  }

  /// Start detection loop - continuously checks vehicle location against pedestrians
  void startDetectionLoop() {
    _detectionTimer?.cancel();
    debugPrint('🔍 Starting pedestrian detection loop...');

    _detectionTimer =
        Timer.periodic(Duration(milliseconds: detectionIntervalMs), (_) {
      // Detection happens via detectPedestriansFromVehicle() call
    });
  }

  /// Stop detection loop
  void stopDetectionLoop() {
    _detectionTimer?.cancel();
    _detectionTimer = null;
    debugPrint('🛑 Detection loop stopped');
  }

  /// Main detection: called when vehicle location updates
  /// Uses A* to calculate actual driving distance to pedestrians
  Future<void> detectPedestriansFromVehicle(LatLng vehicleLocation) async {
    try {
      // Find vehicle's nearest node on road network
      final vehicleNodeId = RealisticAStarPathfinder.findNearestNode(roadNetwork, vehicleLocation);
      debugPrint('🔍 Vehicle at node: $vehicleNodeId, searching pedestrians...');

      for (final ped in pedestrians) {
        try {
          // Find pedestrian's nearest node on road network
          final pedNodeId = RealisticAStarPathfinder.findNearestNode(roadNetwork, ped.roadLocation);

          debugPrint(
              '🔍 Checking ${ped.id}: vehicle at $vehicleNodeId, ped at $pedNodeId');

          // Calculate actual driving route using A*
          final pathResult = RealisticAStarPathfinder.findOptimalRoute(
            roadNetwork,
            vehicleNodeId,
            pedNodeId,
          );

          if (pathResult.found) {
            ped.lastDetectionDistance = pathResult.totalDistanceMeters;

            debugPrint(
                '📍 ${ped.id}: ${pathResult.totalDistanceMeters.toStringAsFixed(0)}m via ${pathResult.nodeSequence.length} nodes (path: ${pathResult.nodeSequence.join(' -> ')}), ETA: ${pathResult.getTimeEstimate()}');

            // Check if within collision threshold
            if (pathResult.totalDistanceMeters <= collisionThresholdMeters) {
              final isNewAlert = !ped.isDetected;
              ped.isDetected = true;

              // Generate alert with routing information
              final alert = PedestrianAlert(
                pedestrianId: ped.id,
                pedestrianLocation: ped.roadLocation,
                distanceMetersToCollision: pathResult.totalDistanceMeters,
                detectionTime: DateTime.now(),
                isNewAlert: isNewAlert,
              );

              debugPrint(
                  '🚨 COLLISION ALERT: ${alert.pedestrianId} at ${pathResult.totalDistanceMeters.toStringAsFixed(0)}m (${pathResult.getTimeEstimate()}) - NEW: $isNewAlert');
              onAlertTriggered?.call(alert);
            } else if (ped.isDetected && pathResult.totalDistanceMeters > collisionThresholdMeters) {
              // Pedestrian moved out of range
              ped.isDetected = false;
              debugPrint(
                  '✓ ${ped.id} out of detection range (${pathResult.totalDistanceMeters.toStringAsFixed(0)}m > ${collisionThresholdMeters.toStringAsFixed(0)}m)');
            }
          } else {
            debugPrint(
                '⚠️ ${ped.id}: No driving route available (from $vehicleNodeId to $pedNodeId)');
            if (ped.isDetected) {
              ped.isDetected = false;
            }
          }
        } catch (e) {
          debugPrint(
              '❌ Error detecting ${ped.id}: $e');
        }
      }

      // Update UI
      onPedestriansUpdated?.call(pedestrians);
    } catch (e) {
      debugPrint('❌ Detection error: $e');
    }
  }

  /// Get all currently detected pedestrians (within threshold)
  List<StaticPedestrian> getDetectedPedestrians() {
    return pedestrians.where((ped) => ped.isDetected).toList();
  }

  /// Clear all pedestrians
  void clearPedestrians() {
    pedestrians.clear();
    onPedestriansUpdated?.call(pedestrians);
    debugPrint('🗑️ Cleared all pedestrians');
  }

  /// Dispose resources
  void dispose() {
    stopDetectionLoop();
  }
}
