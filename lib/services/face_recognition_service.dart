import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

/// Servicio de extracción y comparación de embeddings faciales.
///
/// Reglas invariantes de este servicio:
///  1. TODO embedding que entra o sale está normalizado L2. La distancia coseno
///     se calcula como `1 - dot(a,b)`, fórmula que SOLO es válida con vectores
///     unitarios. Un vector sin normalizar gana todas las comparaciones y
///     produce falsos positivos sistemáticos.
///  2. TODO embedding tiene exactamente [embeddingSize] dimensiones. Vectores
///     de otro modelo se rechazan en lugar de compararse parcialmente.
///  3. La identificación exige umbral Y margen contra el segundo candidato de
///     otra persona.
class FaceRecognitionService {
  Interpreter? _interpreter;

  static const int embeddingSize = 192;
  static const int inputSize = 112;

  /// Poses que se usan para IDENTIFICAR. Las poses de perfil ('Izquierda',
  /// 'Derecha', 'Arriba') se capturan en el enrolamiento por robustez y para
  /// verificar que la persona es real, pero NO se usan para comparar: son
  /// embeddings degradados que quedan cerca del promedio poblacional y generan
  /// coincidencias cruzadas entre personas distintas.
  static const Set<String> frontalPoses = {'Frontal', 'Sonrisa'};

  Future<void> initialize() async {
    if (_interpreter != null) return;
    final interpreterOptions = InterpreterOptions()..threads = 4;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobilefacenet.tflite',
      options: interpreterOptions,
    );
  }

  bool get isReady => _interpreter != null;

  // ====================================================================
  // Extracción
  // ====================================================================

  /// Calcula el embedding de un rostro YA ALINEADO a 112x112.
  ///
  /// Recibe la imagen en memoria para evitar el viaje de ida y vuelta por JPEG
  /// que introducía artefactos de compresión en la entrada del modelo.
  List<double>? getEmbedding(img.Image alignedFace) {
    if (_interpreter == null) {
      throw StateError('FaceRecognitionService.initialize() no fue llamado.');
    }

    final image = (alignedFace.width == inputSize &&
            alignedFace.height == inputSize)
        ? alignedFace
        : img.copyResize(alignedFace, width: inputSize, height: inputSize);

    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(
          inputSize,
          (x) => List.generate(3, (c) {
            final pixel = image.getPixel(x, y);
            final val = c == 0 ? pixel.r : (c == 1 ? pixel.g : pixel.b);
            return (val - 127.5) / 128.0;
          }),
        ),
      ),
    );

    final output = List<double>.filled(
      embeddingSize,
      0,
    ).reshape([1, embeddingSize]);

    _interpreter!.run(input, output);

    return sanitize(List<double>.from(output[0]));
  }

  /// Variante para bytes codificados (compatibilidad).
  List<double>? getEmbeddingFromBytes(Uint8List imageBytes) {
    final image = img.decodeImage(imageBytes);
    if (image == null) return null;
    return getEmbedding(image);
  }

  // ====================================================================
  // Saneamiento — el punto único de verdad para validar un embedding
  // ====================================================================

  /// Valida y normaliza L2 un vector. Devuelve `null` si es inutilizable:
  /// dimensión incorrecta, valores no finitos, o norma prácticamente cero
  /// (los vectores de ceros que se subían como relleno de poses faltantes).
  static List<double>? sanitize(List<double>? vector) {
    if (vector == null || vector.length != embeddingSize) return null;

    double sumSquares = 0;
    for (final v in vector) {
      if (!v.isFinite) return null;
      sumSquares += v * v;
    }

    final magnitude = sqrt(sumSquares);
    if (!magnitude.isFinite || magnitude < 1e-6) return null;

    return vector.map((v) => v / magnitude).toList(growable: false);
  }

  /// Parsea la representación en texto de SQLite y la sanea.
  static List<double>? parseStored(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != embeddingSize) return null;

    final values = List<double>.filled(embeddingSize, 0);
    for (int i = 0; i < embeddingSize; i++) {
      final v = double.tryParse(parts[i]);
      if (v == null) return null;
      values[i] = v;
    }
    return sanitize(values);
  }

  // ====================================================================
  // Distancia
  // ====================================================================

  /// Distancia coseno entre dos embeddings unitarios (0 = idénticos, 2 = opuestos).
  /// Ambos vectores DEBEN venir de [sanitize].
  double cosineDistance(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError(
        'Dimensiones incompatibles: ${a.length} vs ${b.length}',
      );
    }
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return 1.0 - dot;
  }

  // ====================================================================
  // Construcción de galería
  // ====================================================================

  /// Convierte las filas crudas de SQLite en plantillas validadas.
  ///
  /// Hacerlo una sola vez (y no en cada frame) evita re-parsear miles de
  /// vectores por captura, además de dejar fuera los corruptos de una vez.
  static GalleryBuildResult buildGallery(
    List<Map<String, dynamic>> rows, {
    bool frontalOnly = true,
  }) {
    final templates = <GalleryTemplate>[];
    int rejected = 0;
    final rejectedEmployees = <int>{};

    for (final row in rows) {
      final employeeId = row['employee_id'] as int?;
      final raw = row['embedding'] as String?;
      final angle = (row['angle_type'] as String?) ?? 'Frontal';

      if (employeeId == null || raw == null) {
        rejected++;
        continue;
      }

      if (frontalOnly && !frontalPoses.contains(angle)) continue;

      final vector = parseStored(raw);
      if (vector == null) {
        rejected++;
        rejectedEmployees.add(employeeId);
        continue;
      }

      templates.add(
        GalleryTemplate(
          employeeId: employeeId,
          angleType: angle,
          vector: vector,
        ),
      );
    }

    return GalleryBuildResult(
      templates: templates,
      rejectedCount: rejected,
      rejectedEmployeeIds: rejectedEmployees,
    );
  }

  // ====================================================================
  // Identificación
  // ====================================================================

  /// Identifica al empleado más cercano aplicando umbral Y test de margen.
  ///
  /// El test de margen es lo que distingue una identificación confiable de un
  /// falso positivo: no basta con que el mejor candidato esté cerca, tiene que
  /// estar CLARAMENTE más cerca que la mejor plantilla de cualquier otra
  /// persona. Si dos personas compiten por el mismo rostro, se rechaza.
  IdentificationResult identify(
    List<double> query,
    List<GalleryTemplate> gallery, {
    required double threshold,
    required double margin,
  }) {
    if (gallery.isEmpty) {
      return IdentificationResult.empty('Galería vacía');
    }

    double bestDistance = double.infinity;
    int? bestId;
    String? bestPose;

    // Mejor distancia por empleado, para poder localizar al rival real.
    final bestPerEmployee = <int, double>{};

    for (final t in gallery) {
      final d = cosineDistance(query, t.vector);
      if (!d.isFinite) continue;

      final prev = bestPerEmployee[t.employeeId];
      if (prev == null || d < prev) {
        bestPerEmployee[t.employeeId] = d;
      }

      if (d < bestDistance) {
        bestDistance = d;
        bestId = t.employeeId;
        bestPose = t.angleType;
      }
    }

    if (bestId == null || !bestDistance.isFinite) {
      return IdentificationResult.empty('Sin plantillas comparables');
    }

    // Segundo mejor candidato PERTENECIENTE A OTRA PERSONA.
    double runnerUpDistance = double.infinity;
    int? runnerUpId;
    bestPerEmployee.forEach((id, d) {
      if (id != bestId && d < runnerUpDistance) {
        runnerUpDistance = d;
        runnerUpId = id;
      }
    });

    final observedMargin = runnerUpDistance.isFinite
        ? runnerUpDistance - bestDistance
        : double.infinity;

    final passesThreshold = bestDistance < threshold;
    final passesMargin = observedMargin >= margin;

    String? reason;
    if (!passesThreshold) {
      reason = 'Distancia ${bestDistance.toStringAsFixed(4)} '
          '>= umbral ${threshold.toStringAsFixed(4)}';
    } else if (!passesMargin) {
      reason = 'Margen insuficiente (${observedMargin.toStringAsFixed(4)} < '
          '${margin.toStringAsFixed(4)}): el rostro se parece demasiado a un '
          'segundo colaborador';
    }

    return IdentificationResult(
      employeeId: bestId,
      distance: bestDistance,
      pose: bestPose,
      runnerUpEmployeeId: runnerUpId,
      runnerUpDistance: runnerUpDistance,
      margin: observedMargin,
      accepted: passesThreshold && passesMargin,
      rejectionReason: reason,
      gallerySize: bestPerEmployee.length,
    );
  }

  /// Top-N coincidencias por empleado, para depuración y calibración.
  List<(int, double)> findTopMatches(
    List<double> query,
    List<GalleryTemplate> gallery, {
    int limit = 3,
  }) {
    final bestPerEmployee = <int, double>{};
    for (final t in gallery) {
      final d = cosineDistance(query, t.vector);
      final prev = bestPerEmployee[t.employeeId];
      if (prev == null || d < prev) bestPerEmployee[t.employeeId] = d;
    }
    final entries = bestPerEmployee.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return entries.take(limit).map((e) => (e.key, e.value)).toList();
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}

