class ValidationResult {
  final String tipo; // NORMAL o RETARDO
  final String? duracion; // E.g. "25 minutos"
  final String descripcion;

  ValidationResult({
    required this.tipo,
    this.duracion,
    required this.descripcion,
  });
}

class ScheduleValidator {
  static const int toleranciaMinutos = 5;

  static ValidationResult validarMarcacion(
    Map<String, dynamic>? horario,
    DateTime ahora,
  ) {
    if (horario == null) {
      return ValidationResult(
        tipo: 'NORMAL',
        descripcion: 'Entrada registrada (Sin horario específico asignado).',
      );
    }

    final diasStr = horario['dias']?.toString() ?? '';
    final horaInicioStr = horario['hora_inicio']?.toString() ?? '';

    if (diasStr.isEmpty || horaInicioStr.isEmpty) {
      return ValidationResult(
        tipo: 'NORMAL',
        descripcion: 'Entrada registrada (Horario incompleto).',
      );
    }

    // 1. Validar si hoy es un día laborable del horario
    final diaActual = _diaAbreviado(ahora.weekday);
    final listaDias = diasStr.split(',').map((d) => d.trim()).toList();
    if (!listaDias.contains(diaActual)) {
      return ValidationResult(
        tipo: 'NORMAL',
        descripcion: 'Entrada registrada fuera de días laborables establecidos.',
      );
    }

    // 2. Parsear hora de inicio
    final parts = horaInicioStr.split(':');
    if (parts.length < 2) {
      return ValidationResult(
        tipo: 'NORMAL',
        descripcion: 'Entrada registrada (Error al leer formato de hora).',
      );
    }

    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return ValidationResult(
        tipo: 'NORMAL',
        descripcion: 'Entrada registrada (Error al parsear hora de inicio).',
      );
    }

    // 3. Crear DateTime para la hora de inicio de hoy
    final horaInicioHoy = DateTime(
      ahora.year,
      ahora.month,
      ahora.day,
      hour,
      minute,
    );

    // 4. Calcular límite con tolerancia (15 minutos por defecto)
    final limiteTolerancia = horaInicioHoy.add(const Duration(minutes: toleranciaMinutos));

    if (ahora.isAfter(limiteTolerancia)) {
      final diff = ahora.difference(horaInicioHoy).inMinutes;
      return ValidationResult(
        tipo: 'RETARDO',
        duracion: '$diff minutos',
        descripcion: 'Retardo de $diff minutos registrado.',
      );
    } else {
      return ValidationResult(
        tipo: 'NORMAL',
        descripcion: 'Entrada registrada a tiempo.',
      );
    }
  }

  static bool esSalidaTemprana(Map<String, dynamic> horario, DateTime ahora) {
    final horaFinalStr = horario['hora_final']?.toString() ?? '';
    if (horaFinalStr.isEmpty) return false;

    final parts = horaFinalStr.split(':');
    if (parts.length < 2) return false;

    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return false;

    final horaFinalHoy = DateTime(
      ahora.year,
      ahora.month,
      ahora.day,
      hour,
      minute,
    );

    return ahora.isBefore(horaFinalHoy);
  }

  static String _diaAbreviado(int weekday) {
    const map = {
      1: 'L',
      2: 'M',
      3: 'Mi',
      4: 'J',
      5: 'V',
      6: 'S',
      7: 'D',
    };
    return map[weekday] ?? '';
  }
}
