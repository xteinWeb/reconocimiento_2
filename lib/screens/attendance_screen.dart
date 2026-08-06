import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/camera_service.dart';
import '../services/face_detection_service.dart';
import '../services/face_recognition_service.dart';
import '../services/database_service.dart';
import '../services/light_quality_service.dart';
import '../services/schedule_validator.dart';
import '../services/supervisor_auth.dart';
import '../services/sync_service.dart';
import '../models/employee.dart';

enum ScanState { idle, success, failure }

/// Claves de configuración de reconocimiento (compartidas con el calibrador).
const String kCfgUmbral = 'recognition_threshold';
const String kCfgMargen = 'recognition_margin';
const String kCfgVotos = 'recognition_votes';

/// Valores por defecto conservadores.
///
/// Son un punto de partida, NO un valor correcto: el umbral bueno depende del
/// modelo, la cámara, la iluminación de la sede y de cuán parecidas son las
/// personas de la plantilla. Usa el calibrador para fijarlos con datos reales.
const double kUmbralPorDefecto = 0.20;
const double kMargenPorDefecto = 0.06;
const int kVotosPorDefecto = 3;

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
  final _syncService = SyncService();
  final _supervisor = SupervisorAuth();

  // --- Parámetros de decisión -----------------------------------------
  // Estos tres valores definen juntos la tasa de falsos positivos.
  // El calibrador (Configuración → Calibrar reconocimiento) los deriva de la
  // galería real en lugar de dejarlos a criterio manual.
  double _threshold = kUmbralPorDefecto;
  double _margin = kMargenPorDefecto;
  int _requiredVotes = kVotosPorDefecto;

  int _minFaceSize = 130;
  double _centerTolerance = 0.15;

  // --- Votación multi-frame -------------------------------------------
  int? _voteEmployeeId;
  int _voteCount = 0;
  DateTime? _voteLastAt;
  double _voteBestDistance = double.infinity;
  double _voteMinMargin = double.infinity;

  /// Ventana máxima entre votos consecutivos. Si la persona se va y llega
  /// otra, los votos viejos caducan en lugar de sumarse.
  static const Duration _voteWindow = Duration(seconds: 6);

  // --- Galería en memoria ---------------------------------------------
  // Se construye una sola vez (no en cada frame): parsear y validar miles de
  // vectores por captura era lento y repetía el mismo trabajo.
  List<GalleryTemplate> _gallery = const [];
  DateTime? _galleryBuiltAt;
  int _galleryEmployees = 0;
  int _galleryRejected = 0;
  static const Duration _galleryTtl = Duration(minutes: 3);

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
    await _refreshGallery(force: true);
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
      final tStr = await _database.getConfig(kCfgUmbral);
      final mStr = await _database.getConfig(kCfgMargen);
      final vStr = await _database.getConfig(kCfgVotos);
      final sStr = await _database.getConfig('min_face_size');
      final cStr = await _database.getConfig('center_tolerance');

      if (!mounted) return;
      setState(() {
        _threshold = double.tryParse(tStr ?? '') ?? kUmbralPorDefecto;
        _margin = double.tryParse(mStr ?? '') ?? kMargenPorDefecto;
        _requiredVotes = (int.tryParse(vStr ?? '') ?? kVotosPorDefecto).clamp(
          1,
          5,
        );
        _minFaceSize = int.tryParse(sStr ?? '') ?? 130;
        _centerTolerance = double.tryParse(cStr ?? '') ?? 0.15;
      });
    } catch (e) {
      // Ante un fallo de lectura NO se hereda un valor permisivo: se usan
      // los valores por defecto conservadores definidos arriba.
      debugPrint("Error al cargar configuraciones, usando defaults: $e");
    }
  }

  /// Reconstruye la galería de plantillas frontales validadas.
  Future<void> _refreshGallery({bool force = false}) async {
    final builtAt = _galleryBuiltAt;
    if (!force &&
        builtAt != null &&
        DateTime.now().difference(builtAt) < _galleryTtl) {
      return;
    }

    try {
      final rows = await _database.getAllEmbeddings();
      final built = FaceRecognitionService.buildGallery(rows, frontalOnly: true);

      _gallery = built.templates;
      _galleryBuiltAt = DateTime.now();
      _galleryEmployees = built.enrolledEmployeeIds.length;
      _galleryRejected = built.rejectedCount;

      debugPrint(
        '[Galería] ${_gallery.length} plantillas frontales de '
        '$_galleryEmployees colaboradores. '
        'Descartadas por inválidas: $_galleryRejected.',
      );
    } catch (e) {
      debugPrint('[Galería] Error al construir: $e');
    }
  }

  // ------------------------------------------------------------------
  // Votación multi-frame
  // ------------------------------------------------------------------

  void _resetVotes() {
    _voteEmployeeId = null;
    _voteCount = 0;
    _voteLastAt = null;
    _voteBestDistance = double.infinity;
    _voteMinMargin = double.infinity;
  }

  /// Registra una identificación aceptada y devuelve true si ya se alcanzó el
  /// número de votos coincidentes exigido.
  ///
  /// Cada voto proviene de una captura independiente. Un falso positivo
  /// puntual no acumula; para pasar, el sistema tiene que identificar a la
  /// MISMA persona varias veces seguidas, cada vez superando umbral y margen.
  bool _registerVote(IdentificationResult r) {
    final now = DateTime.now();

    final expired =
        _voteLastAt != null && now.difference(_voteLastAt!) > _voteWindow;

    if (expired || _voteEmployeeId != r.employeeId) {
      _voteEmployeeId = r.employeeId;
      _voteCount = 1;
      _voteBestDistance = r.distance;
      _voteMinMargin = r.margin;
    } else {
      _voteCount++;
      _voteBestDistance = r.distance < _voteBestDistance
          ? r.distance
          : _voteBestDistance;
      _voteMinMargin = r.margin < _voteMinMargin ? r.margin : _voteMinMargin;
    }

    _voteLastAt = now;
    return _voteCount >= _requiredVotes;
  }

  /// Guarda el rostro alineado como evidencia auditable de la marcación.
  Future<String?> _guardarEvidencia(
    img.Image alignedImage,
    String employeeCode,
    DateTime when,
  ) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final evidenceDir = Directory(p.join(dir.path, 'evidencias'));
      if (!await evidenceDir.exists()) {
        await evidenceDir.create(recursive: true);
      }
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(when);
      final file = File(p.join(evidenceDir.path, '${employeeCode}_$stamp.jpg'));
      await file.writeAsBytes(_faceDetection.encodeEvidence(alignedImage));
      return file.path;
    } catch (e) {
      debugPrint('[Evidencia] No se pudo guardar: $e');
      return null;
    }
  }

  void _startAutoTimer() {
    _autoTimer?.cancel();
    if (!_isAutoMode || !mounted || _scanState != ScanState.idle) return;
    _autoTimer = Timer(
      const Duration(milliseconds: 500),
      () => _markAttendance(),
    );
  }

  /// Una captura completa: foto → calidad → detección → alineación →
  /// embedding → identificación. No decide nada, solo reporta.
  Future<_ScanOutcome> _captureAndIdentify() async {
    final file = await _cameraService.takePicture();
    if (file == null) {
      return const _ScanOutcome.discarded(null, resetVotes: false);
    }

    // --- Calidad de luz ---
    final bytes = await file.readAsBytes();
    final lightResult = _lightQuality.analyzeImage(bytes);
    if (mounted) {
      setState(() {
        _lightStatus = lightResult.feedback;
        _lightColor = lightResult.feedbackColor;
      });
    }
    if (lightResult.isOverexposed ||
        lightResult.isBacklit ||
        lightResult.isTooDark) {
      return _ScanOutcome.discarded(lightResult.feedback);
    }

    // --- Detección y encuadre ---
    final detection = await _faceDetection.detectFace(
      file.path,
      minFaceSize: _minFaceSize,
      centerTolerancePercentage: _centerTolerance,
    );

    if (detection == null) {
      return const _ScanOutcome.discarded(
        "Buscando rostro...",
        resetVotes: false,
      );
    }

    if (detection.hasCompetingFace) {
      return const _ScanOutcome.discarded(
        "⚠️ Hay más de una persona frente a la cámara.\n"
        "Acércate solo tú para marcar.",
      );
    }
    if (detection.isNotCentered) {
      return const _ScanOutcome.discarded(
        "⚠️ Por favor, centra tu rostro en el círculo.",
      );
    }
    if (detection.isTooSmall) {
      return const _ScanOutcome.discarded(
        "⚠️ Por favor, acércate más a la pantalla.",
      );
    }
    if (detection.yaw.abs() > 15.0 || detection.pitch.abs() > 15.0) {
      return const _ScanOutcome.discarded(
        "⚠️ Por favor, mira de frente a la pantalla.",
      );
    }
    if (detection.isBlurry) {
      // Un rostro borroso produce un embedding degradado que se acerca al
      // promedio poblacional: es una de las fuentes principales de falsos
      // positivos. Se descarta el frame en lugar de arriesgar la marcación.
      return const _ScanOutcome.discarded(
        "⚠️ Imagen movida. Mantente quieto un momento.",
      );
    }
    if (!detection.isWellLandmarked) {
      return const _ScanOutcome.discarded(
        "⚠️ Rostro parcialmente cubierto. Despeja la cara.",
      );
    }

    // --- Alineación y embedding ---
    final aligned = _faceDetection.alignFace(detection);
    if (aligned == null) {
      return const _ScanOutcome.discarded("Ajustando encuadre...");
    }

    final embedding = _faceRecognition.getEmbedding(aligned);
    if (embedding == null) {
      return const _ScanOutcome.discarded("Ajustando encuadre...");
    }

    // --- Identificación con umbral Y margen ---
    final result = _faceRecognition.identify(
      embedding,
      _gallery,
      threshold: _threshold,
      margin: _margin,
    );

    return _ScanOutcome.identified(result, aligned);
  }

  Future<void> _markAttendance() async {
    if (_isProcessing || !mounted) return;
    setState(() {
      _isProcessing = true;
      _topMatches = [];
    });

    try {
      await _refreshGallery();

      if (_gallery.isEmpty) {
        _resetVotes();
        setState(() {
          _status = _galleryRejected > 0
              ? "Galería biométrica sin plantillas válidas "
                    "($_galleryRejected descartadas). Requiere re-enrolamiento."
              : "No hay colaboradores enrolados en el dispositivo.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });
        return;
      }

      // En modo automático cada tick del temporizador aporta un voto.
      // En modo manual una sola pulsación toma la ráfaga completa, para no
      // obligar al colaborador a pulsar el botón varias veces.
      final int maxCapturas = _isAutoMode ? 1 : _requiredVotes + 2;

      _ScanOutcome? ultima;
      bool confirmado = false;

      for (int i = 0; i < maxCapturas && !confirmado; i++) {
        if (!mounted) return;
        final outcome = await _captureAndIdentify();
        ultima = outcome;

        if (!outcome.isUsable) {
          if (outcome.resetVotes) _resetVotes();
          final feedback = outcome.feedback;
          if (feedback != null && mounted) {
            setState(() => _status = feedback);
          }
          if (_isAutoMode) {
            setState(() => _isProcessing = false);
            return;
          }
          continue;
        }

        final r = outcome.identification!;
        debugPrint('[Reconocimiento] ${r.debugLine}');

        if (!r.accepted) {
          // Rechazo por umbral o por margen insuficiente: la votación se
          // reinicia por completo. Un intento dudoso nunca acumula.
          _resetVotes();
          debugPrint('[Reconocimiento] Rechazado: ${r.rejectionReason}');
          if (_isAutoMode) break;
          continue;
        }

        confirmado = _registerVote(r);

        if (!confirmado && mounted) {
          setState(() {
            _status = "Confirmando identidad... ($_voteCount/$_requiredVotes)";
          });
          if (!_isAutoMode) {
            await Future.delayed(const Duration(milliseconds: 300));
          }
        }
      }

      if (!confirmado) {
        if (_isAutoMode) {
          setState(() {
            if (_voteCount == 0) _status = "Mira a la cámara para marcar";
            _isProcessing = false;
          });
        } else {
          setState(() {
            _scanState = ScanState.failure;
            _status = "Rostro no reconocido con la certeza requerida.";
            _isProcessing = false;
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
        }
        return;
      }

      // ---------------- Identidad confirmada ----------------
      final matchedId = _voteEmployeeId!;
      final distance = _voteBestDistance;
      final margenFinal = _voteMinMargin;
      final rivalId = ultima?.identification?.runnerUpEmployeeId;
      final rostroAlineado = ultima?.aligned;
      _resetVotes();

      {
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

          // 5. Guardar localmente en SQLite con rastro auditable completo:
          //    distancia, margen contra el segundo candidato, quién era ese
          //    candidato, la foto del rostro que produjo la decisión y, si
          //    hubo bypass, quién lo autorizó y por qué.
          final deviceId = await _database.getDeviceId();

          String? evidenciaPath;
          if (rostroAlineado != null) {
            evidenciaPath = await _guardarEvidencia(
              rostroAlineado,
              employee.employeeCode,
              now,
            );
          }

          final recordId = await _database.insertAttendance(
            matchedId,
            now,
            distance,
            evento: selection,
            tipo: tipoFinal,
            duracion: duracionRetardo,
            isSynced: 0,
            dispositivoId: deviceId,
            margen: margenFinal.isFinite ? margenFinal : null,
            rivalEmployeeId: rivalId,
            evidenciaPath: evidenciaPath,
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
      }
    } catch (e) {
      _resetVotes();
      setState(() => _status = "Error: $e");
    } finally {
      setState(() => _isProcessing = false);
      if (_isAutoMode && mounted && _scanState == ScanState.idle) {
        _startAutoTimer();
      }
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

    // Si quedó en estado de fallo (rechazo, cancelación, error, etc.), el
    // aro/ícono rojo se limpia solo tras un momento. Sin esto, cualquier
    // camino que llegue aquí con _scanState == failure deja el ícono de
    // error pegado en pantalla indefinidamente.
    if (_scanState == ScanState.failure) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _scanState == ScanState.failure) {
          setState(() {
            _scanState = ScanState.idle;
            _status = _isAutoMode
                ? "Mira a la cámara para marcar"
                : "Presiona Marcar para escanear";
            _topMatches = [];
          });
          // _startAutoTimer() de más arriba se bloqueó porque en ese momento
          // _scanState todavía era failure. Ahora que ya volvió a idle, hay
          // que rearmar el temporizador o el modo automático se queda
          // pausado para siempre después de este tipo de fallo.
          if (_isAutoMode) {
            _startAutoTimer();
          }
        }
      });
    }
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

    // La marcación por cédula NO verifica identidad: quien la usa solo tiene
    // que conocer un número. Sin control era el mayor hueco de fraude del
    // sistema — mayor que cualquier falso positivo del reconocimiento, porque
    // permitía a cualquiera marcarle la asistencia a un compañero ausente.
    // Ahora es un respaldo que exige un supervisor presente y queda auditado.
    final autorizado = await _supervisor.solicitar(
      context,
      titulo: 'Marcación manual por cédula',
      motivo:
          'Este método no verifica la identidad del colaborador. '
          'Úsalo solo cuando el reconocimiento facial falle y puedas '
          'confirmar en persona quién está marcando.',
    );

    if (!autorizado) {
      if (mounted) {
        setState(() {
          _status = _isAutoMode
              ? "Mira a la cámara para marcar"
              : "Presiona Marcar para escanear";
        });
      }
      _resumeAutoTimerAfterDelay();
      return;
    }

    if (!mounted) return;

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
        autorizadoPor: 'SUPERVISOR',
        bypassMotivo: 'Marcación manual sin verificación biométrica',
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
                if (_voteCount > 0 && _scanState == ScanState.idle)
                  Center(
                    child: SizedBox(
                      width: 263,
                      height: 263,
                      child: CircularProgressIndicator(
                        value: _voteCount / _requiredVotes,
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

                      // Resaltar solo si supera el umbral REAL en uso.
                      final isMatch = distance < _threshold;

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

/// Resultado de UNA captura. Separa "el frame no sirve" de "el frame sirve y
/// esto es lo que dijo el reconocedor", para que la política de votación viva
/// en un único sitio.
class _ScanOutcome {
  final IdentificationResult? identification;
  final img.Image? aligned;
  final String? feedback;

  /// Si el descarte debe invalidar los votos acumulados. Los descartes
  /// transitorios (no hay rostro todavía) no rompen una secuencia en curso;
  /// los que indican un cambio de condiciones sí.
  final bool resetVotes;

  const _ScanOutcome.identified(
    IdentificationResult this.identification,
    img.Image this.aligned,
  )   : feedback = null,
        resetVotes = false;

  const _ScanOutcome.discarded(this.feedback, {this.resetVotes = true})
      : identification = null,
        aligned = null;

  bool get isUsable => identification != null;
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
        if (mounted) Navigator.of(context).pop(null);
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
      content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),

                // Se muestran siempre las 4 opciones: el colaborador elige
                // libremente, sin restricción por el último registro del día.
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
                const SizedBox(height: 12),

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
                const SizedBox(height: 12),

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
