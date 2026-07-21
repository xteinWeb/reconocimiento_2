import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class LightQualityService {
  /// Analiza la calidad de luz de una imagen
  LightQualityResult analyzeImage(Uint8List imageBytes) {
    final image = img.decodeImage(imageBytes);
    if (image == null) {
      return LightQualityResult(
        averageBrightness: 0,
        faceBrightness: 0,
        backgroundBrightness: 0,
        isOverexposed: false,
        isBacklit: false,
        isTooDark: true,
      );
    }

    // Calcular brillo promedio muestreando cada 10 píxeles
    double totalBrightness = 0;
    int pixelCount = 0;

    for (int y = 0; y < image.height; y += 10) {
      for (int x = 0; x < image.width; x += 10) {
        final pixel = image.getPixel(x, y);
        final brightness = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        totalBrightness += brightness;
        pixelCount++;
      }
    }

    final avgBrightness = totalBrightness / pixelCount;

    // Dividir imagen en 9 regiones para detectar contraluz
    final regions = _analyzeRegions(image);
    final faceRegion = regions['center']!;
    final bgRegions = [
      regions['topLeft']!,
      regions['topRight']!,
      regions['bottomLeft']!,
      regions['bottomRight']!
    ];

    final faceBrightness = faceRegion;
    final bgBrightness = bgRegions.reduce((a, b) => a + b) / 4;

    return LightQualityResult(
      averageBrightness: avgBrightness,
      faceBrightness: faceBrightness,
      backgroundBrightness: bgBrightness,
      isOverexposed: avgBrightness > 220,
      isBacklit: (bgBrightness - faceBrightness) > 80,
      isTooDark: avgBrightness < 45,
    );
  }

  Map<String, double> _analyzeRegions(img.Image image) {
    final w = image.width ~/ 3;
    final h = image.height ~/ 3;

    return {
      'topLeft': _avgBrightness(image, 0, 0, w, h),
      'topRight': _avgBrightness(image, w * 2, 0, w, h),
      'center': _avgBrightness(image, w, h, w, h),
      'bottomLeft': _avgBrightness(image, 0, h * 2, w, h),
      'bottomRight': _avgBrightness(image, w * 2, h * 2, w, h),
    };
  }

  double _avgBrightness(img.Image image, int x, int y, int w, int h) {
    double total = 0;
    int count = 0;
    for (int dy = y; dy < y + h; dy += 5) {
      for (int dx = x; dx < x + w; dx += 5) {
        final p = image.getPixel(dx, dy);
        total += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        count++;
      }
    }
    return total / count;
  }
}

class LightQualityResult {
  final double averageBrightness;
  final double faceBrightness;
  final double backgroundBrightness;
  final bool isOverexposed;
  final bool isBacklit;
  final bool isTooDark;

  LightQualityResult({
    required this.averageBrightness,
    required this.faceBrightness,
    required this.backgroundBrightness,
    required this.isOverexposed,
    required this.isBacklit,
    required this.isTooDark,
  });

  String get feedback {
    if (isOverexposed) return "⚠️ Luz muy intensa. Busca sombra.";
    if (isBacklit) return "⚠️ Contraluz detectado. Gírate.";
    if (isTooDark) return "⚠️ Muy oscuro. Acércate a la luz.";
    return "✅ Luz óptima";
  }

  Color get feedbackColor {
    if (isOverexposed || isBacklit || isTooDark) return Colors.orange;
    return Colors.green;
  }
}
