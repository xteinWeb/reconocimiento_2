import 'dart:convert';
import 'dart:async';
import 'database_service.dart';
import 'sql_server_service.dart';
import '../models/employee.dart';
import '../models/face_embedding.dart';

class SyncService {
  final SqlServerService _sqlServer = SqlServerService();
  final DatabaseService _database = DatabaseService();

  /// Sincroniza los empleados y vectores desde SQL Server central hacia SQLite local
  Future<void> sincronizarDesdeSqlServer() async {
    // Reportar latido del dispositivo antes de iniciar la sincronización
    final deviceId = await _database.getDeviceId();
    if (deviceId != null && deviceId.isNotEmpty) {
      await _sqlServer.reportarSincronizacionTotem(deviceId);
    } else {
      print('[Sync] Advertencia: Este tótem no tiene un identificador de dispositivo asignado.');
    }

    // Sincronizar primero enrolamientos locales pendientes
    await sincronizarEnrolamientosPendientes();

    print('[Sync] Iniciando descarga de horarios desde SQL Server...');
    try {
      final remoteSchedules = await _sqlServer.obtenerHorariosServidor();
      print('[Sync] Descargados ${remoteSchedules.length} bloques de horarios.');
      await _database.clearSchedules();
      for (final s in remoteSchedules) {
        if (s['id_horario'] != null) {
          await _database.saveSchedule({
            'id_horario': s['id_horario'].toString().trim(),
            'hora_inicio': s['hora_inicio']?.toString().trim() ?? '',
            'hora_final': s['hora_final']?.toString().trim() ?? '',
            'tipo': s['tipo']?.toString().trim() ?? 'PRODUCTIVA',
            'dias': s['dias']?.toString().trim() ?? '',
          });
        }
      }
    } catch (e) {
      print('[Sync] Advertencia al sincronizar horarios: $e');
    }

    print('[Sync] Iniciando descarga de tipos de ausencia desde SQL Server...');
    try {
      final remoteAbsenceTypes = await _sqlServer.obtenerTiposAusenciaServidor();
      print('[Sync] Descargados ${remoteAbsenceTypes.length} tipos de ausencia.');
      for (final t in remoteAbsenceTypes) {
        final String? sigla = t['sigla']?.toString().trim();
        final String? nombre = t['nombre']?.toString().trim();
        if (sigla != null && sigla.isNotEmpty && nombre != null && nombre.isNotEmpty) {
          await _database.saveAbsenceType({
            'sigla': sigla,
            'nombre': nombre,
          });
        }
      }
    } catch (e) {
      print('[Sync] Advertencia al sincronizar tipos de ausencia: $e');
    }

    print('[Sync] Iniciando descarga de empleados desde SQL Server...');
    final remoteData = await _sqlServer.obtenerYActualizarEmpleados();
    print('[Sync] Descargados ${remoteData.length} empleados.');

    for (final row in remoteData) {
      final String? cedula = row['cedula']?.toString().trim();
      final String? nombre = row['nombre']?.toString().trim();
      final String? estado = row['estado']?.toString().trim();
      final String? nombreSeccion = row['nombre_seccion']?.toString().trim();
      final String? idSeccion = row['id_seccion']?.toString().trim();
      final String departamento = (nombreSeccion != null && nombreSeccion.isNotEmpty)
          ? nombreSeccion
          : ((idSeccion != null && idSeccion.isNotEmpty) ? idSeccion : 'ADMINISTRATIVO');
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

      // Si el empleado ya existe localmente y no está sincronizado (enrolamiento local pendiente),
      // no debemos sobrescribir su vector local con el del servidor (que sería viejo o vacío)
      final db = await _database.database;
      final existingEmployee = await db.query(
        'employees',
        where: 'employee_code = ?',
        whereArgs: [cedula],
      );
      bool skipVectorOverwrite = false;
      int isSynced = 1;
      if (existingEmployee.isNotEmpty) {
        final int localIsSynced = existingEmployee.first['is_synced'] as int? ?? 1;
        if (localIsSynced == 0) {
          skipVectorOverwrite = true;
          isSynced = 0;
          print('[Sync] Evitando sobrescribir enrolamiento local pendiente para: $nombre ($cedula)');
        }
      }

      final String? idEmpresa = row['id_empresa']?.toString().trim();
      final String? rawIdUnItem = row['id_un_item']?.toString().trim();
      final String? rawSede = row['sede_principal']?.toString().trim();
      final String? idUnItem = (rawIdUnItem != null && rawIdUnItem.isNotEmpty)
          ? rawIdUnItem
          : ((rawSede != null && rawSede.isNotEmpty) ? rawSede : null);

      // Insertar o actualizar el empleado en SQLite local
      final employee = Employee(
        name: nombre,
        employeeCode: cedula,
        department: departamento,
        horarioId: horarioId != null && horarioId.isNotEmpty ? horarioId : null,
        createdAt: DateTime.now(),
        isSynced: isSynced,
        idEmpresa: idEmpresa != null && idEmpresa.isNotEmpty ? idEmpresa : null,
        idUnItem: idUnItem,
      );

      final employeeId = await _insertOrUpdateEmployee(employee);

      // Sincronizar el vector biométrico si existe
      print('[Sync] Empleado: $nombre ($cedula) - skipOverwrite: $skipVectorOverwrite, mapaVectorFotoStr length: ${mapaVectorFotoStr.length}');
      if (!skipVectorOverwrite && mapaVectorFotoStr.isNotEmpty) {
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

    // Sincronizar ausencias locales hacia el servidor
    await sincronizarAusenciasPendientes();

    // Autogenerar novedades de LLT y SC en el servidor central
    await autogenerarNovedadesCentral();

    // Sincronizar asistencias del servidor al local (bidireccional)
    await descargarAsistenciasDesdeSqlServer();

    // Sincronizar programaciones especiales (bidireccional)
    await sincronizarProgramacionesEspeciales();

    print('[Sync] Sincronización completada con éxito.');
  }

  /// Sincroniza programaciones especiales (sube pendientes y descarga desde SQL Server)
  Future<void> sincronizarProgramacionesEspeciales() async {
    print('[Sync] Iniciando sincronización de programaciones especiales...');
    final deviceId = await _database.getDeviceId();

    // 1. Subir programaciones locales pendientes en lote
    try {
      final pending = await _database.getPendingSpecialSchedules();
      print('[Sync] Programaciones especiales pendientes por subir: ${pending.length}');

      if (pending.isNotEmpty) {
        final List<Map<String, dynamic>> itemsToUpload = [];
        final List<int> pendingIds = [];

        for (final p in pending) {
          final int id = p['id'] as int;
          final String? cedula = p['employee_code']?.toString();
          final String? date = p['date']?.toString();
          if (cedula != null && date != null) {
            pendingIds.add(id);
            itemsToUpload.add({
              'cedula': cedula,
              'fecha': date,
              'horaInicio': p['hora_inicio']?.toString(),
              'horaFinal': p['hora_final']?.toString(),
              'observacion': p['observacion']?.toString(),
              'dispositivoId': deviceId,
            });
          }
        }

        if (itemsToUpload.isNotEmpty) {
          final success = await _sqlServer.guardarProgramacionesEspecialesLoteServidor(itemsToUpload);
          if (success) {
            for (final id in pendingIds) {
              await _database.markSpecialScheduleAsSynced(id);
            }
          }
        }
      }
    } catch (e) {
      print('[Sync] Error al subir programaciones especiales en lote: $e');
    }

    // 2. Descargar programaciones especiales desde el servidor
    try {
      final remoteList = await _sqlServer.obtenerProgramacionesEspecialesServidor();
      print('[Sync] Descargadas ${remoteList.length} programaciones especiales del servidor.');
      for (final r in remoteList) {
        await _database.upsertSpecialScheduleFromServer(r);
      }
    } catch (e) {
      print('[Sync] Error al descargar programaciones especiales: $e');
    }
  }

  /// Elimina una programación especial por ID
  Future<void> eliminarProgramacionEspecial(int id) async {
    await eliminarProgramacionesEspeciales([id]);
  }

  /// Elimina múltiples programaciones especiales en lote (local y remotamente en una sola consulta)
  Future<void> eliminarProgramacionesEspeciales(List<int> ids) async {
    if (ids.isEmpty) return;

    try {
      final db = await _database.database;
      final placeholders = List.filled(ids.length, '?').join(',');

      // 1. Obtener pares (cedula, fecha) antes de borrar localmente
      final rows = await db.rawQuery('''
        SELECT s.id, s.date, e.employee_code
        FROM special_schedules s
        INNER JOIN employees e ON s.employee_id = e.id
        WHERE s.id IN ($placeholders)
      ''', ids);

      final List<Map<String, String>> itemsToDelete = [];
      for (final r in rows) {
        final dateStr = r['date']?.toString();
        final cedula = r['employee_code']?.toString();
        if (dateStr != null && cedula != null) {
          itemsToDelete.add({'cedula': cedula, 'fecha': dateStr});
        }
      }

      // 2. Eliminar de SQLite local
      for (final id in ids) {
        await _database.deleteSpecialSchedule(id);
      }

      // 3. Eliminar de SQL Server central en una sola consulta
      if (itemsToDelete.isNotEmpty) {
        await _sqlServer.eliminarProgramacionesEspecialesServidor(itemsToDelete);
      }
    } catch (e) {
      print('[Sync] Error al eliminar programaciones especiales en lote: $e');
    }
  }

  /// Sincroniza los enrolamientos locales pendientes (is_synced = 0) hacia SQL Server
  Future<void> sincronizarEnrolamientosPendientes() async {
    print('[Sync] Iniciando sincronización de enrolamientos locales pendientes...');
    try {
      final db = await _database.database;
      final pendingEmployees = await db.query(
        'employees',
        where: 'is_synced = 0',
      );

      print('[Sync] Encontrados ${pendingEmployees.length} enrolamientos pendientes.');

      for (final empMap in pendingEmployees) {
        final employee = Employee.fromMap(empMap);
        if (employee.id == null) continue;

        print('[Sync] Sincronizando enrolamiento para: ${employee.name} (${employee.employeeCode})');
        final embeddings = await _database.getEmbeddingsByEmployee(employee.id!);

        if (embeddings.length < 5) {
          print('[Sync] Advertencia: El empleado ${employee.name} tiene solo ${embeddings.length} poses guardadas. Se requieren 5.');
          continue;
        }

        // Orden esperado por el servidor central de SQL Server
        final expectedPoses = [
          'Frontal',
          'Izquierda',
          'Derecha',
          'Arriba',
          'Sonrisa',
        ];
        final sortedPoses = <List<double>>[];

        for (final poseName in expectedPoses) {
          final match = embeddings.firstWhere(
            (e) => e.angleType == poseName,
            orElse: () => FaceEmbedding(
              employeeId: employee.id!,
              embedding: List.filled(192, 0.0),
              angleType: poseName,
              createdAt: DateTime.now(),
            ),
          );
          sortedPoses.add(match.embedding);
        }

        final success = await subirEnrolamiento(
          cedula: employee.employeeCode,
          nombre: employee.name,
          poses: sortedPoses,
          departamento: employee.department,
          horarioId: employee.horarioId,
        );

        if (success) {
          await _database.updateEmployeeSyncStatus(employee.id!, 1);
          print('[Sync] Enrolamiento subido con éxito para: ${employee.name}');
        } else {
          print('[Sync] Error al subir enrolamiento para: ${employee.name}');
        }
      }
    } catch (e) {
      print('[Sync] Error en sincronizarEnrolamientosPendientes: $e');
    }
  }

  /// Sube un colaborador recién enrolado localmente hacia SQL Server central
  Future<bool> subirEnrolamiento({
    required String cedula,
    required String nombre,
    required List<List<double>> poses,
    String? departamento,
    String? horarioId,
  }) async {
    try {
      // Unificar las 5 poses en un vector plano de 960
      final combinedVector = poses.expand((p) => p).toList();

      final success = await _sqlServer.actualizarVectorEmpleado(
        cedula: cedula,
        nombre: nombre,
        vector: combinedVector,
        idSeccion: departamento,
        horarioId: horarioId,
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

  /// Sincroniza todas las marcaciones pendientes (is_synced = 0) de SQLite con SQL Server
  Future<Map<String, int>> sincronizarAsistenciasPendientes() async {
    // Sincronizar primero enrolamientos locales pendientes
    await sincronizarEnrolamientosPendientes();

    final pendingRecords = await _database.getPendingAttendanceRecords();
    int total = pendingRecords.length;
    int successCount = 0;
    int failCount = 0;

    print('[Sync] Iniciando sincronización de $total marcaciones pendientes...');

    for (final record in pendingRecords) {
      final int recordId = record['id'] as int;
      final String? cedula = record['employee_code']?.toString();
      final String timestampStr = record['timestamp']?.toString() ?? '';
      final DateTime? fechaHora = DateTime.tryParse(timestampStr);
      final String evento = record['evento']?.toString() ?? 'ENTRADA';
      final String tipo = record['tipo']?.toString() ?? 'NORMAL';
      final String? duracionStr = record['duracion']?.toString();
      final double duracion = duracionStr != null
          ? double.tryParse(duracionStr.split(' ')[0]) ?? 0.0
          : 0.0;
      final String departamento = record['employee_department']?.toString() ?? '';

      if (cedula == null || cedula.isEmpty || fechaHora == null) {
        failCount++;
        continue;
      }

      final success = await _sqlServer.guardarAsistenciaServidor(
        cedula: cedula,
        fechaHora: fechaHora,
        evento: evento,
        duracion: duracion,
        tipo: tipo,
        unidadNegocio: departamento,
        metodoRegistro: record['metodo_registro']?.toString() ?? 'FACIAL',
        idDispositivo: record['dispositivo_id']?.toString(),
      );

      if (success) {
        await _database.markAttendanceAsSynced(recordId);
        successCount++;
        print('[Sync] Marcación #$recordId subida con éxito ($cedula).');
      } else {
        failCount++;
        print('[Sync] Marcación #$recordId falló al subirse.');
      }
    }

    print('[Sync] Proceso finalizado: $successCount exitosos, $failCount fallidos.');
    return {
      'total': total,
      'success': successCount,
      'failed': failCount,
    };
  }

  /// Sincroniza un registro de marcación individual por su ID
  Future<bool> sincronizarMarcacionIndividual(Map<String, dynamic> record) async {
    final int recordId = record['id'] as int;
    final String? cedula = record['employee_code']?.toString();
    final String timestampStr = record['timestamp']?.toString() ?? '';
    final DateTime? fechaHora = DateTime.tryParse(timestampStr);
    final String evento = record['evento']?.toString() ?? 'ENTRADA';
    final String tipo = record['tipo']?.toString() ?? 'NORMAL';
    final String? duracionStr = record['duracion']?.toString();
    final double duracion = duracionStr != null
        ? double.tryParse(duracionStr.split(' ')[0]) ?? 0.0
        : 0.0;
    final String departamento = record['employee_department']?.toString() ?? '';

    if (cedula == null || cedula.isEmpty || fechaHora == null) {
      return false;
    }

    final success = await _sqlServer.guardarAsistenciaServidor(
      cedula: cedula,
      fechaHora: fechaHora,
      evento: evento,
      duracion: duracion,
      tipo: tipo,
      unidadNegocio: departamento,
      metodoRegistro: record['metodo_registro']?.toString() ?? 'FACIAL',
      idDispositivo: record['dispositivo_id']?.toString(),
    );

    if (success) {
      await _database.markAttendanceAsSynced(recordId);
    }
    return success;
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

  /// Descarga asistencias desde SQL Server central hacia SQLite local (últimos 30 días)
  Future<void> descargarAsistenciasDesdeSqlServer() async {
    print('[Sync] Iniciando descarga de asistencias desde SQL Server...');
    try {
      final remoteRecords = await _sqlServer.obtenerAsistenciasServidor();
      print('[Sync] Descargados ${remoteRecords.length} registros de asistencia desde el servidor.');

      final db = await _database.database;

      for (final r in remoteRecords) {
        final String? cedula = r['cedula']?.toString().trim();
        final String? timestampStr = r['fecha_hora']?.toString().trim();
        final String? evento = r['evento']?.toString().trim();
        final String? tipo = r['tipo']?.toString().trim();
        final String? duracionStr = r['duracion']?.toString().trim();
        
        if (cedula == null || cedula.isEmpty || timestampStr == null || timestampStr.isEmpty) {
          continue;
        }

        // Buscar empleado local para asociar
        final empList = await db.query(
          'employees',
          where: 'employee_code = ?',
          whereArgs: [cedula],
        );
        if (empList.isEmpty) {
          continue; 
        }
        final int employeeId = empList.first['id'] as int;

        // Estandarizar fecha
        DateTime? parsedTime = DateTime.tryParse(timestampStr);
        if (parsedTime == null) continue;
        final String localTimestamp = parsedTime.toIso8601String();

        // Evitar duplicados locales
        final existing = await db.query(
          'attendance_records',
          where: 'employee_id = ? AND timestamp = ? AND evento = ?',
          whereArgs: [employeeId, localTimestamp, evento],
        );

        if (existing.isEmpty) {
          await db.insert('attendance_records', {
            'employee_id': employeeId,
            'timestamp': localTimestamp,
            'confidence': 1.0,
            'evento': evento ?? 'ENTRADA',
            'tipo': tipo ?? 'NORMAL',
            'duracion': duracionStr,
            'is_synced': 1,
          });
          print('[Sync] Registro de asistencia descargado y guardado para empleado ID $employeeId ($evento en $localTimestamp)');
        }
      }
    } catch (e) {
      print('[Sync] Error al descargar asistencias: $e');
    }
  }

  /// Sincroniza novedades de ausencias locales pendientes de subir al servidor
  Future<Map<String, int>> sincronizarAusenciasPendientes() async {
    final pendingAbsences = await _database.getPendingAbsences();
    final int total = pendingAbsences.length;
    int successCount = 0;
    int failCount = 0;

    if (total == 0) {
      return {'total': 0, 'success': 0, 'failed': 0};
    }

    print('[Sync] Iniciando sincronización de $total ausencias/novedades pendientes...');

    for (final absence in pendingAbsences) {
      final int employeeId = absence['employee_id'] as int;
      final String date = absence['date'].toString();
      final String sigla = absence['sigla_ausencia'].toString();
      final String? observacion = absence['observacion']?.toString();
      final String? cedula = absence['employee_code']?.toString();

      if (cedula == null || cedula.isEmpty) {
        failCount++;
        continue;
      }

      final success = await _sqlServer.guardarAusentismoServidor(
        cedula: cedula,
        fecha: date,
        sigla: sigla,
        observacion: observacion,
        idDispositivo: absence['dispositivo_id']?.toString(),
      );

      if (success) {
        await _database.markAbsenceAsSynced(employeeId, date);
        successCount++;
        print('[Sync] Ausencia de $cedula en fecha $date subida con éxito.');
      } else {
        failCount++;
        print('[Sync] Ausencia de $cedula en fecha $date falló al subirse.');
      }
    }

    print('[Sync] Sincronización de ausencias finalizada: $successCount exitosas, $failCount fallidas.');
    return {
      'total': total,
      'success': successCount,
      'failed': failCount,
    };
  }

  /// Descarga los ausentismos (SC y justificantes) registrados en el servidor para una fecha específica y los guarda en SQLite
  Future<void> descargarAusentismosServidor(String fecha) async {
    try {
      final remoteAbsences = await _sqlServer.obtenerAusentismosServidor(fecha);
      print('[Sync] Descargados ${remoteAbsences.length} ausentismos del servidor para la fecha $fecha');

      for (final ra in remoteAbsences) {
        final String? cedula = ra['cedula'];
        final String? sigla = ra['sigla_ausencia'];
        final String? obs = ra['observacion'];
        if (cedula != null && sigla != null) {
          final emp = await _database.getEmployeeByCode(cedula);
          if (emp != null && emp.id != null) {
            await _database.saveAbsence(
              emp.id!,
              fecha,
              sigla,
              obs,
              isSynced: 1,
            );
          }
        }
      }
    } catch (e) {
      print('[Sync] Error al descargar ausentismos del servidor: $e');
    }
  }

  /// Dispara la autogeneración de LLT y SC en el servidor SQL Server central.
  /// SC solo se ejecuta hoy si la hora actual es posterior o igual a las 16:00 (4:00 PM)
  /// y además se valida que todos los demás tótems activos hayan sincronizado.
  /// Para los dos días anteriores, se ejecuta sin restricciones de hora.
  Future<void> autogenerarNovedadesCentral() async {
    print('[Sync] Iniciando proceso automático de novedades (LLT y SC)...');
    try {
      final String? deviceId = await _database.getDeviceId();
      if (deviceId == null || deviceId.isEmpty) {
        print('[Sync] Omitiendo autogeneración: esta tablet no tiene un ID de dispositivo asignado (debe configurarse en ajustes).');
        return;
      }

      // Asegurar que nuestro latido esté registrado antes de validar el de los demás
      await _sqlServer.reportarSincronizacionTotem(deviceId);

      // 1. Generar Llegadas Tardes (LLT)
      await _sqlServer.autogenerarLltEnServidor();

      // 2. Generar Faltas Sin Justa Causa (SC) para los últimos 3 días
      final DateTime now = DateTime.now();
      
      // Hoy
      final String hoyStr = now.toIso8601String().substring(0, 10);
      if (now.hour >= 16) {
        // VALIDACIÓN: Verificar si todas las tablets activas ya sincronizaron hoy después de las 4:00 PM
        final bool todosSincronizados = await _sqlServer.validarSincronizacionTotalHoy();
        if (todosSincronizados) {
          await _sqlServer.autogenerarScEnServidor(hoyStr);
        } else {
          print('[Sync] Pospuesta la autogeneración de SC de hoy ($hoyStr): Hay tótems de otras sedes pendientes de sincronizar.');
        }
      } else {
        print('[Sync] Omitiendo SC para hoy ($hoyStr) por no ser aún las 4:00 PM.');
      }

      // Ayer
      final String ayerStr = now.subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      await _sqlServer.autogenerarScEnServidor(ayerStr);

      // Anteayer
      final String anteayerStr = now.subtract(const Duration(days: 2)).toIso8601String().substring(0, 10);
      await _sqlServer.autogenerarScEnServidor(anteayerStr);

      print('[Sync] Proceso automático de novedades finalizado.');
    } catch (e) {
      print('[Sync] Error al autogenerar novedades: $e');
    }
  }

  static Timer? _diarioScTimer;

  /// Programa un temporizador automático para que se ejecute todos los días exactamente a las 4:00 PM
  void iniciarTemporizadorDiarioSc() {
    _diarioScTimer?.cancel();

    final DateTime now = DateTime.now();
    DateTime target = DateTime(now.year, now.month, now.day, 16, 0, 0); // 4:00 PM hoy

    if (now.isAfter(target)) {
      // Si ya pasó de las 4:00 PM hoy, programar para mañana a las 4:00 PM
      target = target.add(const Duration(days: 1));
    }

    final Duration duration = target.difference(now);
    print('[Sync] Programando autogeneración de novedades diarias para las 16:00 (dentro de ${duration.inHours} horas, ${duration.inMinutes % 60} minutos)...');

    _diarioScTimer = Timer(duration, () async {
      print('[Sync] Temporizador diario activado. Iniciando sincronización completa...');
      await sincronizarDesdeSqlServer();
      // Reprogramar para el siguiente día
      iniciarTemporizadorDiarioSc();
    });
  }
}
