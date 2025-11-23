import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

// --- CONFIGURATION ---
// YOUR LAPTOP'S IP ADDRESS
const String SERVER_IP = '192.168.0.113'; 
const String SERVER_URL = 'http://$SERVER_IP:5000';

List<CameraDescription> cameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Error: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Virtual Eye Client',
      theme: ThemeData.dark(),
      home: const ClientScreen(),
    );
  }
}

class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key});

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  bool _isListening = false;
  String _statusText = "Tap to Speak";
  String _lastCommand = "";

  @override
  void initState() {
    super.initState();
    _initSystem();
  }

  Future<void> _initSystem() async {
    await _requestPermissions();
    await _initCamera();
    await _initTTS();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ].request();
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) return;
    _controller = CameraController(
      cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _initTTS() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.5);
  }

  Future<void> _speak(String text) async {
    await _tts.speak(text);
  }

  // --- 1. LISTEN FOR COMMAND ---
  void _startListening() async {
    bool available = await _speech.initialize(
      onStatus: (status) => print('Speech status: $status'),
      onError: (errorNotification) => print('Speech error: $errorNotification'),
    );

    if (available) {
      setState(() {
        _isListening = true;
        _statusText = "Listening...";
      });
      
      _speech.listen(onResult: (val) {
        setState(() {
          _lastCommand = val.recognizedWords;
        });
        
        if (val.finalResult) {
          _processCommand(_lastCommand.toLowerCase());
        }
      });
    } else {
      setState(() => _statusText = "Mic denied/unavailable");
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  // --- 2. PROCESS COMMAND ---
  void _processCommand(String command) async {
    _stopListening();
    setState(() => _statusText = "Processing: $command");

    // Route the command
    if (command.contains("what") || command.contains("describe") || command.contains("see")) {
      await _sendDescribeRequest();
    } else if (command.contains("take me") || command.contains("navigate")) {
      // Extract query (e.g., remove "take me to")
      String query = command.replaceAll("take me to", "").replaceAll("navigate to", "").trim();
      await _sendNavigationRequest(query);
    } else {
      _speak("I didn't understand that command.");
      setState(() => _statusText = "Unknown command");
    }
  }

  // --- 3. SEND TO SERVER (DESCRIBE) ---
  Future<void> _sendDescribeRequest() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      // Capture Image
      final image = await _controller!.takePicture();
      
      setState(() => _statusText = "Sending to Brain...");
      
      // Upload to Server
      var request = http.MultipartRequest('POST', Uri.parse('$SERVER_URL/describe_scene'));
      request.files.add(await http.MultipartFile.fromPath('image', image.path));
      
      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var json = jsonDecode(responseData);
        String narration = json['narration'];
        
        setState(() => _statusText = narration);
        _speak(narration);
      } else {
        _speak("Error reaching the brain.");
      }
    } catch (e) {
      _speak("Connection failed. Check laptop IP.");
      debugPrint(e.toString());
    }
  }

  // --- 4. SEND TO SERVER (NAVIGATE) ---
  Future<void> _sendNavigationRequest(String query) async {
    try {
      setState(() => _statusText = "Getting location...");
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      
      setState(() => _statusText = "Asking Brain...");
      
      var response = await http.post(
        Uri.parse('$SERVER_URL/start_navigation'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "query": query,
          "latitude": position.latitude,
          "longitude": position.longitude,
        }),
      );

      if (response.statusCode == 200) {
        var json = jsonDecode(response.body);
        String narration = json['narration'];
        setState(() => _statusText = narration);
        _speak(narration);
        
        // If it's a confirmation, you could add logic here to listen for "Yes"
      } else {
        _speak("Navigation error.");
      }
    } catch (e) {
      _speak("Connection failed.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Virtual Eye Client")),
      body: Column(
        children: [
          Expanded(
            child: _controller != null && _controller!.value.isInitialized
                ? CameraPreview(_controller!)
                : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            color: Colors.black87,
            width: double.infinity,
            child: Column(
              children: [
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: _startListening,
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: _isListening ? Colors.red : Colors.blue,
                    child: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text("Tap to Speak", style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}