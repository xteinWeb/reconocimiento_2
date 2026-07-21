import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class FaceRecognitionService {
  Interpreter? _interpreter;
  static const int _embeddingSize = 192;
  static const int _inputSize = 112;

  Future<void> initialize() async {
    final interpreterOptions = InterpreterOptions()..threads = 4;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobilefacenet.tflite',
      options: interpreterOptions,
    );
  }

  /// Convierte imagen 112x112 a embedding de 192 floats
  List<double> getEmbedding(Uint8List imageBytes) {
    final image = img.decodeImage(imageBytes)!;

    // Convertir a tensor [1, 112, 112, 3] con normalización MobileFaceNet
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(
          _inputSize,
          (x) => List.generate(3, (c) {
            final pixel = image.getPixel(x, y);
            final val = c == 0 ? pixel.r : (c == 1 ? pixel.g : pixel.b);
            return (val - 127.5) / 128.0;
          }),
        ),
      ),
    );

    final output = List<double>.filled(_embeddingSize, 0)
        .reshape([1, _embeddingSize]);

    _interpreter!.run(input, output);

    final embedding = List<double>.from(output[0]);
    return _normalize(embedding);
  }

  /// Normalización L2 del vector
  List<double> _normalize(List<double> vector) {
    final magnitude = sqrt(vector.fold(0.0, (s, v) => s + v * v));
    return vector.map((v) => v / magnitude).toList();
  }

  /// Distancia coseno entre dos embeddings (0 = idénticos, 2 = opuestos)
  double cosineDistance(List<double> a, List<double> b) {
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return 1.0 - dot;
  }

  /// Encuentra el embedding más cercano y devuelve (employeeId, distance)
  (int?, double) findNearest(
    List<double> queryEmbedding,
    List<Map<String, dynamic>> allEmbeddings,
  ) {
    double minDistance = double.infinity;
    int? matchedEmployeeId;

    for (final row in allEmbeddings) {
      final storedEmbedding = (row['embedding'] as String)
          .split(',')
          .map((e) => double.parse(e))
          .toList();

      final distance = cosineDistance(queryEmbedding, storedEmbedding);

      if (distance < minDistance) {
        minDistance = distance;
        matchedEmployeeId = row['employee_id'] as int;
      }
    }

    return (matchedEmployeeId, minDistance);
  }

  void dispose() => _interpreter?.close();
}
