import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Servicio de detección, control de calidad y ALINEACIÓN de rostros.
///
/// Cambios clave respecto a la versión anterior:
///  - Se "hornea" la orientación EXIF antes de usar las coordenadas de ML Kit,
///    eliminando el desfase entre el bounding box y la imagen decodificada.
///  - El recorte ya no es un rectángulo crudo: se aplica una transformación de
///    similitud (rotación + escala + traslación) que lleva los landmarks del
///    rostro a la plantilla canónica de 112x112 que MobileFaceNet espera.
///  - Se añaden controles de calidad que reducen falsos positivos en origen:
///    nitidez (varianza del laplaciano) y presencia de múltiples rostros.
class FaceDetectionService {
  static const int alignedSize = 112;

  /// Plantilla canónica de 5 puntos para 112x112 (convención ArcFace).
  /// El orden es por POSICIÓN EN LA IMAGEN, no por lateralidad del sujeto:
  /// [ojo lado izq. de la imagen, ojo lado der., nariz, boca izq., boca der.]
  static const List<List<double>> _canonical = [
    [38.2946, 51.6963],
    [73.5318, 51.5014],
    [56.0252, 71.7366],
    [41.5493, 92.3655],
    [70.7299, 92.2041],
  ];

  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableTracking: true,
      enableClassification: true,
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  /// Detecta el rostro principal y devuelve toda la información de calidad.
  ///
  /// [minSharpness] es la varianza mínima del laplaciano sobre la región del
  /// rostro. Los frames borrosos producen embeddings degradados que se acercan
  /// al promedio poblacional y disparan falsos positivos, por eso se rechazan.
  ///
  /// El valor por defecto es deliberadamente permisivo: solo descarta frames
  /// claramente movidos. La escala depende de la cámara, así que conviene mirar
  /// la nitidez real en la prueba en vivo del calibrador antes de subirlo.
  Future<FaceDetectionResult?> detectFace(
    String imagePath, {
    int minFaceSize = 130,
    double centerTolerancePercentage = 0.15,
    double minSharpness = 5.0,
  }) async {
    // ------------------------------------------------------------------
    // 1. Normalizar la orientación ANTES de detectar.
    //
    // El paquete `image` no aplica EXIF automáticamente, pero ML Kit sí lo
    // interpreta. Si la tablet guarda las fotos con orientación EXIF != 1,
    // el bounding box apunta a una región distinta de la que recortamos.
    // Para eliminar la ambigüedad por completo enderezamos la imagen y, si
    // hubo rotación real, corremos el detector sobre la imagen enderezada.
    // ------------------------------------------------------------------
    final rawBytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) return null;

    // Se endereza SIEMPRE y se corre el detector sobre la imagen ya
    // enderezada y sin EXIF. Así las coordenadas que devuelve ML Kit
    // corresponden pixel a pixel con la imagen que vamos a recortar, sin
    // depender de si ML Kit interpreta o no la etiqueta EXIF.
    //
    // Cuesta una codificación JPEG por captura. Es un precio pequeño frente
    // a recortar la región equivocada de la cara, que degrada todos los
    // embeddings y es la causa silenciosa de falsos positivos en las tablets
    // que guardan las fotos rotadas.
    final img.Image upright = img.bakeOrientation(decoded);
    final bool camaraEntregaRotada =
        upright.width != decoded.width || upright.height != decoded.height;

    final tmpDir = await getTemporaryDirectory();
    final detectionPath = p.join(tmpDir.path, 'upright_frame.jpg');
    await File(detectionPath).writeAsBytes(img.encodeJpg(upright, quality: 95));

    final faces = await _detector.processImage(
      InputImage.fromFilePath(detectionPath),
    );
    if (faces.isEmpty) return null;

    // Ordenar por área descendente (el rostro más cercano a la cámara).
    faces.sort((a, b) {
      final areaA = a.boundingBox.width * a.boundingBox.height;
      final areaB = b.boundingBox.width * b.boundingBox.height;
      return areaB.compareTo(areaA);
    });

