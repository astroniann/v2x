import 'package:latlong2/latlong.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Represents traffic conditions on a road
enum TrafficCondition { free, light, moderate, heavy, blocked }

/// Represents a road segment (edge) in the network
class RoadSegment {
  final String id;
  final String fromNodeId;
  final String toNodeId;
  final double distanceMeters;
  final String roadName;
  final int speedLimitKmh; // Posted speed limit
  final bool isBidirectional;
  final bool isOneWay;
  TrafficCondition trafficCondition;
  int vehicleCountOnSegment;

  RoadSegment({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
    required this.distanceMeters,
    required this.roadName,
    required this.speedLimitKmh,
    this.isBidirectional = true,
    this.isOneWay = false,
    this.trafficCondition = TrafficCondition.free,
    this.vehicleCountOnSegment = 0,
  });

  /// Get actual travel speed based on traffic
  double getActualSpeedKmh() {
    double speedFactor = 1.0;
    switch (trafficCondition) {
      case TrafficCondition.free:
        speedFactor = 1.0;
        break;
      case TrafficCondition.light:
        speedFactor = 0.8;
        break;
      case TrafficCondition.moderate:
        speedFactor = 0.6;
        break;
      case TrafficCondition.heavy:
        speedFactor = 0.3;
        break;
      case TrafficCondition.blocked:
        speedFactor = 0.05; // Nearly stopped
        break;
    }
    return speedLimitKmh * speedFactor;
  }

  /// Calculate travel time in seconds
  double getTravelTimeSeconds() {
    final speedMs = getActualSpeedKmh() * 1000 / 3600; // Convert km/h to m/s
    if (speedMs <= 0) return double.infinity;
    return distanceMeters / speedMs;
  }

  /// Get cost for A* (considering distance and time)
  double getCost() {
    final timeSeconds = getTravelTimeSeconds();
    return timeSeconds + (distanceMeters / 100); // Weight distance slightly
  }

  @override
  String toString() =>
      '$roadName ($fromNodeId→$toNodeId): ${distanceMeters.toStringAsFixed(0)}m, ${speedLimitKmh}km/h, Traffic: $trafficCondition';
}

/// Represents an intersection node in the road network
class RoadNode {
  final String id;
  final String name;
  final LatLng location;
  final List<String> connectedEdgeIds;
  final bool isIntersection; // True if major intersection
  final bool isTrafficSignal; // Has traffic light?
  int pedestrianCountHere;

  RoadNode({
    required this.id,
    required this.name,
    required this.location,
    this.connectedEdgeIds = const [],
    this.isIntersection = false,
    this.isTrafficSignal = false,
    this.pedestrianCountHere = 0,
  });

  @override
  String toString() => '$name ($id) at ${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}';
}

/// Real-world road network for Ahmedabad
class RealWorldRoadNetwork {
  final Map<String, RoadNode> nodes = {};
  final Map<String, RoadSegment> segments = {};
  final Map<String, List<String>> adjacencyList = {};

  late DateTime _lastTrafficUpdate;

  RealWorldRoadNetwork() {
    _lastTrafficUpdate = DateTime.now();
  }

  /// Add a node to the network
  void addNode(RoadNode node) {
    nodes[node.id] = node;
    adjacencyList[node.id] = [];
    debugPrint('✓ Added node: ${node.name}');
  }

  /// Add a bidirectional or one-way segment
  void addSegment(RoadSegment segment) {
    segments[segment.id] = segment;

    // Add to adjacency list
    if (!adjacencyList[segment.fromNodeId]!.contains(segment.id)) {
      adjacencyList[segment.fromNodeId]!.add(segment.id);
    }

    if (segment.isBidirectional && !segment.isOneWay) {
      // Add reverse edge if bidirectional
      final reverseId = '${segment.id}_rev';
      if (!segments.containsKey(reverseId)) {
        final reverseSegment = RoadSegment(
          id: reverseId,
          fromNodeId: segment.toNodeId,
          toNodeId: segment.fromNodeId,
          distanceMeters: segment.distanceMeters,
          roadName: segment.roadName,
          speedLimitKmh: segment.speedLimitKmh,
          isBidirectional: false,
          isOneWay: false,
          trafficCondition: segment.trafficCondition,
        );
        segments[reverseId] = reverseSegment;
        adjacencyList[segment.toNodeId]!.add(reverseId);
      }
    }

    debugPrint('✓ Added segment: ${segment.roadName}');
  }

  /// Get outgoing segments from a node
  List<RoadSegment> getOutgoingSegments(String nodeId) {
    final edgeIds = adjacencyList[nodeId] ?? [];
    return edgeIds
        .map((edgeId) => segments[edgeId])
        .whereType<RoadSegment>()
        .toList();
  }

