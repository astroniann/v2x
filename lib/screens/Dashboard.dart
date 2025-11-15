import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../models/RSU.dart' as rsu;
import '../models/StaticPedestrian.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? _currentLocation;
  late final MapController _mapController;
  final ApiService _apiService = ApiService();

  // Pedestrians list
  final List<StaticPedestrian> _pedestrians = [];
  final List<PedestrianAlertData> _activeAlerts = [];
  
  StreamSubscription<Position>? _positionSub;
  Timer? _distanceCheckTimer;

  final LatLng _fallbackCenter = const LatLng(23.0225, 72.5714);
  static const double _collisionThresholdMeters = 2000.0; // 2km alert range

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _initLocation();
    _fetchPedestriansFromBackend();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _distanceCheckTimer?.cancel();
    super.dispose();
  }

  // Initialize GPS location
  Future<void> _initLocation() async {
    final hasPermission = await _handleLocationPermission();
    if (!hasPermission) return;

    try {
      // Get initial position
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      setState(() {
        _currentLocation = LatLng(pos.latitude, pos.longitude);
      });

      debugPrint('✅ Initial location: ${pos.latitude}, ${pos.longitude}');

      // Center map on user location
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(_currentLocation!, 15);
      });

      // Start distance checking
      _startDistanceChecking();

    } catch (e) {
      debugPrint('❌ Error getting location: $e');
      setState(() {
        _currentLocation = _fallbackCenter;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(_fallbackCenter, 15);
      });
    }

    // Live GPS tracking
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // Update every 5 meters
      ),
    ).listen((Position position) {
      debugPrint('📍 GPS Update: ${position.latitude}, ${position.longitude}');

      final newLoc = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentLocation = newLoc;
      });

      // Send location to backend
      _apiService.updateLocation(position.latitude, position.longitude);

      // Update map
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _mapController.move(newLoc, _mapController.camera.zoom);
        } catch (e) {
          debugPrint('Map update error: $e');
        }
      });
    });
  }

  // Handle location permissions
  Future<bool> _handleLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('⚠️ Location services disabled');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('⚠️ Location permission denied');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('⚠️ Location permission permanently denied');
      return false;
    }

    return true;
  }

  // Fetch pedestrians from backend
  Future<void> _fetchPedestriansFromBackend() async {
    try {
      final List<rsu.Pedestrian> data = await _apiService.fetchPedestrians();
      debugPrint('📡 Fetched ${data.length} pedestrians from backend');

      setState(() {
        _pedestrians.clear();
        for (final p in data) {
          _pedestrians.add(StaticPedestrian(
            id: p.id,
            roadLocation: LatLng(p.lat, p.lon),
            isDetected: false,
          ));
        }
      });

      // Start checking distances
      if (_currentLocation != null) {
        _checkAllPedestrianDistances();
      }
    } catch (e) {
      debugPrint('❌ Error fetching pedestrians: $e');
    }
  }

  // Spawn proxy pedestrian on map (for testing)
  Future<void> _spawnProxyPedestrian() async {
    if (_currentLocation == null) {
      debugPrint('⚠️ Current location not available');
      return;
    }

    // Create a pedestrian at a random nearby location (within ~5km)
    final random = (DateTime.now().millisecondsSinceEpoch % 1000) / 1000.0;
    final offset = (random - 0.5) * 0.05; // Random offset
    
    final testLat = _currentLocation!.latitude + offset;
    final testLon = _currentLocation!.longitude + offset;

    final testLocation = LatLng(testLat, testLon);

    // Snap to nearest road
    debugPrint('📍 Spawning pedestrian near (${testLat.toStringAsFixed(5)}, ${testLon.toStringAsFixed(5)})');
    final snappedLocation = await _apiService.snapToRoad(testLocation);
    final finalLocation = snappedLocation ?? testLocation;

    final proxyPed = StaticPedestrian(
      id: 'ped_${DateTime.now().millisecondsSinceEpoch}',
      roadLocation: finalLocation,
      isDetected: false,
    );

    setState(() {
      _pedestrians.add(proxyPed);
    });

    debugPrint('✅ Spawned pedestrian at (${finalLocation.latitude.toStringAsFixed(5)}, ${finalLocation.longitude.toStringAsFixed(5)})');

    // Calculate distance immediately
    await _checkPedestrianDistance(proxyPed);
  }

  // Spawn multiple pedestrians
  Future<void> _spawnMultiplePedestrians(int count) async {
    if (_currentLocation == null) {
      debugPrint('⚠️ Current location not available');
      return;
    }

    debugPrint('👥 Spawning $count pedestrians...');
    
    for (int i = 0; i < count; i++) {
      await _spawnProxyPedestrian();
      // Small delay to avoid rate limiting
      await Future.delayed(const Duration(milliseconds: 200));
    }
    
    debugPrint('✅ Spawned $count pedestrians');
  }

  // Start periodic distance checking (every 2 seconds)
  void _startDistanceChecking() {
    _distanceCheckTimer?.cancel();
    _distanceCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_currentLocation != null) {
        _checkAllPedestrianDistances();
      }
    });
  }

  // Check distance to all pedestrians using REAL API
  Future<void> _checkAllPedestrianDistances() async {
    if (_currentLocation == null || _pedestrians.isEmpty) return;

    debugPrint('🔍 Checking distances to ${_pedestrians.length} pedestrians...');

    for (final ped in _pedestrians) {
      await _checkPedestrianDistance(ped);
    }
  }

  // Check distance to single pedestrian using REAL OSRM API
  Future<void> _checkPedestrianDistance(StaticPedestrian ped) async {
    if (_currentLocation == null) return;

    try {
      // Calculate REAL road distance using OSRM API
      final proximityResult = await _apiService.checkPedestrianProximity(
        _currentLocation!,
        ped.roadLocation,
        _collisionThresholdMeters,
      );

      if (proximityResult.error != null) {
        debugPrint('⚠️ ${ped.id}: ${proximityResult.error}');
        return;
      }

      // Update pedestrian data
      setState(() {
        ped.lastDetectionDistance = proximityResult.distanceMeters;

        if (proximityResult.isNearby) {
          // Pedestrian is within threshold - ALERT!
          if (!ped.isDetected) {
            // New alert
            ped.isDetected = true;
            
            final alert = PedestrianAlertData(
              pedestrianId: ped.id,
              pedestrianLocation: ped.roadLocation,
              distanceMeters: proximityResult.distanceMeters,
              durationSeconds: proximityResult.durationSeconds,
              detectionTime: DateTime.now(),
              isNew: true,
            );

            _activeAlerts.insert(0, alert);
            if (_activeAlerts.length > 10) {
              _activeAlerts.removeLast();
            }

            // Send alert to backend
            _apiService.updatePedestrian(
              ped.roadLocation.latitude,
              ped.roadLocation.longitude,
              pedestrianId: ped.id,
            );

            debugPrint('🚨 NEW ALERT: ${ped.id} at ${proximityResult.distanceMeters.toStringAsFixed(0)}m');
          }
        } else {
          // Pedestrian is far - clear alert
          if (ped.isDetected) {
            ped.isDetected = false;
            debugPrint('✓ ${ped.id} moved out of range');
          }
        }
      });
    } catch (e) {
      debugPrint('❌ Error checking ${ped.id}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("V2X Pedestrian Alert System"),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Add 1 Pedestrian',
            onPressed: _spawnProxyPedestrian,
          ),
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Add 5 Pedestrians',
            onPressed: () => _spawnMultiplePedestrians(5),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh from Backend',
            onPressed: _fetchPedestriansFromBackend,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear All',
            onPressed: () {
              setState(() {
                _pedestrians.clear();
                _activeAlerts.clear();
              });
            },
          ),
        ],
      ),

      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation ?? _fallbackCenter,
              initialZoom: 15,
            ),
            children: [
              TileLayer(
                urlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
                subdomains: ['a', 'b', 'c'],
              ),

              MarkerLayer(
                markers: [
                  // Vehicle marker
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

                  // Pedestrian markers
                  ..._pedestrians.map((ped) {
                    final isDetected = ped.isDetected;
                    final distance = ped.lastDetectionDistance ?? double.infinity;
                    
                    return Marker(
                      width: 60,
                      height: 60,
                      point: ped.roadLocation,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Alert ring
                          if (isDetected)
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.red, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withOpacity(0.7),
                                    blurRadius: 15,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                          // Pedestrian icon
                          Container(
                            width: 45,
                            height: 45,
                            decoration: BoxDecoration(
                              color: isDetected ? Colors.red : Colors.orange,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                          // Distance badge
                          if (distance != double.infinity)
                            Positioned(
                              bottom: -5,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isDetected ? Colors.red : Colors.orange,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${(distance / 1000).toStringAsFixed(1)}km',
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
                  }),
                ],
              ),
            ],
          ),

          // Alert panel
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
                    child: _activeAlerts.isEmpty
                        ? const Row(
                            children: [
                              Icon(Icons.check_circle, color: Colors.green, size: 20),
                              SizedBox(width: 8),
                              Text(
                                '✓ No collision alerts',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          )
                        : SingleChildScrollView(
                            child: Column(
                              children: _activeAlerts.map((alert) {
                                return Padding(
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
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Text('🚨', style: TextStyle(fontSize: 14)),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                alert.pedestrianId,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.red,
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
                                            '📍 ${(alert.distanceMeters / 1000).toStringAsFixed(2)}km (${alert.distanceMeters.toStringAsFixed(0)}m)',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'ETA: ${(alert.durationSeconds / 60).toStringAsFixed(1)} min',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.red.withOpacity(0.7),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),

          // Stats panel
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
                        'Pedestrians: ${_pedestrians.length}',
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
                          color: Colors.orange,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Using: OSRM Real Distance API',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  if (_currentLocation != null) ...[
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
                          'GPS: ${_currentLocation!.latitude.toStringAsFixed(4)}, ${_currentLocation!.longitude.toStringAsFixed(4)}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Floating action buttons for spawning
          Positioned(
            bottom: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'spawn1',
                  onPressed: _spawnProxyPedestrian,
                  backgroundColor: Colors.green,
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add 1'),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'spawn5',
                  onPressed: () => _spawnMultiplePedestrians(5),
                  backgroundColor: Colors.orange,
                  icon: const Icon(Icons.group_add),
                  label: const Text('Add 5'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Alert data class
class PedestrianAlertData {
  final String pedestrianId;
  final LatLng pedestrianLocation;
  final double distanceMeters;
  final double durationSeconds;
  final DateTime detectionTime;
  final bool isNew;

  PedestrianAlertData({
    required this.pedestrianId,
    required this.pedestrianLocation,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.detectionTime,
    required this.isNew,
  });
}