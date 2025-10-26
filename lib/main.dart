import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:collection/collection.dart';
import 'dart:io';
import 'dart:math';
import 'dart:async';

// --- Global Variables ---
List<CameraDescription> cameras = [];

// --- Blind Assistance Data Structures ---
enum ObjectType { obstacle, landmark, person, vehicle, furniture, food, electronic, other }
enum Priority { critical, high, medium, low }
enum Direction { left, center, right, far_left, far_right }

class DetectedObject {
  final String label;
  final double confidence;
  final ObjectType type;
  final Priority priority;
  final Direction direction;
  final double distance; // Estimated distance (0.0 = very close, 1.0 = far)
  final DateTime timestamp;
  final Rect boundingBox;

  DetectedObject({
    required this.label,
    required this.confidence,
    required this.type,
    required this.priority,
    required this.direction,
    required this.distance,
    required this.timestamp,
    required this.boundingBox,
  });
}

class NavigationContext {
  final List<DetectedObject> objects;
  final String guidance;
  final bool isSafeToMove;
  final String warning;
  final DateTime timestamp;

  NavigationContext({
    required this.objects,
    required this.guidance,
    required this.isSafeToMove,
    required this.warning,
    required this.timestamp,
  });
}

class BlindAssistant {
  static const Map<String, ObjectType> _objectTypeMap = {
    'person': ObjectType.person,
    'car': ObjectType.vehicle,
    'bus': ObjectType.vehicle,
    'truck': ObjectType.vehicle,
    'motorcycle': ObjectType.vehicle,
    'bicycle': ObjectType.vehicle,
    'chair': ObjectType.furniture,
    'couch': ObjectType.furniture,
    'bed': ObjectType.furniture,
    'dining table': ObjectType.furniture,
    'laptop': ObjectType.electronic,
    'tv': ObjectType.electronic,
    'cell phone': ObjectType.electronic,
    'keyboard': ObjectType.electronic,
    'mouse': ObjectType.electronic,
    'bottle': ObjectType.food,
    'cup': ObjectType.food,
    'bowl': ObjectType.food,
    'book': ObjectType.other,
    'backpack': ObjectType.other,
    'handbag': ObjectType.other,
  };

  static const Map<String, Priority> _priorityMap = {
    'person': Priority.high,
    'car': Priority.critical,
    'bus': Priority.critical,
    'truck': Priority.critical,
    'motorcycle': Priority.critical,
    'bicycle': Priority.high,
    'chair': Priority.medium,
    'couch': Priority.medium,
    'bed': Priority.medium,
    'dining table': Priority.medium,
    'laptop': Priority.low,
    'tv': Priority.low,
    'cell phone': Priority.low,
    'keyboard': Priority.low,
    'mouse': Priority.low,
    'bottle': Priority.low,
    'cup': Priority.low,
    'bowl': Priority.low,
    'book': Priority.low,
    'backpack': Priority.low,
    'handbag': Priority.low,
  };

  static ObjectType getObjectType(String label) {
    return _objectTypeMap[label] ?? ObjectType.other;
  }

  static Priority getPriority(String label) {
    return _priorityMap[label] ?? Priority.low;
  }

  static Direction calculateDirection(double centerX, double imageWidth) {
    final normalizedX = centerX / imageWidth;
    if (normalizedX < 0.2) return Direction.far_left;
    if (normalizedX < 0.4) return Direction.left;
    if (normalizedX < 0.6) return Direction.center;
    if (normalizedX < 0.8) return Direction.right;
    return Direction.far_right;
  }

  static double estimateDistance(double confidence, double boxArea) {
    // Higher confidence and larger box area = closer object
    return (1.0 - confidence) + (1.0 - min(boxArea, 1.0)) / 2.0;
  }

