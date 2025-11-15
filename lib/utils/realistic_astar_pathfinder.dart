import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import 'dart:math' as math;
import '../models/RealWorldRoadNetwork.dart';

/// Path result with detailed driving information
class PathResult {
  final List<String> nodeSequence; // Order of nodes to visit
  final List<String> segmentSequence; // Road segments to travel
  final double totalDistanceMeters;
  final double estimatedTravelTimeSeconds;
  final List<RoadSegment> roadSegments; // Detailed segment info for navigation
  final bool found;

  PathResult({
    required this.nodeSequence,
    required this.segmentSequence,
    required this.totalDistanceMeters,
    required this.estimatedTravelTimeSeconds,
    required this.roadSegments,
    required this.found,
  });

  /// Get estimated travel time in readable format
  String getTimeEstimate() {
    final minutes = (estimatedTravelTimeSeconds / 60).toInt();
    final seconds = (estimatedTravelTimeSeconds % 60).toInt();
    if (minutes > 0) {
      return '$minutes min $seconds sec';
    }
    return '$seconds sec';
  }

  @override
  String toString() =>
      'Path(distance: ${totalDistanceMeters.toStringAsFixed(0)}m, time: ${getTimeEstimate()}, nodes: ${nodeSequence.length}, found: $found)';
}

/// Real A* pathfinder for traffic-aware routing
class RealisticAStarPathfinder {
  static const String tag = '🗺️ A*';

  /// Find shortest path considering distance, traffic, and time
  static PathResult findOptimalRoute(
    RealWorldRoadNetwork network,
    String startNodeId,
    String goalNodeId,
  ) {
    debugPrint('$tag Finding route from $startNodeId to $goalNodeId...');

    if (!network.nodes.containsKey(startNodeId) ||
        !network.nodes.containsKey(goalNodeId)) {
      debugPrint('$tag Invalid nodes');
      return PathResult(
        nodeSequence: [],
        segmentSequence: [],
        totalDistanceMeters: 0,
        estimatedTravelTimeSeconds: 0,
        roadSegments: [],
        found: false,
      );
    }

    final startNode = network.nodes[startNodeId]!;
    final goalNode = network.nodes[goalNodeId]!;

    // A* data structures
    final openSet = <String>{startNodeId};
    final cameFrom = <String, String>{};
    final gScore = <String, double>{};
    final fScore = <String, double>{};

    // Initialize scores
    for (final nodeId in network.nodes.keys) {
      gScore[nodeId] = double.infinity;
      fScore[nodeId] = double.infinity;
    }

    gScore[startNodeId] = 0;
    fScore[startNodeId] = _heuristic(startNode, goalNode);

    int iterations = 0;
    const maxIterations = 1000;

    while (openSet.isNotEmpty && iterations < maxIterations) {
      iterations++;

      // Find node in openSet with lowest fScore
      String current = startNodeId;
      double lowestF = double.infinity;

      for (final nodeId in openSet) {
        if ((fScore[nodeId] ?? double.infinity) < lowestF) {
          lowestF = fScore[nodeId] ?? double.infinity;
          current = nodeId;
        }
      }

      if (current == goalNodeId) {
        // Path found - reconstruct it
        debugPrint('$tag Path found after $iterations iterations');
        return _reconstructPath(network, cameFrom, current, goalNode);
      }

      openSet.remove(current);
      final currentNode = network.nodes[current]!;
      final neighbors = network.getOutgoingSegments(current);

      for (final segment in neighbors) {
        final neighbor = segment.toNodeId;
        final neighborNode = network.nodes[neighbor]!;

        // Calculate tentative gScore
        final segmentCost = segment.getCost();
        final tentativeGScore = (gScore[current] ?? double.infinity) + segmentCost;

        if (tentativeGScore < (gScore[neighbor] ?? double.infinity)) {
          cameFrom[neighbor] = current;
          gScore[neighbor] = tentativeGScore;
          fScore[neighbor] = tentativeGScore + _heuristic(neighborNode, goalNode);

          if (!openSet.contains(neighbor)) {
            openSet.add(neighbor);
          }
        }
      }
    }

    debugPrint('$tag No path found after $iterations iterations');
    return PathResult(
      nodeSequence: [],
      segmentSequence: [],
      totalDistanceMeters: 0,
      estimatedTravelTimeSeconds: 0,
      roadSegments: [],
      found: false,
    );
  }

