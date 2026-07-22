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
    return openDatabase(
      path,
      version: 3,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE employees (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        employee_code TEXT UNIQUE,
        department TEXT,
        horario_id TEXT,
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
        evento TEXT,
        tipo TEXT,
        duracion TEXT,
        FOREIGN KEY (employee_id) REFERENCES employees(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE schedules (
        id_horario TEXT PRIMARY KEY,
        hora_inicio TEXT NOT NULL,
        hora_final TEXT NOT NULL,
        tipo TEXT NOT NULL,
        dias TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE absences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        date TEXT NOT NULL,
        sigla_ausencia TEXT NOT NULL,
        observacion TEXT,
        FOREIGN KEY (employee_id) REFERENCES employees(id),
        UNIQUE(employee_id, date) ON CONFLICT REPLACE
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute('ALTER TABLE employees ADD COLUMN horario_id TEXT');
      } catch (e) {
        print('Column horario_id already exists or error: $e');
      }
      try {
        await db.execute('ALTER TABLE attendance_records ADD COLUMN evento TEXT');
        await db.execute('ALTER TABLE attendance_records ADD COLUMN tipo TEXT');
        await db.execute('ALTER TABLE attendance_records ADD COLUMN duracion TEXT');
      } catch (e) {
        print('Columns in attendance_records already exist or error: $e');
      }
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS schedules (
            id_horario TEXT PRIMARY KEY,
            hora_inicio TEXT NOT NULL,
            hora_final TEXT NOT NULL,
            tipo TEXT NOT NULL,
            dias TEXT NOT NULL
          )
        ''');
      } catch (e) {
        print('Error creating schedules table: $e');
      }
    }
    if (oldVersion < 3) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS absences (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employee_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            sigla_ausencia TEXT NOT NULL,
            observacion TEXT,
            FOREIGN KEY (employee_id) REFERENCES employees(id),
            UNIQUE(employee_id, date) ON CONFLICT REPLACE
          )
        ''');
      } catch (e) {
        print('Error creating absences table: $e');
      }
    }
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
  Future<int> insertAttendance(
    int employeeId,
    DateTime timestamp,
    double confidence, {
    String? evento,
    String? tipo,
    String? duracion,
  }) async {
    final db = await database;
    return db.insert('attendance_records', {
      'employee_id': employeeId,
      'timestamp': timestamp.toIso8601String(),
      'confidence': confidence,
      'evento': evento ?? 'ENTRADA',
      'tipo': tipo ?? 'NORMAL',
      'duracion': duracion,
    });
  }

  Future<Map<String, dynamic>?> getLastAttendanceForEmployee(int employeeId) async {
    final db = await database;
    final results = await db.query(
      'attendance_records',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return results.first;
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

  Future<List<Map<String, dynamic>>> getAttendanceByDateRange(DateTime start, DateTime end) async {
    final db = await database;
    final startStr = DateTime(start.year, start.month, start.day).toIso8601String();
    final endStr = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.timestamp BETWEEN ? AND ?
      ORDER BY ar.timestamp DESC
    ''', [startStr, endStr]);
  }

  Future<List<Map<String, dynamic>>> getAttendanceByEmployeeAndDateRange(int employeeId, DateTime start, DateTime end) async {
    final db = await database;
    final startStr = DateTime(start.year, start.month, start.day).toIso8601String();
    final endStr = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.employee_id = ? AND ar.timestamp BETWEEN ? AND ?
      ORDER BY ar.timestamp DESC
    ''', [employeeId, startStr, endStr]);
  }

  // HORARIOS
  Future<int> saveSchedule(Map<String, dynamic> schedule) async {
    final db = await database;
    return db.insert(
      'schedules',
      schedule,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getScheduleById(String idHorario) async {
    final db = await database;
    final maps = await db.query(
      'schedules',
      where: 'id_horario = ?',
      whereArgs: [idHorario],
    );
    if (maps.isEmpty) return null;
    return maps.first;
  }

  Future<List<Map<String, dynamic>>> getAllSchedules() async {
    final db = await database;
    return db.query('schedules');
  }

  // AUSENTISMOS / ABSENCES
  Future<int> saveAbsence(int employeeId, String date, String sigla, String? observacion) async {
    final db = await database;
    return db.insert(
      'absences',
      {
        'employee_id': employeeId,
        'date': date,
        'sigla_ausencia': sigla,
        'observacion': observacion,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAbsencesByDate(String date) async {
    final db = await database;
    return db.rawQuery('''
      SELECT a.*, e.name AS employee_name, e.employee_code AS employee_code
      FROM absences a
      JOIN employees e ON a.employee_id = e.id
      WHERE a.date = ?
    ''', [date]);
  }

  Future<int> deleteAbsence(int employeeId, String date) async {
    final db = await database;
    return db.delete(
      'absences',
      where: 'employee_id = ? AND date = ?',
      whereArgs: [employeeId, date],
    );
  }
}
