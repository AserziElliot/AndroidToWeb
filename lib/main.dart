import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:permission_handler/permission_handler.dart';
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
    'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]
  };

  @override
  void initState() {
    super.initState();
    _requestInitialPermissions();
  }

  Future<void> _requestInitialPermissions() async {
    await [Permission.camera, Permission.microphone].request();
  }

  Future<void> _startScreenCast() async {
    final String salaIntroducida = _codeController.text.trim();
    if (salaIntroducida.isEmpty) {
      _showError('Por favor, introduce el código de la sala web');
      return;
    }

    setState(() { _status = 'connecting'; });

    try {
      // PASO A: CONECTAR PRIMERO AL SERVIDOR PARA COMPROBAR LA DISPONIBILIDAD
      final serverUrl = 'wss://androidtowebbutrenderrn.onrender.com'; 
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      // Enviar solicitud de verificación de sala
      _channel!.sink.add(jsonEncode({
        'type': 'check_room',
        'room': salaIntroducida
      }));

      // Escuchar la respuesta del servidor antes de activar Android
      _channel!.stream.listen((message) async {
        var data = jsonDecode(message);

        // Verificación de disponibilidad de la sala
        if (data['type'] == 'room_status') {
          bool salaExiste = data['valid'] ?? false;
          
          if (!salaExiste) {
            _stopScreenCast();
            _showError('La sala web $salaIntroducida no está activa. Abre la web primero.');
            return;
          }

          // PASO B: LA SALA EXISTE -> AHORA SÍ RESERVAMOS CAPTURA DE PANTALLA NATIVA
          try {
            final Map<String, dynamic> mediaConstraints = {'audio': false, 'video': true};
            _localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);

            if (_localStream == null) {
              _stopScreenCast();
              return;
            }

            // PASO C: CONFIGURAR EL PEER WEBRTC DIRECTO
            _peerConnection = await createPeerConnection(_rtcConfig);
            _localStream!.getTracks().forEach((track) {
              _peerConnection!.addTrack(track, _localStream!);
            });

            _peerConnection!.onIceCandidate = (candidate) {
              _channel!.sink.add(jsonEncode({
                'type': 'candidate',
                'room': salaIntroducida,
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
              }));
            };

            RTCSessionDescription offer = await _peerConnection!.createOffer();
            await _peerConnection!.setLocalDescription(offer);

            _channel!.sink.add(jsonEncode({
              'type': 'offer',
              'room': salaIntroducida,
              'sdp': offer.sdp,
            }));

          } catch (e) {
            _stopScreenCast();
            _showError('Android denegó o falló la captura de pantalla.');
          }
          return;
        }

        // Procesar la respuesta SDP (Answer) de la web si todo va bien
        if (data['type'] == 'answer') {
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
          setState(() { _status = 'casting'; });
        } else if (data['type'] == 'candidate') {
          await _peerConnection?.addCandidate(
            RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']),
          );
        }
      }, onError: (error) {
        _stopScreenCast();
        _showError('Error de conexión con Render.');
      }, onDone: () {
        _stopScreenCast();
      });

    } catch (e) {
      _stopScreenCast();
      _showError('No se pudo conectar al servidor.');
    }
  }

  void _stopScreenCast() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.close();
    _channel?.sink.close();
    setState(() { _status = 'idle'; _localStream = null; _peerConnection = null; _channel = null; });
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
      appBar: AppBar(title: const Text('Android Screen Caster'), centerTitle: true, backgroundColor: Colors.transparent, elevation: 0),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(_status == 'casting' ? Icons.portable_wifi_off : Icons.screen_share, size: 80, color: _status == 'casting' ? Colors.greenAccent : Colors.blueAccent),
            const SizedBox(height: 20),
            Text(
              _status == 'idle' ? 'Listo para transmitir' : (_status == 'connecting' ? 'Verificando sala web...' : '¡Transmitiendo Pantalla!'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 40),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, letterSpacing: 4, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Código de la Sala Web',
                hintText: '0000',
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
              ),
              enabled: _status == 'idle',
            ),
            const SizedBox(height: 25),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _status != 'idle' ? Colors.redAccent : Colors.blueAccent, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
              onPressed: _status == 'connecting' ? null : (_status == 'casting' ? _stopScreenCast : _startScreenCast),
              child: _status == 'connecting'
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(_status == 'casting' ? 'DETENER EMISIÓN' : 'EMPEZAR A COMPARTIR', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