  static NavigationContext analyzeScene(List<DetectedObject> objects) {
    final now = DateTime.now();
    final criticalObjects = objects.where((obj) => obj.priority == Priority.critical).toList();
    final highPriorityObjects = objects.where((obj) => obj.priority == Priority.high).toList();
    final indoorObjects = objects.where((obj) => 
      ['person', 'bottle', 'cup', 'chair', 'dining table', 'laptop', 'tv', 'book', 'cell phone', 'keyboard', 'mouse', 'couch', 'bed', 'potted plant', 'clock', 'vase'].contains(obj.label)
    ).toList();
    
    String guidance = "Point your camera at objects around you...";
    bool isSafeToMove = true;
    String warning = "";

    if (criticalObjects.isNotEmpty) {
      isSafeToMove = false;
      final vehicle = criticalObjects.firstWhere((obj) => obj.type == ObjectType.vehicle, orElse: () => criticalObjects.first);
      guidance = "STOP! ${vehicle.label} detected ${_getDirectionText(vehicle.direction)}. Wait for it to pass.";
      warning = "Vehicle detected - do not proceed";
    } else if (highPriorityObjects.isNotEmpty) {
      final person = highPriorityObjects.firstWhere((obj) => obj.type == ObjectType.person, orElse: () => highPriorityObjects.first);
      guidance = "${person.label} detected ${_getDirectionText(person.direction)}. Proceed with caution.";
      warning = "Person nearby - slow down";
    } else if (indoorObjects.isNotEmpty) {
      // Indoor-specific guidance
      final objectsByType = <String, List<DetectedObject>>{};
      for (final obj in indoorObjects) {
        objectsByType.putIfAbsent(obj.label, () => []).add(obj);
      }
      
      final sortedObjects = objectsByType.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      
      if (sortedObjects.isNotEmpty) {
        final mainObject = sortedObjects.first.value.first;
        final count = sortedObjects.first.value.length;
        final countText = count > 1 ? " ($count detected)" : "";
        
        guidance = "${mainObject.label}$countText ${_getDirectionText(mainObject.direction)}. ";
        
        // Add additional objects if detected
        if (sortedObjects.length > 1) {
          final additionalObjects = sortedObjects.skip(1).take(2).map((e) => e.key).join(', ');
          guidance += "Also detected: $additionalObjects.";
        }
      }
    } else {
      guidance = "No objects detected. Try pointing at furniture, bottles, or other indoor items.";
    }

    return NavigationContext(
      objects: objects,
      guidance: guidance,
      isSafeToMove: isSafeToMove,
      warning: warning,
      timestamp: now,
    );
  }

  static String _getDirectionText(Direction direction) {
    switch (direction) {
      case Direction.far_left: return "far to your left";
      case Direction.left: return "to your left";
      case Direction.center: return "directly ahead";
      case Direction.right: return "to your right";
      case Direction.far_right: return "far to your right";
    }
  }
}

// --- Main App ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Error finding cameras: ${e.code}\nError Message: ${e.description}');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Virtual Eye',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.blueGrey,
      ),
      home: const CameraScreen(),
    );
  }
}