    final face = faces.first;
    final faceWidth = face.boundingBox.width;
    final faceHeight = face.boundingBox.height;
    final mainArea = faceWidth * faceHeight;

    // ------------------------------------------------------------------
    // 2. Múltiples rostros: si hay un segundo rostro de tamaño comparable
    //    no podemos saber a quién pertenece la marcación. Se rechaza.
    // ------------------------------------------------------------------
    bool hasCompetingFace = false;
    for (int i = 1; i < faces.length; i++) {
      final other = faces[i].boundingBox;
      final otherArea = other.width * other.height;
      if (otherArea > mainArea * 0.55) {
        hasCompetingFace = true;
        break;
      }
    }

    // ------------------------------------------------------------------
    // 3. Encuadre: tamaño y centrado.
    // ------------------------------------------------------------------
    final isTooSmall = faceWidth < minFaceSize || faceHeight < minFaceSize;

    final imgCenterX = upright.width / 2.0;
    final imgCenterY = upright.height / 2.0;
    final faceCenterX = face.boundingBox.left + faceWidth / 2.0;
    final faceCenterY = face.boundingBox.top + faceHeight / 2.0;

    final distanceToCenter = sqrt(
      pow(faceCenterX - imgCenterX, 2) + pow(faceCenterY - imgCenterY, 2),
    );
    final minDimension = min(upright.width, upright.height);
    final maxDistance = minDimension * centerTolerancePercentage;
    final isNotCentered = distanceToCenter > maxDistance;

    // ------------------------------------------------------------------
    // 4. Nitidez sobre la región del rostro.
    // ------------------------------------------------------------------
    final sharpness = _faceSharpness(upright, face.boundingBox);

