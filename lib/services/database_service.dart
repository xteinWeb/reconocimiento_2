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
      version: 5,
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
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        is_synced INTEGER DEFAULT 1
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
        is_synced INTEGER DEFAULT 0,
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
    if (oldVersion < 4) {
      try {
        await db.execute('ALTER TABLE attendance_records ADD COLUMN is_synced INTEGER DEFAULT 0');
      } catch (e) {
        print('Column is_synced already exists or error: $e');
      }
    }
    if (oldVersion < 5) {
      try {
        await db.execute('ALTER TABLE employees ADD COLUMN is_synced INTEGER DEFAULT 1');
      } catch (e) {
        print('Column is_synced already exists in employees or error: $e');
      }
    }
  }

  // EMPLEADOS
  Future<int> insertEmployee(Employee employee) async {
    final db = await database;
    return db.insert('employees', employee.toMap());
  }

  Future<int> updateEmployeeSyncStatus(int employeeId, int isSynced) async {
    final db = await database;
    return db.update(
      'employees',
      {'is_synced': isSynced},
      where: 'id = ?',
      whereArgs: [employeeId],
    );
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
    int isSynced = 0,
  }) async {
    final db = await database;
    return db.insert('attendance_records', {
      'employee_id': employeeId,
      'timestamp': timestamp.toIso8601String(),
      'confidence': confidence,
      'evento': evento ?? 'ENTRADA',
      'tipo': tipo ?? 'NORMAL',
      'duracion': duracion,
      'is_synced': isSynced,
    });
  }

  Future<int> markAttendanceAsSynced(int id) async {
    final db = await database;
    return db.update(
      'attendance_records',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingAttendanceRecords() async {
    final db = await database;
    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.is_synced = 0 OR ar.is_synced IS NULL
      ORDER BY ar.timestamp ASC
    ''');
  }

  Future<List<Map<String, dynamic>>> getAttendanceWithSyncStatus({int? syncedFilter}) async {
    final db = await database;
    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (syncedFilter != null) {
      if (syncedFilter == 0) {
        whereClause = 'WHERE (ar.is_synced = 0 OR ar.is_synced IS NULL)';
      } else {
        whereClause = 'WHERE ar.is_synced = ?';
        whereArgs.add(syncedFilter);
      }
    }

    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      $whereClause
      ORDER BY ar.timestamp DESC
    ''', whereArgs);
  }

  Future<int> deleteAttendanceRecord(int id) async {
    final db = await database;
    return db.delete('attendance_records', where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, int>> getSyncCounts() async {
    final db = await database;
    final total = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM attendance_records')) ?? 0;
    final pending = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM attendance_records WHERE is_synced = 0 OR is_synced IS NULL')) ?? 0;
    final synced = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM attendance_records WHERE is_synced = 1')) ?? 0;
    return {
      'total': total,
      'pending': pending,
      'synced': synced,
    };
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
