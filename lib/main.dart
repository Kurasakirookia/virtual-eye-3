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

// --- Global Variables ---
List<CameraDescription> cameras = [];

// --- Main App ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
    debugPrint('Found ${cameras.length} cameras');
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
  String _narrationText = "Initializing...";
  bool _isProcessing = false;

  Isolate? _isolate;
  final ReceivePort _receivePort = ReceivePort();
  SendPort? _sendPort;

  final FlutterTts _flutterTts = FlutterTts();
  Set<String> _lastSpokenObjects = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _requestPermissionAndInit();
  }

  Future<void> _initTts() async {
    try {
      await _flutterTts.setSharedInstance(true);
      await _flutterTts.setLanguage("en-US");
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);
      debugPrint('TTS initialized successfully');
    } catch (e) {
      debugPrint('Error initializing TTS: $e');
    }
  }

  void _speak(String text) async {
    try {
      await _flutterTts.stop();
      await _flutterTts.speak(text);
      debugPrint('Speaking: $text');
    } catch (e) {
      debugPrint('Error speaking: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort.close();
    _flutterTts.stop();
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
    debugPrint('Requesting camera permission...');
    if (await Permission.camera.request().isGranted) {
      debugPrint('Camera permission granted');
      if (cameras.isNotEmpty) {
        await _initializeCamera(cameras.first);
        await _startInference();
      } else {
        if (mounted) setState(() => _narrationText = "No cameras available.");
        _speak("No cameras available");
      }
    } else {
      debugPrint('Camera permission denied');
      if (mounted) setState(() => _narrationText = "Camera permission denied.");
      _speak("Camera permission denied");
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    debugPrint('Initializing camera...');
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {
        _isCameraInitialized = true;
        _narrationText = "Point at your surroundings...";
      });
      debugPrint('Camera initialized successfully');
      
      _cameraController!.startImageStream((image) {
        if (!_isProcessing && _sendPort != null) {
          _isProcessing = true;
          _sendPort!.send(image);
        }
      });
      debugPrint('Image stream started');
    } on CameraException catch (e) {
      debugPrint('Error initializing camera: $e');
      if (mounted) {
        setState(() => _narrationText = "Failed to initialize camera.");
        _speak("Failed to initialize camera");
      }
    }
  }

  Future<void> _startInference() async {
    debugPrint('Starting inference isolate...');
    try {
      final modelBytes = await rootBundle.load('assets/ssd_mobilenet.tflite');
      debugPrint('Model loaded: ${modelBytes.lengthInBytes} bytes');
      
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      final labelsList = labelsData.split('\n').where((l) => l.trim().isNotEmpty).toList();
      debugPrint('Labels loaded: ${labelsList.length} labels');
      debugPrint('First 5 labels: ${labelsList.take(5).join(", ")}');

      final initData = IsolateInitData(
        modelBytes.buffer.asUint8List(),
        labelsData,
        _receivePort.sendPort,
      );

      _isolate = await Isolate.spawn(_inferenceIsolate, initData);
      debugPrint('Isolate spawned successfully');
      
      _receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          debugPrint('SendPort received from isolate');
        } else if (message is String && message.startsWith('DEBUG:')) {
          debugPrint('Isolate: $message');
        } else if (message is List<String>) {
          debugPrint('Received detections: $message');
          if (mounted) {
            final currentObjects = message.toSet();
            String narration;
            if (currentObjects.isEmpty) {
              narration = "Point at your surroundings...";
            } else {
              narration = "I see: ${currentObjects.join(', ')}";
            }
            setState(() => _narrationText = narration);
            
            if (!const SetEquality().equals(currentObjects, _lastSpokenObjects)) {
              _lastSpokenObjects = currentObjects;
              if (currentObjects.isNotEmpty) {
                _speak(narration);
              }
            }
          }
        }
        _isProcessing = false;
      });
    } catch (e) {
      debugPrint('Error starting inference: $e');
      if (mounted) {
        setState(() => _narrationText = "Failed to load model: $e");
        _speak("Failed to load model");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Virtual Eye'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Debug Info'),
                  content: Text('Camera: $_isCameraInitialized\n'
                      'Processing: $_isProcessing\n'
                      'SendPort: ${_sendPort != null}\n'
                      'Last spoken: ${_lastSpokenObjects.join(", ")}'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
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
                child: _isCameraInitialized && 
                       _cameraController != null && 
                       _cameraController!.value.isInitialized
                    ? CameraPreview(_cameraController!)
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Initializing camera...', 
                              style: TextStyle(color: Colors.white)),
                        ],
                      ),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              width: double.infinity,
              color: Colors.blueGrey[900],
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    _narrationText,
                    style: const TextStyle(
                      color: Colors.white, 
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Data structure to pass initial data to the isolate
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

// Isolate for running inference
void _inferenceIsolate(IsolateInitData initData) async {
  final port = ReceivePort();
  initData.sendPort.send(port.sendPort);
  
  initData.sendPort.send('DEBUG: Isolate started');

  try {
    final interpreterOptions = InterpreterOptions();
    if (Platform.isAndroid) {
      interpreterOptions.addDelegate(XNNPackDelegate());
      initData.sendPort.send('DEBUG: Using XNNPack delegate');
    }

    final interpreter = Interpreter.fromBuffer(
      initData.modelBytes, 
      options: interpreterOptions
    );
    
    initData.sendPort.send('DEBUG: Interpreter created');
    initData.sendPort.send('DEBUG: Input shape: ${interpreter.getInputTensor(0).shape}');
    initData.sendPort.send('DEBUG: Output tensors: ${interpreter.getOutputTensors().length}');
    
    final labels = initData.labelsData
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    
    initData.sendPort.send('DEBUG: ${labels.length} labels loaded');
    
    const priority = {
      'person': 10, 
      'car': 5, 
      'bus': 5, 
      'truck': 5,
      'bicycle': 4, 
      'motorcycle': 4,
      'dog': 3, 
      'cat': 3,
      'chair': 2,
      'bottle': 2,
    };
    const topK = 5;
    const confidenceThreshold = 0.3; // Lowered threshold

    int frameCount = 0;
    await for (final CameraImage image in port) {
      frameCount++;
      try {
        final input = _prepareInput(image);
        if (input == null) {
          initData.sendPort.send('DEBUG: Failed to prepare input');
          continue;
        }
        
        // Reshape input to [1, 300, 300, 3] with normalization
        final reshapedInput = [
          List.generate(300, (y) => List.generate(300, (x) {
            final index = (y * 300 + x) * 3;
            return [
              (input[index] - 127.5) / 127.5,
              (input[index + 1] - 127.5) / 127.5,
              (input[index + 2] - 127.5) / 127.5,
            ];
          }))
        ];

        // Prepare output buffers
        final output = {
          0: [List.generate(10, (_) => List.filled(4, 0.0))], // Bounding boxes
          1: [List.filled(10, 0.0)],                           // Classes
          2: [List.filled(10, 0.0)],                           // Scores
          3: [0.0],                                            // Number of detections
        };

        interpreter.runForMultipleInputs([reshapedInput], output);
        
        final numDetections = (output[3]![0] as double).toInt();
        final scores = (output[2]![0] as List<dynamic>).cast<double>();
        final classes = (output[1]![0] as List<dynamic>).cast<double>();
        
        // Log every 30th frame
        if (frameCount % 30 == 0) {
          initData.sendPort.send('DEBUG: Frame $frameCount - Detections: $numDetections');
          var topScores = <String>[];
          for (int i = 0; i < scores.length.clamp(0, 5); i++) {
            if (classes[i].toInt() < labels.length) {
              topScores.add('${labels[classes[i].toInt()]}: ${scores[i].toStringAsFixed(2)}');
            }
          }
          initData.sendPort.send('DEBUG: Top scores: ${topScores.join(", ")}');
        }

        List<Detection> detections = [];
        for (int i = 0; i < scores.length; i++) {
          if (scores[i] > confidenceThreshold) {
            final classIndex = classes[i].toInt();
            if (classIndex < labels.length && classIndex >= 0) {
              final label = labels[classIndex].trim();
              if (label.isNotEmpty) {
                detections.add(Detection(label, scores[i]));
              }
            }
          }
        }

        detections.sort((a, b) {
          final priorityA = priority[a.label] ?? 0;
          final priorityB = priority[b.label] ?? 0;
          if (priorityA != priorityB) {
            return priorityB.compareTo(priorityA);
          }
          return b.score.compareTo(a.score);
        });

        final topDetections = detections
            .map((d) => d.label)
            .toSet()
            .take(topK)
            .toList();
            
        initData.sendPort.send(topDetections);

      } catch (e) {
        initData.sendPort.send('DEBUG: Inference error: $e');
        initData.sendPort.send([]);
      }
    }
  } catch (e) {
    initData.sendPort.send('DEBUG: Isolate initialization error: $e');
  }
}

// Prepare input image
Uint8List? _prepareInput(CameraImage image) {
  const modelInputSize = 300;
  img.Image? convertedImage = _convertYUV420ToImage(image);
  if (convertedImage == null) return null;

  final resizedImage = img.copyResize(
    convertedImage, 
    width: modelInputSize, 
    height: modelInputSize,
    interpolation: img.Interpolation.linear,
  );
  return resizedImage.toUint8List();
}

// Convert YUV420 to RGB
img.Image? _convertYUV420ToImage(CameraImage image) {
  try {
    final int width = image.width;
    final int height = image.height;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int? uvPixelStride = image.planes[1].bytesPerPixel;

    if (uvPixelStride == null) return null;

    final imageBytes = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvPixelStride * (x >> 1) + uvRowStride * (y >> 1);
        final int index = y * width + x;

        final yp = image.planes[0].bytes[index];
        final up = image.planes[1].bytes[uvIndex];
        final vp = image.planes[2].bytes[uvIndex];

        int r = (yp + 1.13983 * (vp - 128)).toInt().clamp(0, 255);
        int g = (yp - 0.39465 * (up - 128) - 0.58060 * (vp - 128)).toInt().clamp(0, 255);
        int b = (yp + 2.03211 * (up - 128)).toInt().clamp(0, 255);
        
        imageBytes.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return imageBytes;
  } catch (e) {
    debugPrint("Error converting YUV image: $e");
    return null;
  }
}