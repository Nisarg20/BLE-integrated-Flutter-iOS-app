import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'auth_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  bool _isScanning = false;
  List<BluetoothDevice> _devicesList = [];
  
  // Multiple device support
  List<BluetoothDevice> _connectedDevices = [];
  Map<String, StreamSubscription> _connectionStateSubscriptions = {};
  Map<String, StreamSubscription<List<int>>> _dataSubscriptions = {};
  
  // Per-device data buffers
  Map<String, List<int>> _receivedDataPerDevice = {};
  Map<String, bool> _isReceivingPerDevice = {};
  Map<String, int> _currentClipIndexPerDevice = {};
  
  StreamSubscription? _scanSubscription;

  bool _isLoading = false;
  List<StorageItem> _uploadedFiles = [];
  
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadFiles();
    _checkBluetoothState();
  }

  Future<void> _checkBluetoothState() async {
    try {
      await Future.delayed(const Duration(milliseconds: 1000));
      
      if (await FlutterBluePlus.isSupported == false) {
        _showMessage('Bluetooth not supported on this device', isError: true);
        return;
      }

      FlutterBluePlus.adapterState.listen((state) {
        debugPrint('Bluetooth adapter state: $state');
        if (state == BluetoothAdapterState.off) {
          _showMessage('Bluetooth is turned off', isError: true);
        } else if (state == BluetoothAdapterState.on) {
          debugPrint('Bluetooth is ready');
        } else if (state == BluetoothAdapterState.unauthorized) {
          _showMessage('Bluetooth permission not granted', isError: true);
        } else if (state == BluetoothAdapterState.unavailable) {
          _showMessage('Bluetooth unavailable on this device', isError: true);
        }
      });
    } catch (e) {
      debugPrint('Error checking Bluetooth state: $e');
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _disconnectBLE();
    _tabController.dispose();
    super.dispose();
  }

  void _cleanupDevice(String deviceId) {
    _connectionStateSubscriptions[deviceId]?.cancel();
    _dataSubscriptions[deviceId]?.cancel();
    _receivedDataPerDevice.remove(deviceId);
    _isReceivingPerDevice.remove(deviceId);
    _currentClipIndexPerDevice.remove(deviceId);
  }

  // ----------- BLE METHODS -----------

  Future<void> _startScan() async {
    debugPrint('🔍 Starting scan...');
    
    try {
      if (await FlutterBluePlus.isSupported == false) {
        debugPrint('❌ Bluetooth not supported');
        _showMessage('Bluetooth not supported on this device', isError: true);
        return;
      }
      debugPrint('✅ Bluetooth is supported');

      debugPrint('⏳ Waiting for Bluetooth to be ready...');
      
      var adapterState = await FlutterBluePlus.adapterState
          .firstWhere(
            (state) => state != BluetoothAdapterState.unknown,
            orElse: () => BluetoothAdapterState.unknown,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
      
      debugPrint('📡 Adapter state: $adapterState');
      
      if (adapterState == BluetoothAdapterState.unknown) {
        _showMessage('Bluetooth is still initializing, please try again', isError: true);
        return;
      }
      
      if (adapterState != BluetoothAdapterState.on) {
        debugPrint('❌ Bluetooth is not ON');
        _showMessage('Please turn on Bluetooth in Settings', isError: true);
        return;
      }
      
      debugPrint('✅ Bluetooth is ON, proceeding with scan');
    } catch (e) {
      _showMessage('Error checking Bluetooth: $e', isError: true);
      debugPrint('❌ Bluetooth check error: $e');
      return;
    }

    setState(() {
      _isScanning = true;
      _devicesList.clear();
    });
    
    debugPrint('🔄 Scan state set, devices list cleared');

    try {
      debugPrint('👂 Setting up scan results listener');
      
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        debugPrint('📥 Received ${results.length} scan results');
        for (var r in results) {
          bool hasOurService = r.advertisementData.serviceUuids.any(
            (uuid) => uuid.toString().toLowerCase() == '4fafc201-1fb5-459e-8fcc-c5c9c331914b'
          );
          
          if (hasOurService) {
            debugPrint('  ⭐ FOUND ESP32 DEVICE: ${r.device.platformName} (${r.device.remoteId})');
          }
          
          debugPrint('  Device: ${r.device.platformName} (${r.device.remoteId}) RSSI: ${r.rssi}');
          debugPrint('    Service UUIDs: ${r.advertisementData.serviceUuids}');
          
          if (!_devicesList.contains(r.device)) {
            debugPrint('  ➕ Adding new device to list');
            setState(() => _devicesList.add(r.device));
          }
        }
      });

      debugPrint('🚀 Starting Bluetooth scan with service filter');
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
        withServices: [Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b')],
        androidUsesFineLocation: false,
      );
      
      debugPrint('⏰ Scan started, waiting for results...');
      await Future.delayed(const Duration(seconds: 8));
      
    } catch (e) {
      _showMessage('Error scanning: $e', isError: true);
      debugPrint('❌ BLE scan error: $e');
    } finally {
      debugPrint('🛑 Stopping scan');
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      if (mounted) {
        setState(() => _isScanning = false);
        debugPrint('✅ Scan complete. Found ${_devicesList.length} devices');
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      _showMessage('Connecting to ${device.platformName}...', duration: 1);
      
      // CRITICAL: Initialize data structures FIRST, before any BLE operations
      String deviceId = device.remoteId.toString();
      _receivedDataPerDevice[deviceId] = [];
      _isReceivingPerDevice[deviceId] = false;
      _currentClipIndexPerDevice[deviceId] = 0;
      
      await device.connect(timeout: const Duration(seconds: 15));
      
      setState(() => _connectedDevices.add(device));
      _showMessage('Connected to ${device.platformName}');
      
      // Listen for connection state changes
      _connectionStateSubscriptions[deviceId] = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() => _connectedDevices.remove(device));
          _cleanupDevice(deviceId);
          _showMessage('${device.platformName} disconnected', isError: true);
        }
      });
      
      // Discover services and start listening for data
      await _setupDataListener(device);
      
    } catch (e) {
      _showMessage('Failed to connect: $e', isError: true);
      debugPrint('BLE connect error: $e');
    }
  }

  Future<void> _setupDataListener(BluetoothDevice device) async {
    try {
      debugPrint('🔍 Discovering services for ${device.platformName}...');
      List<BluetoothService> services = await device.discoverServices();
      
      for (BluetoothService service in services) {
        debugPrint('Found service: ${service.uuid}');
        
        if (service.uuid.toString().toLowerCase() == "4fafc201-1fb5-459e-8fcc-c5c9c331914b") {
          debugPrint('✅ Found our service!');
          
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            debugPrint('  Characteristic: ${characteristic.uuid}');
            
            if (characteristic.uuid.toString().toLowerCase() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
              debugPrint('✅ Found our characteristic!');
              
              await characteristic.setNotifyValue(true);
              debugPrint('✅ Notifications enabled');
              
              // Store subscription with device ID
              String deviceId = device.remoteId.toString();
              _dataSubscriptions[deviceId] = characteristic.lastValueStream.listen((data) {
                if (data.isNotEmpty) {
                  debugPrint('📥 [${device.platformName}] Received ${data.length} bytes');
                  _handleIncomingData(deviceId, device.platformName, data);
                }
              });
              
              _showMessage('Listening for clips from ${device.platformName}...');
              return;
            }
          }
        }
      }
      
      _showMessage('Could not find expected service/characteristic', isError: true);
      
    } catch (e) {
      debugPrint('❌ Error setting up data listener: $e');
      _showMessage('Failed to setup data listener: $e', isError: true);
    }
  }

  void _handleIncomingData(String deviceId, String deviceName, List<int> data) {
    if (data.isEmpty) return;
    
    // Use safe access instead of ! operator
    bool isCurrentlyReceiving = _isReceivingPerDevice[deviceId] ?? false;
    
    // Check for start marker (header)
    if (!isCurrentlyReceiving && data.length >= 16) {
      if (data[0] == 0xFF && data[1] == 0xAA) {
        // This is a clip header
        int clipIndex = data[2];
        
        // Extract size (4 bytes starting at index 4)
        int clipSize = data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24);
        
        // Extract timestamp (4 bytes starting at index 8)
        int timestamp = data[8] | (data[9] << 8) | (data[10] << 16) | (data[11] << 24);
        
        debugPrint('🎵 [$deviceName] Starting clip #$clipIndex (size: $clipSize bytes, timestamp: $timestamp)');
        
        setState(() {
          _isReceivingPerDevice[deviceId] = true;
          _currentClipIndexPerDevice[deviceId] = clipIndex;
          _receivedDataPerDevice[deviceId]!.clear();
        });
        
        _showMessage('[$deviceName] Receiving clip #$clipIndex...', duration: 1);
        return;
      }
    }
    
    // Check for end marker
    if (isCurrentlyReceiving && data.length >= 4) {
      if (data[0] == 0xFF && data[1] == 0xBB) {
        // End of clip
        debugPrint('✅ [$deviceName] Clip complete: ${_receivedDataPerDevice[deviceId]!.length} bytes');
        _processReceivedAudio(deviceId, deviceName);
        return;
      }
    }
    
    // Continue receiving data chunks
    if (isCurrentlyReceiving) {
      _receivedDataPerDevice[deviceId]!.addAll(data);
      debugPrint('📦 [$deviceName] Total received: ${_receivedDataPerDevice[deviceId]!.length} bytes');
      setState(() {});
    }
  }

  Future<void> _processReceivedAudio(String deviceId, String deviceName) async {
    if (_receivedDataPerDevice[deviceId]!.isEmpty) return;
    
    setState(() => _isReceivingPerDevice[deviceId] = false);
    _showMessage('[$deviceName] Processing audio clip...');
    
    try {
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final clipIndex = _currentClipIndexPerDevice[deviceId];
      
      // Create unique filename: deviceName_timestamp_clipIndex.wav
      final sanitizedDeviceName = deviceName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final filePath = '${dir.path}/${sanitizedDeviceName}_${timestamp}_clip${clipIndex}.wav';
      final file = File(filePath);
      
      await file.writeAsBytes(_receivedDataPerDevice[deviceId]!);
      
      debugPrint('💾 [$deviceName] Saved clip to: $filePath');
      
      // Upload to S3
      await _uploadToS3(file, deviceName);
      
      // Clear received data for next clip
      _receivedDataPerDevice[deviceId]!.clear();
      
    } catch (e) {
      debugPrint('❌ Error processing audio: $e');
      _showMessage('[$deviceName] Error processing audio: $e', isError: true);
    }
  }

  Future<void> _uploadToS3(File file, String deviceName) async {
    try {
      final fileName = file.uri.pathSegments.last;
      final sanitizedDeviceName = deviceName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final key = 'uploads/$sanitizedDeviceName/$fileName';
      
      await Amplify.Storage.uploadFile(
        localFile: AWSFile.fromPath(file.path),
        path: StoragePath.fromString('public/$key'),
        onProgress: (progress) {
          debugPrint('📤 Upload progress: ${(progress.fractionCompleted * 100).toStringAsFixed(1)}%');
        },
      ).result;
      
      _showMessage('[$deviceName] Clip uploaded!');
      await _loadFiles();
      
      // Delete temporary file
      await file.delete();
      
    } catch (e) {
      debugPrint('❌ Upload error: $e');
      _showMessage('Upload failed: $e', isError: true);
    }
  }

  Future<void> _disconnectBLE() async {
    try {
      // Disconnect all devices
      for (var device in List.from(_connectedDevices)) {
        String deviceId = device.remoteId.toString();
        await _dataSubscriptions[deviceId]?.cancel();
        await _connectionStateSubscriptions[deviceId]?.cancel();
        await device.disconnect();
        _cleanupDevice(deviceId);
      }
      
      setState(() => _connectedDevices.clear());
      if (_connectedDevices.isEmpty) {
        _showMessage('All devices disconnected');
      }
    } catch (e) {
      _showMessage('Error disconnecting: $e', isError: true);
      debugPrint('BLE disconnect error: $e');
    }
  }

  Future<void> _disconnectSingleDevice(BluetoothDevice device) async {
    try {
      String deviceId = device.remoteId.toString();
      await _dataSubscriptions[deviceId]?.cancel();
      await _connectionStateSubscriptions[deviceId]?.cancel();
      await device.disconnect();
      
      setState(() => _connectedDevices.remove(device));
      _cleanupDevice(deviceId);
      _showMessage('${device.platformName} disconnected');
    } catch (e) {
      _showMessage('Error disconnecting: $e', isError: true);
    }
  }

  // ----------- AWS AMPLIFY METHODS -----------

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);

    try {
      final result = await Amplify.Storage.list(
        path: StoragePath.fromString('public/uploads/'),
      ).result;

      if (!mounted) return;
      setState(() {
        _uploadedFiles = result.items;
      });
    } catch (e) {
      _showMessage('Error loading files: $e', isError: true);
      debugPrint('Amplify load files error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteFile(StorageItem item) async {
    try {
      await Amplify.Storage.remove(
        path: StoragePath.fromString(item.path),
      ).result;
      
      setState(() => _uploadedFiles.remove(item));
      _showMessage('File deleted');
    } catch (e) {
      _showMessage('Error deleting file: $e', isError: true);
      debugPrint('Amplify delete file error: $e');
    }
  }

  Future<void> _signOut() async {
    try {
      await Amplify.Auth.signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
        (route) => false,
      );
    } catch (e) {
      _showMessage('Error signing out: $e', isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false, int duration = 3}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[400] : Colors.green[400],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: Duration(seconds: duration),
      ),
    );
  }

  String _formatFileSize(int? size) {
    if (size == null) return 'Unknown';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(2)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'Unknown';
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    
    if (difference.inDays > 0) return '${difference.inDays}d ago';
    if (difference.inHours > 0) return '${difference.inHours}h ago';
    if (difference.inMinutes > 0) return '${difference.inMinutes}m ago';
    return 'Just now';
  }

  // ----------- UI -----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF6C63FF).withOpacity(0.1),
              Colors.white,
            ],
            stops: const [0.0, 0.3],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildBLETab(),
                    _buildFilesTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFF4CAF50)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.bluetooth_audio,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'BLE Audio Hub',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _connectedDevices.isEmpty 
                        ? 'ESP32 Audio Monitor'
                        : '${_connectedDevices.length} device(s) connected',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _signOut,
                icon: const Icon(Icons.logout),
                tooltip: 'Sign Out',
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C63FF), Color(0xFF4CAF50)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              labelColor: Colors.white,
              padding: const EdgeInsets.all(4),
              indicatorSize: TabBarIndicatorSize.tab,
              unselectedLabelColor: Colors.grey,
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(text: 'BLE Device'),
                Tab(text: 'Files'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBLETab() {
    return RefreshIndicator(
      onRefresh: _startScan,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_connectedDevices.isNotEmpty) ..._buildConnectedCards(),
            if (_connectedDevices.isEmpty || _devicesList.isNotEmpty) ...[
              if (_connectedDevices.isNotEmpty) const SizedBox(height: 20),
              _buildScanCard(),
              if (_devicesList.isNotEmpty) ...[
                const SizedBox(height: 20),
                _buildDevicesList(),
              ],
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildConnectedCards() {
    return _connectedDevices.map((device) {
      String deviceId = device.remoteId.toString();
      bool isReceiving = _isReceivingPerDevice[deviceId] ?? false;
      int dataSize = _receivedDataPerDevice[deviceId]?.length ?? 0;
      
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF4CAF50).withOpacity(0.1),
                  Colors.white,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4CAF50).withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.bluetooth_connected,
                        size: 32,
                        color: Color(0xFF4CAF50),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.platformName.isNotEmpty
                                ? device.platformName
                                : 'ESP32 Device',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            deviceId,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[400],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (isReceiving) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    'Receiving: ${_formatFileSize(dataSize)}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _disconnectSingleDevice(device),
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: const Text('Disconnect'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[400],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildScanCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              _isScanning ? Icons.bluetooth_searching : Icons.bluetooth,
              size: 64,
              color: _isScanning ? const Color(0xFF6C63FF) : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              _isScanning ? 'Scanning for devices...' : 'Find ESP32 Devices',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isScanning
                  ? 'Please wait while we search'
                  : _connectedDevices.isEmpty
                      ? 'Tap the button below to start scanning'
                      : 'Scan for more devices',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isScanning ? null : _startScan,
                icon: Icon(_isScanning ? Icons.hourglass_empty : Icons.search),
                label: Text(_isScanning ? 'Scanning...' : 'Start Scan'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  disabledBackgroundColor: Colors.grey[300],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDevicesList() {
    // Filter out already connected devices
    final availableDevices = _devicesList.where((device) => 
      !_connectedDevices.contains(device)
    ).toList();
    
    if (availableDevices.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'Available devices (${availableDevices.length})',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...availableDevices.map((device) => Card(
              elevation: 2,
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.bluetooth,
                    color: Color(0xFF6C63FF),
                  ),
                ),
                title: Text(
                  device.platformName.isNotEmpty
                      ? device.platformName
                      : 'Unknown Device',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    device.remoteId.toString(),
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                ),
                trailing: ElevatedButton(
                  onPressed: () => _connectToDevice(device),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Connect'),
                ),
              ),
            )),
      ],
    );
  }

  Widget _buildFilesTab() {
    return RefreshIndicator(
      onRefresh: _loadFiles,
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _uploadedFiles.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: _uploadedFiles.length,
                  itemBuilder: (context, index) {
                    final file = _uploadedFiles[index];
                    final fileName = file.path.split('/').last;
                    
                    return Card(
                      elevation: 2,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF6C63FF), Color(0xFF4CAF50)],
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.audiotrack,
                            color: Colors.white,
                          ),
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(Icons.storage, size: 14, color: Colors.grey[600]),
                              const SizedBox(width: 4),
                              Text(
                                _formatFileSize(file.size),
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Icon(Icons.access_time, size: 14, color: Colors.grey[600]),
                              const SizedBox(width: 4),
                              Text(
                                _formatTimestamp(file.lastModified),
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () => _showDeleteDialog(file),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off,
            size: 80,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            'No files uploaded yet',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect your ESP32 device to start',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(StorageItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete File?'),
        content: Text('Are you sure you want to delete ${item.path.split('/').last}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteFile(item);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}