import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/employee.dart';
import '../models/face_embedding.dart';

class DatabaseService {
  static Database? _db;

  Future<Database> get database async {
    _db ??= await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final path = join(await getDatabasesPath(), 'attendance.db');
    return openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE employees (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        employee_code TEXT UNIQUE,
        department TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE face_embeddings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        embedding TEXT NOT NULL,
        angle_type TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (employee_id) REFERENCES employees(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE attendance_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        confidence REAL,
        FOREIGN KEY (employee_id) REFERENCES employees(id)
      )
    ''');
  }

  // EMPLEADOS
  Future<int> insertEmployee(Employee employee) async {
    final db = await database;
    return db.insert('employees', employee.toMap());
  }

  Future<List<Employee>> getAllEmployees() async {
    final db = await database;
    final maps = await db.query('employees');
    return maps.map((m) => Employee.fromMap(m)).toList();
  }

  Future<Employee?> getEmployeeById(int id) async {
    final db = await database;
    final maps = await db.query('employees', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Employee.fromMap(maps.first);
  }

  // EMBEDDINGS
  Future<int> saveEmbedding(int employeeId, List<double> embedding, String angleType) async {
    final db = await database;
    return db.insert('face_embeddings', {
      'employee_id': employeeId,
      'embedding': embedding.join(','),
      'angle_type': angleType,
    });
  }

  Future<List<Map<String, dynamic>>> getAllEmbeddings() async {
    final db = await database;
    return db.query('face_embeddings', columns: ['employee_id', 'embedding']);
  }

  Future<List<FaceEmbedding>> getEmbeddingsByEmployee(int employeeId) async {
    final db = await database;
    final maps = await db.query(
      'face_embeddings',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
    );
    return maps.map((m) => FaceEmbedding.fromMap(m)).toList();
  }

  // ASISTENCIA
  Future<int> insertAttendance(int employeeId, DateTime timestamp, double confidence) async {
    final db = await database;
    return db.insert('attendance_records', {
      'employee_id': employeeId,
      'timestamp': timestamp.toIso8601String(),
      'confidence': confidence,
    });
  }

  Future<List<Map<String, dynamic>>> getAttendanceByDate(DateTime date) async {
    final db = await database;
    final start = DateTime(date.year, date.month, date.day).toIso8601String();
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59).toIso8601String();
    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.timestamp BETWEEN ? AND ?
      ORDER BY ar.timestamp DESC
    ''', [start, end]);
  }

  Future<List<Map<String, dynamic>>> getAttendanceByEmployee(int employeeId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.employee_id = ?
      ORDER BY ar.timestamp DESC
    ''', [employeeId]);
  }
}
