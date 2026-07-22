import 'dart:convert';
import 'database_service.dart';
import 'sql_server_service.dart';
import '../models/employee.dart';

class SyncService {
  final SqlServerService _sqlServer = SqlServerService();
  final DatabaseService _database = DatabaseService();

  /// Sincroniza los empleados y vectores desde SQL Server central hacia SQLite local
  Future<void> sincronizarDesdeSqlServer() async {
    print('[Sync] Iniciando descarga de horarios desde SQL Server...');
    try {
      final remoteSchedules = await _sqlServer.obtenerHorariosServidor();
      print('[Sync] Descargados ${remoteSchedules.length} horarios.');
      for (final s in remoteSchedules) {
        if (s['id_horario'] != null) {
          await _database.saveSchedule({
            'id_horario': s['id_horario'].toString().trim(),
            'hora_inicio': s['hora_inicio']?.toString().trim() ?? '',
            'hora_final': s['hora_final']?.toString().trim() ?? '',
            'tipo': s['tipo']?.toString().trim() ?? 'LABORAL',
            'dias': s['dias']?.toString().trim() ?? '',
          });
        }
      }
    } catch (e) {
      print('[Sync] Advertencia al sincronizar horarios: $e');
    }

    print('[Sync] Iniciando descarga de empleados desde SQL Server...');
    final remoteData = await _sqlServer.obtenerYActualizarEmpleados();
    print('[Sync] Descargados ${remoteData.length} empleados.');

    for (final row in remoteData) {
      final String? cedula = row['cedula']?.toString().trim();
      final String? nombre = row['nombre']?.toString().trim();
      final String? estado = row['estado']?.toString().trim();
      final String? departamento = row['id_seccion']?.toString().trim() ?? row['tipo']?.toString().trim();
      final String? horarioId = row['horario_id']?.toString().trim();
      final String part1 = row['vec_part1']?.toString() ?? '';
      final String part2 = row['vec_part2']?.toString() ?? '';
      final String part3 = row['vec_part3']?.toString() ?? '';
      final String mapaVectorFotoStr = (part1 + part2 + part3).trim();

      if (cedula == null || cedula.isEmpty || nombre == null || nombre.isEmpty) {
        continue;
      }

      // Si el empleado está inactivo en el ERP, lo eliminamos de local (o desactivamos)
      if (estado == 'INACTIVO') {
        final db = await _database.database;
        final existing = await db.query('employees', where: 'employee_code = ?', whereArgs: [cedula]);
        if (existing.isNotEmpty) {
          final empId = existing.first['id'] as int;
          await db.delete('face_embeddings', where: 'employee_id = ?', whereArgs: [empId]);
          await db.delete('employees', where: 'id = ?', whereArgs: [empId]);
          print('[Sync] Empleado inactivo eliminado: $nombre ($cedula)');
        }
        continue;
      }

      // Insertar o actualizar el empleado en SQLite local
      final employee = Employee(
        name: nombre,
        employeeCode: cedula,
        department: departamento,
        horarioId: horarioId != null && horarioId.isNotEmpty ? horarioId : null,
        createdAt: DateTime.now(),
      );

      final employeeId = await _insertOrUpdateEmployee(employee);

      // Sincronizar el vector biométrico si existe
      if (mapaVectorFotoStr != null && mapaVectorFotoStr.isNotEmpty) {
        try {
          final List<dynamic> rawVector = jsonDecode(mapaVectorFotoStr);
          final List<double> vector = rawVector.map((e) => (e as num).toDouble()).toList();

          if (vector.isNotEmpty) {
            // Limpiar embeddings anteriores para evitar duplicados
            final db = await _database.database;
            await db.delete('face_embeddings', where: 'employee_id = ?', whereArgs: [employeeId]);

            // Si es multi-pose de 5 poses (960 elementos)
            if (vector.length == 960) {
              final poses = ['Frontal', 'Izquierda', 'Derecha', 'Arriba', 'Sonrisa'];
              for (int i = 0; i < 5; i++) {
                final chunk = vector.sublist(i * 192, (i + 1) * 192);
                await _database.saveEmbedding(employeeId, chunk, poses[i]);
              }
              print('[Sync] Cargadas 5 poses biométricas para: $nombre');
            } else if (vector.length == 192) {
              // Pose única
              await _database.saveEmbedding(employeeId, vector, 'Frontal');
              print('[Sync] Cargada pose biométrica única para: $nombre');
            } else {
              // Si es un vector de otro modelo (por ejemplo, 128 o 640 dimensiones)
              // Se guarda en SQLite para mantener compatibilidad pero se advierte que requiere re-enrolamiento
              if (vector.length == 640) {
                final poses = ['Frontal', 'Izquierda', 'Derecha', 'Arriba', 'Sonrisa'];
                for (int i = 0; i < 5; i++) {
                  final chunk = vector.sublist(i * 128, (i + 1) * 128);
                  await _database.saveEmbedding(employeeId, chunk, poses[i]);
                }
              } else if (vector.length == 128) {
                await _database.saveEmbedding(employeeId, vector, 'Frontal');
              }
              print('[Sync] Vector de dimensión alternativa (${vector.length}) cargado para $nombre. Puede requerir re-enrolamiento.');
            }
          }
        } catch (e) {
          print('[Sync] Error al parsear vector para $nombre ($cedula): $e');
        }
      }
    }
    print('[Sync] Sincronización completada con éxito.');
  }

  /// Sube un colaborador recién enrolado localmente hacia SQL Server central
  Future<bool> subirEnrolamiento({
    required String cedula,
    required String nombre,
    required List<List<double>> poses,
    String? departamento,
  }) async {
    try {
      // Unificar las 5 poses en un vector plano de 960
      final combinedVector = poses.expand((p) => p).toList();

      final success = await _sqlServer.actualizarVectorEmpleado(
        cedula: cedula,
        nombre: nombre,
        vector: combinedVector,
        idSeccion: departamento,
      );

      if (success) {
        print('[Sync] Enrolamiento subido con éxito a SQL Server para: $nombre ($cedula)');
      }
      return success;
    } catch (e) {
      print('[Sync] Error al subir enrolamiento: $e');
      return false;
    }
  }

  Future<int> _insertOrUpdateEmployee(Employee employee) async {
    final db = await _database.database;
    final existing = await db.query(
      'employees',
      where: 'employee_code = ?',
      whereArgs: [employee.employeeCode],
    );

    if (existing.isEmpty) {
      return db.insert('employees', employee.toMap());
    } else {
      final id = existing.first['id'] as int;
      await db.update(
        'employees',
        employee.toMap()..remove('id'),
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
  }
}
