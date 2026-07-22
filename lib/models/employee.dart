class Employee {
  final int? id;
  final String name;
  final String employeeCode;
  final String? department;
  final String? horarioId;
  final DateTime createdAt;

  Employee({
    this.id,
    required this.name,
    required this.employeeCode,
    this.department,
    this.horarioId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'employee_code': employeeCode,
      'department': department,
      'horario_id': horarioId,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    return Employee(
      id: map['id'] as int?,
      name: map['name'] as String,
      employeeCode: map['employee_code'] as String,
      department: map['department'] as String?,
      horarioId: map['horario_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
