import 'dart:math';
import 'package:flutter/foundation.dart';
import 'face_recognition_service.dart';

/// Calibración empírica del umbral de reconocimiento.
///
/// El umbral correcto NO es un número universal: depende del modelo, de la
/// cámara, de la iluminación de la sede y —sobre todo— de cuán parecidas son
/// entre sí las personas realmente enroladas. Elegirlo a ojo es la razón por
/// la que un sistema "funciona en pruebas" y falla en producción.
///
/// Este servicio mide la **distribución de impostores** sobre la galería real:
/// todas las distancias entre plantillas de personas DISTINTAS. El umbral debe
/// quedar por debajo de la menor de esas distancias, con holgura. Esa es la
/// única forma de acotar los falsos positivos con datos en lugar de intuición.
class CalibrationService {
  /// Ejecuta el análisis fuera del hilo de UI.
  static Future<CalibrationReport> analizar(
    List<GalleryTemplate> gallery,
  ) async {
    if (gallery.length < 2) {
      return CalibrationReport.insuficiente(gallery.length);
    }

    final payload = <String, dynamic>{
      'ids': gallery.map((t) => t.employeeId).toList(),
      'poses': gallery.map((t) => t.angleType).toList(),
      'vectors': gallery.map((t) => t.vector).toList(),
    };

    return compute(_analizarEnIsolate, payload);
  }
}

// ======================================================================
// Cómputo pesado (corre en un isolate)
// ======================================================================

CalibrationReport _analizarEnIsolate(Map<String, dynamic> payload) {
  final ids = (payload['ids'] as List).cast<int>();
  final poses = (payload['poses'] as List).cast<String>();
  final vectors = (payload['vectors'] as List)
      .map((v) => (v as List).cast<double>())
      .toList();

  final n = ids.length;

  final impostores = <double>[];
  final genuinos = <double>[];
  final paresCercanos = <ParImpostor>[];

  double dist(int i, int j) {
    final a = vectors[i];
    final b = vectors[j];
    double dot = 0;
    for (int k = 0; k < a.length; k++) {
      dot += a[k] * b[k];
    }
    return 1.0 - dot;
  }

  // Mejor (menor) distancia observada entre cada par de PERSONAS distintas.
  final mejorPorPar = <String, ParImpostor>{};

  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      final d = dist(i, j);
      if (!d.isFinite) continue;

      if (ids[i] == ids[j]) {
        // Misma persona, poses distintas -> distribución genuina.
        genuinos.add(d);
      } else {
        impostores.add(d);

        final a = min(ids[i], ids[j]);
        final b = max(ids[i], ids[j]);
        final key = '$a-$b';
        final actual = mejorPorPar[key];
        if (actual == null || d < actual.distancia) {
          mejorPorPar[key] = ParImpostor(
            employeeIdA: a,
            employeeIdB: b,
            distancia: d,
            poseA: poses[i],
            poseB: poses[j],
          );
        }
      }
    }
  }

  paresCercanos.addAll(mejorPorPar.values);
  paresCercanos.sort((x, y) => x.distancia.compareTo(y.distancia));

  impostores.sort();
  genuinos.sort();

  final impostorMin = impostores.isEmpty ? double.nan : impostores.first;
  final impostorP01 = _percentil(impostores, 0.001);
  final impostorP1 = _percentil(impostores, 0.01);
  final impostorMedia = _media(impostores);

  final genuinoP95 = _percentil(genuinos, 0.95);
  final genuinoMax = genuinos.isEmpty ? double.nan : genuinos.last;
  final genuinoMedia = _media(genuinos);

  // ------------------------------------------------------------------
  // Recomendación
  // ------------------------------------------------------------------
  double umbral;
  double margen;
  String justificacion;
  bool hayTraslape;

  if (impostores.isEmpty) {
    umbral = 0.20;
    margen = 0.06;
    hayTraslape = false;
    justificacion =
        'Solo hay un colaborador con plantillas. No se puede medir la '
        'distribución de impostores; se usan valores conservadores por defecto.';
  } else if (genuinos.isNotEmpty && genuinoP95 < impostorMin) {
    // Separación limpia: el umbral va en la brecha, más cerca del lado
    // genuino para no sacrificar usabilidad, pero con holgura al impostor.
    final brecha = impostorMin - genuinoP95;
    umbral = genuinoP95 + brecha * 0.35;
    margen = brecha * 0.30;
    hayTraslape = false;
    justificacion =
        'Separación limpia: el 95% de las comparaciones de la misma persona '
        'queda por debajo de ${genuinoP95.toStringAsFixed(3)} y la comparación '
        'más cercana entre personas distintas está en '
        '${impostorMin.toStringAsFixed(3)}. El umbral se coloca dentro de esa '
        'brecha.';
  } else {
    // Traslape: se prioriza CERO falsos positivos sobre la comodidad.
    // Marcar a la persona equivocada es un error que corrompe la nómina;
    // no reconocer a alguien solo obliga a reintentar.
    umbral = impostorMin * 0.85;
    margen = 0.05;
    hayTraslape = true;
    justificacion =
        'Hay traslape entre las distancias genuinas y las de impostores. '
        'El umbral se fija por debajo del impostor más cercano '
        '(${impostorMin.toStringAsFixed(3)}) priorizando no marcar a la '
        'persona equivocada, aunque algunos colaboradores deban reintentar.';
  }

  umbral = umbral.clamp(0.08, 0.40);
  margen = margen.clamp(0.03, 0.20);

  return CalibrationReport(
    plantillas: n,
    personas: ids.toSet().length,
    paresImpostores: impostores.length,
    paresGenuinos: genuinos.length,
    impostorMin: impostorMin,
    impostorP01: impostorP01,
    impostorP1: impostorP1,
    impostorMedia: impostorMedia,
    genuinoMedia: genuinoMedia,
    genuinoP95: genuinoP95,
    genuinoMax: genuinoMax,
    umbralRecomendado: umbral,
    margenRecomendado: margen,
    justificacion: justificacion,
    hayTraslape: hayTraslape,
    paresMasCercanos: paresCercanos.take(10).toList(),
    suficiente: true,
  );
}

