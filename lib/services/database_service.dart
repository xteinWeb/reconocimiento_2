import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';
import '../models/employee.dart';
import '../models/face_embedding.dart';
import 'face_recognition_service.dart';

/// Resumen de la limpieza de la galería biométrica local.
class EmbeddingPurgeReport {
  final int totalRevisados;
  final int eliminados;
  final int renormalizados;
  final Set<int> empleadosSinPlantillaFrontal;

  const EmbeddingPurgeReport({
    required this.totalRevisados,
    required this.eliminados,
    required this.renormalizados,
    required this.empleadosSinPlantillaFrontal,
  });

  bool get sinCambios => eliminados == 0 && renormalizados == 0;
}

/// Clasificación biométrica de un colaborador.
enum NivelEnrolamiento {
  /// Listo: tiene plantilla frontal válida y las 5 poses.
  ok,

  /// Puede marcar por rostro, pero le faltan poses válidas para poder
  /// sincronizar el enrolamiento con el servidor central.
  incompleto,

  /// Tiene plantillas válidas pero ninguna frontal: el reconocimiento solo
  /// compara contra poses frontales, así que NO puede identificarse.
  sinFrontal,

  /// Tenía plantillas, pero todas resultaron inválidas y se descartaron.
  /// Es el grupo que perdió su enrolamiento en la limpieza.
  invalido,

  /// Nunca se enroló.
  nuncaEnrolado,
}

class EnrollmentStatus {
  final Employee employee;
  final int plantillasTotales;
  final int plantillasValidas;
  final int plantillasInvalidas;
  final int frontalesValidas;
  final Set<String> posesValidas;

  const EnrollmentStatus({
    required this.employee,
    required this.plantillasTotales,
    required this.plantillasValidas,
    required this.plantillasInvalidas,
    required this.frontalesValidas,
    required this.posesValidas,
  });

  NivelEnrolamiento get nivel {
    if (plantillasTotales == 0) return NivelEnrolamiento.nuncaEnrolado;
    if (plantillasValidas == 0) return NivelEnrolamiento.invalido;
    if (frontalesValidas == 0) return NivelEnrolamiento.sinFrontal;
    if (plantillasValidas < 5) return NivelEnrolamiento.incompleto;
    return NivelEnrolamiento.ok;
  }

  /// true si esta persona NO puede marcar por rostro ahora mismo.
  bool get requiereReenrolamiento =>
      nivel == NivelEnrolamiento.nuncaEnrolado ||
      nivel == NivelEnrolamiento.invalido ||
      nivel == NivelEnrolamiento.sinFrontal;

  String get etiqueta => switch (nivel) {
        NivelEnrolamiento.ok => 'Enrolado',
        NivelEnrolamiento.incompleto => 'Incompleto',
        NivelEnrolamiento.sinFrontal => 'Sin pose frontal',
        NivelEnrolamiento.invalido => 'Plantillas inválidas',
        NivelEnrolamiento.nuncaEnrolado => 'Sin enrolar',
      };