  /// Update traffic conditions based on time of day
  void updateTrafficByTime(DateTime time) {
    _lastTrafficUpdate = time;
    final hour = time.hour;

    // Rush hour logic (realistic for Ahmedabad)
    final isMorningRush = hour >= 7 && hour <= 10;
    final isEveningRush = hour >= 17 && hour <= 20;

    for (final segment in segments.values) {
      final baseName = segment.roadName.toLowerCase();

      // Major roads congestion
      final isMajorRoad = baseName.contains('sg highway') ||
          baseName.contains('satellite road') ||
          baseName.contains('ring road');

      if (isMorningRush) {
        if (isMajorRoad) {
          segment.trafficCondition = TrafficCondition.heavy;
          segment.vehicleCountOnSegment = 200;
        } else {
          segment.trafficCondition = TrafficCondition.moderate;
          segment.vehicleCountOnSegment = 50;
        }
      } else if (isEveningRush) {
        if (isMajorRoad) {
          segment.trafficCondition = TrafficCondition.heavy;
          segment.vehicleCountOnSegment = 250;
        } else {
          segment.trafficCondition = TrafficCondition.light;
          segment.vehicleCountOnSegment = 30;
        }
      } else {
        // Off-peak
        segment.trafficCondition = TrafficCondition.free;
        segment.vehicleCountOnSegment = 10;
      }
    }

    debugPrint('🚦 Traffic updated for ${time.hour}:${time.minute}');
  }

