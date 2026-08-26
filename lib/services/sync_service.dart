import 'dart:convert';
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:intl/intl.dart';
import 'database_service.dart';
import 'face_recognition_service.dart';
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
            const int dim = FaceRecognitionService.embeddingSize; // 192
            const poses = ['Frontal', 'Izquierda', 'Derecha', 'Arriba', 'Sonrisa'];

            // Solo aceptamos vectores del modelo actual. Un vector de otra
            // dimensión NO es comparable con nuestros embeddings: guardarlo
            // "por compatibilidad" solo contamina la galería y produce
            // errores o coincidencias sin sentido. Se descarta y se marca
            // al empleado como pendiente de re-enrolamiento.
            if (vector.length != dim && vector.length != dim * 5) {
              print(
                '[Sync] Vector de dimensión ${vector.length} DESCARTADO para '
                '$nombre ($cedula). El modelo actual usa $dim. '
                'Requiere re-enrolamiento.',
              );
            } else {
              // Limpiar embeddings anteriores para evitar duplicados
              final db = await _database.database;
              await db.delete('face_embeddings',
                  where: 'employee_id = ?', whereArgs: [employeeId]);

              int guardados = 0;
              int descartados = 0;

              if (vector.length == dim * 5) {
                for (int i = 0; i < 5; i++) {
                  final chunk = vector.sublist(i * dim, (i + 1) * dim);
                  // saveEmbedding normaliza y rechaza ceros/NaN por sí solo.
                  final id = await _database.saveEmbedding(
                      employeeId, chunk, poses[i]);
                  if (id > 0) {
                    guardados++;
                  } else {
                    descartados++;
                  }
                }
              } else {
                final id =
                    await _database.saveEmbedding(employeeId, vector, 'Frontal');
                if (id > 0) {
                  guardados++;
                } else {
                  descartados++;
                }
              }

              print(
                '[Sync] $nombre ($cedula): $guardados poses válidas cargadas'
                '${descartados > 0 ? ", $descartados descartadas (vector nulo o corrupto)" : ""}.',
              );

              if (guardados == 0) {
                print(
                  '[Sync] ATENCIÓN: $nombre ($cedula) quedó SIN plantilla '
                  'biométrica utilizable. No podrá marcar por rostro.',
                );
              }
            }
          }
        } catch (e) {
          print('[Sync] Error al parsear vector para $nombre ($cedula): $e');
        }
      }
    }

    // Depuración de inactivos: obtenerYActualizarEmpleados() solo devuelve
    // empleados ACTIVOS, así que el chequeo `estado == 'INACTIVO'` de arriba
    // nunca se cumple. Cualquier empleado local que ya no venga en ese
    // listado (porque pasó a INACTIVO en el ERP) se elimina aquí.
    final cedulasActivas = remoteData
        .map((r) => r['cedula']?.toString().trim())
        .whereType<String>()
        .where((c) => c.isNotEmpty)
        .toSet();

    final localEmployees = await _database.getAllEmployees();
    for (final localEmp in localEmployees) {
      final code = localEmp.employeeCode.trim();
      if (code.isNotEmpty && localEmp.id != null && !cedulasActivas.contains(code)) {
        final db = await _database.database;
        await db.delete('face_embeddings', where: 'employee_id = ?', whereArgs: [localEmp.id]);
        await db.delete('employees', where: 'id = ?', whereArgs: [localEmp.id]);
        print('[Sync] Empleado ya no activo en el servidor, eliminado localmente: ${localEmp.name} ($code)');
      }
    }

    // Bajar las novedades (incapacidades, permisos, etc.) vigentes para HOY,
    // con su rango exacto de fecha/hora. Es lo que permite que al marcar
    // asistencia se detecte localmente si la persona tiene un permiso activo
    // en ese momento, sin depender de una consulta en línea al marcar.
    try {
      final hoyStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final novedades = await _sqlServer.obtenerNovedadesEmpleadoServidor(hoyStr);
      await _database.reemplazarNovedadesEmpleado(novedades);
      print('[Sync] Novedades de empleado vigentes hoy: ${novedades.length}.');
    } catch (e) {
      print('[Sync] Advertencia al sincronizar novedades de empleado: $e');
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

        // Orden esperado por el servidor central de SQL Server.
        //
        // Antes, una pose faltante se rellenaba con un vector de 192 ceros.
        // Ese relleno viajaba al servidor central y volvía a TODOS los tótems
        // en la siguiente sincronización, contaminando la galería. Ahora un
        // enrolamiento incompleto simplemente no se sube.
        final sortedPoses = _ordenarPosesParaServidor(embeddings);
        if (sortedPoses == null) {
          print(
            '[Sync] Enrolamiento de ${employee.name} INCOMPLETO o con vectores '
            'inválidos. No se sube al servidor; debe repetirse la captura.',
          );
          continue;
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

  /// Orden canónico de las 5 poses que espera el servidor central.
  static const List<String> posesEsperadas = [
    'Frontal',
    'Izquierda',
    'Derecha',
    'Arriba',
    'Sonrisa',
  ];

  /// Ordena las poses en el formato del servidor, validando cada vector.
  ///
  /// Devuelve `null` si falta alguna pose o si alguna es inválida, en lugar de
  /// rellenar con ceros. Un vector de ceros propagado al servidor central
  /// termina replicándose a todos los tótems.
  static List<List<double>>? ordenarPosesParaServidor(
    List<FaceEmbedding> embeddings,
  ) {
    final ordenadas = <List<double>>[];

    for (final poseName in posesEsperadas) {
      FaceEmbedding? match;
      for (final e in embeddings) {
        if (e.angleType == poseName) {
          match = e;
          break;
        }
      }
      if (match == null) return null;

      final clean = FaceRecognitionService.sanitize(match.embedding);
      if (clean == null) return null;

      ordenadas.add(clean);
    }

    return ordenadas;
  }

  static List<List<double>>? _ordenarPosesParaServidor(
    List<FaceEmbedding> embeddings,
  ) =>
      ordenarPosesParaServidor(embeddings);

  /// Sube un colaborador recién enrolado localmente hacia SQL Server central
  Future<bool> subirEnrolamiento({
    required String cedula,
    required String nombre,
    required List<List<double>> poses,
    String? departamento,
    String? horarioId,
  }) async {
    try {
      const int dim = FaceRecognitionService.embeddingSize;

      // Barrera final: nunca subir un enrolamiento incompleto o corrupto.
      if (poses.length != posesEsperadas.length) {
        print(
          '[Sync] subirEnrolamiento abortado para $cedula: se esperaban '
          '${posesEsperadas.length} poses y llegaron ${poses.length}.',
        );
        return false;
      }
      for (int i = 0; i < poses.length; i++) {
        if (FaceRecognitionService.sanitize(poses[i]) == null) {
          print(
            '[Sync] subirEnrolamiento abortado para $cedula: la pose '
            '"${posesEsperadas[i]}" es inválida (dim=${poses[i].length} '
            'o vector nulo).',
          );
          return false;
        }
      }

      // Unificar las 5 poses (ya normalizadas) en un vector plano de 960
      final combinedVector = poses
          .map((p) => FaceRecognitionService.sanitize(p)!)
          .expand((p) => p)
          .toList();

      assert(combinedVector.length == dim * 5);

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

  /// Sube de inmediato la novedad de llegada tarde (LLT) a `ausentismos` en el
  /// servidor central, sin esperar al ciclo de sincronización/autogeneración.
  ///
  /// Es un intento "mejor esfuerzo": si no hay conexión ahora, no falla nada —
  /// `autogenerarLltEnServidor()` la va a generar igual en la próxima
  /// sincronización, porque su `NOT EXISTS` evita duplicados.
  Future<void> registrarLltInmediato({
    required String cedula,
    required DateTime fechaHora,
    required String duracion,
    String? idDispositivo,
  }) async {
    try {
      final fechaStr = DateFormat('yyyy-MM-dd').format(fechaHora);
      final success = await _sqlServer.guardarAusentismoServidor(
        cedula: cedula,
        fecha: fechaStr,
        sigla: 'LLT',
        observacion: 'Retardo: $duracion',
        idDispositivo: idDispositivo,
      );
      print('[Sync] Registro inmediato de LLT para $cedula: $success');
    } catch (e) {
      print('[Sync] No se pudo registrar el LLT inmediato para $cedula (se generará en la próxima sincronización): $e');
    }
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

  static StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Monitorea la conexión de red y dispara la sincronización automática de asistencias cuando se reconecta
  void iniciarMonitoreoConexion() {
    if (_connectivitySubscription != null) {
      print('[Sync] El monitoreo de conectividad ya está activo.');
      return;
    }
    print('[Sync] Iniciando monitoreo de conectividad para sincronización automática...');
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final hasConnection = results.any((result) => result != ConnectivityResult.none);
      if (hasConnection) {
        print('[Sync] Conexión de red detectada: $results. Procesando marcaciones pendientes...');
        sincronizarAsistenciasPendientes().then((result) {
          print('[Sync] Sincronización automática tras reconexión completa: $result');
        }).catchError((e) {
          print('[Sync] Error al sincronizar automáticamente tras reconexión: $e');
        });
      } else {
        print('[Sync] Dispositivo sin conexión de red.');
      }
    });
  }
}