/// Una plantilla biométrica validada y lista para comparar.
class GalleryTemplate {
  final int employeeId;
  final String angleType;
  final List<double> vector;

  const GalleryTemplate({
    required this.employeeId,
    required this.angleType,
    required this.vector,
  });
}

class GalleryBuildResult {
  final List<GalleryTemplate> templates;
  final int rejectedCount;
  final Set<int> rejectedEmployeeIds;

  const GalleryBuildResult({
    required this.templates,
    required this.rejectedCount,
    required this.rejectedEmployeeIds,
  });

  bool get isEmpty => templates.isEmpty;

  Set<int> get enrolledEmployeeIds =>
      templates.map((t) => t.employeeId).toSet();
}

class IdentificationResult {
  final int? employeeId;
  final double distance;
  final String? pose;
  final int? runnerUpEmployeeId;
  final double runnerUpDistance;
  final double margin;
  final bool accepted;
  final String? rejectionReason;
  final int gallerySize;

  const IdentificationResult({
    required this.employeeId,
    required this.distance,
    required this.pose,
    required this.runnerUpEmployeeId,
    required this.runnerUpDistance,
    required this.margin,
    required this.accepted,
    required this.rejectionReason,
    required this.gallerySize,
  });

  factory IdentificationResult.empty(String reason) => IdentificationResult(
        employeeId: null,
        distance: double.infinity,
        pose: null,
        runnerUpEmployeeId: null,
        runnerUpDistance: double.infinity,
        margin: 0,
        accepted: false,
        rejectionReason: reason,
        gallerySize: 0,
      );

  String get debugLine =>
      'id=$employeeId d=${distance.toStringAsFixed(4)} '
      'rival=$runnerUpEmployeeId d2=${runnerUpDistance.isFinite ? runnerUpDistance.toStringAsFixed(4) : "-"} '
      'margen=${margin.isFinite ? margin.toStringAsFixed(4) : "inf"} '
      'aceptado=$accepted';
}
