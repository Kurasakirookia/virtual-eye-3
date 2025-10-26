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

  bool _isIsolateReady = false;

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
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  void _speak(String text) async {
    await _flutterTts.stop();
    await _flutterTts.speak(text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort.close();
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
     _cameraController!.startImageStream((image) {
       if (!_isProcessing && _sendPort != null) {
         _isProcessing = true;
         final input = _prepareInput(image);
         if (input != null) {
           _sendPort!.send(input);
         } else {
           _isProcessing = false;
         }
       }
     });
  }

  void _startInference() async {
    debugPrint("[Main] Starting inference isolate setup...");
    try {
      final modelBytes = await rootBundle.load('assets/ssd_mobilenet.tflite');
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      debugPrint("[Main] Model and labels loaded from assets.");

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
          if (_isCameraInitialized) {
             _startStreaming();
          }
        } else if (message is List<String>) {
          if (mounted) {
            final currentObjects = message.toSet();
            String narration;
            if (currentObjects.isEmpty) {
              narration = "Point at your surroundings...";
            } else {
              narration = "I see: ${currentObjects.join(', ')}";
            }
            if (narration != _narrationText) {
                setState(() => _narrationText = narration);
            }
            if (!const SetEquality().equals(currentObjects, _lastSpokenObjects)) {
              _lastSpokenObjects = currentObjects;
              if (currentObjects.isNotEmpty) {
                _speak(narration);
              }
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
      if (mounted) setState(() => _narrationText = "Failed to load model.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Virtual Eye')),
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
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    _narrationText,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
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
    
    const priority = {'person': 10, 'car': 5, 'bus': 5, 'bicycle': 4, 'dog': 3, 'cat': 3};
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
         debugPrint("[Isolate] Top Scores: ${topDetectionsDebug.take(3).map((d) => '${d.label}: ${d.score.toStringAsFixed(2)}').join(', ')}");

         List<Detection> detections = [];
         for (int i = 0; i < scores.length; i++) {
           if (scores[i] > 0.5) { 
             final classIdx = classes[i].toInt();
             final labelIndex = classIdx - 1;
             if (labelIndex >= 0 && labelIndex < labels.length) {
               detections.add(Detection(labels[labelIndex], scores[i]));
             }
           }
         }

         detections.sort((a, b) {
           final priorityA = priority[a.label] ?? 0;
           final priorityB = priority[b.label] ?? 0;
           return priorityB.compareTo(priorityA);
         });

         final topDetections = detections.map((d) => d.label).toSet().take(topK).toList();
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