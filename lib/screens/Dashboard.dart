import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../models/RSU.dart' as rsu; // API pedestrian model
import '../models/Pedestrian.dart'; // Local pedestrian model with PedestrianState
import '../models/StaticPedestrian.dart';
import '../models/RealWorldRoadNetwork.dart';
import '../services/pedestrian_manager.dart';
import '../services/static_pedestrian_manager.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? _currentLocation;
  late final MapController _mapController;
  final ApiService _apiService = ApiService();

  // Static pedestrian system (NEW - replaces dynamic pedestrian manager)
  late StaticPedestrianManager _staticPedestrianManager;
  List<PedestrianAlert> _activeAlerts = [];
  static const int _maxAlertsShown = 10;

  // Live GPS stream subscription
  StreamSubscription<Position>? _positionSub;

  // Fallback location (Ahmedabad, India)
  final LatLng _fallbackCenter = const LatLng(23.0225, 72.5714);
  
  // Map bounds for Ahmedabad area (rough approximation)
  static const double _mapLatMin = 22.95;
  static const double _mapLatMax = 23.15;
  static const double _mapLonMin = 72.45;
  static const double _mapLonMax = 72.65;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    // Create realistic Ahmedabad road network
    final roadNetwork = RealWorldRoadNetwork.createAhmedabadNetwork();

    // Initialize static pedestrian manager with real road network
    _staticPedestrianManager = StaticPedestrianManager(
      roadNetwork: roadNetwork,
      mapBoundsLatMin: _mapLatMin,
      mapBoundsLatMax: _mapLatMax,
      mapBoundsLonMin: _mapLonMin,
      mapBoundsLonMax: _mapLonMax,
      collisionThresholdMeters: 2000.0, // 2km alert threshold for real roads
    );

    // Set up callbacks
    _staticPedestrianManager.onAlertTriggered = _handlePedestrianAlert;
    _staticPedestrianManager.onPedestriansUpdated = (peds) {
      setState(() {
        // UI will update to show detected pedestrians
      });
    };

    // Ask permission + start live GPS as soon as this screen runs
    _initLocation();

    // Fetch pedestrians from backend
    _fetchPedestrians();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _staticPedestrianManager.dispose();
    super.dispose();
  }

  // Full location init: permission + initial position + live stream
  Future<void> _initLocation() async {
    final hasPermission = await _handleLocationPermission();
    if (!hasPermission) return;

    // Get initial position once (so we can center quickly)
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _currentLocation = LatLng(pos.latitude, pos.longitude);
      });

      // Spawn static pedestrians on roads + 1 test pedestrian within threshold
      _showMsg('👥 Spawning static pedestrians on road network...');
      _staticPedestrianManager.spawnStaticPedestrians(5);
      _staticPedestrianManager.spawnTestPedestrianNearby(_currentLocation!);
      _showMsg('✓ ${_staticPedestrianManager.pedestrians.length} pedestrians placed on roads');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(_currentLocation!, 17);
      });
    } catch (e) {
      debugPrint('Error getting initial position: $e');
    }

    // Start live GPS stream (real-time updates)
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0, // update on every movement (for testing)
      ),
    ).listen((Position position) {
      debugPrint(
          'New live position: ${position.latitude}, ${position.longitude}');

      final newLoc = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentLocation = newLoc;
      });

      // Detect pedestrians on roads (OSRM-based distance calculation)
      _staticPedestrianManager.detectPedestriansFromVehicle(newLoc);

      // Update vehicle location on backend API
      _apiService.updateLocation(position.latitude, position.longitude);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _mapController.move(newLoc, 17);
        } catch (e) {
          debugPrint('MapController move skipped: $e');
        }
      });
    });
  }

  // Handle location permission + service
  Future<bool> _handleLocationPermission() async {
    // 1) Check if location services are enabled
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showMsg("Please enable location services (GPS).");
      return false;
    }

    // 2) Check existing permission
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // Ask the user when app/screen runs
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showMsg("Location permission denied.");
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showMsg(
        "Location permission permanently denied. "
        "Please enable it from Settings.",
      );
      return false;
    }

    // Granted (while in use / always)
    return true;
  }

  // Fetch pedestrian data from API (legacy - now uses local road network spawning)
  Future<void> _fetchPedestrians() async {
    try {
      final List<rsu.Pedestrian> data = await _apiService.fetchPedestrians();
      debugPrint('📡 Fetched ${data.length} pedestrians from API');
      // Now using local spawning on road network, so no need to store API pedestrians
    } catch (e) {
      debugPrint('Error fetching pedestrians: $e');
      // Not critical - local pedestrians still spawn
    }
  }

  // Handle pedestrian collision alerts
  void _handlePedestrianAlert(PedestrianAlert alert) {
    setState(() {
      // Track active alerts, max 10 shown
      _activeAlerts.insert(0, alert);
      if (_activeAlerts.length > _maxAlertsShown) {
        _activeAlerts.removeLast();
      }
    });

    final distanceKm = alert.distanceMetersToCollision / 1000.0;
    final msg = alert.isNewAlert
        ? '🚨 NEW ALERT: ${alert.pedestrianId}\nDistance: ${alert.distanceMetersToCollision.toStringAsFixed(1)}m (${distanceKm.toStringAsFixed(2)}km)'
        : '📍 UPDATE: ${alert.pedestrianId}\nDistance: ${alert.distanceMetersToCollision.toStringAsFixed(1)}m';

    debugPrint(
        '🚨 COLLISION ALERT: ${alert.pedestrianId} at ${alert.distanceMetersToCollision.toStringAsFixed(1)}m (NEW: ${alert.isNewAlert})');

    // Show prominent alert
    if (alert.isNewAlert) {
      _showMsg(msg);
    }

    // Send alert to backend API
    _apiService.updatePedestrian(
      alert.pedestrianLocation.latitude,
      alert.pedestrianLocation.longitude,
      pedestrianId: alert.pedestrianId,
    );
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 5),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("V2X Pedestrian Alert System"),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _staticPedestrianManager.clearPedestrians();
              _staticPedestrianManager.spawnStaticPedestrians(5);
              setState(() {});
            },
          ),
        ],
      ),

      // Map always shows; uses fallback until GPS lock is ready
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation ?? _fallbackCenter,
              initialZoom: 17,
            ),
            children: [
              // Base map layer (OpenStreetMap)
              TileLayer(
                urlTemplate:
                    "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
                subdomains: ['a', 'b', 'c'],
              ),

              // Markers layer: car (live GPS) + pedestrians (spawned)
              MarkerLayer(
                markers: [
                  // Car marker (only when GPS exists)
                  if (_currentLocation != null)
                    Marker(
                      width: 60,
                      height: 60,
                      point: _currentLocation!,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withOpacity(0.5),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.directions_car,
                          color: Colors.white,
                          size: 35,
                        ),
                      ),
                    ),

                  // Static pedestrian markers (on real roads, snapped via OSRM)
                  ..._staticPedestrianManager.pedestrians.map(
                    (ped) {
                      final isDetected = ped.isDetected;
                      final distance = ped.lastDetectionDistance ?? double.infinity;
                      
                      return Marker(
                        width: 55,
                        height: 55,
                        point: ped.roadLocation,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Outer alert circle when detected
                            if (isDetected)
                              Container(
                                width: 55,
                                height: 55,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.red,
                                    width: 3,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.red.withOpacity(0.7),
                                      blurRadius: 15,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                              ),
                            // Main pedestrian icon
                            Container(
                              width: 45,
                              height: 45,
                              decoration: BoxDecoration(
                                color: isDetected ? Colors.red : Colors.orange,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: (isDetected ? Colors.red : Colors.orange)
                                        .withOpacity(0.6),
                                    blurRadius: isDetected ? 10 : 6,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.person,
                                color: Colors.white,
                                size: isDetected ? 26 : 24,
                              ),
                            ),
                            // Distance badge when detected
                            if (isDetected && distance != double.infinity)
                              Positioned(
                                bottom: -5,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${distance.toStringAsFixed(0)}m',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),

          // Alert panel (top-right) - Shows collision alerts
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              width: 350,
              constraints: const BoxConstraints(maxHeight: 350),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
                border: Border.all(
                  color: _activeAlerts.isNotEmpty ? Colors.red : Colors.green,
                  width: 2,
                ),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Collision Alerts (${_activeAlerts.length})',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      if (_activeAlerts.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            '🚨 DANGER',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _activeAlerts.isEmpty
                            ? [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.check_circle,
                                      color: Colors.green,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      '✓ No collision alerts',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.green,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ]
                            : _activeAlerts
                                .map(
                                  (alert) => Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.red.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Colors.red.withOpacity(0.4),
                                          width: 2,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Text(
                                                '🚨',
                                                style: TextStyle(fontSize: 14),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  alert.pedestrianId,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.red,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (alert.isNewAlert)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.red,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text(
                                                    'NEW',
                                                    style: TextStyle(
                                                      fontSize: 8,
                                                      fontWeight: FontWeight.bold,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.red,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              '📍 ${alert.distanceMetersToCollision.toStringAsFixed(1)}m to collision',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Detected: ${alert.detectionTime.hour.toString().padLeft(2, '0')}:${alert.detectionTime.minute.toString().padLeft(2, '0')}:${alert.detectionTime.second.toString().padLeft(2, '0')}',
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: Colors.red.withOpacity(0.7),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Stats panel (bottom-left)
          Positioned(
            bottom: 16,
            left: 16,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'System Status',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Pedestrians: ${_staticPedestrianManager.pedestrians.length}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Threshold: ${_staticPedestrianManager.collisionThresholdMeters.toStringAsFixed(0)}m',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_currentLocation != null) ...[
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Lat: ${_currentLocation!.latitude.toStringAsFixed(5)}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Lon: ${_currentLocation!.longitude.toStringAsFixed(5)}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Pedestrian spawning control (bottom-right)
          Positioned(
            bottom: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Spawn near location button
                FloatingActionButton.extended(
                  onPressed: () async {
                    if (_currentLocation != null) {
                      _showMsg('👥 Spawning pedestrians NEAR your location...');
                      _staticPedestrianManager.clearPedestrians();
                      _staticPedestrianManager.spawnPedestriansNearYourLocation(_currentLocation!, 3);
                      
                      // Calculate and show distances immediately
                      await Future.delayed(const Duration(milliseconds: 100));
                      await _staticPedestrianManager.detectPedestriansFromVehicle(_currentLocation!);
                      
                      setState(() {});
                      _showMsg('✓ Spawned ${_staticPedestrianManager.pedestrians.length} pedestrians near you!');
                      
                      // Show distance details
                      for (final ped in _staticPedestrianManager.pedestrians) {
                        if (ped.lastDetectionDistance != null) {
                          _showMsg('📍 ${ped.id}: ${ped.lastDetectionDistance!.toStringAsFixed(0)}m away');
                        }
                      }
                    } else {
                      _showMsg('⚠️ Waiting for GPS location...');
                    }
                  },
                  backgroundColor: Colors.green,
                  icon: const Icon(Icons.location_on),
                  label: const Text('Near Me'),
                ),
                const SizedBox(height: 12),
                // Random spawn button (original)
                FloatingActionButton.extended(
                  onPressed: () async {
                    _showMsg('👥 Spawning random pedestrians on roads...');
                    _staticPedestrianManager.clearPedestrians();
                    _staticPedestrianManager.spawnStaticPedestrians(5);
                    setState(() {});
                    _showMsg('✓ Spawned ${_staticPedestrianManager.pedestrians.length} pedestrians randomly');
                  },
                  backgroundColor: Colors.orange,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Random'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