  /// Heuristic: Haversine distance to goal (admissible for A*)
  static double _heuristic(RoadNode from, RoadNode to) {
    const earthRadiusMeters = 6371000.0;
    final dLat = (to.location.latitude - from.location.latitude) * math.pi / 180.0;
    final dLon = (to.location.longitude - from.location.longitude) * math.pi / 180.0;
    final lat1Rad = from.location.latitude * math.pi / 180.0;
    final lat2Rad = to.location.latitude * math.pi / 180.0;

    final sinHalfDLat = math.sin(dLat / 2.0);
    final sinHalfDLon = math.sin(dLon / 2.0);

    final a = sinHalfDLat * sinHalfDLat +
        math.cos(lat1Rad) * math.cos(lat2Rad) * sinHalfDLon * sinHalfDLon;
    final c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Reconstruct path from cameFrom map
  static PathResult _reconstructPath(
    RealWorldRoadNetwork network,
    Map<String, String> cameFrom,
    String current,
    RoadNode goalNode,
  ) {
    final path = <String>[current];
    final segments = <RoadSegment>[];
    double totalDistance = 0;
    double totalTime = 0;

    while (cameFrom.containsKey(current)) {
      final previous = cameFrom[current]!;

      // Find the segment connecting previous to current
      final outgoing = network.getOutgoingSegments(previous);
      final connectingSegment = outgoing.firstWhere(
        (seg) => seg.toNodeId == current,
        orElse: () => throw Exception('Segment not found'),
      );

      segments.insert(0, connectingSegment);
      totalDistance += connectingSegment.distanceMeters;
      totalTime += connectingSegment.getTravelTimeSeconds();

      path.insert(0, previous);
      current = previous;
    }

    final segmentIds = segments.map((s) => s.id).toList();

    return PathResult(
      nodeSequence: path,
      segmentSequence: segmentIds,
      totalDistanceMeters: totalDistance,
      estimatedTravelTimeSeconds: totalTime,
      roadSegments: segments,
      found: true,
    );
  }

  /// Calculate distance from current location to target on the road network
  static double calculateRoadDistance(
    RealWorldRoadNetwork network,
    LatLng currentLocation,
    LatLng targetLocation,
    String nearestStartNodeId,
    String nearestTargetNodeId,
  ) {
    final path = findOptimalRoute(
      network,
      nearestStartNodeId,
      nearestTargetNodeId,
    );

    if (!path.found) {
      return double.infinity;
    }

    // Add straight-line distance from current location to start node
    final startNode = network.nodes[nearestStartNodeId]!;
    final distToStart = _haversineDistance(currentLocation, startNode.location);

    // Add straight-line distance from target node to target location
    final targetNode = network.nodes[nearestTargetNodeId]!;
    final distFromEnd = _haversineDistance(targetNode.location, targetLocation);

    return distToStart + path.totalDistanceMeters + distFromEnd;
  }

  /// Haversine distance
  static double _haversineDistance(LatLng p1, LatLng p2) {
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

  /// Find nearest node to a GPS coordinate
  static String findNearestNode(RealWorldRoadNetwork network, LatLng location) {
    String nearest = network.nodes.keys.first;
    double minDist = double.infinity;

    for (final nodeId in network.nodes.keys) {
      final node = network.nodes[nodeId]!;
      final dist = _haversineDistance(location, node.location);
      if (dist < minDist) {
        minDist = dist;
        nearest = nodeId;
      }
    }

    debugPrint('$tag Nearest node to (${location.latitude}, ${location.longitude}): $nearest (${minDist.toStringAsFixed(0)}m away)');
    return nearest;
  }
}
