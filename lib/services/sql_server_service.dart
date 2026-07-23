import 'dart:convert';
import 'package:sql_conn/sql_conn.dart';

class SqlServerService {
  final String connectionId = 'mainDB';
  final String ip = '190.85.54.78';
  final int port = 9788;
  final String dbname = 'ARTDECOM';
  final String username = 'sa';
  final String password = 'sql2025DEVadmin';

  bool _isConnected = false;

  Future<bool> connect() async {
    try {
      if (_isConnected) {
        return true;
      }
      print('[SqlServer] Conectando a $ip:$port/$dbname...');
      final success = await SqlConn.connect(
        connectionId: connectionId,
        host: ip,
        port: port,
        database: dbname,
        username: username,
        password: password,
      );
      _isConnected = success;
      return _isConnected;
    } catch (e) {
      print('[SqlServer] ERROR al conectar: $e');
      _isConnected = false;
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      if (_isConnected) {
        await SqlConn.disconnect(connectionId);
        _isConnected = false;
      }
    } catch (e) {
      print('[SqlServer] ERROR al desconectar: $e');
    }
  }

  /// Ejecuta el flujo completo de sincronización directa
  Future<List<Map<String, dynamic>>> obtenerYActualizarEmpleados() async {
    final connected = await connect();
    if (!connected) {
      throw Exception('No se pudo conectar al servidor SQL Server.');
    }

    try {
      // 1. Sincronizar estados inactivos desde 'empleados' (ERP) a 'empleados_asistencia'
      print('[SqlServer] Ejecutando sincronización de Inactivos...');
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.estado = 'INACTIVO'
        FROM empleados_asistencia ea
        INNER JOIN empleados emp ON ea.cedula = emp.ID_EMPLEADO
        WHERE emp.ESTADO = 'INACTIVO' AND ea.estado <> 'INACTIVO'
      """);

      // 2. Sincronizar estados activos desde 'empleados' (ERP) a 'empleados_asistencia'
      print('[SqlServer] Ejecutando sincronización de Activos...');
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.estado = 'ACTIVO'
        FROM empleados_asistencia ea
        INNER JOIN empleados emp ON ea.cedula = emp.ID_EMPLEADO
        WHERE emp.ESTADO = 'ACTIVO' AND ea.estado <> 'ACTIVO'
      """);

      // 3. Insertar nuevos empleados activos en 'empleados_asistencia'
      print('[SqlServer] Insertando nuevos empleados...');
      await SqlConn.write(connectionId, """
        INSERT INTO empleados_asistencia (cedula, nombre, estado, fecha_creacion)
        SELECT 
            emp.ID_EMPLEADO,
            LTRIM(RTRIM(
                COALESCE(il.NOMBRE, '') + ' ' + 
                COALESCE(il.NOMBRE2, '') + ' ' + 
                COALESCE(il.APELLIDO, '') + ' ' + 
                COALESCE(il.APELLIDO2, '')
            )),
            'ACTIVO',
            GETDATE()
        FROM empleados emp
        INNER JOIN IDENTIFICACIONES_LEGALES il ON emp.ID_LEGAL = il.ID_LEGAL
        WHERE COALESCE(emp.ESTADO, 'ACTIVO') = 'ACTIVO'
          AND emp.ID_EMPLEADO NOT IN (SELECT cedula FROM empleados_asistencia)
      """);

      // 4. Obtener la lista unificada de empleados con horarios de ITM_EMPLEADOS_TURNOS
      print('[SqlServer] Obteniendo lista unificada de empleados...');
      final results = await SqlConn.read(connectionId, """
        SELECT 
            COALESCE(LTRIM(RTRIM(emp.ID_EMPLEADO)), LTRIM(RTRIM(ea.cedula))) AS cedula,
            COALESCE(
                LTRIM(RTRIM(
                    COALESCE(il.NOMBRE, '') + ' ' + 
                    COALESCE(il.NOMBRE2, '') + ' ' + 
                    COALESCE(il.APELLIDO, '') + ' ' + 
                    COALESCE(il.APELLIDO2, '')
                )), 
                ea.nombre, 
                ''
            ) AS nombre,
            CAST(SUBSTRING(ea.mapa_vector_foto, 1, 8000) AS VARCHAR(8000)) AS vec_part1,
            CAST(SUBSTRING(ea.mapa_vector_foto, 8001, 8000) AS VARCHAR(8000)) AS vec_part2,
            CAST(SUBSTRING(ea.mapa_vector_foto, 16001, 8000) AS VARCHAR(8000)) AS vec_part3,
            COALESCE(turn.ID_HORARIO, ea.horario_id, '') AS horario_id,
            COALESCE(ea.fecha_ini_contrato, '0') AS fecha_ini_contrato,
            COALESCE(ea.fecha_fin_contrato, '0') AS fecha_fin_contrato,
            COALESCE(emp.ESTADO, ea.estado, 'ACTIVO') AS estado,
            COALESCE(ea.sede_principal, emp.ID_UN_ITEM, '') AS sede_principal,
            ies.ID_SECCION AS id_seccion,
            COALESCE(ea.tipo, ies.ID_ACTIVIDAD, '') AS tipo,
            ea.fecha_creacion AS fecha_registro
        FROM empleados emp
        FULL OUTER JOIN empleados_asistencia ea ON LTRIM(RTRIM(emp.ID_EMPLEADO)) = LTRIM(RTRIM(ea.cedula))
        LEFT JOIN IDENTIFICACIONES_LEGALES il ON (emp.ID_LEGAL = il.ID_LEGAL OR TRY_CAST(COALESCE(emp.ID_EMPLEADO, ea.cedula) AS FLOAT) = il.ID_LEGAL)
        LEFT JOIN empleados_secciones es ON COALESCE(LTRIM(RTRIM(emp.ID_EMPLEADO)), LTRIM(RTRIM(ea.cedula))) = LTRIM(RTRIM(es.ID_EMPLEADO)) AND COALESCE(emp.ID_UN, ea.sede_principal, '00') = es.ID_UN
        LEFT JOIN (
            SELECT LTRIM(RTRIM(ID_EMPLEADO)) AS ID_EMPLEADO, ID_UN, MAX(ID_SECCION) AS ID_SECCION, MAX(ID_ACTIVIDAD) AS ID_ACTIVIDAD
            FROM itm_empleados_Secciones
            WHERE TIPO = 'PRINCIPAL'
            GROUP BY LTRIM(RTRIM(ID_EMPLEADO)), ID_UN
        ) ies ON COALESCE(LTRIM(RTRIM(emp.ID_EMPLEADO)), LTRIM(RTRIM(ea.cedula))) = ies.ID_EMPLEADO AND COALESCE(emp.ID_UN, '00') = ies.ID_UN
        LEFT JOIN (
            SELECT t.ID_EMPLEADO, MAX(t.ID_HORARIO) AS ID_HORARIO
            FROM ITM_EMPLEADOS_TURNOS t
            INNER JOIN (
                SELECT ID_EMPLEADO, MAX(FECHA) AS MAX_FECHA
                FROM ITM_EMPLEADOS_TURNOS
                WHERE ESTADO = 'ACTIVO'
                GROUP BY ID_EMPLEADO
            ) latest ON t.ID_EMPLEADO = latest.ID_EMPLEADO AND t.FECHA = latest.MAX_FECHA
            GROUP BY t.ID_EMPLEADO
        ) turn ON COALESCE(LTRIM(RTRIM(emp.ID_EMPLEADO)), LTRIM(RTRIM(ea.cedula))) = turn.ID_EMPLEADO
        WHERE COALESCE(emp.ESTADO, ea.estado, 'ACTIVO') = 'ACTIVO'
      """);

      return results;
    } finally {
      await disconnect();
    }
  }

  /// Guarda o actualiza los datos del enrolamiento de un empleado de vuelta en SQL Server
  Future<bool> actualizarVectorEmpleado({
    required String cedula,
    required List<double> vector,
    String? nombre,
    String? horarioId,
    String? fechaIniContrato,
    String? fechaFinContrato,
    String? sedePrincipal,
    String? idSeccion,
    String? tipo,
  }) async {
    final connected = await connect();
    if (!connected) return false;

    try {
      final vectorStr = jsonEncode(vector);

      final query =
          """
        MERGE empleados_asistencia AS target
        USING (SELECT '$cedula' AS cedula) AS source
        ON (LTRIM(RTRIM(target.cedula)) = LTRIM(RTRIM(source.cedula)))
        WHEN MATCHED THEN
            UPDATE SET 
                nombre = ${nombre != null ? "'$nombre'" : 'target.nombre'},
                mapa_vector_foto = '$vectorStr',
                horario_id = ${horarioId != null ? "'$horarioId'" : 'target.horario_id'},
                fecha_ini_contrato = ${fechaIniContrato != null ? "'$fechaIniContrato'" : 'target.fecha_ini_contrato'},
                fecha_fin_contrato = ${fechaFinContrato != null ? "'$fechaFinContrato'" : 'target.fecha_fin_contrato'},
                estado = 'ACTIVO',
                sede_principal = ${sedePrincipal != null ? "'$sedePrincipal'" : 'target.sede_principal'},
                id_seccion = ${idSeccion != null ? "'$idSeccion'" : 'target.id_seccion'},
                tipo = ${tipo != null ? "'$tipo'" : 'target.tipo'}
        WHEN NOT MATCHED THEN
            INSERT (cedula, nombre, mapa_vector_foto, horario_id, fecha_ini_contrato, fecha_fin_contrato, estado, sede_principal, id_seccion, tipo, fecha_creacion)
            VALUES (
              '$cedula', 
              ${nombre != null ? "'$nombre'" : "'Nuevo Empleado'"}, 
              '$vectorStr', 
              ${horarioId != null ? "'$horarioId'" : 'NULL'}, 
              ${fechaIniContrato != null ? "'$fechaIniContrato'" : 'NULL'}, 
              ${fechaFinContrato != null ? "'$fechaFinContrato'" : 'NULL'}, 
              'ACTIVO', 
              ${sedePrincipal != null ? "'$sedePrincipal'" : 'NULL'}, 
              ${idSeccion != null ? "'$idSeccion'" : 'NULL'}, 
              ${tipo != null ? "'$tipo'" : 'NULL'}, 
              GETDATE()
            );
      """;

      await SqlConn.write(connectionId, query);
      return true;
    } catch (e) {
      print('[SqlServer] ERROR al actualizar vector: $e');
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Registra una marcación de asistencia en el servidor SQL Server central
  Future<bool> guardarAsistenciaServidor({
    required String cedula,
    required DateTime fechaHora,
    String evento = 'ENTRADA',
    double duracion = 0.0,
    String tipo = 'NORMAL',
    String unidadNegocio = '',
    String metodoRegistro = 'FACIAL',
  }) async {
    final connected = await connect();
    if (!connected) return false;

    try {
      final fechaHoraStr = fechaHora
          .toIso8601String()
          .replaceFirst('T', ' ')
          .substring(0, 19);
      final query =
          """
        INSERT INTO registros_asistencia (
          fecha_hora, 
          cedula, 
          evento, 
          duracion, 
          tipo, 
          unidad_negocio, 
          fecha_registro_servidor, 
          metodo_registro
        )
        VALUES (
          '$fechaHoraStr', 
          '$cedula', 
          '$evento', 
          $duracion, 
          '$tipo', 
          '$unidadNegocio', 
          GETDATE(), 
          '$metodoRegistro'
        );
      """;

      await SqlConn.write(connectionId, query);
      return true;
    } catch (e) {
      print('[SqlServer] ERROR al guardar asistencia en servidor: $e');
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Obtiene los detalles de los horarios (turnos) desde SQL Server central
  Future<List<Map<String, dynamic>>> obtenerHorariosServidor() async {
    final connected = await connect();
    if (!connected) {
      throw Exception('No se pudo conectar al servidor SQL Server.');
    }

    try {
      print('[SqlServer] Obteniendo detalles de itm_horarios...');
      final results = await SqlConn.read(connectionId, """
        SELECT 
            LTRIM(RTRIM(ID_HORARIO)) AS id_horario,
            CONVERT(VARCHAR(5), MIN(INICIO), 108) AS hora_inicio,
            CONVERT(VARCHAR(5), MAX(FINAL), 108) AS hora_final,
            'PRODUCTIVA' AS tipo,
            STUFF(
              (CASE WHEN MAX(CAST(LUNES AS INT)) = 1 THEN ',L' ELSE '' END) +
              (CASE WHEN MAX(CAST(MARTES AS INT)) = 1 THEN ',M' ELSE '' END) +
              (CASE WHEN MAX(CAST(MIERCOLES AS INT)) = 1 THEN ',Mi' ELSE '' END) +
              (CASE WHEN MAX(CAST(JUEVES AS INT)) = 1 THEN ',J' ELSE '' END) +
              (CASE WHEN MAX(CAST(VIERNES AS INT)) = 1 THEN ',V' ELSE '' END) +
              (CASE WHEN MAX(CAST(SABADO AS INT)) = 1 THEN ',S' ELSE '' END) +
              (CASE WHEN MAX(CAST(DOMINGO AS INT)) = 1 THEN ',D' ELSE '' END),
              1, 1, ''
            ) AS dias
        FROM itm_horarios
        WHERE ID_HORARIO IS NOT NULL AND INICIO IS NOT NULL AND FINAL IS NOT NULL AND TIPO = 'PRODUCTIVA'
        GROUP BY ID_HORARIO
      """);
      return results;
    } finally {
      await disconnect();
    }
  }
}