// --- Camera Screen Widget ---
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  String _narrationText = "Initializing Virtual Eye Assistant...";
  bool _isProcessing = false;
  String _debugInfo = "Starting up...";
  DateTime? _lastProcessTime;
  static const Duration _processingInterval = Duration(milliseconds: 500); // Faster processing for real-time assistance

  Isolate? _isolate;
  final ReceivePort _receivePort = ReceivePort();
  SendPort? _sendPort;

  final FlutterTts _flutterTts = FlutterTts();
  Set<String> _lastSpokenObjects = {};
  NavigationContext? _lastNavigationContext;
  Timer? _speechTimer;

  bool _isIsolateReady = false;
  bool _testMode = false;
  
  // Blind assistance specific variables
  List<DetectedObject> _currentObjects = [];
  String _currentGuidance = "";
  bool _isSafeToMove = true;
  String _currentWarning = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _requestPermissionAndInit();
  }

  Future<void> _initTts() async {
    await _flutterTts.setSharedInstance(true);
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.6); // Slightly faster for real-time assistance
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  void _speak(String text, {bool urgent = false}) async {
    debugPrint("[Main] TTS: Attempting to speak: $text");
    try {
      await _flutterTts.stop();
      if (urgent) {
        await _flutterTts.setSpeechRate(0.8); // Faster for urgent messages
      } else {
        await _flutterTts.setSpeechRate(0.6);
      }
      await _flutterTts.speak(text);
      debugPrint("[Main] TTS: Speech started successfully");
    } catch (e) {
      debugPrint("[Main] TTS Error: $e");
    }
  }

  void _speakGuidance(NavigationContext context) {
    final guidance = context.guidance;
    final warning = context.warning;
    
    // Cancel previous speech timer
    _speechTimer?.cancel();
    
    // Speak guidance with appropriate urgency
    if (context.warning.isNotEmpty) {
      _speak("WARNING: $warning", urgent: true);
      _speechTimer = Timer(const Duration(seconds: 2), () {
        _speak(guidance);
      });
    } else {
      _speak(guidance);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort.close();
    _speechTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera(cameraController.description);
    }
  }

  Future<void> _requestPermissionAndInit() async {
    debugPrint("[Main] Requesting camera permission...");
    if (await Permission.camera.request().isGranted) {
      debugPrint("[Main] Camera permission granted.");

      _startInference();

      if (cameras.isNotEmpty) {
        await _initializeCamera(cameras.first);
      } else {
        debugPrint("[Main] No cameras available.");
        if (mounted) setState(() => _narrationText = "No cameras available.");
      }
    } else {
      debugPrint("[Main] Camera permission denied.");
      if (mounted) setState(() => _narrationText = "Camera permission denied.");
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    debugPrint("[Main] Initializing camera...");
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _cameraController!.initialize();
      debugPrint("[Main] Camera initialized successfully.");
      if (!mounted) return;
      setState(() {
        _isCameraInitialized = true;
        _narrationText = "Point at your surroundings...";
      });
      if (_isIsolateReady) {
         _startStreaming();
      }
    } on CameraException catch (e) {
      debugPrint('[Main] Error initializing camera: $e');
      if (mounted) setState(() => _narrationText = "Failed to initialize camera.");
    }
  }

  void _startStreaming() {
     debugPrint("[Main] Starting camera stream...");
     if (mounted) setState(() => _debugInfo = "Camera stream started");
     _cameraController!.startImageStream((image) {
       final now = DateTime.now();
       if (!_isProcessing && _sendPort != null && 
           (_lastProcessTime == null || now.difference(_lastProcessTime!) >= _processingInterval)) {
         _isProcessing = true;
         _lastProcessTime = now;
         if (mounted) setState(() => _debugInfo = "Processing frame...");
         final input = _prepareInput(image);
         if (input != null) {
           _sendPort!.send(input);
         } else {
           _isProcessing = false;
           if (mounted) setState(() => _debugInfo = "Failed to prepare input");
         }
       }
     });
  }

  void _startInference() async {
    debugPrint("[Main] Starting inference isolate setup...");
    if (mounted) setState(() => _debugInfo = "Loading model...");
    try {
      final modelBytes = await rootBundle.load('assets/ssd_mobilenet.tflite');
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      debugPrint("[Main] Model and labels loaded from assets.");
      if (mounted) setState(() => _debugInfo = "Model loaded, spawning isolate...");

      final initData = IsolateInitData(
        modelBytes.buffer.asUint8List(),
        labelsData,
        _receivePort.sendPort,
      );

      _isolate = await Isolate.spawn(_inferenceIsolate, initData);
      debugPrint("[Main] Inference isolate spawned.");

      _receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _isIsolateReady = true;
          debugPrint("[Main] Received SendPort from isolate. Isolate is ready.");
          if (mounted) setState(() => _debugInfo = "Isolate ready, starting camera stream");
          if (_isCameraInitialized) {
             _startStreaming();
          }
        } else if (message is List<String>) {
          debugPrint("[Main] Received detection results: ${message.length} objects");
          if (mounted) {
            // Convert simple string list to DetectedObject list for blind assistance
            _currentObjects = message.map((label) {
              final now = DateTime.now();
              // For indoor testing, prioritize common indoor objects
              final isIndoorObject = ['person', 'bottle', 'cup', 'chair', 'dining table', 'laptop', 'tv', 'book', 'cell phone', 'keyboard', 'mouse', 'couch', 'bed', 'potted plant', 'clock', 'vase'].contains(label);
              
              return DetectedObject(
                label: label,
                confidence: isIndoorObject ? 0.9 : 0.7, // Higher confidence for indoor objects
                type: BlindAssistant.getObjectType(label),
                priority: BlindAssistant.getPriority(label),
                direction: Direction.center, // Default direction - will be improved with bounding boxes
                distance: 0.5, // Default distance
                timestamp: now,
                boundingBox: const Rect.fromLTWH(0, 0, 100, 100), // Default bounding box
              );
            }).toList();
            
            // Analyze scene for navigation guidance
            final navigationContext = BlindAssistant.analyzeScene(_currentObjects);
            
            debugPrint("[Main] Navigation context: ${navigationContext.guidance}");
            
            // Update UI with guidance information
            setState(() {
              _narrationText = navigationContext.guidance;
              _currentGuidance = navigationContext.guidance;
              _isSafeToMove = navigationContext.isSafeToMove;
              _currentWarning = navigationContext.warning;
              _debugInfo = "Objects: ${_currentObjects.length} | Safe: ${_isSafeToMove ? 'Yes' : 'No'} | ${navigationContext.warning.isNotEmpty ? 'WARNING: ' + navigationContext.warning : 'Clear'}";
            });
            
            // Speak guidance if context changed significantly
            if (_lastNavigationContext == null || 
                _lastNavigationContext!.guidance != navigationContext.guidance ||
                _lastNavigationContext!.isSafeToMove != navigationContext.isSafeToMove) {
              _lastNavigationContext = navigationContext;
              _speakGuidance(navigationContext);
            }
          }
        } else if (message is String && message.startsWith("ERROR:")) {
            debugPrint("[Main] Received error from isolate: $message");
            if(mounted) setState(() => _narrationText = message);
        }
        _isProcessing = false;
      });
    } catch (e) {
      debugPrint('[Main] Error starting inference: $e');
      if (mounted) setState(() {
        _narrationText = "Failed to load model.";
        _debugInfo = "Error: $e";
      });
    }
  }

  void _testVoice() {
    debugPrint("[Main] Testing voice output");
    _speak("Testing voice output. Can you hear me?");
  }

  void _testIndoorDetection() {
    debugPrint("[Main] Testing indoor object detection");
    final testObjects = [
      DetectedObject(
        label: "bottle",
        confidence: 0.9,
        type: ObjectType.food,
        priority: Priority.low,
        direction: Direction.right,
        distance: 0.3,
        timestamp: DateTime.now(),
        boundingBox: const Rect.fromLTWH(0, 0, 100, 100),
      ),
      DetectedObject(
        label: "chair",
        confidence: 0.85,
        type: ObjectType.furniture,
        priority: Priority.medium,
        direction: Direction.left,
        distance: 0.4,
        timestamp: DateTime.now(),
        boundingBox: const Rect.fromLTWH(0, 0, 100, 100),
      ),
      DetectedObject(
        label: "person",
        confidence: 0.95,
        type: ObjectType.person,
        priority: Priority.high,
        direction: Direction.center,
        distance: 0.2,
        timestamp: DateTime.now(),
        boundingBox: const Rect.fromLTWH(0, 0, 100, 100),
      ),
    ];
    final context = BlindAssistant.analyzeScene(testObjects);
    _speakGuidance(context);
    
    // Update UI to show test results
    setState(() {
      _currentObjects = testObjects;
      _narrationText = context.guidance;
      _currentGuidance = context.guidance;
      _isSafeToMove = context.isSafeToMove;
      _currentWarning = context.warning;
      _debugInfo = "TEST MODE: Objects: ${testObjects.length} | Safe: ${_isSafeToMove ? 'Yes' : 'No'} | ${context.warning.isNotEmpty ? 'WARNING: ' + context.warning : 'Clear'}";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Virtual Eye Assistant'),
        backgroundColor: _isSafeToMove ? Colors.green[700] : Colors.red[700],
        actions: [
          IconButton(
            icon: const Icon(Icons.volume_up),
            onPressed: _testVoice,
            tooltip: 'Test Voice',
          ),
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: _testIndoorDetection,
            tooltip: 'Test Indoor Detection',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: Center(
                child: _isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized
                    ? CameraPreview(_cameraController!)
                    : const CircularProgressIndicator(),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              width: double.infinity,
              color: Colors.blueGrey[900],
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Safety indicator
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _isSafeToMove ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isSafeToMove ? Colors.green : Colors.red, 
                        width: 2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isSafeToMove ? Icons.check_circle : Icons.warning,
                          color: _isSafeToMove ? Colors.green : Colors.red,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isSafeToMove ? "SAFE TO MOVE" : "STOP - UNSAFE",
                          style: TextStyle(
                            color: _isSafeToMove ? Colors.green : Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Main guidance text
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
                    child: Text(
                      _narrationText,
                      style: TextStyle(
                        color: _isSafeToMove ? Colors.white : Colors.red[200], 
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  
                  // Warning text if present
                  if (_currentWarning.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 2),
                      child: Text(
                        "⚠️ $_currentWarning",
                        style: const TextStyle(
                          color: Colors.red, 
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  
                  // Debug info
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
                    child: Text(
                      _debugInfo,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class IsolateInitData {
  final Uint8List modelBytes;
  final String labelsData;
  final SendPort sendPort;
  IsolateInitData(this.modelBytes, this.labelsData, this.sendPort);
}

class Detection {
  final String label;
  final double score;
  Detection(this.label, this.score);
}

void _inferenceIsolate(IsolateInitData initData) async {
  final port = ReceivePort();
  initData.sendPort.send(port.sendPort);

  Interpreter? interpreter;
  List<String> labels = [];

  try {
    debugPrint("[Isolate] Initializing...");
    final interpreterOptions = InterpreterOptions();
    if (Platform.isAndroid) {
      interpreterOptions.addDelegate(XNNPackDelegate());
    }

    interpreter = Interpreter.fromBuffer(initData.modelBytes, options: interpreterOptions);
    labels = initData.labelsData.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    debugPrint("[Isolate] Interpreter and labels loaded.");
    
    const priority = {
      'person': 10, 
      'laptop': 8, 
      'bottle': 7, 
      'cup': 7, 
      'book': 6, 
      'cell phone': 6, 
      'keyboard': 6, 
      'mouse': 6, 
      'chair': 5, 
      'tv': 5, 
      'car': 5, 
      'bus': 5, 
      'bicycle': 4, 
      'dog': 3, 
      'cat': 3
    };
    const topK = 3;

    await for (final dynamic message in port) {
       if (message is! Uint8List) {
         continue;
       }
       final Uint8List input = message;
       if (interpreter == null) {
         debugPrint("[Isolate] Interpreter not ready, skipping frame.");
         continue;
       }
       try {
          // Create input tensor with proper uint8 format - try different approach
          final reshapedInput = List.generate(300, (y) => 
            List.generate(300, (x) {
              final index = (y * 300 + x) * 3;
              return [
                input[index].round().clamp(0, 255).toInt(),
                input[index + 1].round().clamp(0, 255).toInt(),
                input[index + 2].round().clamp(0, 255).toInt(),
              ];
            })
          );

         final output = {
           0: [List.generate(25, (_) => List.filled(4, 0.0))],
           1: [List.filled(25, 0.0)],
           2: [List.filled(25, 0.0)],
           3: [0.0],
         };

         interpreter.runForMultipleInputs([reshapedInput], output);
         debugPrint("[Isolate] Inference complete.");
        
         final scores = (output[2]![0] as List<dynamic>).cast<double>();
         final classes = (output[1]![0] as List<dynamic>).cast<double>();
        
         var topDetectionsDebug = <Detection>[];
         for (int i = 0; i < scores.length; i++) {
           final classIdx = classes[i].toInt();
           final labelIndex = classIdx - 1;
           if (labelIndex >= 0 && labelIndex < labels.length) {
             topDetectionsDebug.add(Detection(labels[labelIndex], scores[i]));
           }
         }
         topDetectionsDebug.sort((a, b) => b.score.compareTo(a.score));
         debugPrint("[Isolate] All Scores: ${topDetectionsDebug.take(5).map((d) => '${d.label}: ${d.score.toStringAsFixed(3)}').join(', ')}");

         List<Detection> detections = [];
         for (int i = 0; i < scores.length; i++) {
           if (scores[i] > 0.1) { // Much lower threshold for better detection
             final classIdx = classes[i].toInt();
             final labelIndex = classIdx - 1;
             if (labelIndex >= 0 && labelIndex < labels.length) {
               detections.add(Detection(labels[labelIndex], scores[i]));
             }
         }
         }
         
         debugPrint("[Isolate] Detections above 0.1: ${detections.map((d) => '${d.label}: ${d.score.toStringAsFixed(3)}').join(', ')}");

         detections.sort((a, b) {
           final priorityA = priority[a.label] ?? 0;
           final priorityB = priority[b.label] ?? 0;
           return priorityB.compareTo(priorityA);
         });

          final topDetections = detections.map((d) => d.label).toSet().take(topK).toList();
          debugPrint("[Isolate] Sending ${topDetections.length} detections: ${topDetections.join(', ')}");
          initData.sendPort.send(topDetections);

       } catch (e) {
         debugPrint("[Isolate] Inference Loop ERROR: $e");
         initData.sendPort.send(<String>[]);
       }
    }
  } catch (e) {
    debugPrint("[Isolate] Initialization ERROR: $e");
     initData.sendPort.send("ERROR: Isolate failed to initialize.");
  } finally {
     interpreter?.close();
  }
}

// FIXED: Updated to work with newer image package API
Uint8List? _prepareInput(CameraImage image) {
  const modelInputSize = 300;
  img.Image? convertedImage = _convertYUV420ToImage(image);
  if (convertedImage == null) return null;

  final resizedImage = img.copyResize(convertedImage, width: modelInputSize, height: modelInputSize);

  final int w = resizedImage.width;
  final int h = resizedImage.height;
  final out = Uint8List(w * h * 3);
  int idx = 0;
  
  // FIXED: Use getPixelSafe or iterate through pixels properly
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final pixel = resizedImage.getPixel(x, y);
      out[idx++] = pixel.r.toInt();
      out[idx++] = pixel.g.toInt();
      out[idx++] = pixel.b.toInt();
    }
  }
  return out;
}

img.Image? _convertYUV420ToImage(CameraImage image) {
  try {
    final int width = image.width;
    final int height = image.height;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int? uvPixelStride = image.planes[1].bytesPerPixel;

    if (uvPixelStride == null) {
       debugPrint("[Convert] uvPixelStride is null");
       return null;
    }

    final imageBytes = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvPixelStride * (x >> 1) + uvRowStride * (y >> 1);
        final int index = y * width + x;

        if (index >= image.planes[0].bytes.length || uvIndex >= image.planes[1].bytes.length || uvIndex >= image.planes[2].bytes.length) {
          continue;
        }

        final yp = image.planes[0].bytes[index];
        final up = image.planes[1].bytes[uvIndex];
        final vp = image.planes[2].bytes[uvIndex];

        int r = (yp + 1.13983 * (vp - 128)).toInt().clamp(0, 255);
        int g = (yp - 0.39465 * (up - 128) - 0.58060 * (vp - 128)).toInt().clamp(0, 255);
        int b = (yp + 2.03211 * (up - 128)).toInt().clamp(0, 255);
        
        imageBytes.setPixelRgb(x, y, r, g, b);
      }
    }
     return imageBytes;
  } catch (e) {
    debugPrint("[Convert] Error: $e");
    return null;
  }
}