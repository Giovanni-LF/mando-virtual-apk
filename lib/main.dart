import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Skins visuales disponibles para el modo carreras.
enum SkinId { carbon, hitech, arcade, retro }

class SkinPreset {
  const SkinPreset({
    required this.id,
    required this.name,
    required this.bgCenter,
    required this.bgEdge,
    required this.accent,
    required this.accentDim,
    required this.danger,
    required this.success,
    required this.muted,
    required this.grid,
    required this.fontFamily,
  });

  final SkinId id;
  final String name;
  final Color bgCenter;
  final Color bgEdge;
  final Color accent;
  final Color accentDim;
  final Color danger;
  final Color success;
  final Color muted;
  final Color grid;
  final String fontFamily;
}

const List<SkinPreset> kSkins = <SkinPreset>[
  SkinPreset(
    id: SkinId.carbon,
    name: 'Carbono',
    bgCenter: Color(0xFF0C2A3E),
    bgEdge: Color(0xFF050A11),
    accent: Color(0xFF00E5FF),
    accentDim: Color(0xFF007ACC),
    danger: Color(0xFFFF5252),
    success: Color(0xFF4CAF50),
    muted: Color(0x99FFFFFF),
    grid: Color(0x0A00E5FF),
    fontFamily: 'Rajdhani',
  ),
  SkinPreset(
    id: SkinId.hitech,
    name: 'Hi‑Tech',
    bgCenter: Color(0xFF141A3A),
    bgEdge: Color(0xFF050716),
    accent: Color(0xFF7C4DFF),
    accentDim: Color(0xFF2962FF),
    danger: Color(0xFFFF4081),
    success: Color(0xFF00E676),
    muted: Color(0xAA9EADFF),
    grid: Color(0x147C4DFF),
    fontFamily: 'Audiowide',
  ),
  SkinPreset(
    id: SkinId.arcade,
    name: 'Arcade',
    bgCenter: Color(0xFF3A1233),
    bgEdge: Color(0xFF120510),
    accent: Color(0xFFFFD740),
    accentDim: Color(0xFFFF6D00),
    danger: Color(0xFFFF1744),
    success: Color(0xFF64DD17),
    muted: Color(0xBBFFE0B2),
    grid: Color(0x12FFD740),
    fontFamily: 'Audiowide',
  ),
  SkinPreset(
    id: SkinId.retro,
    name: 'Retro',
    bgCenter: Color(0xFF14300F),
    bgEdge: Color(0xFF030803),
    accent: Color(0xFFFFB300),
    accentDim: Color(0xFF9E9D24),
    danger: Color(0xFFFF3D00),
    success: Color(0xFF76FF03),
    muted: Color(0xAAFFE082),
    grid: Color(0x10FFB300),
    fontFamily: 'ShareTechMono',
  ),
];

SkinPreset skinOf(SkinId id) => kSkins.firstWhere((s) => s.id == id);

void main() {
  runApp(const MandoApp());
}

class MandoApp extends StatelessWidget {
  const MandoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mando Virtual',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF007ACC),
        brightness: Brightness.dark,
      ),
      home: const MandoHome(),
    );
  }
}

class MandoHome extends StatefulWidget {
  const MandoHome({super.key});

  @override
  State<MandoHome> createState() => _MandoHomeState();
}

class _MandoHomeState extends State<MandoHome> {
  final TextEditingController _urlController =
      TextEditingController(text: 'ws://192.168.0.104:8765/ws');

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _serverSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  Timer? _ticker;

  bool _connected = false;

  // --- Giroscopio (inclinación absoluta) ---
  bool _gyro = false;
  bool _gyroReady = false;
  double _gyroZero = 0;
  double _gyroSmoothed = 0;
  double _gyroRange = 30;      // grados para llegar al extremo
  double _gyroSmoothing = 0.2; // filtro paso bajo
  bool _gyroInvert = false;

  // --- Perfil / UI ---
  String _profile = '0';
  String _template = 'xbox';
  double _controlScale = 1.0;
  bool _racingUi = false;
  SkinId _skin = SkinId.carbon;

  int _seq = 0;
  int _buttons = 0;
  double _lx = 0, _ly = 0, _rx = 0, _ry = 0, _lt = 0, _rt = 0;

  // HUD con datos reales
  int _gear = 0;
  int _packetsSent = 0;
  int _pps = 0;
  Timer? _ppsTimer;

  // Arrastre del volante táctil
  int? _wheelPointer;
  double _wheelStartX = 0;
  double _wheelStartValue = 0;

  double _deadzone = 0.05;
  double _sensitivity = 1.0;
  double _linearity = 1.0;

  final List<String> _log = <String>[];

  static const Map<String, String> _templateProfiles = <String, String>{
    'xbox': '0',
    'driving': '1',
    'platform': '0',
    'flight': '2',
    'custom': '1',
  };

  static const Map<String, String> _profileOptions = <String, String>{
    '0': 'Xbox 360',
    '1': 'Volante',
    '2': 'Yoke',
    '3': 'Teclado/Ratón',
  };