  /// Create realistic Ahmedabad road network
  static RealWorldRoadNetwork createAhmedabadNetwork() {
    final network = RealWorldRoadNetwork();

    // Major intersections in Ahmedabad
    final nodeData = [
      // SG Highway corridor
      ('n1', 'Urvashi Complex', 23.0225, 72.5714, true, true),
      ('n2', 'Mithakhali Six Roads', 23.0291, 72.5761, true, true),
      ('n3', 'Gujarat Vidhyapith', 23.0356, 72.5808, false, false),
      ('n4', 'Thaltej', 23.0421, 72.5855, true, true),

      // Satellite Road corridor
      ('n5', 'CIMS Hospital', 23.0500, 72.5500, false, false),
      ('n6', 'Satellite Complex', 23.0550, 72.5450, true, true),
      ('n7', 'Vastrapur', 23.0600, 72.5400, false, false),

      // Ring Road
      ('n8', 'Ring Road East', 23.0375, 72.6000, true, false),
      ('n9', 'Ring Road North', 23.0625, 72.5750, true, false),
      ('n10', 'Ring Road West', 23.0500, 72.5500, true, false),

      // Central nodes
      ('n11', 'Paldi Chowk', 23.0450, 72.5600, true, true),
      ('n12', 'Law Garden', 23.0375, 72.5650, false, false),
      ('n13', 'Relief Road', 23.0300, 72.5550, true, true),

      // Eastern expansion
      ('n14', 'Iscon Ambiance', 23.0480, 72.6100, true, true),
      ('n15', 'Mahadev Chowk', 23.0530, 72.6200, false, false),

      // Western nodes
      ('n16', 'Ellis Bridge', 23.0200, 72.5400, true, true),
      ('n17', 'Vastrapur Lake', 23.0150, 72.5350, false, false),
    ];

    for (final (id, name, lat, lon, isIntersection, hasSignal) in nodeData) {
      network.addNode(RoadNode(
        id: id,
        name: name,
        location: LatLng(lat, lon),
        isIntersection: isIntersection,
        isTrafficSignal: hasSignal,
      ));
    }

    // SG Highway - Main corridor (high traffic)
    network.addSegment(RoadSegment(
      id: 'sg1',
      fromNodeId: 'n1',
      toNodeId: 'n2',
      distanceMeters: 880,
      roadName: 'SG Highway - Urvashi to Mithakhali',
      speedLimitKmh: 60,
      isBidirectional: true,
      trafficCondition: TrafficCondition.moderate,
    ));

    network.addSegment(RoadSegment(
      id: 'sg2',
      fromNodeId: 'n2',
      toNodeId: 'n3',
      distanceMeters: 720,
      roadName: 'SG Highway - Mithakhali to Vidhyapith',
      speedLimitKmh: 60,
      isBidirectional: true,
      trafficCondition: TrafficCondition.light,
    ));

    network.addSegment(RoadSegment(
      id: 'sg3',
      fromNodeId: 'n3',
      toNodeId: 'n4',
      distanceMeters: 700,
      roadName: 'SG Highway - Vidhyapith to Thaltej',
      speedLimitKmh: 70,
      isBidirectional: true,
      trafficCondition: TrafficCondition.free,
    ));

    // Satellite Road - Secondary corridor
    network.addSegment(RoadSegment(
      id: 'sat1',
      fromNodeId: 'n5',
      toNodeId: 'n6',
      distanceMeters: 650,
      roadName: 'Satellite Road - CIMS to Complex',
      speedLimitKmh: 50,
      isBidirectional: true,
      trafficCondition: TrafficCondition.light,
    ));

    network.addSegment(RoadSegment(
      id: 'sat2',
      fromNodeId: 'n6',
      toNodeId: 'n7',
      distanceMeters: 700,
      roadName: 'Satellite Road - Complex to Vastrapur',
      speedLimitKmh: 50,
      isBidirectional: true,
      trafficCondition: TrafficCondition.moderate,
    ));

    // Ring Road
    network.addSegment(RoadSegment(
      id: 'ring1',
      fromNodeId: 'n8',
      toNodeId: 'n9',
      distanceMeters: 3500,
      roadName: 'Ring Road - East to North',
      speedLimitKmh: 80,
      isBidirectional: true,
      trafficCondition: TrafficCondition.light,
    ));

    network.addSegment(RoadSegment(
      id: 'ring2',
      fromNodeId: 'n9',
      toNodeId: 'n10',
      distanceMeters: 3000,
      roadName: 'Ring Road - North to West',
      speedLimitKmh: 80,
      isBidirectional: true,
      trafficCondition: TrafficCondition.free,
    ));

    // Central connecting roads
    network.addSegment(RoadSegment(
      id: 'central1',
      fromNodeId: 'n11',
      toNodeId: 'n12',
      distanceMeters: 450,
      roadName: 'Paldi to Law Garden',
      speedLimitKmh: 40,
      isBidirectional: true,
      trafficCondition: TrafficCondition.moderate,
    ));

    network.addSegment(RoadSegment(
      id: 'central2',
      fromNodeId: 'n12',
      toNodeId: 'n13',
      distanceMeters: 500,
      roadName: 'Relief Road - Law Garden to Central',
      speedLimitKmh: 40,
      isBidirectional: true,
      trafficCondition: TrafficCondition.moderate,
    ));

    // Eastern expansion roads
    network.addSegment(RoadSegment(
      id: 'east1',
      fromNodeId: 'n4',
      toNodeId: 'n14',
      distanceMeters: 2200,
      roadName: 'Thaltej to Iscon Ambiance',
      speedLimitKmh: 60,
      isBidirectional: true,
      trafficCondition: TrafficCondition.light,
    ));

    network.addSegment(RoadSegment(
      id: 'east2',
      fromNodeId: 'n14',
      toNodeId: 'n15',
      distanceMeters: 1500,
      roadName: 'Iscon to Mahadev Chowk',
      speedLimitKmh: 50,
      isBidirectional: true,
      trafficCondition: TrafficCondition.moderate,
    ));

    // Western roads
    network.addSegment(RoadSegment(
      id: 'west1',
      fromNodeId: 'n1',
      toNodeId: 'n16',
      distanceMeters: 1800,
      roadName: 'Urvashi to Ellis Bridge',
      speedLimitKmh: 50,
      isBidirectional: true,
      trafficCondition: TrafficCondition.heavy,
    ));

    network.addSegment(RoadSegment(
      id: 'west2',
      fromNodeId: 'n16',
      toNodeId: 'n17',
      distanceMeters: 900,
      roadName: 'Ellis Bridge to Vastrapur Lake',
      speedLimitKmh: 40,
      isBidirectional: true,
      trafficCondition: TrafficCondition.light,
    ));

    // Cross connections
    network.addSegment(RoadSegment(
      id: 'cross1',
      fromNodeId: 'n2',
      toNodeId: 'n11',
      distanceMeters: 1100,
      roadName: 'Mithakhali to Paldi',
      speedLimitKmh: 45,
      isBidirectional: true,
      trafficCondition: TrafficCondition.moderate,
    ));

    network.addSegment(RoadSegment(
      id: 'cross2',
      fromNodeId: 'n11',
      toNodeId: 'n8',
      distanceMeters: 1300,
      roadName: 'Paldi to Ring Road East',
      speedLimitKmh: 50,
      isBidirectional: true,
      trafficCondition: TrafficCondition.light,
    ));

    // Initial traffic update
    network.updateTrafficByTime(DateTime.now());

    debugPrint('✓ Ahmedabad road network created: ${network.nodes.length} nodes, ${network.segments.length} segments');
    return network;
  }
}
