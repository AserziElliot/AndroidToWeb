import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
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
  
  // Estados de la conexión: 'idle' (libre), 'connecting' (conectando), 'casting' (transmitiendo)
  String _status = 'idle'; 
  final TextEditingController _codeController = TextEditingController();

  // Servidores STUN públicos de Google para establecer la conexión P2P
  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ]
  };

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
      // 1. Conexión al servidor de señalización de tu web estática
      // REEMPLAZA ESTA URL CON TU SERVIDOR DE WEBSOCKETS (ej: de Render, Heroku o tu IP local)
      final serverUrl = 'wss://tu-servidor-signaling.onrender.com'; 
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      // 2. Crear la conexión WebRTC Peer antes de capturar pantalla
      _peerConnection = await createPeerConnection(_rtcConfig);

      // Escuchar las respuestas (SDP Answer y Candidatos ICE) desde la web receptora
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

      // 3. Solicitar permiso nativo de Android para capturar pantalla completa
      final Map<String, dynamic> mediaConstraints = {
        'audio': true, // Captura también el audio interno del dispositivo si Android lo permite
        'video': {
          'mandatory': {
            'minWidth': '1280', // Resolución HD para que se vea nítido en la web
            'minHeight': '720',
            'minFrameRate': '30',
          },
          'optional': [],
        }
      };

      _localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);

      // 4. Inyectar el vídeo de la pantalla dentro de la conexión WebRTC
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      // Intercambiar datos de red (ICE Candidates) con la web
      _peerConnection!.onIceCandidate = (candidate) {
        _channel!.sink.add(jsonEncode({
          'type': 'candidate',
          'room': _codeController.text.trim(),
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }));
      };

      // 5. Crear la oferta de transmisión (SDP Offer) y enviarla a la web
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
        padding: const EdgeInsets.symmetric(horizontal: 30.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Icono de estado dinámico
            Icon(
              _status == 'casting' ? Icons.portable_wifi_off_rounded : Icons.screen_share_rounded,
              size: 100,
              color: _status == 'casting' ? Colors.greenAccent : (_status == 'connecting' ? Colors.orangeAccent : Colors.blueAccent),
            ),
            const SizedBox(height: 30),
            
            // Texto indicador de estado
            Text(
              _status == 'casting' 
                  ? 'TRANSMITIENDO PANTALLA...' 
                  : (_status == 'connecting' ? 'CONECTANDO CON LA WEB...' : 'LISTO PARA EMITIR'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18, 
                fontWeight: FontWeight.bold,
                color: _status == 'casting' ? Colors.greenAccent : Colors.white70
              ),
            ),
            const SizedBox(height: 40),

            // Input del código de sala
            TextField(
              controller: _codeController,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, letterSpacing: 2),
              decoration: InputDecoration(
                hintText: 'CÓDIGO WEB',
                hintStyle: const TextStyle(fontSize: 16, color: Colors.white30),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
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
