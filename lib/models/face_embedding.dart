class FaceEmbedding {
  final int? id;
  final int employeeId;
  final List<double> embedding;
  final String angleType;
  final DateTime createdAt;

  FaceEmbedding({
    this.id,
    required this.employeeId,
    required this.embedding,
    required this.angleType,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'employee_id': employeeId,
      'embedding': embedding.join(','),
      'angle_type': angleType,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory FaceEmbedding.fromMap(Map<String, dynamic> map) {
    // Tolerante a datos corruptos: un valor no parseable ya no revienta toda
    // la consulta. El vector resultante queda vacío y `sanitize` lo rechaza
    // más adelante, que es el comportamiento correcto.
    final raw = (map['embedding'] as String?) ?? '';
    final values = <double>[];
    for (final part in raw.split(',')) {
      final v = double.tryParse(part);
      if (v == null) {
        values.clear();
        break;
      }
      values.add(v);
    }

    return FaceEmbedding(
      id: map['id'] as int?,
      employeeId: map['employee_id'] as int,
      embedding: values,
      angleType: (map['angle_type'] as String?) ?? 'Frontal',
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
              DateTime.now(),
    );
  }
}
