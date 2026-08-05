import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:intl/intl.dart';
import '../services/camera_service.dart';
import '../services/face_detection_service.dart';
import '../services/face_recognition_service.dart';
import '../services/database_service.dart';
import '../services/light_quality_service.dart';
import '../services/sql_server_service.dart';
import '../services/schedule_validator.dart';
import '../services/sync_service.dart';
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
  final _syncService = SyncService();

  double _threshold = 0.22;
  int _minFaceSize = 130;
  double _centerTolerance = 0.15;
  int? _lastMatchedId;
  int _consecutiveMatchCount = 0;

  String _status = "Mira a la cámara para marcar";
  String _lightStatus = "";
  Color _lightColor = Colors.grey;
  bool _isProcessing = false;
  bool _isAutoMode = true; // Habilitado por defecto para facilitar el flujo
  Timer? _autoTimer;

  // Estado del resultado de escaneo para feedback visual
  ScanState _scanState = ScanState.idle;
  Employee? _recognizedEmployee;
  List<Map<String, dynamic>> _topMatches = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadConfigs();
    await _cameraService.initialize();
    await _faceRecognition.initialize();
    if (mounted) {
      setState(() {});
      if (_isAutoMode) {
        _startAutoTimer();
      }
    }
  }

  Future<void> _loadConfigs() async {
    try {
      final tStr = await _database.getConfig('recognition_threshold');
      final sStr = await _database.getConfig('min_face_size');
      final cStr = await _database.getConfig('center_tolerance');

      setState(() {
        if (tStr != null) _threshold = double.tryParse(tStr) ?? 0.22;
        if (sStr != null) _minFaceSize = int.tryParse(sStr) ?? 130;
        if (cStr != null) _centerTolerance = double.tryParse(cStr) ?? 0.15;
      });
    } catch (e) {
      debugPrint("Error al cargar configuraciones: $e");
    }
  }

  Future<bool> _mostrarDialogoBypass(
    String title,
    String message,
  ) async {
    if (!mounted) return false;

    bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        int secondsRemaining = 5;
        Timer? timer;

        return StatefulBuilder(
          builder: (context, setState) {
            // Iniciar el temporizador si no está activo
            timer ??= Timer.periodic(const Duration(seconds: 1), (t) {
              if (secondsRemaining > 1) {
                if (context.mounted) {
                  setState(() {
                    secondsRemaining--;
                  });
                }
              } else {
                t.cancel();
                if (context.mounted) {
                  Navigator.of(context).pop(true); // Auto-confirmar
                }
              }
            });

            return AlertDialog(
              backgroundColor: const Color(0xFF2B3A24),
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.amber),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Registrando automáticamente en ${secondsRemaining}s...',
                        style: const TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    timer?.cancel();
                    Navigator.of(context).pop(false); // Cancelar
                  },
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.white60),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: const Color(0xFF2B3A24),
                  ),
                  onPressed: () {
                    timer?.cancel();
                    Navigator.of(context).pop(true); // Registrar de todos modos
                  },
                  child: const Text(
                    'Registrar de todos modos',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    return result ?? false;
  }

  Future<bool> _validarFlujoMarcacion(
    Employee employee,
    String selection,
    DateTime now,
  ) async {
    Map<String, dynamic>? lastRecord;
    bool isSameDay = false;
    String? lastEvento;

    // Intentar obtener el último registro global de hoy desde SQL Server
    try {
      lastRecord = await _sqlServer.obtenerUltimoRegistroHoy(employee.employeeCode);
      if (lastRecord != null) {
        isSameDay = true;
        lastEvento = lastRecord['evento']?.toString();
        print('[SyncFlow] Estado global desde SQL Server: $lastEvento');
      }
    } catch (e) {
      print('[SyncFlow] Error al verificar flujo en servidor, usando SQLite local: $e');
    }

    // Si falló la consulta o no retornó nada, usar local SQLite
    if (lastEvento == null) {
      final localRecord = await _database.getLastAttendanceForEmployee(employee.id!);
      if (localRecord != null) {
        lastEvento = localRecord['evento']?.toString();
        final String? lastTimestampStr = localRecord['timestamp'];
        if (lastTimestampStr != null) {
          final lastDateTime = DateTime.tryParse(lastTimestampStr);
          if (lastDateTime != null) {
            isSameDay =
                lastDateTime.year == now.year &&
                lastDateTime.month == now.month &&
                lastDateTime.day == now.day;
          }
        }
        if (isSameDay) {
          print('[SyncFlow] Estado local desde SQLite: $lastEvento');
        }
      }
    }

    bool isValid = true;

    if (selection == 'SALIDA') {
      final bool tieneEntradaPreviaHoy =
          isSameDay && (lastEvento == 'ENTRADA' || lastEvento == 'ENTRADA_TRASLADO');

      if (!tieneEntradaPreviaHoy) {
        isValid = await _mostrarDialogoBypass(
          'Entrada Requerida',
          'No se detectó un registro de ENTRADA previo el día de hoy para este colaborador.',
        );
      }
    } else if (selection == 'SALIDA_TRASLADO') {
      final bool tieneEntradaPreviaHoy =
          isSameDay && (lastEvento == 'ENTRADA' || lastEvento == 'ENTRADA_TRASLADO');

      if (!tieneEntradaPreviaHoy) {
        isValid = await _mostrarDialogoBypass(
          'Entrada Requerida',
          'No se detectó un registro de ENTRADA previo el día de hoy para esta SALIDA POR TRASLADO.',
        );
      }
    } else if (selection == 'ENTRADA') {
      final bool yaTieneEntradaActiva =
          isSameDay && (lastEvento == 'ENTRADA' || lastEvento == 'ENTRADA_TRASLADO');

      if (yaTieneEntradaActiva) {
        isValid = await _mostrarDialogoBypass(
          'Registro Duplicado',
          'Ya se encuentra registrada una ENTRADA activa para el día de hoy.',
        );
      }
    } else if (selection == 'ENTRADA_TRASLADO') {
      final bool vieneDeTraslado =
          isSameDay && lastEvento == 'SALIDA_TRASLADO';

      if (!vieneDeTraslado) {
        isValid = await _mostrarDialogoBypass(
          'Traslado no Iniciado',
          'No se detectó una SALIDA POR TRASLADO previa en la sede de origen el día de hoy.',
        );
      }
    }

    return isValid;
  }

  void _startAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => _markAttendance(),
    );
  }

  Future<void> _markAttendance() async {
    if (_isProcessing || !mounted) return;
    setState(() {
      _isProcessing = true;
      _topMatches = [];
    });

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

      final detection = await _faceDetection.detectFace(
        file.path,
        minFaceSize: _minFaceSize,
        centerTolerancePercentage: _centerTolerance,
      );
      if (detection == null) {
        setState(() {
          _status = "Buscando rostro...";
          _isProcessing = false;
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
        });
        return;
      }

      if (detection.isNotCentered) {
        setState(() {
          _status = "⚠️ Por favor, centra tu rostro en el círculo.";
          _isProcessing = false;
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
        });
        return;
      }

      if (detection.isTooSmall) {
        setState(() {
          _status = "⚠️ Por favor, acércate más a la pantalla.";
          _isProcessing = false;
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
        });
        return;
      }

      // Validar que la persona esté mirando de frente a la cámara (frontal) para evitar falsos positivos
      if (detection.yaw.abs() > 15.0 || detection.pitch.abs() > 15.0) {
        setState(() {
          _status = "⚠️ Por favor, mira de frente a la pantalla.";
          _isProcessing = false;
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
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
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
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
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
        });
        return;
      }

      final (matchedId, distance) = _faceRecognition.findNearest(
        currentEmbedding,
        allEmbeddings,
      );

      /*
      // Obtener las 3 mejores coincidencias para depuración/testing
      final topMatchesRaw = _faceRecognition.findTopMatches(
        currentEmbedding,
        allEmbeddings,
        limit: 3,
      );

      final List<Map<String, dynamic>> resolvedMatches = [];
      for (final match in topMatchesRaw) {
        final empId = match.$1;
        final dist = match.$2;
        final employee = await _database.getEmployeeById(empId);
        if (employee != null) {
          resolvedMatches.add({'employee': employee, 'distance': dist});
        }
      }

      setState(() {
        _topMatches = resolvedMatches;
      });
      */

      debugPrint(
        '[FaceRecognition] ID detectado: $matchedId, Distancia calculada: ${distance.toStringAsFixed(4)}',
      );

      if (distance < _threshold && matchedId != null) {
        if (_isAutoMode) {
          if (_lastMatchedId == matchedId) {
            _consecutiveMatchCount++;
          } else {
            _lastMatchedId = matchedId;
            _consecutiveMatchCount = 1;
          }

          if (_consecutiveMatchCount < 3) {
            setState(() {
              _status = "Confirmando identidad... (${_consecutiveMatchCount}/3)";
              _isProcessing = false;
            });
            return;
          }
        }

        // Si llegó a 3 o es modo manual, resetear para la marcación
        _consecutiveMatchCount = 0;
        _lastMatchedId = null;

        final employee = await _database.getEmployeeById(matchedId);
        if (employee != null) {
          // 1. Pausar el temporizador automático temporalmente para no acumular fotos
          _autoTimer?.cancel();

          final now = DateTime.now();

          // 1.1 Verificar si el colaborador tiene un horario asignado o programación especial
          final scheduleRes = await _resolveEffectiveSchedule(employee, now);
          final horario = scheduleRes.horario;
          final isNotProgrammed = scheduleRes.isNotProgrammed;

          if (horario == null && !isNotProgrammed) {
            setState(() {
              _status = "Acceso denegado: Sin horario asignado.";
              _scanState = ScanState.failure;
            });

            if (mounted) {
              await showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF2B3A24),
                  title: const Text(
                    'Horario no asignado',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: Text(
                    'El colaborador ${employee.name} no cuenta con un horario asignado en el sistema.\nPor favor, comuníquese con Recursos Humanos.',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text(
                        'Aceptar',
                        style: TextStyle(color: Colors.amber),
                      ),
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

          // 3. Validar marcación consecutiva (Entrada previa obligatoria para Salida)
          final isValid = await _validarFlujoMarcacion(
            employee,
            selection,
            now,
          );
          if (!isValid) {
            setState(() {
              _status = "Registro inválido para el flujo actual.";
              _scanState = ScanState.failure;
            });
            _resumeAutoTimerAfterDelay();
            return;
          }

          // 4. Calcular retardo si es ENTRADA o si es salida temprana / no programado
          String tipoFinal = 'NORMAL';
          String? duracionRetardo;
          String feedbackMsg = '¡Asistencia registrada!';

          if (isNotProgrammed) {
            tipoFinal = 'NO_PROGRAMADO';
            duracionRetardo = null;
            feedbackMsg =
                (selection == 'ENTRADA' || selection == 'ENTRADA_TRASLADO')
                ? 'Entrada registrada — No estabas programado hoy.'
                : 'Salida registrada — No estabas programado hoy.';
          } else if (selection == 'ENTRADA_TRASLADO') {
            tipoFinal = 'TRASLADO';
            duracionRetardo = null;
            feedbackMsg = 'Entrada por traslado registrada con éxito.';
          } else if (selection == 'SALIDA_TRASLADO') {
            tipoFinal = 'TRASLADO';
            duracionRetardo = null;
            feedbackMsg = 'Salida por traslado registrada. ¡Buen viaje!';
          } else if (selection == 'ENTRADA') {
            final validation = ScheduleValidator.validarMarcacion(horario, now);
            tipoFinal = validation.tipo;
            duracionRetardo = validation.duracion;
            feedbackMsg = validation.descripcion;
          } else {
            // Verificar si es salida temprana
            if (horario != null &&
                ScheduleValidator.esSalidaTemprana(horario, now)) {
              tipoFinal = 'SALIDA_TEMPRANA';
              feedbackMsg = 'Salida anticipada registrada.';
            } else {
              feedbackMsg = 'Salida registrada. ¡Hasta mañana!';
            }
          }

          // 5. Guardar localmente en SQLite
          final deviceId = await _database.getDeviceId();
          final recordId = await _database.insertAttendance(
            matchedId,
            now,
            distance,
            evento: selection,
            tipo: tipoFinal,
            duracion: duracionRetardo,
            isSynced: 0,
            dispositivoId: deviceId,
          );

          // 6. Sincronización en segundo plano con el servidor SQL Server central (offline-friendly)
          _syncService.sincronizarAsistenciasPendientes().then((result) {
            print('[Sync] Sincronización automática de marcaciones: $result');
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
                _topMatches = [];
              });
              _resumeAutoTimerAfterDelay();
            }
          });
        }
      } else {
        setState(() {
          _consecutiveMatchCount = 0;
          _lastMatchedId = null;
        });

        if (!_isAutoMode) {
          setState(() {
            _scanState = ScanState.failure;
            _status = "Rostro no reconocido.";
          });
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _scanState == ScanState.failure) {
              setState(() {
                _scanState = ScanState.idle;
                _status = "Presiona Marcar para escanear";
                _topMatches = [];
              });
            }
          });
        } else {
          setState(() {
            _status = "Mira a la cámara para marcar";
          });
        }
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

  Future<({Map<String, dynamic>? horario, bool isNotProgrammed})>
  _resolveEffectiveSchedule(Employee employee, DateTime now) async {
    final dateStr = DateFormat('yyyy-MM-dd').format(now);
    final specialSchedule = await _database.getSpecialScheduleForEmployee(
      employee.id!,
      dateStr,
    );
    final isSpecialDay = await _database.hasAnySpecialScheduleOnDate(dateStr);

    if (specialSchedule != null) {
      final hInicio = specialSchedule['hora_inicio']?.toString();
      final hFinal = specialSchedule['hora_final']?.toString();

      if (hInicio != null &&
          hInicio.isNotEmpty &&
          hFinal != null &&
          hFinal.isNotEmpty) {
        return (
          horario: {
            'id_horario': 'ESPECIAL',
            'hora_inicio': hInicio,
            'hora_final': hFinal,
            'tipo': 'ESPECIAL',
            'dias': 'L,M,Mi,J,V,S,D',
          },
          isNotProgrammed: false,
        );
      } else {
        Map<String, dynamic>? baseHorario;
        if (employee.horarioId != null) {
          baseHorario = await _database.getScheduleByIdAndDate(
            employee.horarioId!,
            now,
          );
        }
        if (baseHorario != null) {
          final modHorario = Map<String, dynamic>.from(baseHorario);
          modHorario['dias'] = 'L,M,Mi,J,V,S,D';
          return (horario: modHorario, isNotProgrammed: false);
        } else {
          return (
            horario: {
              'id_horario': 'ESPECIAL',
              'hora_inicio': '07:00',
              'hora_final': '17:00',
              'tipo': 'ESPECIAL',
              'dias': 'L,M,Mi,J,V,S,D',
            },
            isNotProgrammed: false,
          );
        }
      }
    } else if (isSpecialDay) {
      Map<String, dynamic>? baseHorario;
      if (employee.horarioId != null) {
        baseHorario = await _database.getScheduleByIdAndDate(
          employee.horarioId!,
          now,
        );
      }
      return (horario: baseHorario, isNotProgrammed: true);
    } else {
      Map<String, dynamic>? baseHorario;
      if (employee.horarioId != null) {
        baseHorario = await _database.getScheduleByIdAndDate(
          employee.horarioId!,
          now,
        );
      }
      return (horario: baseHorario, isNotProgrammed: false);
    }
  }

  Future<void> _marcarConCedula() async {
    _autoTimer?.cancel();

    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final cedula = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Marcación por Cédula',
          style: TextStyle(color: Colors.white),
        ),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Número de Cédula',
              labelStyle: TextStyle(color: Colors.cyanAccent),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white54),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.cyanAccent),
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Por favor ingresa la cédula';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(controller.text.trim());
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent),
            child: const Text(
              'Aceptar',
              style: TextStyle(color: Colors.black87),
            ),
          ),
        ],
      ),
    );

    if (cedula == null || cedula.isEmpty) {
      _resumeAutoTimerAfterDelay();
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = "Buscando colaborador...";
    });

    try {
      final employee = await _database.getEmployeeByCode(cedula);
      if (employee == null) {
        setState(() {
          _status = "Cédula no encontrada en el dispositivo.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });
        _resumeAutoTimerAfterDelay();
        return;
      }

      final now = DateTime.now();
      final scheduleRes = await _resolveEffectiveSchedule(employee, now);
      final horario = scheduleRes.horario;
      final isNotProgrammed = scheduleRes.isNotProgrammed;

      if (horario == null && !isNotProgrammed) {
        setState(() {
          _status = "Acceso denegado: Sin horario asignado.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });

        if (mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF2B3A24),
              title: const Text(
                'Horario no asignado',
                style: TextStyle(color: Colors.white),
              ),
              content: Text(
                'El colaborador ${employee.name} no cuenta con un horario asignado en el sistema.\nPor favor, comuníquese con Recursos Humanos.',
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    'Aceptar',
                    style: TextStyle(color: Colors.amber),
                  ),
                ),
              ],
            ),
          );
        }

        _resumeAutoTimerAfterDelay();
        return;
      }

      if (!mounted) return;
      final selection = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => EventSelectionDialog(employee: employee),
      );

      if (selection == null) {
        setState(() {
          _status = "Marcación cancelada por inactividad.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });
        _resumeAutoTimerAfterDelay();
        return;
      }

      // 3. Validar marcación consecutiva (Entrada previa obligatoria para Salida)
      final isValid = await _validarFlujoMarcacion(employee, selection, now);
      if (!isValid) {
        setState(() {
          _status = "Registro inválido para el flujo actual.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });
        _resumeAutoTimerAfterDelay();
        return;
      }

      String tipoFinal = 'NORMAL';
      String? duracionRetardo;
      String feedbackMsg = '¡Asistencia registrada!';

      if (isNotProgrammed) {
        tipoFinal = 'NO_PROGRAMADO';
        duracionRetardo = null;
        feedbackMsg =
            (selection == 'ENTRADA' || selection == 'ENTRADA_TRASLADO')
            ? 'Entrada registrada — No estabas programado hoy.'
            : 'Salida registrada — No estabas programado hoy.';
      } else if (selection == 'ENTRADA_TRASLADO') {
        tipoFinal = 'TRASLADO';
        duracionRetardo = null;
        feedbackMsg = 'Entrada por traslado registrada con éxito.';
      } else if (selection == 'SALIDA_TRASLADO') {
        tipoFinal = 'TRASLADO';
        duracionRetardo = null;
        feedbackMsg = 'Salida por traslado registrada. ¡Buen viaje!';
      } else if (selection == 'ENTRADA') {
        final validation = ScheduleValidator.validarMarcacion(horario, now);
        tipoFinal = validation.tipo;
        duracionRetardo = validation.duracion;
        feedbackMsg = validation.descripcion;
      } else {
        // Verificar si es salida temprana
        if (horario != null &&
            ScheduleValidator.esSalidaTemprana(horario, now)) {
          tipoFinal = 'SALIDA_TEMPRANA';
          feedbackMsg = 'Salida anticipada registrada.';
        } else {
          feedbackMsg = 'Salida registrada. ¡Hasta mañana!';
        }
      }

      final deviceId = await _database.getDeviceId();
      final recordId = await _database.insertAttendance(
        employee.id!,
        now,
        0.0,
        evento: selection,
        tipo: tipoFinal,
        duracion: duracionRetardo,
        isSynced: 0,
        metodoRegistro: 'CEDULA',
        dispositivoId: deviceId,
      );

      setState(() {
        _status = feedbackMsg;
        _scanState = ScanState.success;
        _recognizedEmployee = employee;
        _isProcessing = false;
      });

      _syncService.sincronizarAsistenciasPendientes().then((result) {
        print(
          '[Sync] Sincronización automática de marcaciones por cédula: $result',
        );
      });

      await Future.delayed(const Duration(seconds: 4));
      if (mounted) {
        setState(() {
          _recognizedEmployee = null;
          _status = _isAutoMode
              ? "Mira a la cámara para marcar"
              : "Presiona Marcar para escanear";
          _scanState = ScanState.idle;
        });
        _resumeAutoTimerAfterDelay();
      }
    } catch (e) {
      setState(() {
        _status = "Error al marcar: $e";
        _scanState = ScanState.failure;
        _isProcessing = false;
      });
      _resumeAutoTimerAfterDelay();
    }
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

                // Progreso de confirmación multicuadro
                if (_consecutiveMatchCount > 0 && _scanState == ScanState.idle)
                  Center(
                    child: SizedBox(
                      width: 263,
                      height: 263,
                      child: CircularProgressIndicator(
                        value: _consecutiveMatchCount / 3.0,
                        strokeWidth: 5,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                        backgroundColor: Colors.transparent,
                      ),
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
                if (_topMatches.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 12),
                  const Text(
                    "Top 3 Coincidencias de Lectura Facial",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Column(
                    children: _topMatches.map((match) {
                      final employee = match['employee'] as Employee;
                      final distance = match['distance'] as double;
                      final percentage = ((1.0 - distance) * 100).clamp(
                        0.0,
                        100.0,
                      );

                      // Highlight if it's below the threshold (recognized)
                      final isMatch = distance < 0.35;

                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isMatch
                              ? Colors.green.withOpacity(0.1)
                              : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isMatch
                                ? Colors.greenAccent.withOpacity(0.5)
                                : Colors.white12,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    employee.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'Cod: ${employee.employeeCode} | Dept: ${employee.department ?? "N/A"}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'Distancia: ${distance.toStringAsFixed(4)}',
                                  style: TextStyle(
                                    color: isMatch
                                        ? Colors.greenAccent
                                        : Colors.amberAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'Similitud: ${percentage.toStringAsFixed(1)}%',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isProcessing ? null : _marcarConCedula,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.cyanAccent,
                    side: const BorderSide(color: Colors.cyanAccent),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text(
                    'Marcar con Cédula',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
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
  final _database = DatabaseService();
  Timer? _timeoutTimer;
  int _secondsRemaining = 7;
  bool _loading = true;
  String? _lastEvento;
  bool _isSameDay = false;

  @override
  void initState() {
    super.initState();
    _loadStateAndStartTimer();
  }

  Future<void> _loadStateAndStartTimer() async {
    try {
      final lastRecord = await _database.getLastAttendanceForEmployee(widget.employee.id!);
      if (lastRecord != null) {
        final String? lastTimestampStr = lastRecord['timestamp'];
        if (lastTimestampStr != null) {
          final lastDateTime = DateTime.tryParse(lastTimestampStr);
          if (lastDateTime != null) {
            final now = DateTime.now();
            _isSameDay =
                lastDateTime.year == now.year &&
                lastDateTime.month == now.month &&
                lastDateTime.day == now.day;
          }
        }
        if (_isSameDay) {
          _lastEvento = lastRecord['evento']?.toString();
        }
      }
    } catch (e) {
      debugPrint("Error al cargar estado del diálogo: $e");
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_secondsRemaining <= 1) {
          timer.cancel();
          if (mounted) Navigator.of(context).pop(null);
        } else {
          setState(() {
            _secondsRemaining--;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Calcular condiciones
    final bool tieneEntradaActiva = _isSameDay && (_lastEvento == 'ENTRADA' || _lastEvento == 'ENTRADA_TRASLADO');
    final bool vieneDeTraslado = _isSameDay && _lastEvento == 'SALIDA_TRASLADO';

    return AlertDialog(
      backgroundColor: const Color(0xFF2B3A24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Column(
        children: [
          const Icon(Icons.lock_person_rounded, size: 48, color: Colors.amber),
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
            style: TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      content: _loading
          ? const SizedBox(
              height: 100,
              child: Center(
                child: CircularProgressIndicator(color: Colors.amber),
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                
                // Mostrar ENTRADA (normal) si no tiene entrada activa y no viene de traslado
                if (!tieneEntradaActiva && !vieneDeTraslado) ...[
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop('ENTRADA'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent.shade700,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 5,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.login_rounded, size: 28, color: Colors.white),
                        SizedBox(width: 12),
                        Text(
                          'REGISTRAR ENTRADA',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Mostrar ENTRADA EN OTRA SEDE si viene de traslado (SALIDA_TRASLADO anterior hoy)
                if (vieneDeTraslado) ...[
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop('ENTRADA_TRASLADO'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 5,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.directions_run_rounded, size: 28, color: Colors.white),
                        SizedBox(width: 12),
                        Text(
                          'ENTRADA EN OTRA SEDE',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Mostrar SALIDA y SALIDA A OTRA SEDE si tiene entrada activa hoy
                if (tieneEntradaActiva) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Botón SALIDA normal
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop('SALIDA'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            elevation: 5,
                          ),
                          child: const Column(
                            children: [
                              Icon(Icons.logout_rounded, size: 28, color: Colors.white),
                              SizedBox(height: 6),
                              Text(
                                'SALIDA\nFINAL',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Botón SALIDA A OTRA SEDE (Traslado)
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop('SALIDA_TRASLADO'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            elevation: 5,
                          ),
                          child: const Column(
                            children: [
                              Icon(Icons.transfer_within_a_station_rounded, size: 28, color: Colors.white),
                              SizedBox(height: 6),
                              Text(
                                'SALIDA A\nOTRA SEDE',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text(
            'CANCELAR',
            style: TextStyle(
              color: Colors.redAccent,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
