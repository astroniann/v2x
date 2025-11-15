import 'dart:math';

/// Simple Euclidean distance utility for grid-based pathfinding (A*).
/// Uses lat/lon degrees as-is for proximity checks.

/// Euclidean distance between two lat/lon points (in degrees)
double euclideanDistance(double lat1, double lon1, double lat2, double lon2) {
	final dLat = lat2 - lat1;
	final dLon = lon2 - lon1;
	return sqrt(dLat * dLat + dLon * dLon);
}