double _percentil(List<double> ordenados, double q) {
  if (ordenados.isEmpty) return double.nan;
  final idx = (q * (ordenados.length - 1)).round().clamp(
    0,
    ordenados.length - 1,
  );
  return ordenados[idx];
}

double _media(List<double> v) {
  if (v.isEmpty) return double.nan;
  return v.reduce((a, b) => a + b) / v.length;
}

// ======================================================================
// Modelos
// ======================================================================

class ParImpostor {
  final int employeeIdA;
  final int employeeIdB;
  final double distancia;
  final String poseA;
  final String poseB;

  const ParImpostor({
    required this.employeeIdA,
    required this.employeeIdB,
    required this.distancia,
    required this.poseA,
    required this.poseB,
  });
}

class CalibrationReport {
  final int plantillas;
  final int personas;
  final int paresImpostores;
  final int paresGenuinos;

  final double impostorMin;
  final double impostorP01;
  final double impostorP1;
  final double impostorMedia;

  final double genuinoMedia;
  final double genuinoP95;
  final double genuinoMax;

  final double umbralRecomendado;
  final double margenRecomendado;
  final String justificacion;
  final bool hayTraslape;

  final List<ParImpostor> paresMasCercanos;
  final bool suficiente;

  const CalibrationReport({
    required this.plantillas,
    required this.personas,
    required this.paresImpostores,
    required this.paresGenuinos,
    required this.impostorMin,
    required this.impostorP01,
    required this.impostorP1,
    required this.impostorMedia,
    required this.genuinoMedia,
    required this.genuinoP95,
    required this.genuinoMax,
    required this.umbralRecomendado,
    required this.margenRecomendado,
    required this.justificacion,
    required this.hayTraslape,
    required this.paresMasCercanos,
    required this.suficiente,
  });

  factory CalibrationReport.insuficiente(int plantillas) => CalibrationReport(
        plantillas: plantillas,
        personas: 0,
        paresImpostores: 0,
        paresGenuinos: 0,
        impostorMin: double.nan,
        impostorP01: double.nan,
        impostorP1: double.nan,
        impostorMedia: double.nan,
        genuinoMedia: double.nan,
        genuinoP95: double.nan,
        genuinoMax: double.nan,
        umbralRecomendado: 0.20,
        margenRecomendado: 0.06,
        justificacion:
            'Se necesitan al menos dos plantillas válidas para calibrar.',
        hayTraslape: false,
        paresMasCercanos: const [],
        suficiente: false,
      );

  /// Pares de colaboradores que el sistema puede confundir con el umbral dado.
  List<ParImpostor> paresEnRiesgo(double umbral) =>
      paresMasCercanos.where((p) => p.distancia < umbral).toList();
}
