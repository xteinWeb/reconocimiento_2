import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/camera_service.dart';
import '../services/face_detection_service.dart';
import '../services/face_recognition_service.dart';
import '../services/database_service.dart';
import '../services/light_quality_service.dart';
import '../services/sql_server_service.dart';
import '../services/schedule_validator.dart';
import '../models/employee.dart';

enum ScanState { idle, success, failure }

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final _cameraService = CameraService();
  final _faceDetection = FaceDetectionService();
  final _faceRecognition = FaceRecognitionService();
  final _database = DatabaseService();
  final _lightQuality = LightQualityService();
  final _sqlServer = SqlServerService();

  String _status = "Mira a la cámara para marcar";
  String _lightStatus = "";
  Color _lightColor = Colors.grey;
  bool _isProcessing = false;
  bool _isAutoMode = true; // Habilitado por defecto para facilitar el flujo
  Timer? _autoTimer;

  // Estado del resultado de escaneo para feedback visual
  ScanState _scanState = ScanState.idle;
  Employee? _recognizedEmployee;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _cameraService.initialize();
    await _faceRecognition.initialize();
    if (mounted) {
      setState(() {});
      if (_isAutoMode) {
        _startAutoTimer();
      }
    }
  }

  void _startAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _markAttendance(),
    );
  }

  Future<void> _markAttendance() async {
    if (_isProcessing || !mounted) return;
    setState(() => _isProcessing = true);

    try {
      final file = await _cameraService.takePicture();
      if (file == null) {
        setState(() => _isProcessing = false);
        return;
      }

      final bytes = await file.readAsBytes();
      final lightResult = _lightQuality.analyzeImage(bytes);

      setState(() {
        _lightStatus = lightResult.feedback;
        _lightColor = lightResult.feedbackColor;
      });

      if (lightResult.isOverexposed ||
          lightResult.isBacklit ||
          lightResult.isTooDark) {
        setState(() {
          _status = lightResult.feedback;
          _isProcessing = false;
        });
        return;
      }

      final detection = await _faceDetection.detectFace(file.path);
      if (detection == null) {
        setState(() {
          _status = "Buscando rostro...";
          _isProcessing = false;
        });
        return;
      }

      final cropped = await _faceDetection.cropFace(
        file.path,
        detection.boundingBox,
      );
      if (cropped == null) {
        setState(() {
          _status = "Ajustando encuadre...";
          _isProcessing = false;
        });
        return;
      }

      final currentEmbedding = _faceRecognition.getEmbedding(cropped);
      final allEmbeddings = await _database.getAllEmbeddings();

      if (allEmbeddings.isEmpty) {
        setState(() {
          _status = "No hay colaboradores enrolados en el dispositivo.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });
        return;
      }

      final (matchedId, distance) = _faceRecognition.findNearest(
        currentEmbedding,
        allEmbeddings,
      );
      const threshold = 0.35; // Umbral de distancia coseno

      if (distance < threshold && matchedId != null) {
        final employee = await _database.getEmployeeById(matchedId);
        if (employee != null) {
          // 1. Pausar el temporizador automático temporalmente para no acumular fotos
          _autoTimer?.cancel();

          // 1.1 Verificar si el colaborador tiene un horario asignado
          Map<String, dynamic>? horario;
          if (employee.horarioId != null) {
            horario = await _database.getScheduleById(employee.horarioId!);
          }

          if (horario == null) {
            setState(() {
              _status = "Acceso denegado: Sin horario asignado.";
              _scanState = ScanState.failure;
            });

            if (mounted) {
              await showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF2B3A24),
                  title: const Text('Horario no asignado', style: TextStyle(color: Colors.white)),
                  content: Text(
                    'El colaborador ${employee.name} no cuenta con un horario asignado en el sistema.\nPor favor, comuníquese con Recursos Humanos.',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Aceptar', style: TextStyle(color: Colors.amber)),
                    ),
                  ],
                ),
              );
            }

            _resumeAutoTimerAfterDelay();
            return;
          }

          // 2. Mostrar diálogo de selección de Entrada o Salida
          if (!mounted) return;
          final selection = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => EventSelectionDialog(employee: employee),
          );

          // Si el diálogo se cerró por timeout sin seleccionar
          if (selection == null) {
            setState(() {
              _status = "Marcación cancelada por inactividad.";
              _scanState = ScanState.failure;
            });
            _resumeAutoTimerAfterDelay();
            return;
          }

          final now = DateTime.now();

          // 2.1 Si es SALIDA, validar salida temprana
          if (selection == 'SALIDA') {
            final esTemprana = ScheduleValidator.esSalidaTemprana(horario, now);
            if (esTemprana) {
              setState(() {
                _status = "Registro inválido: Salida anticipada.";
                _scanState = ScanState.failure;
              });

              if (mounted) {
                await showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF2B3A24),
                    title: const Text('Salida Anticipada', style: TextStyle(color: Colors.white)),
                    content: Text(
                      'No tienes permitido registrar la salida antes de tu hora establecida (${horario!['hora_final']}).',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Aceptar', style: TextStyle(color: Colors.amber)),
                      ),
                    ],
                  ),
                );
              }

              _resumeAutoTimerAfterDelay();
              return;
            }
          }

          // 3. Validar marcación consecutiva
          final lastRecord = await _database.getLastAttendanceForEmployee(employee.id!);
          if (lastRecord != null) {
            final String lastEvento = lastRecord['evento'] ?? '';
            if (lastEvento == selection) {
              setState(() {
                _status = "Registro inválido: Ya marcaste una $selection.";
                _scanState = ScanState.failure;
              });

              if (mounted) {
                await showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF2B3A24),
                    title: const Text('Registro Duplicado', style: TextStyle(color: Colors.white)),
                    content: Text(
                      'Ya registraste una $selection anteriormente.\nDebes registrar una ${selection == 'ENTRADA' ? 'SALIDA' : 'ENTRADA'} primero.',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Aceptar', style: TextStyle(color: Colors.amber)),
                      ),
                    ],
                  ),
                );
              }

              _resumeAutoTimerAfterDelay();
              return;
            }
          }

          // 4. Calcular retardo si es ENTRADA
          String tipoFinal = 'NORMAL';
          String? duracionRetardo;
          String feedbackMsg = '¡Asistencia registrada!';

          if (selection == 'ENTRADA') {
            final validation = ScheduleValidator.validarMarcacion(horario, now);
            tipoFinal = validation.tipo;
            duracionRetardo = validation.duracion;
            feedbackMsg = validation.descripcion;
          } else {
            feedbackMsg = 'Salida registrada. ¡Hasta mañana!';
          }

          // 5. Guardar localmente en SQLite
          await _database.insertAttendance(
            matchedId,
            now,
            distance,
            evento: selection,
            tipo: tipoFinal,
            duracion: duracionRetardo,
          );

          // 6. Sincronización en segundo plano con el servidor SQL Server central (offline-friendly)
          _sqlServer.guardarAsistenciaServidor(
            cedula: employee.employeeCode,
            fechaHora: now,
            evento: selection,
            tipo: tipoFinal,
            duracion: duracionRetardo != null ? double.tryParse(duracionRetardo.split(' ')[0]) ?? 0.0 : 0.0,
            unidadNegocio: employee.department ?? '',
          ).then((success) {
            if (success) {
              print('[SqlServer] Marcación sincronizada para: ${employee.name}');
            } else {
              print('[SqlServer] Marcación guardada localmente (servidor offline)');
            }
          });

          setState(() {
            _scanState = ScanState.success;
            _recognizedEmployee = employee;
            _status = feedbackMsg;
          });

          // Limpiar el estado de éxito después de 3 segundos
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) {
              setState(() {
                _scanState = ScanState.idle;
                _recognizedEmployee = null;
                _status = "Mira a la cámara para marcar";
              });
              _resumeAutoTimerAfterDelay();
            }
          });
        }
      } else {
        setState(() {
          _scanState = ScanState.failure;
          _status = "Rostro no reconocido.";
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _scanState == ScanState.failure) {
            setState(() {
              _scanState = ScanState.idle;
              _status = "Mira a la cámara para marcar";
            });
          }
        });
      }
    } catch (e) {
      setState(() => _status = "Error: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _toggleAutoMode(bool value) {
    setState(() {
      _isAutoMode = value;
      if (_isAutoMode) {
        _status = "Modo automático activado...";
        _startAutoTimer();
      } else {
        _autoTimer?.cancel();
        _status = "Presiona Marcar para escanear";
      }
    });
  }

  void _resumeAutoTimerAfterDelay() {
    if (_isAutoMode) {
      _startAutoTimer();
    }
    setState(() {
      _isProcessing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    Color ringColor = Colors.white;
    if (_scanState == ScanState.success) {
      ringColor = Colors.greenAccent;
    } else if (_scanState == ScanState.failure) {
      ringColor = Colors.redAccent;
    } else if (_lightStatus.isNotEmpty) {
      ringColor = _lightColor;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Marcado de Asistencia'),
        foregroundColor: Colors.white,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Row(
            children: [
              const Text(
                'Auto',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Switch(
                value: _isAutoMode,
                onChanged: _toggleAutoMode,
                activeColor: Colors.cyanAccent,
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _cameraService.isInitialized
                    ? CameraPreview(_cameraService.controller!)
                    : const Center(
                        child: CircularProgressIndicator(
                          color: Colors.cyanAccent,
                        ),
                      ),

                // Overlay de cámara según estado de escaneo
                if (_scanState == ScanState.success)
                  Container(color: Colors.green.withOpacity(0.15)),
                if (_scanState == ScanState.failure)
                  Container(color: Colors.red.withOpacity(0.15)),

                // Ring guía de la cara
                Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 255,
                    height: 255,
                    decoration: BoxDecoration(
                      border: Border.all(color: ringColor, width: 3.5),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: ringColor.withOpacity(0.2),
                          blurRadius: 15,
                          spreadRadius: 3,
                        ),
                      ],
                    ),
                    child: _scanState == ScanState.success
                        ? const Center(
                            child: Icon(
                              Icons.check_circle_outline_rounded,
                              color: Colors.greenAccent,
                              size: 80,
                            ),
                          )
                        : (_scanState == ScanState.failure
                              ? const Center(
                                  child: Icon(
                                    Icons.error_outline_rounded,
                                    color: Colors.redAccent,
                                    size: 80,
                                  ),
                                )
                              : null),
                  ),
                ),

                // Tarjeta de confirmación del empleado en caso de éxito
                if (_scanState == ScanState.success &&
                    _recognizedEmployee != null)
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Card(
                      color: const Color(0xFF1E1E1E),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(
                          color: Colors.greenAccent,
                          width: 1.5,
                        ),
                      ),
                      elevation: 10,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        child: Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor: Colors.green,
                              radius: 26,
                              child: Icon(
                                Icons.person,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _recognizedEmployee!.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Código: ${_recognizedEmployee!.employeeCode}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (_recognizedEmployee!.department !=
                                      null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Depto: ${_recognizedEmployee!.department}',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E1E),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_lightStatus.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _lightColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _lightColor, width: 1),
                    ),
                    child: Text(
                      _lightStatus,
                      style: TextStyle(
                        color: _lightColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (!_isAutoMode) ...[
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _markAttendance,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black87,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      minimumSize: const Size(double.infinity, 50),
                    ),
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black87,
                            ),
                          )
                        : const Icon(Icons.camera_front_rounded),
                    label: const Text(
                      'Marcar Asistencia',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _cameraService.dispose();
    _faceDetection.dispose();
    _faceRecognition.dispose();
    super.dispose();
  }
}

class EventSelectionDialog extends StatefulWidget {
  final Employee employee;
  const EventSelectionDialog({super.key, required this.employee});

  @override
  State<EventSelectionDialog> createState() => _EventSelectionDialogState();
}

class _EventSelectionDialogState extends State<EventSelectionDialog> {
  Timer? _timeoutTimer;
  int _secondsRemaining = 7;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining <= 1) {
        timer.cancel();
        if (mounted) Navigator.of(context).pop(null); // Cerrar por inactividad
      } else {
        setState(() {
          _secondsRemaining--;
        });
      }
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      backgroundColor: const Color(0xFF2B3A24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Column(
        children: [
          const Icon(
            Icons.lock_person_rounded,
            size: 48,
            color: Colors.amber,
          ),
          const SizedBox(height: 12),
          Text(
            widget.employee.name,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white,
              fontSize: 20,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          const Text(
            '¿Qué registro deseas realizar hoy?',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Botón ENTRADA
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop('ENTRADA'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.tealAccent.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    elevation: 5,
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.login_rounded, size: 36, color: Colors.white),
                      SizedBox(height: 8),
                      Text(
                        'ENTRADA',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Botón SALIDA
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop('SALIDA'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    elevation: 5,
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.logout_rounded, size: 36, color: Colors.white),
                      SizedBox(height: 8),
                      Text(
                        'SALIDA',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Se cerrará por inactividad en $_secondsRemaining segundos...',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white38,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
