import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceDetectionService {
  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableTracking: true,
      enableClassification: true,
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  /// Detecta rostros y devuelve info de ángulos
  Future<FaceDetectionResult?> detectFace(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) return null;

    final face = faces.first;
    return FaceDetectionResult(
      face: face,
      yaw: face.headEulerAngleY ?? 0,
      pitch: face.headEulerAngleX ?? 0,
      roll: face.headEulerAngleZ ?? 0,
      boundingBox: face.boundingBox,
      smilingProbability: face.smilingProbability,
    );
  }

  /// Recorta el rostro de la imagen original a 112x112 para MobileFaceNet
  Future<Uint8List?> cropFace(String imagePath, Rect boundingBox) async {
    final bytes = await File(imagePath).readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return null;

    // Agregar 20% de margen al recorte
    final margin = (boundingBox.width * 0.2).toInt();
    final x = (boundingBox.left - margin).toInt().clamp(0, original.width);
    final y = (boundingBox.top - margin).toInt().clamp(0, original.height);
    final w = (boundingBox.width + margin * 2).toInt().clamp(0, original.width - x);
    final h = (boundingBox.height + margin * 2).toInt().clamp(0, original.height - y);

    final cropped = img.copyCrop(original, x: x, y: y, width: w, height: h);
    final resized = img.copyResize(cropped, width: 112, height: 112);

    return img.encodeJpg(resized);
  }

  void dispose() => _detector.close();
}

class FaceDetectionResult {
  final Face face;
  final double yaw, pitch, roll;
  final Rect boundingBox;
  final double? smilingProbability;

  FaceDetectionResult({
    required this.face,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.boundingBox,
    this.smilingProbability,
  });

  bool isValidPose(Map<String, double> pose) {
    return yaw >= pose['yawMin']! &&
        yaw <= pose['yawMax']! &&
        pitch >= pose['pitchMin']! &&
        pitch <= pose['pitchMax']!;
  }
}
