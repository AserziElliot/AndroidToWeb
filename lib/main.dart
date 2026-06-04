import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:permission_handler/permission_handler.dart'; // <-- Nueva librería de control
import 'dart:convert';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WebCasterApp());
}

class WebCasterApp extends StatelessWidget {
  const WebCasterApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android Screen Caster',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const ScreenCastHome(),
    );
  }
}

class ScreenCastHome extends StatefulWidget {
  const ScreenCastHome({Key? key}) : super(key: key);

  @override
  State<ScreenCastHome> createState() => _ScreenCastHomeState();
}

class _ScreenCastHomeState extends State<ScreenCastHome> {
  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  WebSocketChannel? _channel;
  
  String _status = 'idle'; 
  final TextEditingController _codeController = TextEditingController();

  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]
  };

  @override
  void initState() {
    super.initState();
    _requestInitialPermissions(); // Pedir permisos amigablemente al abrir la app
  }

  // Función para asegurar que el móvil tiene los permisos base antes de emitir
  Future<void> _requestInitialPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
    ].request();
  }

  Future<void> _startScreenCast() async {
    if (_codeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, introduce el código de la sala web')),
      );
      return;
    }

    setState(() {
      _status = 'connecting';
    });

    try {
      // 1. SOLICITAR PERMISOS DE CAPTURA NATIVOS
      // Esto fuerza a Android a entender que somos una app legal pidiendo compartir pantalla
      final Map<String, dynamic> mediaConstraints = {
        'audio': false,
        'video': true
      };

      // Lanzar la captura nativa de pantalla
      _localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);

      if (_localStream == null) {
        _stopScreenCast();
        return;
      }

      // 2. CONECTAR AL SERVIDOR DE RENDER
      final serverUrl = 'wss://androidtowebbutrenderrn.onrender.com'; 
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      // 3. CONFIGURAR WEBRTC PEER CONNECTION
      _peerConnection = await createPeerConnection(_rtcConfig);

      // Añadir la pista de video de la pantalla a WebRTC
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      // Escuchar las respuestas de tu servidor en Render
      _channel!.stream.listen((message) async {
        var data = jsonDecode(message);
        
        if (data['type'] == 'answer') {
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
          setState(() {
            _status = 'casting';
          });
        } else if (data['type'] == 'candidate') {
          await _peerConnection?.addCandidate(
            RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']),
          );
        }
      }, onError: (error) {
        _stopScreenCast();
        _showError('Error de red: $error');
      }, onDone: () {
        _stopScreenCast();
      });

      // Enviar nuestros candidatos ICE hacia la web
      _peerConnection!.onIceCandidate = (candidate) {
        _channel!.sink.add(jsonEncode({
          'type': 'candidate',
          'room': _codeController.text.trim(),
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }));
      };

      // 4. CREAR LA OFERTA DE VIDEO
      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      _channel!.sink.add(jsonEncode({
        'type': 'offer',
        'room': _codeController.text.trim(),
        'sdp': offer.sdp,
      }));

    } catch (e) {
      _stopScreenCast();
      _showError('No se pudo iniciar la captura: $e');
    }
  }

  void _stopScreenCast() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.close();
    _channel?.sink.close();
    
    setState(() {
      _status = 'idle';
      _localStream = null;
      _peerConnection = null;
      _channel = null;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _stopScreenCast();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Android Screen Caster'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Estado visual
            Icon(
              _status == 'casting' ? Icons.portable_wifi_off : Icons.screen_share,
              size: 80,
              color: _status == 'casting' ? Colors.greenAccent : Colors.blueAccent,
            ),
            const SizedBox(height: 20),
            Text(
              _status == 'idle' 
                  ? 'Listo para transmitir' 
                  : (_status == 'connecting' ? 'Conectando con la Web...' : '¡Transmitiendo Pantalla!'),
              textAlign: center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 40),

            // Cuadro de texto para introducir la sala
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              textAlign: center,
              style: const TextStyle(fontSize: 22, letterSpacing: 4, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Código de la Sala Web',
                labelStyle: const TextStyle(fontSize: 14, letterSpacing: 0),
                hintText: '0000',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
                ),
              ),
              enabled: _status == 'idle',
            ),
            const SizedBox(height: 25),

            // Botón de acción principal
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _status != 'idle' ? Colors.redAccent : Colors.blueAccent,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              onPressed: _status == 'connecting' 
                  ? null 
                  : (_status == 'casting' ? _stopScreenCast : _startScreenCast),
              child: _status == 'connecting'
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : Text(
                      _status == 'casting' ? 'DETENER EMISIÓN' : 'EMPEZAR A COMPARTIR',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
