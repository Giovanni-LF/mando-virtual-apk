import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _ticker;

  bool _connected = false;
  bool _gyro = false;

  String _profile = '0';
  String _template = 'xbox';
  double _controlScale = 1.0;

  int _seq = 0;
  int _buttons = 0;
  double _lx = 0, _ly = 0, _rx = 0, _ry = 0, _lt = 0, _rt = 0;

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

  @override
  void dispose() {
    _ticker?.cancel();
    _gyroSub?.cancel();
    _serverSub?.cancel();
    _channel?.sink.close();
    _urlController.dispose();
    super.dispose();
  }

  void _logLine(String msg) {
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

  void _connect() {
    final text = _urlController.text.trim();
    Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (e) {
      _logLine('URL inválida: $e');
      return;
    }
    if (!uri.hasScheme ||
        (uri.scheme != 'ws' && uri.scheme != 'wss')) {
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
    } catch (e) {
      _logLine('No se pudo conectar: $e');
      _markDisconnected();
    }
  }

  void _disconnectLocal() {
    _ticker?.cancel();
    _ticker = null;
    _gyroSub?.cancel();
    _gyroSub = null;
    _serverSub?.cancel();
    _serverSub = null;
    _channel?.sink.close();
    _channel = null;
    _gyro = false;
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
    data.setFloat32(11, _calAxis(_lx), Endian.little);
    data.setFloat32(15, _calAxis(_ly), Endian.little);
    data.setFloat32(19, _calAxis(_rx), Endian.little);
    data.setFloat32(23, _calAxis(_ry), Endian.little);
    data.setFloat32(27, _calTrigger(_lt), Endian.little);
    data.setFloat32(31, _calTrigger(_rt), Endian.little);
    ch.sink.add(data.buffer.asUint8List());
  }

  void _changeProfile(String value) {
    setState(() => _profile = value);
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
    if (_connected) _sendProfile();
    _logLine('Plantilla: $id');
  }

  void _toggleGyro() {
    if (_gyro) {
      _gyroSub?.cancel();
      _gyroSub = null;
      setState(() {
        _gyro = false;
        _lx = 0;
      });
      _logLine('Giroscopio desactivado');
      return;
    }
    _gyroSub = gyroscopeEvents.listen((GyroscopeEvent event) {
      if (!_gyro) return;
      var v = _clamp(event.z / 3.0, -1, 1);
      if (v.abs() < _deadzone) v = 0;
      if ((_lx - v).abs() > 0.001) {
        setState(() => _lx = v);
      }
    }, onError: (Object e) {
      _logLine('Giroscopio no disponible: $e');
    });
    setState(() => _gyro = true);
    _logLine('Giroscopio activado');
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
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
              'La PC y el móvil deben estar en la misma Wi-Fi. Para giroscopio, '
              'usa wss:// y el puerto 8766 (certificado autofirmado).',
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
                    'Perfil',
                    _profile,
                    const {
                      '0': 'Xbox 360',
                      '1': 'Volante',
                      '2': 'Yoke',
                      '3': 'Teclado/Ratón',
                    },
                    _changeProfile,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildDropdown(
                    'Plantilla',
                    _template,
                    const {
                      'xbox': 'Mando',
                      'driving': 'Conducción',
                      'platform': 'Plataformas',
                      'flight': 'Vuelo',
                      'custom': 'Personalizada',
                    },
                    _applyTemplate,
                  ),
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
                    : _buildWheelLayout(),
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

  Widget _buildWheelLayout() {
    return Column(
      children: [
        const Text('Volante', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        GestureDetector(
          onPanUpdate: (d) {
            if (_gyro) return;
            _setAxis('lx', _clamp(_lx + d.delta.dx / 150, -1, 1));
          },
          onPanEnd: (_) {
            if (!_gyro) _setAxis('lx', 0);
          },
          child: Container(
            width: 180 * _controlScale,
            height: 180 * _controlScale,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black38,
              border: Border.all(color: Colors.grey.shade700, width: 3),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Transform.rotate(
                  angle: _lx * math.pi / 2,
                  child: Container(
                    width: 6,
                    height: 120 * _controlScale,
                    decoration: BoxDecoration(
                      color: const Color(0xFF007ACC),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                Text('${(_lx * 180).round()}°'),
              ],
            ),
          ),
        ),
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
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            _buildButton('C+', 4, compact: true),
            _buildButton('C-', 5, compact: true),
            _buildButton('Back', 6, compact: true),
            _buildButton('Start', 7, compact: true),
            _buildButton('A', 0, compact: true),
            _buildButton('B', 1, compact: true),
            _buildButton('X', 2, compact: true),
            _buildButton('Y', 3, compact: true),
          ],
        ),
      ],
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
        SizedBox(width: 100, child: Text(label, style: const TextStyle(fontSize: 12))),
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