    return FaceDetectionResult(
      face: face,
      uprightImage: upright,
      yaw: face.headEulerAngleY ?? 0,
      pitch: face.headEulerAngleX ?? 0,
      roll: face.headEulerAngleZ ?? 0,
      boundingBox: face.boundingBox,
      smilingProbability: face.smilingProbability,
      isTooSmall: isTooSmall,
      isNotCentered: isNotCentered,
      hasCompetingFace: hasCompetingFace,
      sharpness: sharpness,
      isBlurry: sharpness < minSharpness,
      camaraEntregaRotada: camaraEntregaRotada,
      anchoImagen: upright.width,
      altoImagen: upright.height,
      landmarkCount: _usableLandmarks(face).length,
    );
  }

  /// Alinea el rostro a 112x112 usando los landmarks.
  ///
  /// Devuelve la imagen ya alineada en memoria — sin pasar por JPEG — para no
  /// introducir artefactos de compresión en la entrada del modelo.
  ///
  /// Si no hay suficientes landmarks utilizables cae a un recorte CUADRADO
  /// centrado en el bounding box (sin deformación de aspecto), que es peor
  /// pero sigue siendo mucho mejor que el recorte rectangular anterior.
  img.Image? alignFace(FaceDetectionResult result) {
    final src = _usableLandmarks(result.face);

    if (src.length >= 3) {
      final dst = <Point<double>>[];
      final ordered = _orderLandmarksForTemplate(src, dst);
      if (ordered.length >= 3) {
        final t = _fitSimilarity(ordered, dst);
        if (t != null) {
          return _warp(result.uprightImage, t);
        }
      }
    }

    return _squareCrop(result.uprightImage, result.boundingBox);
  }

  // ====================================================================
  // Landmarks
  // ====================================================================

  /// Extrae los landmarks que usamos para alinear, indexados por tipo.
  Map<FaceLandmarkType, Point<double>> _usableLandmarks(Face face) {
    const wanted = [
      FaceLandmarkType.leftEye,
      FaceLandmarkType.rightEye,
      FaceLandmarkType.noseBase,
      FaceLandmarkType.leftMouth,
      FaceLandmarkType.rightMouth,
    ];

    final out = <FaceLandmarkType, Point<double>>{};
    for (final type in wanted) {
      final lm = face.landmarks[type];
      if (lm != null) {
        out[type] = Point<double>(
          lm.position.x.toDouble(),
          lm.position.y.toDouble(),
        );
      }
    }
    return out;
  }

  /// Empareja los landmarks detectados con la plantilla canónica.
  ///
  /// El emparejamiento se hace por POSICIÓN EN LA IMAGEN (el ojo con menor x
  /// va al punto canónico de menor x), no por la etiqueta izquierda/derecha de
  /// ML Kit. Así la alineación es correcta tanto si la cámara frontal entrega
  /// la imagen espejada como si no, y no depende de la convención de nombres.
  List<Point<double>> _orderLandmarksForTemplate(
    Map<FaceLandmarkType, Point<double>> src,
    List<Point<double>> dstOut,
  ) {
    final srcOut = <Point<double>>[];

    final eyeA = src[FaceLandmarkType.leftEye];
    final eyeB = src[FaceLandmarkType.rightEye];
    if (eyeA != null && eyeB != null) {
      final leftInImage = eyeA.x <= eyeB.x ? eyeA : eyeB;
      final rightInImage = eyeA.x <= eyeB.x ? eyeB : eyeA;
      srcOut.add(leftInImage);
      dstOut.add(Point(_canonical[0][0], _canonical[0][1]));
      srcOut.add(rightInImage);
      dstOut.add(Point(_canonical[1][0], _canonical[1][1]));
    }

    final nose = src[FaceLandmarkType.noseBase];
    if (nose != null) {
      srcOut.add(nose);
      dstOut.add(Point(_canonical[2][0], _canonical[2][1]));
    }

    final mouthA = src[FaceLandmarkType.leftMouth];
    final mouthB = src[FaceLandmarkType.rightMouth];
    if (mouthA != null && mouthB != null) {
      final leftInImage = mouthA.x <= mouthB.x ? mouthA : mouthB;
      final rightInImage = mouthA.x <= mouthB.x ? mouthB : mouthA;
      srcOut.add(leftInImage);
      dstOut.add(Point(_canonical[3][0], _canonical[3][1]));
      srcOut.add(rightInImage);
      dstOut.add(Point(_canonical[4][0], _canonical[4][1]));
    }

    return srcOut;
  }

  // ====================================================================
  // Transformación de similitud (Procrustes 2D, forma cerrada)
  // ====================================================================

  /// Ajusta por mínimos cuadrados la similitud que lleva [src] sobre [dst].
  /// Solo rotación + escala uniforme + traslación (sin reflexión ni cizalla),
  /// que es exactamente lo que exige la alineación facial.
  _SimTransform? _fitSimilarity(
    List<Point<double>> src,
    List<Point<double>> dst,
  ) {
    final n = src.length;
    if (n < 2 || n != dst.length) return null;

    double msx = 0, msy = 0, mdx = 0, mdy = 0;
    for (int i = 0; i < n; i++) {
      msx += src[i].x;
      msy += src[i].y;
      mdx += dst[i].x;
      mdy += dst[i].y;
    }
    msx /= n;
    msy /= n;
    mdx /= n;
    mdy /= n;

    double a = 0, b = 0, den = 0;
    for (int i = 0; i < n; i++) {
      final sx = src[i].x - msx;
      final sy = src[i].y - msy;
      final dx = dst[i].x - mdx;
      final dy = dst[i].y - mdy;
      a += dx * sx + dy * sy;
      b += dy * sx - dx * sy;
      den += sx * sx + sy * sy;
    }

    if (den <= 1e-9) return null;

    final theta = atan2(b, a);
    final scale = sqrt(a * a + b * b) / den;

    if (!scale.isFinite || scale <= 1e-9) return null;

    return _SimTransform(
      theta: theta,
      scale: scale,
      srcMeanX: msx,
      srcMeanY: msy,
      dstMeanX: mdx,
      dstMeanY: mdy,
    );
  }

  /// Aplica la transformación con muestreo bilineal (mapeo inverso).
  img.Image _warp(img.Image src, _SimTransform t) {
    final out = img.Image(
      width: alignedSize,
      height: alignedSize,
      numChannels: 3,
    );

    final inv = 1.0 / t.scale;
    final c = cos(t.theta);
    final s = sin(t.theta);

    for (int y = 0; y < alignedSize; y++) {
      final py = y - t.dstMeanY;
      for (int x = 0; x < alignedSize; x++) {
        final px = x - t.dstMeanX;

        // R(-theta) aplicada al punto de destino centrado, escalada a origen.
        final sx = t.srcMeanX + inv * (c * px + s * py);
        final sy = t.srcMeanY + inv * (-s * px + c * py);

        final rgb = _sampleBilinear(src, sx, sy);
        out.setPixelRgb(x, y, rgb[0], rgb[1], rgb[2]);
      }
    }

    return out;
  }

  List<num> _sampleBilinear(img.Image image, double x, double y) {
    final maxX = image.width - 1;
    final maxY = image.height - 1;

    final cx = x.clamp(0.0, maxX.toDouble());
    final cy = y.clamp(0.0, maxY.toDouble());

    final x0 = cx.floor();
    final y0 = cy.floor();
    final x1 = min(x0 + 1, maxX);
    final y1 = min(y0 + 1, maxY);

    final fx = cx - x0;
    final fy = cy - y0;

    final p00 = image.getPixel(x0, y0);
    final p10 = image.getPixel(x1, y0);
    final p01 = image.getPixel(x0, y1);
    final p11 = image.getPixel(x1, y1);

    double lerp(num a, num b, num cc, num d) {
      final top = a + (b - a) * fx;
      final bottom = cc + (d - cc) * fx;
      return top + (bottom - top) * fy;
    }

    return [
      lerp(p00.r, p10.r, p01.r, p11.r).round().clamp(0, 255),
      lerp(p00.g, p10.g, p01.g, p11.g).round().clamp(0, 255),
      lerp(p00.b, p10.b, p01.b, p11.b).round().clamp(0, 255),
    ];
  }

  // ====================================================================
  // Respaldo: recorte cuadrado sin deformación
  // ====================================================================

  img.Image? _squareCrop(img.Image original, Rect box) {
    // Lado cuadrado con 25% de margen sobre la dimensión mayor del rostro.
    final side = (max(box.width, box.height) * 1.25).round();
    final cx = (box.left + box.width / 2.0).round();
    final cy = (box.top + box.height / 2.0).round();

    final out = img.Image(
      width: alignedSize,
      height: alignedSize,
      numChannels: 3,
    );
    final step = side / alignedSize;
    final originX = cx - side / 2.0;
    final originY = cy - side / 2.0;

    for (int y = 0; y < alignedSize; y++) {
      final sy = originY + (y + 0.5) * step;
      for (int x = 0; x < alignedSize; x++) {
        final sx = originX + (x + 0.5) * step;
        final rgb = _sampleBilinear(original, sx, sy);
        out.setPixelRgb(x, y, rgb[0], rgb[1], rgb[2]);
      }
    }
    return out;
  }

  // ====================================================================
  // Nitidez
  // ====================================================================

  /// Varianza del laplaciano sobre la región del rostro (submuestreada).
  /// Valores bajos = imagen borrosa o movida.
  double _faceSharpness(img.Image image, Rect box) {
    final x0 = box.left.round().clamp(0, image.width - 1);
    final y0 = box.top.round().clamp(0, image.height - 1);
    final x1 = (box.right.round()).clamp(0, image.width - 1);
    final y1 = (box.bottom.round()).clamp(0, image.height - 1);

    if (x1 - x0 < 8 || y1 - y0 < 8) return 0;

    // Submuestrear a ~64 pasos por eje para mantenerlo barato.
    final stepX = max(1, ((x1 - x0) / 64).floor());
    final stepY = max(1, ((y1 - y0) / 64).floor());

    final values = <double>[];
    for (int y = y0 + stepY; y < y1 - stepY; y += stepY) {
      for (int x = x0 + stepX; x < x1 - stepX; x += stepX) {
        final c = _luma(image, x, y);
        final lap =
            4 * c -
            _luma(image, x - stepX, y) -
            _luma(image, x + stepX, y) -
            _luma(image, x, y - stepY) -
            _luma(image, x, y + stepY);
        values.add(lap);
      }
    }

    if (values.length < 4) return 0;

    final mean = values.reduce((a, b) => a + b) / values.length;
    double variance = 0;
    for (final v in values) {
      variance += (v - mean) * (v - mean);
    }
    return variance / values.length;
  }

  double _luma(img.Image image, int x, int y) {
    final p = image.getPixel(
      x.clamp(0, image.width - 1),
      y.clamp(0, image.height - 1),
    );
    return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
  }

  // ====================================================================
  // Diagnóstico (usado por la pantalla de calibración)
  // ====================================================================

  /// Reporta si la cámara de esta tablet entrega las fotos rotadas.
  ///
  /// Es el diagnóstico que confirma (o descarta) el desfase de orientación:
  /// si la imagen viene rotada y no se enderezara antes de detectar, el
  /// bounding box de ML Kit apuntaría a una región distinta de la que se
  /// recorta, y todos los embeddings saldrían corruptos.
  Future<String> diagnosticarOrientacion(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return 'No se pudo decodificar la imagen.';

    final upright = img.bakeOrientation(decoded);
    final rotada =
        upright.width != decoded.width || upright.height != decoded.height;

    if (!rotada) {
      return 'Cámara: ${decoded.width}x${decoded.height}, sin rotación EXIF.';
    }
    return 'Cámara: la foto llega ${decoded.width}x${decoded.height} y se '
        'endereza a ${upright.width}x${upright.height}. Esta corrección es '
        'obligatoria: sin ella los recortes quedarían desalineados.';
  }

  /// Convierte la imagen alineada a JPEG, solo para guardar evidencia.
  Uint8List encodeEvidence(img.Image aligned) =>
      Uint8List.fromList(img.encodeJpg(aligned, quality: 85));

  void dispose() => _detector.close();
}

