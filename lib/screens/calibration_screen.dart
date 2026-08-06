import 'package:flutter/material.dart';
import '../models/employee.dart';
import '../services/calibration_service.dart';
import '../services/camera_service.dart';
import '../services/database_service.dart';
import '../services/face_detection_service.dart';
import '../services/face_recognition_service.dart';
import '../theme/app_colors.dart';
import 'enrollment_status_screen.dart';
import 'attendance_screen.dart'
    show
        kCfgUmbral,
        kCfgMargen,
        kCfgVotos,
        kUmbralPorDefecto,
        kMargenPorDefecto,
        kVotosPorDefecto;

/// Calibra el reconocimiento con datos reales de esta sede.
///
/// Sustituye el "slider de sensibilidad" a ojo por una medición: analiza todas
/// las comparaciones entre plantillas de personas distintas y sitúa el umbral
/// por debajo de la más cercana. También revela qué pares de colaboradores son
/// los que el sistema puede confundir.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final _database = DatabaseService();
  final _faceDetection = FaceDetectionService();
  final _faceRecognition = FaceRecognitionService();
  final _cameraService = CameraService();

  bool _cargando = false;
  String _paso = '';

  EmbeddingPurgeReport? _purga;
  CalibrationReport? _reporte;
  List<GalleryTemplate> _gallery = const [];
  Map<int, Employee> _empleados = {};

  double _umbralActual = kUmbralPorDefecto;
  double _margenActual = kMargenPorDefecto;
  int _votosActuales = kVotosPorDefecto;

  // Prueba en vivo
  bool _probando = false;
  String _resultadoPrueba = '';
  List<_MatchDebug> _topPrueba = const [];

  @override
  void initState() {
    super.initState();
    _cargarActuales();
  }

  Future<void> _cargarActuales() async {
    final t = await _database.getConfig(kCfgUmbral);
    final m = await _database.getConfig(kCfgMargen);
    final v = await _database.getConfig(kCfgVotos);
    if (!mounted) return;
    setState(() {
      _umbralActual = double.tryParse(t ?? '') ?? kUmbralPorDefecto;
      _margenActual = double.tryParse(m ?? '') ?? kMargenPorDefecto;
      _votosActuales = int.tryParse(v ?? '') ?? kVotosPorDefecto;
    });
  }

  // ------------------------------------------------------------------
  // Análisis
  // ------------------------------------------------------------------

  Future<void> _ejecutarAnalisis() async {
    setState(() {
      _cargando = true;
      _paso = 'Limpiando plantillas inválidas...';
      _reporte = null;
    });

    try {
      // 1. Purga: fuera vectores de ceros, dimensiones ajenas y no finitos.
      final purga = await _database.purgarEmbeddingsInvalidos();

      setState(() => _paso = 'Cargando galería...');
      final rows = await _database.getAllEmbeddings();
      final built = FaceRecognitionService.buildGallery(rows, frontalOnly: true);

      final empleados = <int, Employee>{};
      for (final id in built.enrolledEmployeeIds) {
        final e = await _database.getEmployeeById(id);
        if (e != null) empleados[id] = e;
      }

      setState(
        () => _paso =
            'Comparando ${built.templates.length} plantillas entre sí...',
      );

      final reporte = await CalibrationService.analizar(built.templates);

      if (!mounted) return;
      setState(() {
        _purga = purga;
        _gallery = built.templates;
        _empleados = empleados;
        _reporte = reporte;
        _cargando = false;
        _paso = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _paso = '';
      });
      _snack('Error durante el análisis: $e', AppColors.error);
    }
  }

  Future<void> _aplicarRecomendacion() async {
    final r = _reporte;
    if (r == null) return;

    await _database.saveConfig(kCfgUmbral, r.umbralRecomendado.toString());
    await _database.saveConfig(kCfgMargen, r.margenRecomendado.toString());
    await _database.saveConfig(kCfgVotos, _votosActuales.toString());

    await _cargarActuales();
    _snack('Parámetros aplicados. Reinicia la pantalla de marcación.',
        AppColors.success);
  }

  // ------------------------------------------------------------------
  // Prueba en vivo
  // ------------------------------------------------------------------

  Future<void> _pruebaEnVivo() async {
    if (_gallery.isEmpty) {
      _snack('Ejecuta primero el análisis.', AppColors.error);
      return;
    }

    setState(() {
      _probando = true;
      _resultadoPrueba = 'Iniciando cámara...';
      _topPrueba = const [];
    });

    try {
      if (!_cameraService.isInitialized) {
        await _cameraService.initialize();
      }
      await _faceRecognition.initialize();

      setState(() => _resultadoPrueba = 'Mira a la cámara...');
      await Future.delayed(const Duration(milliseconds: 800));

      final file = await _cameraService.takePicture();
      if (file == null) {
        setState(() {
          _resultadoPrueba = 'No se pudo capturar.';
          _probando = false;
        });
        return;
      }

      final detection = await _faceDetection.detectFace(file.path);
      if (detection == null) {
        setState(() {
          _resultadoPrueba = 'No se detectó ningún rostro.';
          _probando = false;
        });
        return;
      }

      final diagnostico = await _faceDetection.diagnosticarOrientacion(
        file.path,
      );

      final aligned = _faceDetection.alignFace(detection);
      final embedding = aligned == null
          ? null
          : _faceRecognition.getEmbedding(aligned);

      if (embedding == null) {
        setState(() {
          _resultadoPrueba = 'No se pudo generar el embedding.';
          _probando = false;
        });
        return;
      }

      final id = _faceRecognition.identify(
        embedding,
        _gallery,
        threshold: _umbralActual,
        margin: _margenActual,
      );

      final top = _faceRecognition.findTopMatches(embedding, _gallery, limit: 5);
      final debug = top
          .map(
            (m) => _MatchDebug(
              nombre: _empleados[m.$1]?.name ?? 'ID ${m.$1}',
              codigo: _empleados[m.$1]?.employeeCode ?? '-',
              distancia: m.$2,
            ),
          )
          .toList();

      setState(() {
        _topPrueba = debug;
        _resultadoPrueba =
            '${id.accepted ? "✅ ACEPTADO" : "❌ RECHAZADO"}\n'
            '${id.accepted ? "" : "${id.rejectionReason}\n"}'
            'Distancia: ${id.distance.toStringAsFixed(4)}  •  '
            'Margen: ${id.margin.isFinite ? id.margin.toStringAsFixed(4) : "∞"}\n'
            'Nitidez: ${detection.sharpness.toStringAsFixed(1)}  •  '
            'Landmarks: ${detection.landmarkCount}/5\n'
            '$diagnostico';
        _probando = false;
      });
    } catch (e) {
      setState(() {
        _resultadoPrueba = 'Error: $e';
        _probando = false;
      });
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _faceDetection.dispose();
    _faceRecognition.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? AppColors.kioskBackground
          : AppColors.background,
      appBar: AppBar(
        title: const Text('Calibrar Reconocimiento'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: isDark ? Colors.white : Colors.black,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _tarjetaActual(isDark),
            const SizedBox(height: 16),
            _tarjetaAnalisis(isDark),
            if (_purga != null) ...[
              const SizedBox(height: 16),
              _tarjetaPurga(isDark),
            ],
            if (_reporte != null) ...[
              const SizedBox(height: 16),
              _tarjetaResultados(isDark),
              const SizedBox(height: 16),
              _tarjetaRiesgo(isDark),
            ],
            const SizedBox(height: 16),
            _tarjetaPrueba(isDark),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _card(bool isDark, {required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: isDark ? AppColors.kioskSurface : Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
    ),
    child: child,
  );

  Widget _titulo(String texto, IconData icono) => Row(
    children: [
      Icon(icono, color: AppColors.primary, size: 22),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          texto,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    ],
  );

  Widget _tarjetaActual(bool isDark) => _card(
    isDark,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titulo('Parámetros en uso', Icons.settings_suggest_outlined),
        const SizedBox(height: 12),
        _fila('Umbral de distancia', _umbralActual.toStringAsFixed(3)),
        _fila('Margen mínimo vs. 2º candidato', _margenActual.toStringAsFixed(3)),
        _fila('Frames coincidentes exigidos', '$_votosActuales'),
        const SizedBox(height: 10),
        const Text(
          'Una identificación se acepta solo si la distancia es menor al umbral, '
          'el segundo candidato está al menos "margen" más lejos, y esto se '
          'repite en varias capturas seguidas.',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    ),
  );

  Widget _tarjetaAnalisis(bool isDark) => _card(
    isDark,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titulo('Analizar la galería real', Icons.science_outlined),
        const SizedBox(height: 8),
        const Text(
          'Compara todas las plantillas entre sí para medir qué tan cerca están '
          'las personas distintas. El umbral debe quedar por debajo de la '
          'pareja más parecida.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        if (_cargando) ...[
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _paso,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ] else
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _ejecutarAnalisis,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text(
              'Ejecutar análisis',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
      ],
    ),
  );

  Widget _tarjetaPurga(bool isDark) {
    final p = _purga!;
    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo('Limpieza de la galería', Icons.cleaning_services_outlined),
          const SizedBox(height: 12),
          _fila('Plantillas revisadas', '${p.totalRevisados}'),
          _fila('Eliminadas por inválidas', '${p.eliminados}'),
          _fila('Re-normalizadas (no eran unitarias)', '${p.renormalizados}'),
          if (p.renormalizados > 0) ...[
            const SizedBox(height: 10),
            _aviso(
              'Se encontraron ${p.renormalizados} plantillas sin normalizar. '
              'Un vector sin normalizar distorsiona la distancia coseno y puede '
              'ganar todas las comparaciones — es una causa directa de falsos '
              'positivos. Ya quedaron corregidas.',
              Colors.orange,
            ),
          ],
          const SizedBox(height: 14),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const EnrollmentStatusScreen(),
                ),
              );
              if (mounted) _ejecutarAnalisis();
            },
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Ver quién quedó sin enrolar'),
          ),
        ],
      ),
    );
  }

  Widget _tarjetaResultados(bool isDark) {
    final r = _reporte!;

    if (!r.suficiente) {
      return _card(
        isDark,
        child: _aviso(r.justificacion, AppColors.error),
      );
    }

    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo('Resultado de la medición', Icons.insights_outlined),
          const SizedBox(height: 12),
          _fila('Personas con plantilla', '${r.personas}'),
          _fila('Plantillas frontales', '${r.plantillas}'),
          const Divider(height: 24),

          const Text(
            'Distancias entre personas DISTINTAS (impostores)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          _fila('Mínima observada', _n(r.impostorMin), destacar: true),
          _fila('Percentil 0.1%', _n(r.impostorP01)),
          _fila('Percentil 1%', _n(r.impostorP1)),
          _fila('Media', _n(r.impostorMedia)),
          const SizedBox(height: 14),

          const Text(
            'Distancias de la MISMA persona (genuinas)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          _fila('Media', _n(r.genuinoMedia)),
          _fila('Percentil 95%', _n(r.genuinoP95)),
          _fila('Máxima', _n(r.genuinoMax)),
          const SizedBox(height: 8),
          const Text(
            'Nota: la distribución genuina se calcula entre plantillas '
            'enroladas, no entre capturas en vivo, así que es optimista. '
            'Usa la prueba en vivo para verla en condiciones reales.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontStyle: FontStyle.italic,
            ),
          ),

          const Divider(height: 28),
          _titulo('Recomendación', Icons.recommend_outlined),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _metricaGrande(
                  'Umbral',
                  r.umbralRecomendado.toStringAsFixed(3),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _metricaGrande(
                  'Margen',
                  r.margenRecomendado.toStringAsFixed(3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            r.justificacion,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (r.hayTraslape) ...[
            const SizedBox(height: 10),
            _aviso(
              'Con traslape no existe un umbral perfecto. Si tras aplicarlo '
              'hay muchos rechazos legítimos, la solución no es subir el '
              'umbral sino mejorar el enrolamiento (mejor luz, rostro '
              'despejado, re-enrolar a quienes fallen).',
              Colors.orange,
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _aplicarRecomendacion,
            icon: const Icon(Icons.check_rounded),
            label: const Text(
              'Aplicar estos valores',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tarjetaRiesgo(bool isDark) {
    final r = _reporte!;
    final enRiesgo = r.paresEnRiesgo(_umbralActual);

    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo('Pares más confundibles', Icons.people_alt_outlined),
          const SizedBox(height: 8),
          const Text(
            'Los colaboradores cuyas plantillas están más cerca entre sí. '
            'Si alguno aparece con una distancia muy baja, revisa que no sea '
            'la misma persona enrolada dos veces con cédulas distintas.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 14),
          if (r.paresMasCercanos.isEmpty)
            const Text(
              'Sin datos suficientes.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            )
          else
            ...r.paresMasCercanos.take(8).map((par) {
              final a = _empleados[par.employeeIdA];
              final b = _empleados[par.employeeIdB];
              final peligroso = par.distancia < _umbralActual;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: peligroso
                      ? AppColors.error.withOpacity(0.08)
                      : Colors.grey.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: peligroso
                        ? AppColors.error.withOpacity(0.4)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${a?.name ?? "ID ${par.employeeIdA}"}  ↔  '
                            '${b?.name ?? "ID ${par.employeeIdB}"}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${a?.employeeCode ?? "-"} / ${b?.employeeCode ?? "-"}'
                            '  •  ${par.poseA}–${par.poseB}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      par.distancia.toStringAsFixed(4),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: peligroso ? AppColors.error : AppColors.primary,
                      ),
                    ),
                  ],
                ),
              );
            }),
          if (enRiesgo.isNotEmpty) ...[
            const SizedBox(height: 8),
            _aviso(
              '${enRiesgo.length} par(es) están por debajo del umbral actual '
              '(${_umbralActual.toStringAsFixed(3)}). El sistema puede '
              'confundirlos. Aplica la recomendación o re-enrola a esas '
              'personas con mejor calidad.',
              AppColors.error,
            ),
          ],
        ],
      ),
    );
  }

  Widget _tarjetaPrueba(bool isDark) => _card(
    isDark,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titulo('Prueba en vivo', Icons.camera_alt_outlined),
        const SizedBox(height: 8),
        const Text(
          'Captura un rostro real y muestra la decisión completa: distancia, '
          'margen, nitidez, landmarks y orientación EXIF de la cámara.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: _probando ? null : _pruebaEnVivo,
          icon: _probando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_search_rounded),
          label: const Text('Capturar y diagnosticar'),
        ),
        if (_resultadoPrueba.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _resultadoPrueba,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Colors.white70,
              ),
            ),
          ),
        ],
        if (_topPrueba.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Candidatos más cercanos',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          ..._topPrueba.map(
            (m) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${m.nombre} (${m.codigo})',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    m.distancia.toStringAsFixed(4),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: m.distancia < _umbralActual
                          ? AppColors.success
                          : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _fila(String etiqueta, String valor, {bool destacar = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                etiqueta,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            Text(
              valor,
              style: TextStyle(
                fontSize: destacar ? 15 : 13,
                fontWeight: FontWeight.bold,
                color: destacar ? AppColors.primary : null,
              ),
            ),
          ],
        ),
      );

  Widget _metricaGrande(String etiqueta, String valor) => Container(
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: BoxDecoration(
      color: AppColors.primary.withOpacity(0.10),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.primary.withOpacity(0.3)),
    ),
    child: Column(
      children: [
        Text(
          etiqueta,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          valor,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: AppColors.primary,
          ),
        ),
      ],
    ),
  );

  Widget _aviso(String texto, Color color) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withOpacity(0.10),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withOpacity(0.35)),
    ),
    child: Text(texto, style: TextStyle(fontSize: 12, color: color)),
  );

  String _n(double v) => v.isNaN ? '—' : v.toStringAsFixed(4);
}

class _MatchDebug {
  final String nombre;
  final String codigo;
  final double distancia;

  const _MatchDebug({
    required this.nombre,
    required this.codigo,
    required this.distancia,
  });
}