  String get explicacion => switch (nivel) {
        NivelEnrolamiento.ok =>
          'Puede marcar por rostro. $plantillasValidas poses válidas.',
        NivelEnrolamiento.incompleto =>
          'Puede marcar por rostro, pero solo tiene $plantillasValidas de 5 '
              'poses válidas: el enrolamiento no se puede subir al servidor '
              'central. Conviene repetir la captura.',
        NivelEnrolamiento.sinFrontal =>
          'Tiene $plantillasValidas plantilla(s) pero ninguna frontal. '
              'El reconocimiento solo compara contra poses frontales, así que '
              'NO puede identificarse. Debe re-enrolarse.',
        NivelEnrolamiento.invalido =>
          'Sus $plantillasTotales plantilla(s) eran inválidas (vector nulo, '
              'sin normalizar o de otro modelo) y se descartaron. '
              'Debe re-enrolarse.',
        NivelEnrolamiento.nuncaEnrolado =>
          'Nunca se le capturó el rostro en este dispositivo.',
      };
}

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
      version: 16,
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
        is_synced INTEGER DEFAULT 1,
        id_empresa TEXT,
        id_un_item TEXT
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
        metodo_registro TEXT DEFAULT 'FACIAL',
        dispositivo_id TEXT,
        margen REAL,
        rival_employee_id INTEGER,
        evidencia_path TEXT,
        autorizado_por TEXT,
        bypass_motivo TEXT,
        FOREIGN KEY (employee_id) REFERENCES employees(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE schedules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        id_horario TEXT NOT NULL,
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
        is_synced INTEGER DEFAULT 0,
        dispositivo_id TEXT,
        FOREIGN KEY (employee_id) REFERENCES employees(id),
        UNIQUE(employee_id, date) ON CONFLICT REPLACE
      )
    ''');

    await db.execute('''
      CREATE TABLE absence_types (
        sigla TEXT PRIMARY KEY,
        nombre TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE system_config (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE special_schedules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        date TEXT NOT NULL,
        hora_inicio TEXT,
        hora_final TEXT,
        observacion TEXT,
        is_synced INTEGER DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
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
    if (oldVersion < 6) {
      try {
        await db.execute("ALTER TABLE attendance_records ADD COLUMN metodo_registro TEXT DEFAULT 'FACIAL'");
      } catch (e) {
        print('Column metodo_registro already exists in attendance_records or error: $e');
      }
    }
    if (oldVersion < 7) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS absence_types (
            sigla TEXT PRIMARY KEY,
            nombre TEXT NOT NULL
          )
        ''');
      } catch (e) {
        print('Error creating absence_types table: $e');
      }
    }
    if (oldVersion < 8) {
      try {
        await db.execute('ALTER TABLE absences ADD COLUMN is_synced INTEGER DEFAULT 0');
      } catch (e) {
        print('Column is_synced already exists in absences or error: $e');
      }
    }
    if (oldVersion < 9) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS system_config (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      } catch (e) {
        print('Error creating system_config table: $e');
      }
    }
    if (oldVersion < 10) {
      try {
        await db.execute('ALTER TABLE attendance_records ADD COLUMN dispositivo_id TEXT');
      } catch (e) {
        print('Column dispositivo_id already exists in attendance_records or error: $e');
      }
    }
    if (oldVersion < 11) {
      try {
        await db.execute('ALTER TABLE absences ADD COLUMN dispositivo_id TEXT');
      } catch (e) {
        print('Column dispositivo_id already exists in absences or error: $e');
      }
    }
    if (oldVersion < 12) {
      try {
        await db.execute('ALTER TABLE employees ADD COLUMN id_empresa TEXT');
      } catch (e) {
        print('Column id_empresa already exists in employees or error: $e');
      }
    }
    if (oldVersion < 13) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS special_schedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            employee_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            hora_inicio TEXT,
            hora_final TEXT,
            observacion TEXT,
            is_synced INTEGER DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (employee_id) REFERENCES employees(id),
            UNIQUE(employee_id, date) ON CONFLICT REPLACE
          )
        ''');
      } catch (e) {
        print('Error creating special_schedules table: $e');
      }
    }
    if (oldVersion < 14) {
      try {
        await db.execute('DROP TABLE IF EXISTS schedules');
        await db.execute('''
          CREATE TABLE schedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            id_horario TEXT NOT NULL,
            hora_inicio TEXT NOT NULL,
            hora_final TEXT NOT NULL,
            tipo TEXT NOT NULL,
            dias TEXT NOT NULL
          )
        ''');
      } catch (e) {
        print('Error updating schedules table: $e');
      }
    }
    if (oldVersion < 15) {
      try {
        await db.execute('ALTER TABLE employees ADD COLUMN id_un_item TEXT');
      } catch (e) {
        print('Error adding id_un_item column to employees table: $e');
      }
    }
    if (oldVersion < 16) {
      // Columnas de auditoría del reconocimiento. Sin ellas no es posible
      // demostrar por qué el sistema aceptó una marcación ante una disputa.
      const nuevas = {
        'margen': 'REAL',
        'rival_employee_id': 'INTEGER',
        'evidencia_path': 'TEXT',
        'autorizado_por': 'TEXT',
        'bypass_motivo': 'TEXT',
      };
      for (final entry in nuevas.entries) {
        try {
          await db.execute(
            'ALTER TABLE attendance_records ADD COLUMN ${entry.key} ${entry.value}',
          );
        } catch (e) {
          print('Column ${entry.key} already exists or error: $e');
        }
      }

      // Limpieza única de la galería heredada: elimina vectores de ceros,
      // vectores de otra dimensión y re-normaliza los que no eran unitarios.
      try {
        final rows = await db.query(
          'face_embeddings',
          columns: ['id', 'embedding'],
        );
        int borrados = 0;
        for (final row in rows) {
          final id = row['id'] as int;
          final raw = (row['embedding'] as String?) ?? '';
          final clean = FaceRecognitionService.parseStored(raw);
          if (clean == null) {
            await db.delete(
              'face_embeddings',
              where: 'id = ?',
              whereArgs: [id],
            );
            borrados++;
          } else {
            final joined = clean.join(',');
            if (joined != raw) {
              await db.update(
                'face_embeddings',
                {'embedding': joined},
                where: 'id = ?',
                whereArgs: [id],
              );
            }
          }
        }
        print('[DB v16] Embeddings inválidos eliminados: $borrados');
      } catch (e) {
        print('[DB v16] Error al purgar embeddings heredados: $e');
      }
    }
  }

  // CONFIGURACIÓN DE SISTEMA
  Future<String?> getDeviceId() async {
    final db = await database;
    final res = await db.query('system_config', where: 'key = ?', whereArgs: ['device_id']);
    if (res.isNotEmpty) {
      return res.first['value'] as String;
    }
    return null;
  }

  Future<void> saveDeviceId(String deviceId) async {
    final db = await database;
    await db.insert(
      'system_config',
      {'key': 'device_id', 'value': deviceId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getConfig(String key) async {
    final db = await database;
    final res = await db.query('system_config', where: 'key = ?', whereArgs: [key]);
    if (res.isNotEmpty) {
      return res.first['value'] as String;
    }
    return null;
  }

  Future<void> saveConfig(String key, String value) async {
    final db = await database;
    await db.insert(
      'system_config',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  Future<Employee?> getEmployeeByCode(String code) async {
    final db = await database;
    final maps = await db.query('employees', where: 'employee_code = ?', whereArgs: [code]);
    if (maps.isEmpty) return null;
    return Employee.fromMap(maps.first);
  }

  // EMBEDDINGS
  /// Guarda un embedding SIEMPRE normalizado L2 y con la dimensión correcta.
  ///
  /// Devuelve -1 y no escribe nada si el vector es inutilizable (dimensión
  /// distinta de 192, valores no finitos, o vector de ceros). Rechazar aquí es
  /// la barrera que impide que un vector inválido contamine la galería y gane
  /// todas las comparaciones.
  Future<int> saveEmbedding(
    int employeeId,
    List<double> embedding,
    String angleType,
  ) async {
    final clean = FaceRecognitionService.sanitize(embedding);
    if (clean == null) {
      print(
        '[DB] Embedding RECHAZADO para employee_id=$employeeId '
        'pose=$angleType (dim=${embedding.length}). No se guarda.',
      );
      return -1;
    }

    final db = await database;
    return db.insert('face_embeddings', {
      'employee_id': employeeId,
      'embedding': clean.join(','),
      'angle_type': angleType,
    });
  }

  Future<List<Map<String, dynamic>>> getAllEmbeddings() async {
    final db = await database;
    return db.query(
      'face_embeddings',
      columns: ['employee_id', 'embedding', 'angle_type'],
    );
  }

  /// Elimina de la galería local todo embedding que no pase la validación:
  /// dimensión incorrecta, vectores de ceros (los placeholders que se subían
  /// por poses faltantes) o valores no finitos. Además re-normaliza los que
  /// sean válidos pero no unitarios.
  ///
  /// Devuelve un resumen para mostrar en la pantalla de calibración.
  Future<EmbeddingPurgeReport> purgarEmbeddingsInvalidos() async {
    final db = await database;
    final rows = await db.query(
      'face_embeddings',
      columns: ['id', 'employee_id', 'embedding', 'angle_type'],
    );

    int eliminados = 0;
    int renormalizados = 0;
    final afectados = <int>{};

    for (final row in rows) {
      final id = row['id'] as int;
      final employeeId = row['employee_id'] as int;
      final raw = (row['embedding'] as String?) ?? '';

      final clean = FaceRecognitionService.parseStored(raw);
      if (clean == null) {
        await db.delete('face_embeddings', where: 'id = ?', whereArgs: [id]);
        eliminados++;
        afectados.add(employeeId);
        continue;
      }

      final joined = clean.join(',');
      if (joined != raw) {
        await db.update(
          'face_embeddings',
          {'embedding': joined},
          where: 'id = ?',
          whereArgs: [id],
        );
        renormalizados++;
      }
    }

    // Empleados que quedaron sin ninguna plantilla frontal utilizable.
    final restantes = await db.query(
      'face_embeddings',
      columns: ['employee_id', 'angle_type'],
    );
    final conFrontal = restantes
        .where(
          (r) => FaceRecognitionService.frontalPoses.contains(
            (r['angle_type'] as String?) ?? '',
          ),
        )
        .map((r) => r['employee_id'] as int)
        .toSet();

    final sinFrontal = afectados.difference(conFrontal);

    return EmbeddingPurgeReport(
      totalRevisados: rows.length,
      eliminados: eliminados,
      renormalizados: renormalizados,
      empleadosSinPlantillaFrontal: sinFrontal,
    );
  }

  /// Estado biométrico de CADA colaborador, validando plantilla por plantilla.
  ///
  /// Responde a la pregunta operativa "¿a quién tengo que re-enrolar?" con
  /// nombres y cédulas, no con un conteo. La validación es la misma que usa el
  /// reconocimiento, así que lo que aquí sale como OK es exactamente lo que el
  /// tótem puede identificar.
  Future<List<EnrollmentStatus>> obtenerEstadoEnrolamiento() async {
    final db = await database;

    final employees = await db.query('employees', orderBy: 'name COLLATE NOCASE');
    final rows = await db.query(
      'face_embeddings',
      columns: ['employee_id', 'embedding', 'angle_type'],
    );

    final porEmpleado = <int, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final id = r['employee_id'] as int?;
      if (id == null) continue;
      porEmpleado.putIfAbsent(id, () => []).add(r);
    }

    final resultado = <EnrollmentStatus>[];

    for (final e in employees) {
      final emp = Employee.fromMap(e);
      final propias = porEmpleado[emp.id] ?? const <Map<String, dynamic>>[];

      int validas = 0;
      int invalidas = 0;
      int frontalesValidas = 0;
      final posesValidas = <String>{};

      for (final r in propias) {
        final raw = (r['embedding'] as String?) ?? '';
        final angle = (r['angle_type'] as String?) ?? 'Frontal';
        final clean = FaceRecognitionService.parseStored(raw);

        if (clean == null) {
          invalidas++;
          continue;
        }
        validas++;
        posesValidas.add(angle);
        if (FaceRecognitionService.frontalPoses.contains(angle)) {
          frontalesValidas++;
        }
      }

      resultado.add(
        EnrollmentStatus(
          employee: emp,
          plantillasTotales: propias.length,
          plantillasValidas: validas,
          plantillasInvalidas: invalidas,
          frontalesValidas: frontalesValidas,
          posesValidas: posesValidas,
        ),
      );
    }

    return resultado;
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
    String metodoRegistro = 'FACIAL',
    String? dispositivoId,
    double? margen,
    int? rivalEmployeeId,
    String? evidenciaPath,
    String? autorizadoPor,
    String? bypassMotivo,
  }) async {
    final db = await database;

    // Protección contra duplicados accidentales: cooldown de 15 segundos
    final checkTime = timestamp.subtract(const Duration(seconds: 15)).toIso8601String();
    final recent = await db.query(
      'attendance_records',
      where: 'employee_id = ? AND evento = ? AND timestamp >= ?',
      whereArgs: [employeeId, evento ?? 'ENTRADA', checkTime],
    );
    if (recent.isNotEmpty) {
      print('[DatabaseService] Marcación duplicada detectada para el empleado $employeeId ($evento). Omitiendo inserción.');
      return -1;
    }

    return db.insert('attendance_records', {
      'employee_id': employeeId,
      'timestamp': timestamp.toIso8601String(),
      'confidence': confidence,
      'evento': evento ?? 'ENTRADA',
      'tipo': tipo ?? 'NORMAL',
      'duracion': duracion,
      'is_synced': isSynced,
      'metodo_registro': metodoRegistro,
      'dispositivo_id': dispositivoId,
      'margen': margen,
      'rival_employee_id': rivalEmployeeId,
      'evidencia_path': evidenciaPath,
      'autorizado_por': autorizadoPor,
      'bypass_motivo': bypassMotivo,
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
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa
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
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa
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
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.timestamp BETWEEN ? AND ?
      ORDER BY ar.timestamp DESC
    ''', [start, end]);
  }

  Future<List<Map<String, dynamic>>> getAttendanceByEmployee(int employeeId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa
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
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa
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
      SELECT ar.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa
      FROM attendance_records ar
      JOIN employees e ON ar.employee_id = e.id
      WHERE ar.employee_id = ? AND ar.timestamp BETWEEN ? AND ?
      ORDER BY ar.timestamp DESC
    ''', [employeeId, startStr, endStr]);
  }

  // HORARIOS
  Future<int> clearSchedules() async {
    final db = await database;
    return db.delete('schedules');
  }

  Future<int> saveSchedule(Map<String, dynamic> schedule) async {
    final db = await database;
    return db.insert(
      'schedules',
      schedule,
    );
  }

  /// Obtiene el sub-horario específico según el id_horario y la fecha (evaluando el día de la semana)
  Future<Map<String, dynamic>?> getScheduleByIdAndDate(String idHorario, DateTime date) async {
    final db = await database;
    final allRows = await db.query(
      'schedules',
      where: 'id_horario = ?',
      whereArgs: [idHorario],
    );

    if (allRows.isEmpty) return null;

    final String dayCode = switch (date.weekday) {
      1 => 'L',
      2 => 'M',
      3 => 'Mi',
      4 => 'J',
      5 => 'V',
      6 => 'S',
      7 => 'D',
      _ => 'D',
    };

    for (final row in allRows) {
      final String dias = row['dias']?.toString() ?? '';
      final List<String> daysList = dias.split(',').map((d) => d.trim()).toList();
      if (daysList.contains(dayCode)) {
        return row;
      }
    }

    return allRows.first;
  }

  Future<Map<String, dynamic>?> getScheduleById(String idHorario) async {
    return getScheduleByIdAndDate(idHorario, DateTime.now());
  }

  Future<List<Map<String, dynamic>>> getAllSchedules() async {
    final db = await database;
    return db.query('schedules');
  }

  // AUSENTISMOS / ABSENCES
  Future<int> saveAbsence(int employeeId, String date, String sigla, String? observacion, {int isSynced = 0, String? dispositivoId}) async {
    final db = await database;
    return db.insert(
      'absences',
      {
        'employee_id': employeeId,
        'date': date,
        'sigla_ausencia': sigla,
        'observacion': observacion,
        'is_synced': isSynced,
        'dispositivo_id': dispositivoId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> markAbsenceAsSynced(int employeeId, String date) async {
    final db = await database;
    return db.update(
      'absences',
      {'is_synced': 1},
      where: 'employee_id = ? AND date = ?',
      whereArgs: [employeeId, date],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingAbsences() async {
    final db = await database;
    return db.rawQuery('''
      SELECT a.*, e.employee_code AS employee_code
      FROM absences a
      JOIN employees e ON a.employee_id = e.id
      WHERE a.is_synced = 0 OR a.is_synced IS NULL
    ''');
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

  Future<List<Map<String, dynamic>>> getAbsencesByDateRange(DateTime start, DateTime end) async {
    final db = await database;
    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);
    return db.rawQuery('''
      SELECT a.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa, at.nombre AS absence_name
      FROM absences a
      JOIN employees e ON a.employee_id = e.id
      LEFT JOIN absence_types at ON a.sigla_ausencia = at.sigla
      WHERE a.date >= ? AND a.date <= ?
      ORDER BY a.date ASC
    ''', [startStr, endStr]);
  }

  Future<List<Map<String, dynamic>>> getAbsencesByEmployeeAndDateRange(int employeeId, DateTime start, DateTime end) async {
    final db = await database;
    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);
    return db.rawQuery('''
      SELECT a.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.id_empresa AS id_empresa, at.nombre AS absence_name
      FROM absences a
      JOIN employees e ON a.employee_id = e.id
      LEFT JOIN absence_types at ON a.sigla_ausencia = at.sigla
      WHERE a.employee_id = ? AND a.date >= ? AND a.date <= ?
      ORDER BY a.date ASC
    ''', [employeeId, startStr, endStr]);
  }

  // TIPOS DE AUSENCIA / NOVEDADES
  Future<int> saveAbsenceType(Map<String, dynamic> type) async {
    final db = await database;
    return db.insert(
      'absence_types',
      type,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllAbsenceTypes() async {
    final db = await database;
    return db.query('absence_types', orderBy: 'nombre ASC');
  }

  Future<int> saveSpecialSchedule(Map<String, dynamic> schedule) async {
    final db = await database;
    return db.insert(
      'special_schedules',
      schedule,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveSpecialSchedulesBatch(List<Map<String, dynamic>> schedules) async {
    final db = await database;
    final batch = db.batch();
    for (final schedule in schedules) {
      batch.insert(
        'special_schedules',
        schedule,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> deleteSpecialSchedule(int id) async {
    final db = await database;
    return db.delete('special_schedules', where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, dynamic>?> getSpecialScheduleForEmployee(int employeeId, String dateStr) async {
    final db = await database;
    final results = await db.query(
      'special_schedules',
      where: 'employee_id = ? AND date = ?',
      whereArgs: [employeeId, dateStr],
    );
    if (results.isNotEmpty) {
      return results.first;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getSpecialSchedulesByDate(String dateStr) async {
    final db = await database;
    return db.rawQuery('''
      SELECT ss.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.horario_id AS employee_horario_id
      FROM special_schedules ss
      JOIN employees e ON ss.employee_id = e.id
      WHERE ss.date = ?
      ORDER BY e.name ASC
    ''', [dateStr]);
  }

  Future<List<Map<String, dynamic>>> getAllSpecialSchedules() async {
    final db = await database;
    return db.rawQuery('''
      SELECT ss.*, e.name AS employee_name, e.employee_code AS employee_code, e.department AS employee_department, e.horario_id AS employee_horario_id
      FROM special_schedules ss
      JOIN employees e ON ss.employee_id = e.id
      ORDER BY ss.date DESC, e.name ASC
    ''');
  }

  Future<bool> hasAnySpecialScheduleOnDate(String dateStr) async {
    final db = await database;
    final res = await db.query(
      'special_schedules',
      where: 'date = ?',
      whereArgs: [dateStr],
      limit: 1,
    );
    return res.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> getPendingSpecialSchedules() async {
    final db = await database;
    return db.rawQuery('''
      SELECT ss.*, e.employee_code AS employee_code
      FROM special_schedules ss
      JOIN employees e ON ss.employee_id = e.id
      WHERE ss.is_synced = 0 OR ss.is_synced IS NULL
    ''');
  }

  Future<void> markSpecialScheduleAsSynced(int id) async {
    final db = await database;
    await db.update(
      'special_schedules',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> upsertSpecialScheduleFromServer(Map<String, dynamic> data) async {
    final db = await database;
    final String? cedula = data['cedula']?.toString().trim();
    final String? date = data['date']?.toString().trim();
    if (cedula == null || date == null) return;

    final empList = await db.query('employees', where: 'employee_code = ?', whereArgs: [cedula]);
    if (empList.isEmpty) return;
    final int employeeId = empList.first['id'] as int;

    await db.insert(
      'special_schedules',
      {
        'employee_id': employeeId,
        'date': date,
        'hora_inicio': data['hora_inicio'],
        'hora_final': data['hora_final'],
        'observacion': data['observacion'],
        'is_synced': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