  static const Map<String, String> _templateOptions = <String, String>{
    'xbox': 'Mando',
    'driving': 'Conducción',
    'platform': 'Plataformas',
    'flight': 'Vuelo',
    'custom': 'Personalizada',
  };

  /// Valor que se dibuja en el volante: salida del giroscopio o eje táctil.
  double get _wheelValue => _gyro ? _gyroSmoothed : _lx;

  SkinPreset get _skinPreset => skinOf(_skin);

  @override
  void dispose() {
    _ticker?.cancel();
    _ppsTimer?.cancel();
    _accelSub?.cancel();
    _serverSub?.cancel();
    _channel?.sink.close();
    _urlController.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _logLine(String msg) {
    if (!mounted) return;
    final time = DateTime.now().toLocal().toString().split('.').first;
    setState(() {
      _log.insert(0, '$time $msg');
      if (_log.length > 8) _log.removeLast();
    });
  }

  double _clamp(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);

  double _calAxis(double raw) {
    if (raw.abs() < _deadzone) return 0;
    double a = (raw.abs() - _deadzone) / (1 - _deadzone);
    if (_linearity != 1) a = math.pow(a, 1 / _linearity).toDouble();
    a *= _sensitivity;
    return _clamp(raw < 0 ? -a : a, -1, 1);
  }

  double _calTrigger(double raw) {
    if (raw < _deadzone) return 0;
    final a = (raw - _deadzone) / (1 - _deadzone) * _sensitivity;
    return _clamp(a, 0, 1);
  }

  void _setButton(int bit, bool pressed) {
    setState(() {
      if (pressed) {
        _buttons |= 1 << bit;
      } else {
        _buttons &= ~(1 << bit);
      }
    });
  }

  void _setAxis(String axis, double value) {
    setState(() {
      switch (axis) {
        case 'lx':
          _lx = value;
          break;
        case 'ly':
          _ly = value;
          break;
        case 'rx':
          _rx = value;
          break;
        case 'ry':
          _ry = value;
          break;
        case 'lt':
          _lt = value;
          break;
        case 'rt':
          _rt = value;
          break;
      }
    });
  }

  double _axisValue(String axis) {
    switch (axis) {
      case 'lx':
        return _lx;
      case 'ly':
        return _ly;
      case 'rx':
        return _rx;
      case 'ry':
        return _ry;
      case 'lt':
        return _lt;
      case 'rt':
        return _rt;
      default:
        return 0;
    }
  }

  // ---------- Giroscopio ----------

  void _stopGyro({bool log = true}) {
    _accelSub?.cancel();
    _accelSub = null;
    final changed = _gyro || _gyroReady || _gyroSmoothed != 0;
    if (mounted) {
      setState(() {
        _gyro = false;
        _gyroReady = false;
        _gyroSmoothed = 0;
      });
    } else {
      _gyro = false;
      _gyroReady = false;
      _gyroSmoothed = 0;
    }
    if (log && changed) _logLine('Giroscopio desactivado');
  }

  void _centerGyro() {
    if (!_gyro) {
      _logLine('Activa el giroscopio primero');
      return;
    }
    setState(() {
      _gyroReady = false;
      _gyroSmoothed = 0;
    });
    _logLine('Giroscopio centrado');
  }

  void _toggleGyro() {
    if (_gyro) {
      _stopGyro();
      return;
    }

    _gyroReady = false;
    _gyroSmoothed = 0;

    _accelSub = accelerometerEventStream().listen((AccelerometerEvent e) {
      if (!_gyro) return;

      // Con el móvil casi plano el ángulo es inestable: ignoramos esos eventos.
      if (math.sqrt(e.x * e.x + e.y * e.y) < 2.0) return;

      final angle = math.atan2(e.x, e.y);
      if (!_gyroReady) {
        _gyroZero = angle;
        _gyroReady = true;
      }

      var delta = angle - _gyroZero;
      delta = math.atan2(math.sin(delta), math.cos(delta));

      // En apaisado de pie el signo va al revés; lo invertimos por defecto.
      var target = _clamp((-delta * 180 / math.pi) / _gyroRange, -1, 1);
      if (_gyroInvert) target = -target;
      if (target.abs() < _deadzone) target = 0;

      // Filtro paso bajo: quita saltos sin añadir retraso excesivo.
      _gyroSmoothed += (target - _gyroSmoothed) * _gyroSmoothing;
      if (mounted) setState(() {});
    }, onError: (Object e) {
      _logLine('Sensor no disponible: $e');
      _stopGyro(log: false);
    });

    setState(() => _gyro = true);
    _logLine('Giroscopio activado (inclinación)');
  }

  // ---------- Conexión ----------

  void _connect() {
    final text = _urlController.text.trim();
    Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (e) {
      _logLine('URL inválida: $e');
      return;
    }
    if (!uri.hasScheme || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      _logLine('La URL debe empezar por ws:// o wss://');
      return;
    }

    _disconnectLocal();

    try {
      _channel = WebSocketChannel.connect(uri);
      _serverSub = _channel!.stream.listen(
        _onServerMessage,
        onError: (Object error) {
          _logLine('Error WebSocket: $error');
          _markDisconnected();
        },
        onDone: () {
          _logLine('Servidor cerró la conexión');
          _markDisconnected();
        },
      );
      setState(() => _connected = true);
      _logLine('Conectado a $uri');
      _sendProfile();
      _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
        _sendPacket();
      });
      _ppsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          _pps = _packetsSent;
          _packetsSent = 0;
        });
      });
    } catch (e) {
      _logLine('No se pudo conectar: $e');
      _markDisconnected();
    }
  }

  void _disconnectLocal() {
    _ticker?.cancel();
    _ticker = null;
    _ppsTimer?.cancel();
    _ppsTimer = null;
    _pps = 0;
    _packetsSent = 0;
    _stopGyro(log: false);
    _serverSub?.cancel();
    _serverSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _markDisconnected() {
    _disconnectLocal();
    if (!mounted) return;
    setState(() => _connected = false);
  }

  void _disconnect() {
    _disconnectLocal();
    setState(() => _connected = false);
    _logLine('Desconectado manualmente');
  }

  void _onServerMessage(dynamic data) {
    if (data is String) {
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        if (msg['cmd'] == 'set_profile' && msg['profile_id'] != null) {
          final newProfile = msg['profile_id'].toString();
          setState(() => _profile = newProfile);
          if (newProfile != '1') _stopGyro(log: false);
          _logLine('Perfil cambiado desde el panel: $newProfile');
        }
      } catch (_) {}
    } else {
      _logLine('Mensaje binario recibido');
    }
  }

  void _sendProfile() {
    final ch = _channel;
    if (ch == null) return;
    final data = ByteData(10);
    data.setUint8(0, 0x4d);
    data.setUint8(1, 0x56);
    data.setUint8(2, 0x47);
    data.setUint8(3, 0x50);
    data.setUint32(4, _seq++ & 0xffffffff, Endian.little);
    data.setUint8(8, 0x02);
    data.setUint8(9, int.tryParse(_profile) ?? 0);
    ch.sink.add(data.buffer.asUint8List());
  }

  void _sendPacket() {
    final ch = _channel;
    if (ch == null || !_connected) return;
    final data = ByteData(35);
    data.setUint8(0, 0x4d);
    data.setUint8(1, 0x56);
    data.setUint8(2, 0x47);
    data.setUint8(3, 0x50);
    data.setUint32(4, _seq++ & 0xffffffff, Endian.little);
    data.setUint8(8, 0x01);
    data.setUint16(9, _buttons & 0xffff, Endian.little);

    // El giroscopio ya entrega un valor calibrado: NO aplicar _calAxis otra vez.
    data.setFloat32(11, _gyro ? _gyroSmoothed : _calAxis(_lx), Endian.little);
    data.setFloat32(15, _calAxis(_ly), Endian.little);
    data.setFloat32(19, _calAxis(_rx), Endian.little);
    data.setFloat32(23, _calAxis(_ry), Endian.little);
    data.setFloat32(27, _calTrigger(_lt), Endian.little);
    data.setFloat32(31, _calTrigger(_rt), Endian.little);
    ch.sink.add(data.buffer.asUint8List());
    _packetsSent++;
  }

  void _changeProfile(String value) {
    setState(() => _profile = value);
    if (value != '1') _stopGyro(log: false);
    if (_connected) _sendProfile();
  }

  void _applyTemplate(String id) {
    final profile = _templateProfiles[id];
    final scale = id == 'platform'
        ? 1.15
        : id == 'flight'
            ? 0.9
            : 1.0;
    setState(() {
      _template = id;
      _controlScale = scale;
      if (profile != null) _profile = profile;
    });
    if (profile != null && profile != '1') _stopGyro(log: false);
    if (_connected) _sendProfile();
    _logLine('Plantilla: $id');
  }

  void _syncRacingUi(bool racing) {
    if (_racingUi == racing) return;
    _racingUi = racing;
    SystemChrome.setPreferredOrientations(
      racing
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : DeviceOrientation.values,
    );
    SystemChrome.setEnabledSystemUIMode(
      racing ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final racing = _connected && _profile == '1';
    _syncRacingUi(racing);

    if (racing) return _buildRacingScaffold();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mando Virtual'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Chip(
              avatar: Icon(
                _connected ? Icons.wifi : Icons.wifi_off,
                size: 15,
              ),
              label: Text(_connected ? 'Conectado' : 'Desconectado'),
              backgroundColor:
                  _connected ? Colors.green.shade900 : Colors.red.shade900,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!_connected) _buildConnectCard(),
              if (_connected) _buildConnectedControls(),
              const SizedBox(height: 10),
              _buildCalibrationCard(),
              const SizedBox(height: 10),
              _buildLogCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRacingScaffold() {
    return Scaffold(
      backgroundColor: _skinPreset.bgEdge,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _RacingBackgroundPainter(skin: _skin)),
          ),
          Positioned.fill(child: _buildRacingLayout()),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  children: [
                    _glassChip(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wifi,
                              size: 14, color: _skinPreset.success),
                          const SizedBox(width: 5),
                          Text('EN LÍNEA',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: _skinPreset.fontFamily,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2)),
                        ],
                      ),
                      borderColor: _skinPreset.success,
                    ),
                    const SizedBox(width: 6),
                    _glassChip(
                      child: Text('$_pps PPS',
                          style: TextStyle(
                              fontSize: 11,
                              fontFamily: _skinPreset.fontFamily,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                              color: _skinPreset.accent)),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Ajustes',
                      icon: const Icon(Icons.settings, color: Colors.white70),
                      onPressed: _openSettings,
                    ),
                    IconButton(
                      tooltip: 'Desconectar',
                      icon: const Icon(Icons.power_settings_new,
                          color: Colors.redAccent),
                      onPressed: _disconnect,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassChip({
    required Widget child,
    Color? borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: borderColor ?? Colors.white.withValues(alpha: 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 8,
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildRacingLayout() {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      // El volante debe dejar espacio para los botones de gyro/centrar
      // y caber en pantallas apaisadas de ~360 dp de alto.
      final wheelSize = math.min(w * 0.36, h * 0.58);

      // Sin SafeArea aquí: aprovechamos todo el ancho y evitamos la franja
      // negra del recorte de pantalla. El overlay superior ya tiene SafeArea.
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 46, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: wheelSize,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildTouchWheel(wheelSize),
                  const SizedBox(height: 10),
                  _HoldButton(
                    label: _gyro ? 'GYRO ON' : 'GYRO OFF',
                    icon: Icons.rotate_right,
                    color: _gyro ? _skinPreset.success : Colors.grey,
                    width: wheelSize,
                    height: 42,
                    skin: _skin,
                    onDown: _toggleGyro,
                    onUp: () {},
                  ),
                  const SizedBox(height: 6),
                  _HoldButton(
                    label: 'CENTRAR',
                    icon: Icons.center_focus_strong,
                    color: Colors.orange,
                    width: wheelSize,
                    height: 38,
                    skin: _skin,
                    onDown: _centerGyro,
                    onUp: () {},
                  ),
                ],
              ),
            ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _roundGear('+', 4, Colors.cyan, shift: 1),
                    const SizedBox(height: 6),
                    _gearDisplay(),
                    const SizedBox(height: 6),
                    _roundGear('-', 5, Colors.cyan, shift: -1),
                    const SizedBox(height: 10),
                    _HoldButton(
                      label: 'F. MANO',
                      icon: Icons.pan_tool,
                      color: Colors.orange,
                      width: 60,
                      height: 60,
                      circular: true,
                      skin: _skin,
                      onDown: () => _setButton(1, true),
                      onUp: () => _setButton(1, false),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _pedal('FRENO', Icons.south, Colors.red, 'rx'),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _pedal('GAS', Icons.north, Colors.green, 'ly'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _HoldButton(
                      label: 'EMBRAGUE',
                      icon: Icons.alt_route,
                      color: Colors.purple,
                      width: double.infinity,
                      height: 42,
                      fill: _ry,
                      skin: _skin,
                      onDown: () => _setAxis('ry', 1),
                      onUp: () => _setAxis('ry', 0),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        _roundAction('A', 0, Colors.blue),
                        _roundAction('B', 1, Colors.red),
                        _roundAction('X', 2, Colors.green),
                        _roundAction('Y', 3, Colors.amber),
                        _roundAction('BACK', 6, Colors.grey),
                        _roundAction('START', 7, Colors.grey),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildTouchWheel(double size) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Listener(
          onPointerDown: (e) {
            if (_gyro) return;
            _wheelPointer = e.pointer;
            _wheelStartX = e.localPosition.dx;
            _wheelStartValue = _lx;
          },
          onPointerMove: (e) {
            if (_gyro || e.pointer != _wheelPointer) return;
            final dx = e.localPosition.dx - _wheelStartX;
            _setAxis('lx', _clamp(_wheelStartValue + dx / (size * 0.32), -1, 1));
          },
          onPointerUp: (e) {
            if (e.pointer == _wheelPointer) _wheelPointer = null;
          },
          onPointerCancel: (e) {
            if (e.pointer == _wheelPointer) _wheelPointer = null;
          },
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _WheelPainter(value: _wheelValue, skin: _skin),
            ),
          ),
        ),
        IgnorePointer(
          child: Text(
            '${(_wheelValue * 180).round()}°',
            style: TextStyle(
              color: _skinPreset.muted,
              fontFamily: _skinPreset.fontFamily,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _pedal(String label, IconData icon, Color color, String axis) {
    return _HoldButton(
      label: label,
      icon: icon,
      color: color,
      width: double.infinity,
      height: double.infinity,
      fill: _axisValue(axis),
      showScale: true,
      skin: _skin,
      onDown: () => _setAxis(axis, 1),
      onUp: () => _setAxis(axis, 0),
    );
  }

  Widget _roundGear(String label, int bit, Color color, {required int shift}) {
    return _HoldButton(
      label: label,
      color: color,
      width: 58,
      height: 58,
      circular: true,
      skin: _skin,
      onDown: () {
        _setButton(bit, true);
        setState(() {
          final next = _gear + shift;
          _gear = next < -1 ? -1 : (next > 6 ? 6 : next);
        });
      },
      onUp: () => _setButton(bit, false),
    );
  }

  Widget _gearDisplay() {
    return Container(
      width: 64,
      height: 66,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _skinPreset.accent.withValues(alpha: 0.16),
            _skinPreset.accent.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(_skin == SkinId.retro ? 4 : 12),
        border: Border.all(color: _skinPreset.accent, width: 1.5),
        boxShadow: _skin == SkinId.retro
            ? null
            : [
                BoxShadow(
                  color: _skinPreset.accent.withValues(alpha: 0.25),
                  blurRadius: 12,
                ),
              ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _gear < 0 ? 'R' : '$_gear',
            style: TextStyle(
              color: _skinPreset.accent,
              fontFamily: _skinPreset.fontFamily,
              fontSize: 30,
              fontWeight: FontWeight.bold,
              height: 1,
            ),
          ),
          const SizedBox(height: 3),
          Text('MARCHA',
              style: TextStyle(
                  color: _skinPreset.muted.withValues(alpha: 0.7),
                  fontFamily: _skinPreset.fontFamily,
                  fontSize: 8,
                  letterSpacing: 1.2)),
        ],
      ),
    );
  }

  Widget _roundAction(String label, int bit, Color color) {
    return _HoldButton(
      label: label,
      color: color,
      width: 44,
      height: 44,
      circular: true,
      skin: _skin,
      onDown: () => _setButton(bit, true),
      onUp: () => _setButton(bit, false),
    );
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101822),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ajustes',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _buildDropdown('Perfil', _profile, _profileOptions, _changeProfile),
              const SizedBox(height: 8),
              _buildDropdown(
                  'Plantilla', _template, _templateOptions, _applyTemplate),
              const SizedBox(height: 16),
              _buildSkinSelector(),
              const SizedBox(height: 16),
              _buildGyroSettings(),
              const SizedBox(height: 16),
              _buildCalibrationCard(),
              const SizedBox(height: 12),
              _buildLogCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSkinSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: const [
                Icon(Icons.palette, color: Color(0xFF00E5FF)),
                SizedBox(width: 8),
                Text('Skin del volante',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final preset in kSkins) _skinChip(preset)],
            ),
          ],
        ),
      ),
    );
  }

  Widget _skinChip(SkinPreset preset) {
    final active = preset.id == _skin;
    return GestureDetector(
      onTap: () => setState(() => _skin = preset.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: preset.bgEdge,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? preset.accent
                : preset.muted.withValues(alpha: 0.3),
            width: active ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CustomPaint(
                painter: _WheelPainter(value: 0.35, skin: preset.id),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              preset.name,
              style: TextStyle(
                color: active ? preset.accent : preset.muted,
                fontFamily: preset.fontFamily,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGyroSettings() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.rotate_right, color: Color(0xFF00E5FF)),
                const SizedBox(width: 8),
                const Text('Giroscopio',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Switch(value: _gyro, onChanged: (_) => _toggleGyro()),
              ],
            ),
            if (_gyro) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _centerGyro,
                      icon: const Icon(Icons.center_focus_strong, size: 16),
                      label: const Text('Centrar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () =>
                          setState(() => _gyroInvert = !_gyroInvert),
                      icon: const Icon(Icons.swap_horiz, size: 16),
                      label: Text(_gyroInvert ? 'Invertido' : 'Normal'),
                    ),
                  ),
                ],
              ),
              _buildSlider(
                'Rango (°)',
                _gyroRange,
                15,
                45,
                1,
                _gyroRange.round().toString(),
                (v) => setState(() => _gyroRange = v),
              ),
              _buildSlider(
                'Suavizado',
                _gyroSmoothing,
                0.05,
                0.6,
                0.05,
                _gyroSmoothing.toStringAsFixed(2),
                (v) => setState(() => _gyroSmoothing = v),
              ),
            ],
            const SizedBox(height: 4),
            Text('Ángulo: ${(_wheelValue * 180).round()}°',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Conectar al servidor',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'URL WebSocket',
                hintText: 'ws://192.168.0.104:8765/ws',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Conectar'),
            ),
            const SizedBox(height: 10),
            const Text(
              'La PC y el móvil deben estar en la misma Wi-Fi. El giroscopio '
              'nativo no necesita HTTPS.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: _buildDropdown(
                      'Perfil', _profile, _profileOptions, _changeProfile),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildDropdown('Plantilla', _template,
                      _templateOptions, _applyTemplate),
                ),
                IconButton(
                  tooltip: 'Desconectar',
                  onPressed: _disconnect,
                  icon: const Icon(Icons.power_settings_new, color: Colors.red),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: _profile == '0'
                ? _buildXboxLayout()
                : _profile == '3'
                    ? _buildKeyboardLayout()
                    : _buildClassicWheelLayout(),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown(
    String label,
    String value,
    Map<String, String> options,
    ValueChanged<String> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: options.entries
              .map((e) => DropdownMenuItem<String>(
                    value: e.key,
                    child: Text(e.value,
                        style: const TextStyle(fontSize: 13)),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }

  /// Layout clásico para el perfil Volante cuando no se usa la UI de carreras.
  Widget _buildClassicWheelLayout() {
    return Column(
      children: [
        _buildTouchWheel(180),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Giroscopio', style: TextStyle(fontSize: 12)),
            Switch(value: _gyro, onChanged: (_) => _toggleGyro()),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildAxisButton('Acelerar', 'ly'),
            _buildAxisButton('Frenar', 'rx'),
            _buildAxisButton('Embrague', 'ry'),
          ],
        ),
      ],
    );
  }

  Widget _buildXboxLayout() {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStick('lx', 'ly', 'Stick izq.'),
              _buildDpad(),
              _buildAbxy(),
              _buildStick('rx', 'ry', 'Stick der.'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildButton('Back', 6),
            _buildButton('Guide', 8),
            _buildButton('Start', 7),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildButton('LB', 4),
            _buildButton('RB', 5),
            _buildAxisButton('LT', 'lt'),
            _buildAxisButton('RT', 'rt'),
          ],
        ),
      ],
    );
  }

  Widget _buildStick(String axisX, String axisY, String label) {
    final size = 100.0 * _controlScale;
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        SizedBox(
          width: size,
          height: size,
          child: LayoutBuilder(builder: (context, constraints) {
            final s = constraints.maxWidth;
            return GestureDetector(
              onPanUpdate: (d) {
                final nx = _clamp((d.localPosition.dx - s / 2) / (s / 2), -1, 1);
                final ny = _clamp((d.localPosition.dy - s / 2) / (s / 2), -1, 1);
                _setAxis(axisX, nx);
                _setAxis(axisY, ny);
              },
              onPanEnd: (_) {
                _setAxis(axisX, 0);
                _setAxis(axisY, 0);
              },
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black38,
                  border: Border.all(color: Colors.grey.shade700, width: 2),
                ),
                child: Center(
                  child: Container(
                    width: s * 0.3,
                    height: s * 0.3,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF007ACC),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildDpad() {
    return Column(
      children: [
        const Text('D-pad', style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Column(
          children: [
            _buildButton('▲', 11, compact: true),
            Row(
              children: [
                _buildButton('◀', 13, compact: true),
                _buildButton('▼', 12, compact: true),
                _buildButton('▶', 14, compact: true),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAbxy() {
    return Column(
      children: [
        const Text('ABXY', style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Column(
          children: [
            _buildButton('Y', 3, compact: true),
            Row(
              children: [
                _buildButton('X', 2, compact: true),
                _buildButton('B', 1, compact: true),
              ],
            ),
            _buildButton('A', 0, compact: true),
          ],
        ),
      ],
    );
  }

  Widget _buildButton(String label, int bit, {bool compact = false}) {
    final size = (compact ? 42.0 : 54.0) * _controlScale;
    return GestureDetector(
      onTapDown: (_) => _setButton(bit, true),
      onTapUp: (_) => _setButton(bit, false),
      onTapCancel: () => _setButton(bit, false),
      child: Container(
        width: size,
        height: size,
        margin: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade600),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildAxisButton(String label, String axis) {
    return GestureDetector(
      onTapDown: (_) => _setAxis(axis, 1),
      onTapUp: (_) => _setAxis(axis, 0),
      onTapCancel: () => _setAxis(axis, 0),
      child: Container(
        width: 58 * _controlScale,
        height: 40 * _controlScale,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade600),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildKeyboardLayout() {
    return Column(
      children: [
        const Text('Ratón táctil', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        Container(
          width: 180,
          height: 180,
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade700, width: 2),
          ),
          child: GestureDetector(
            onPanUpdate: (d) {
              _setAxis('rx', _clamp(_rx + d.delta.dx / 100, -1, 1));
              _setAxis('ry', _clamp(_ry + d.delta.dy / 100, -1, 1));
            },
            onPanEnd: (_) {
              _setAxis('rx', 0);
              _setAxis('ry', 0);
            },
            child: const Center(child: Icon(Icons.mouse, size: 40)),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            _buildButton('W', 0, compact: true),
            _buildButton('S', 1, compact: true),
            _buildButton('A', 2, compact: true),
            _buildButton('D', 3, compact: true),
            _buildButton('Espacio', 4, compact: true),
            _buildButton('Shift', 5, compact: true),
            _buildButton('ESC', 6, compact: true),
            _buildButton('Enter', 7, compact: true),
          ],
        ),
      ],
    );
  }

  Widget _buildCalibrationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            _buildSlider(
              'Zona muerta',
              _deadzone,
              0,
              0.3,
              0.01,
              _deadzone.toStringAsFixed(2),
              (v) => setState(() => _deadzone = v),
            ),
            _buildSlider(
              'Sensibilidad',
              _sensitivity,
              0.5,
              2.0,
              0.1,
              _sensitivity.toStringAsFixed(1),
              (v) => setState(() => _sensitivity = v),
            ),
            _buildSlider(
              'Linealidad',
              _linearity,
              0.3,
              2.0,
              0.1,
              _linearity.toStringAsFixed(1),
              (v) => setState(() => _linearity = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(String label, double value, double min, double max,
      double step, String display, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
            width: 100, child: Text(label, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 38, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }

  Widget _buildLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Diagnóstico',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              _log.isEmpty ? 'Sin mensajes' : _log.join('\n'),
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botón mantenido con multi-touch real (un pointer distinto por dedo).
class _HoldButton extends StatefulWidget {
  const _HoldButton({
    required this.label,
    required this.color,
    required this.onDown,
    required this.onUp,
    this.icon,
    this.width = 60,
    this.height = 60,
    this.circular = false,
    this.fill,
    this.showScale = false,
    this.skin = SkinId.carbon,
  });

  final String label;
  final IconData? icon;
  final Color color;
  final double width;
  final double height;
  final bool circular;
  final VoidCallback onDown;
  final VoidCallback onUp;

  /// Si se indica, dibuja un relleno ascendente (para pedales).
  final double? fill;

  /// Dibuja marcas de escala y zona roja (solo pedales verticales).
  final bool showScale;

  /// Skin visual activo (forma, borde, tipografía y glow).
  final SkinId skin;

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  final Set<int> _pointers = <int>{};

  void _down(int pointer) {
    final first = _pointers.add(pointer) && _pointers.length == 1;
    if (first) {
      HapticFeedback.selectionClick();
      widget.onDown();
    }
    if (mounted) setState(() {});
  }

  void _up(int pointer) {
    final wasLast = _pointers.remove(pointer) && _pointers.isEmpty;
    if (wasLast) widget.onUp();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_pointers.isNotEmpty) widget.onUp();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pressed = _pointers.isNotEmpty;
    final s = skinOf(widget.skin);
    final retro = widget.skin == SkinId.retro;
    final arcade = widget.skin == SkinId.arcade;
    return Listener(
      onPointerDown: (e) => _down(e.pointer),
      onPointerUp: (e) => _up(e.pointer),
      onPointerCancel: (e) => _up(e.pointer),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        width: widget.width,
        height: widget.height,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              widget.color.withValues(
                  alpha: pressed ? 0.90 : arcade ? 0.50 : retro ? 0.26 : 0.34),
              widget.color.withValues(
                  alpha: pressed ? 0.55 : retro ? 0.10 : arcade ? 0.26 : 0.14),
            ],
          ),
          borderRadius: BorderRadius.circular(widget.circular
              ? math.min(widget.width, widget.height) / 2
              : retro
                  ? 4
                  : arcade
                      ? 24
                      : 16),
          border: Border.all(
            color: widget.color.withValues(alpha: pressed ? 1 : retro ? 0.85 : 0.55),
            width: pressed ? 3 : arcade ? 3 : retro ? 1 : 2,
          ),
          boxShadow: retro
              ? null
              : [
                  BoxShadow(
                    color: widget.color.withValues(
                        alpha: pressed ? 0.55 : arcade ? 0.28 : 0.15),
                    blurRadius: pressed ? 18 : arcade ? 14 : 8,
                  ),
                ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.fill != null)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: widget.fill!.clamp(0.0, 1.0).toDouble(),
                  child: SizedBox.expand(
                    child: ColoredBox(
                      color: widget.color.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            if (widget.showScale)
              Positioned.fill(
                child: CustomPaint(painter: _PedalScalePainter(skin: widget.skin)),
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null)
                  Icon(widget.icon, color: s.muted, size: arcade ? 26 : 22),
                Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: s.muted,
                    fontFamily: s.fontFamily,
                    fontSize: arcade ? 12 : 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Fondo del modo carreras: degradado radial, fibra de carbono y rejilla.
class _RacingBackgroundPainter extends CustomPainter {
  const _RacingBackgroundPainter({required this.skin});

  final SkinId skin;

  @override
  void paint(Canvas canvas, Size size) {
    final s = skinOf(skin);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.55),
          radius: 1.3,
          colors: [s.bgCenter, s.bgEdge],
        ).createShader(rect),
    );

    final carbon = Paint()
      ..color = s.accent.withValues(alpha: 0.03)
      ..strokeWidth = 12;
    for (double x = -size.height; x < size.width + size.height; x += 30) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        carbon,
      );
    }

    final grid = Paint()
      ..color = s.grid
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 52) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += 52) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.82, size.width, size.height * 0.18),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.center,
          colors: [
            s.accent.withValues(alpha: 0.20),
            s.accent.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );

    if (skin == SkinId.retro) {
      final scan = Paint()
        ..color = s.accent.withValues(alpha: 0.035)
        ..strokeWidth = 1;
      for (double y = 0; y < size.height; y += 4) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), scan);
      }
    }
  }

  @override
  bool shouldRepaint(_RacingBackgroundPainter old) => old.skin != skin;
}

/// Reglón con marcas y zona roja para los pedales verticales.
class _PedalScalePainter extends CustomPainter {
  const _PedalScalePainter({required this.skin});

  final SkinId skin;

  @override
  void paint(Canvas canvas, Size size) {
    final s = skinOf(skin);
    final x = size.width - 14;
    final top = size.height * 0.16;
    final bottom = size.height * 0.84;
    final h = bottom - top;
    if (h <= 0) return;

    canvas.drawRect(
      Rect.fromLTWH(x - 3, top, 6, h * 0.18),
      Paint()..color = s.danger.withValues(alpha: 0.75),
    );

    final tick = Paint()
      ..color = s.muted
      ..strokeWidth = skin == SkinId.arcade ? 2.5 : 1.5;
    for (var i = 0; i <= 10; i++) {
      final y = bottom - h * i / 10;
      final len = i % 5 == 0 ? 12.0 : 6.0;
      canvas.drawLine(Offset(x - len, y), Offset(x, y), tick);
    }
  }

  @override
  bool shouldRepaint(_PedalScalePainter old) => old.skin != skin;
}

/// Volante dibujado con Canvas: aro carbono, glow, arco, escala y cubo.
class _WheelPainter extends CustomPainter {
  const _WheelPainter({required this.value, required this.skin});

  final double value;
  final SkinId skin;

  @override
  void paint(Canvas canvas, Size size) {
    final s = skinOf(skin);
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 8;
    if (radius <= 0) return;

    final retro = skin == SkinId.retro;
    final arcade = skin == SkinId.arcade;
    final hitech = skin == SkinId.hitech;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = -math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final progress = sweep * ((value + 1) / 2);

    // Glow exterior del aro (el skin retro no lo usa)
    if (!retro) {
      canvas.drawCircle(
        center,
        radius * 0.96,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.22
          ..color = s.accent.withValues(alpha: arcade ? 0.28 : 0.16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    // Aro
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * (arcade ? 0.20 : hitech ? 0.12 : 0.16);
    if (retro) {
      rim.color = s.accentDim;
    } else {
      rim.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [s.bgCenter, s.accentDim],
      ).createShader(rect);
    }
    canvas.drawCircle(center, radius, rim);

    // Arco base
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.10
        ..strokeCap = StrokeCap.round
        ..color = s.muted.withValues(alpha: 0.22),
    );

    // Zonas rojas en los extremos (no en Hi‑Tech ni Retro)
    if (!hitech && !retro) {
      final red = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.10
        ..strokeCap = StrokeCap.round
        ..color = s.danger.withValues(alpha: 0.85);
      canvas.drawArc(rect, start, sweep * 0.10, false, red);
      canvas.drawArc(rect, start + sweep * 0.90, sweep * 0.10, false, red);
    }

    // Arco de giro con glow
    if (!retro) {
      canvas.drawArc(
        rect,
        start,
        progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.14
          ..strokeCap = StrokeCap.round
          ..color = s.accent.withValues(alpha: 0.40)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
    canvas.drawArc(
      rect,
      start,
      progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * (arcade ? 0.12 : 0.10)
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [s.accentDim, s.accent],
        ).createShader(rect),
    );

    // Marcas de escala
    final divisions = hitech ? 12 : arcade ? 5 : retro ? 8 : 6;
    final tick = Paint()
      ..color = s.muted
      ..strokeWidth = arcade ? 2.5 : 1.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= divisions; i++) {
      final a = start + sweep * i / divisions;
      final dir = Offset(math.cos(a), math.sin(a));
      final major = i % (hitech ? 3 : 2) == 0;
      final inner = major ? radius * 0.80 : radius * 0.86;
      canvas.drawLine(center + dir * inner, center + dir * (radius * 0.94), tick);
    }

    // Radios
    final spokes = arcade
        ? [0.0, math.pi / 2, math.pi, 3 * math.pi / 2]
        : retro
            ? [0.0, math.pi]
            : [0.0, math.pi, math.pi / 2];
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(value * math.pi * 0.75);
    final spoke = Paint()
      ..color = s.muted
      ..strokeWidth = radius * (arcade ? 0.08 : 0.06)
      ..strokeCap = StrokeCap.round;
    for (final a in spokes) {
      final dx = math.cos(a);
      final dy = math.sin(a);
      canvas.drawLine(
        Offset(dx * radius * 0.26, dy * radius * 0.26),
        Offset(dx * radius * 0.78, dy * radius * 0.78),
        spoke,
      );
    }
    canvas.restore();

    // Cubo
    canvas.drawCircle(
      center,
      radius * 0.26,
      Paint()..color = s.bgEdge,
    );
    canvas.drawCircle(
      center,
      radius * 0.26,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = s.accent,
    );
    canvas.drawCircle(center, radius * 0.05, Paint()..color = s.accent);
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.value != value || old.skin != skin;
}
