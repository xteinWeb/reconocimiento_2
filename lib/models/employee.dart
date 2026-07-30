class Employee {
  final int? id;
  final String name;
  final String employeeCode;
  final String? department;
  final String? horarioId;
  final DateTime createdAt;
  final int isSynced;
  final String? idEmpresa;

  Employee({
    this.id,
    required this.name,
    required this.employeeCode,
    this.department,
    this.horarioId,
    required this.createdAt,
    this.isSynced = 1,
    this.idEmpresa,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'employee_code': employeeCode,
      'department': department,
      'horario_id': horarioId,
      'created_at': createdAt.toIso8601String(),
      'is_synced': isSynced,
      'id_empresa': idEmpresa,
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
      isSynced: map['is_synced'] as int? ?? 1,
      idEmpresa: map['id_empresa'] as String?,
    );
  }
}
