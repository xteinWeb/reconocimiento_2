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
    return FaceEmbedding(
      id: map['id'] as int?,
      employeeId: map['employee_id'] as int,
      embedding: (map['embedding'] as String)
          .split(',')
          .map((e) => double.parse(e))
          .toList(),
      angleType: map['angle_type'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
