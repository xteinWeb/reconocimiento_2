class Employee {
  final int? id;
  final String name;
  final String employeeCode;
  final String? department;
  final DateTime createdAt;

  Employee({
    this.id,
    required this.name,
    required this.employeeCode,
    this.department,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'employee_code': employeeCode,
      'department': department,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    return Employee(
      id: map['id'] as int?,
      name: map['name'] as String,
      employeeCode: map['employee_code'] as String,
      department: map['department'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