class _SimTransform {
  final double theta;
  final double scale;
  final double srcMeanX;
  final double srcMeanY;
  final double dstMeanX;
  final double dstMeanY;

  const _SimTransform({
    required this.theta,
    required this.scale,
    required this.srcMeanX,
    required this.srcMeanY,
    required this.dstMeanX,
    required this.dstMeanY,
  });
}

class FaceDetectionResult {
  final Face face;

  /// Imagen con la orientación EXIF ya aplicada. Las coordenadas del
  /// bounding box y de los landmarks corresponden a ESTA imagen.
  final img.Image uprightImage;

  final double yaw, pitch, roll;
  final Rect boundingBox;
  final double? smilingProbability;
  final bool isTooSmall;
  final bool isNotCentered;
  final bool hasCompetingFace;
  final double sharpness;
  final bool isBlurry;

  /// true si la cámara entrega la foto rotada y hubo que enderezarla.
  final bool camaraEntregaRotada;
  final int anchoImagen;
  final int altoImagen;
  final int landmarkCount;

  FaceDetectionResult({
    required this.face,
    required this.uprightImage,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.boundingBox,
    this.smilingProbability,
    this.isTooSmall = false,
    this.isNotCentered = false,
    this.hasCompetingFace = false,
    this.sharpness = 0,
    this.isBlurry = false,
    this.camaraEntregaRotada = false,
    this.anchoImagen = 0,
    this.altoImagen = 0,
    this.landmarkCount = 0,
  });

  /// true si la alineación se hará con landmarks reales (calidad alta).
  bool get isWellLandmarked => landmarkCount >= 3;

  bool isValidPose(Map<String, double> pose) {
    return yaw >= pose['yawMin']! &&
        yaw <= pose['yawMax']! &&
        pitch >= pose['pitchMin']! &&
        pitch <= pose['pitchMax']!;
  }
}
