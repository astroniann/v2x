import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Snaps arbitrary coordinates to the nearest road using OSRM Snap Service
class RoadService {
  static const String osrmSnapEndpoint =
      "https://router.project-osrm.org/nearest/v1/driving";

  /// Snap a coordinate to the nearest road
  /// Returns the snapped coordinate on an actual road
  static Future<LatLng?> snapToRoad(LatLng coordinate) async {
    try {
      final url = Uri.parse(
        '$osrmSnapEndpoint/${coordinate.longitude},${coordinate.latitude}',
      );

      debugPrint(
          '🛣️ Snapping coordinate (${coordinate.latitude.toStringAsFixed(5)}, ${coordinate.longitude.toStringAsFixed(5)}) to road');

      final response = await http.get(url).timeout(
        const Duration(seconds: 8),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok' && data['waypoints'].isNotEmpty) {
          final waypoint = data['waypoints'][0];
          final location = waypoint['location'];

          // location is [lon, lat]
          final snappedLoc = LatLng(
            (location[1] as num).toDouble(),
            (location[0] as num).toDouble(),
          );

          final distance =
              (waypoint['distance'] as num?)?.toDouble() ?? 0.0;

          debugPrint(
              '✓ Snapped to road: (${snappedLoc.latitude.toStringAsFixed(5)}, ${snappedLoc.longitude.toStringAsFixed(5)}) - ${distance.toStringAsFixed(1)}m from original');

          return snappedLoc;
        } else {
          debugPrint(
              '⚠️ OSRM snap failed - code: ${data['code']}, message: ${data['message']}');
          return null;
        }
      } else {
        debugPrint(
            '⚠️ OSRM snap HTTP error: ${response.statusCode} - ${response.reasonPhrase}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Road snapping error: $e');
      return null;
    }
  }

  /// Snap multiple coordinates to roads
  static Future<List<LatLng>> snapToRoadBatch(List<LatLng> coordinates) async {
    final snappedList = <LatLng>[];

    for (final coord in coordinates) {
      final snapped = await snapToRoad(coord);
      if (snapped != null) {
        snappedList.add(snapped);
      } else {
        // Fallback to original if snapping fails
        snappedList.add(coord);
      }
      // Add small delay to avoid rate limiting
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return snappedList;
  }
}
