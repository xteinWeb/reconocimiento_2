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
      // 0. Asegurar existencia de la columna 'nombre_seccion' en 'empleados_asistencia'
      await SqlConn.write(connectionId, """
        IF NOT EXISTS (
            SELECT * FROM INFORMATION_SCHEMA.COLUMNS 
            WHERE TABLE_NAME = 'empleados_asistencia' AND COLUMN_NAME = 'nombre_seccion'
        )
        BEGIN
          ALTER TABLE empleados_asistencia ADD nombre_seccion VARCHAR(200) NULL;
        END
      """);

      // 1. Sincronizar estados inactivos desde 'empleados' (ERP) a 'empleados_asistencia'
      print('[SqlServer] Ejecutando sincronización de Inactivos...');
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.estado = 'INACTIVO', ea.id_empresa = emp.ID_EMPRESA
        FROM empleados_asistencia ea
        INNER JOIN empleados emp ON LTRIM(RTRIM(ea.cedula)) = LTRIM(RTRIM(emp.ID_EMPLEADO))
        WHERE emp.ESTADO = 'INACTIVO' AND (ea.estado <> 'INACTIVO' OR ea.id_empresa IS NULL OR ea.id_empresa <> emp.ID_EMPRESA)
      """);

      // 2. Sincronizar estados activos desde 'empleados' (ERP) a 'empleados_asistencia'
      print('[SqlServer] Ejecutando sincronización de Activos...');
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.estado = 'ACTIVO', ea.id_empresa = emp.ID_EMPRESA
        FROM empleados_asistencia ea
        INNER JOIN empleados emp ON LTRIM(RTRIM(ea.cedula)) = LTRIM(RTRIM(emp.ID_EMPLEADO))
        WHERE emp.ESTADO = 'ACTIVO' AND (ea.estado <> 'ACTIVO' OR ea.id_empresa IS NULL OR ea.id_empresa <> emp.ID_EMPRESA)
      """);

      // También actualizamos la empresa en empleados activos que ya existen por si acaso cambió
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.id_empresa = emp.ID_EMPRESA
        FROM empleados_asistencia ea
        INNER JOIN empleados emp ON LTRIM(RTRIM(ea.cedula)) = LTRIM(RTRIM(emp.ID_EMPLEADO))
        WHERE ea.id_empresa IS NULL OR ea.id_empresa <> emp.ID_EMPRESA
      """);

      // Actualizar 'id_seccion', 'sede_principal' y 'tipo' en 'empleados_asistencia' desde ERP
      print('[SqlServer] Actualizando id_seccion, sede_principal y tipo en empleados_asistencia...');
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET 
            ea.id_seccion = ies.ID_SECCION,
            ea.sede_principal = COALESCE(emp.ID_UN_ITEM, ea.sede_principal),
            ea.tipo = COALESCE(ies.ID_ACTIVIDAD, ea.tipo)
        FROM empleados_asistencia ea
        INNER JOIN empleados emp ON LTRIM(RTRIM(ea.cedula)) = LTRIM(RTRIM(emp.ID_EMPLEADO))
        LEFT JOIN (
            SELECT LTRIM(RTRIM(ID_EMPLEADO)) AS ID_EMPLEADO, ID_UN, MAX(ID_SECCION) AS ID_SECCION, MAX(ID_ACTIVIDAD) AS ID_ACTIVIDAD
            FROM itm_empleados_Secciones
            WHERE TIPO = 'PRINCIPAL'
            GROUP BY LTRIM(RTRIM(ID_EMPLEADO)), ID_UN
        ) ies ON LTRIM(RTRIM(ea.cedula)) = ies.ID_EMPLEADO AND COALESCE(emp.ID_UN, '00') = ies.ID_UN
        WHERE (ea.id_seccion IS NULL OR ea.id_seccion <> ies.ID_SECCION
            OR ea.sede_principal IS NULL OR ea.sede_principal <> emp.ID_UN_ITEM
            OR ea.tipo IS NULL OR ea.tipo <> ies.ID_ACTIVIDAD)
      """);

      // Actualizar 'nombre_seccion' en 'empleados_asistencia' cruzando con la tabla 'secciones'
      print('[SqlServer] Actualizando nombres de secciones...');
      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.nombre_seccion = LTRIM(RTRIM(sec.DESCRIPCION))
        FROM empleados_asistencia ea
        INNER JOIN (
            SELECT LTRIM(RTRIM(ID_EMPLEADO)) AS ID_EMPLEADO, ID_UN, MAX(ID_SECCION) AS ID_SECCION
            FROM itm_empleados_Secciones
            WHERE TIPO = 'PRINCIPAL'
            GROUP BY LTRIM(RTRIM(ID_EMPLEADO)), ID_UN
        ) ies ON LTRIM(RTRIM(ea.cedula)) = ies.ID_EMPLEADO
        INNER JOIN secciones sec ON LTRIM(RTRIM(ies.ID_SECCION)) = LTRIM(RTRIM(sec.ID_SECCION)) AND (sec.ID_UN = ies.ID_UN OR sec.ID_UN = '00')
        WHERE ea.nombre_seccion IS NULL OR ea.nombre_seccion <> LTRIM(RTRIM(sec.DESCRIPCION))
      """);

      await SqlConn.write(connectionId, """
        UPDATE ea
        SET ea.nombre_seccion = LTRIM(RTRIM(sec.DESCRIPCION))
        FROM empleados_asistencia ea
        INNER JOIN secciones sec ON LTRIM(RTRIM(ea.id_seccion)) = LTRIM(RTRIM(sec.ID_SECCION)) AND (sec.ID_UN = ea.sede_principal OR sec.ID_UN = '00')
        WHERE (ea.nombre_seccion IS NULL OR ea.nombre_seccion <> LTRIM(RTRIM(sec.DESCRIPCION))) AND ea.id_seccion IS NOT NULL
      """);

      // Llenar con 'ADMINISTRATIVO' los registros con id_seccion o nombre_seccion nulos o vacíos
      print('[SqlServer] Asignando ADMINISTRATIVO a secciones nulas...');
      await SqlConn.write(connectionId, """
        UPDATE empleados_asistencia
        SET 
            id_seccion = COALESCE(NULLIF(LTRIM(RTRIM(id_seccion)), ''), 'ADMINISTRATIVO'),
            nombre_seccion = COALESCE(NULLIF(LTRIM(RTRIM(nombre_seccion)), ''), 'ADMINISTRATIVO')
        WHERE id_seccion IS NULL OR LTRIM(RTRIM(id_seccion)) = ''
           OR nombre_seccion IS NULL OR LTRIM(RTRIM(nombre_seccion)) = ''
      """);

      // 3. Insertar nuevos empleados activos en 'empleados_asistencia'
      print('[SqlServer] Insertando nuevos empleados...');
      await SqlConn.write(connectionId, """
        INSERT INTO empleados_asistencia (cedula, nombre, estado, fecha_creacion, id_empresa, id_seccion, nombre_seccion, sede_principal, tipo)
        SELECT 
            emp.ID_EMPLEADO,
            LTRIM(RTRIM(
                COALESCE(il.NOMBRE, '') + ' ' + 
                COALESCE(il.NOMBRE2, '') + ' ' + 
                COALESCE(il.APELLIDO, '') + ' ' + 
                COALESCE(il.APELLIDO2, '')
            )),
            'ACTIVO',
            GETDATE(),
            emp.ID_EMPRESA,
            COALESCE(NULLIF(LTRIM(RTRIM(ies.ID_SECCION)), ''), 'ADMINISTRATIVO'),
            COALESCE(NULLIF(LTRIM(RTRIM(sec.DESCRIPCION)), ''), 'ADMINISTRATIVO'),
            emp.ID_UN_ITEM,
            ies.ID_ACTIVIDAD
        FROM empleados emp
        INNER JOIN IDENTIFICACIONES_LEGALES il ON emp.ID_LEGAL = il.ID_LEGAL
        LEFT JOIN (
            SELECT LTRIM(RTRIM(ID_EMPLEADO)) AS ID_EMPLEADO, ID_UN, MAX(ID_SECCION) AS ID_SECCION, MAX(ID_ACTIVIDAD) AS ID_ACTIVIDAD
            FROM itm_empleados_Secciones
            WHERE TIPO = 'PRINCIPAL'
            GROUP BY LTRIM(RTRIM(ID_EMPLEADO)), ID_UN
        ) ies ON LTRIM(RTRIM(emp.ID_EMPLEADO)) = ies.ID_EMPLEADO AND COALESCE(emp.ID_UN, '00') = ies.ID_UN
        LEFT JOIN secciones sec ON LTRIM(RTRIM(ies.ID_SECCION)) = LTRIM(RTRIM(sec.ID_SECCION)) AND (sec.ID_UN = ies.ID_UN OR sec.ID_UN = '00')
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
            COALESCE(NULLIF(LTRIM(RTRIM(ies.ID_SECCION)), ''), NULLIF(LTRIM(RTRIM(ea.id_seccion)), ''), 'ADMINISTRATIVO') AS id_seccion,
            COALESCE(NULLIF(LTRIM(RTRIM(sec.DESCRIPCION)), ''), NULLIF(LTRIM(RTRIM(ea.nombre_seccion)), ''), 'ADMINISTRATIVO') AS nombre_seccion,
            COALESCE(ea.tipo, ies.ID_ACTIVIDAD, '') AS tipo,
            ea.fecha_creacion AS fecha_registro,
            COALESCE(emp.ID_EMPRESA, ea.id_empresa, '') AS id_empresa
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
        LEFT JOIN secciones sec ON LTRIM(RTRIM(ies.ID_SECCION)) = LTRIM(RTRIM(sec.ID_SECCION)) AND (sec.ID_UN = ies.ID_UN OR sec.ID_UN = '00')
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
    String? idDispositivo,
  }) async {
    final connected = await connect();
    if (!connected) return false;

    try {
      final fechaHoraStr = fechaHora
          .toIso8601String()
          .replaceFirst('T', ' ')
          .substring(0, 19);

      final safeCedula = cedula.replaceAll("'", "''");
      final safeEvento = evento.replaceAll("'", "''");
      final safeTipo = tipo.replaceAll("'", "''");
      final safeUnidadNegocio = unidadNegocio.replaceAll("'", "''");
      final safeMetodoRegistro = metodoRegistro.replaceAll("'", "''");
      final safeIdDispositivo = idDispositivo != null ? "'${idDispositivo.replaceAll("'", "''")}'" : "NULL";

      final query =
          """
        INSERT INTO registros_asistencia (
          id,
          fecha_hora, 
          cedula, 
          evento, 
          duracion, 
          tipo, 
          unidad_negocio, 
          fecha_registro_servidor, 
          metodo_registro,
          id_dispositivo
        )
        VALUES (
          CAST(NEWID() AS VARCHAR(36)),
          '$fechaHoraStr', 
          '$safeCedula', 
          '$safeEvento', 
          $duracion, 
          '$safeTipo', 
          '$safeUnidadNegocio', 
          GETDATE(), 
          '$safeMetodoRegistro',
          $safeIdDispositivo
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

  /// Obtiene las asistencias del servidor (últimos 30 días por defecto)
  Future<List<Map<String, dynamic>>> obtenerAsistenciasServidor({int daysLimit = 30}) async {
    final connected = await connect();
    if (!connected) {
      throw Exception('No se pudo conectar al servidor SQL Server.');
    }

    try {
      print('[SqlServer] Obteniendo registros de asistencia...');
      final results = await SqlConn.read(connectionId, """
        SELECT 
            id,
            fecha_hora,
            cedula,
            evento,
            duracion,
            tipo,
            unidad_negocio,
            metodo_registro
        FROM registros_asistencia
        WHERE fecha_hora >= DATEADD(day, -$daysLimit, GETDATE())
        ORDER BY fecha_hora DESC
      """);
      return results;
    } finally {
      await disconnect();
    }
  }

  /// Obtiene los tipos de ausencia / novedades desde la tabla ITM_DOMINIOS
  Future<List<Map<String, dynamic>>> obtenerTiposAusenciaServidor() async {
    final connected = await connect();
    if (!connected) {
      throw Exception('No se pudo conectar al servidor SQL Server.');
    }

    try {
      print('[SqlServer] Obteniendo tipos de ausencia...');
      final results = await SqlConn.read(connectionId, """
        SELECT 
            VALOR1 AS sigla, 
            VALOR2 AS nombre 
        FROM ITM_DOMINIOS 
        WHERE ID_DOMINIO = 'AUSENCIAS' 
        ORDER BY VALOR2 ASC
      """);
      return results;
    } finally {
      await disconnect();
    }
  }

  /// Guarda una novedad de ausentismo en la tabla ausentismos del servidor
  Future<bool> guardarAusentismoServidor({
    required String cedula,
    required String fecha,
    required String sigla,
    String? observacion,
    String? idDispositivo,
  }) async {
    final connected = await connect();
    if (!connected) {
      return false;
    }

    try {
      print('[SqlServer] Registrando ausentismo para $cedula ($fecha - $sigla)...');
      final safeIdDispositivo = idDispositivo != null ? "'${idDispositivo.replaceAll("'", "''")}'" : "NULL";
      final query = """
        INSERT INTO ausentismos (
          id, 
          cedula_empleado, 
          fecha, 
          sigla_ausencia, 
          observacion, 
          fecha_registro_servidor,
          id_dispositivo
        )
        VALUES (
          CAST(NEWID() AS VARCHAR(36)),
          '${cedula.replaceAll("'", "''")}',
          '${fecha.replaceAll("'", "''")}',
          '${sigla.replaceAll("'", "''")}',
          ${observacion != null ? "'${observacion.replaceAll("'", "''")}'" : "NULL"},
          GETDATE(),
          $safeIdDispositivo
        )
      """;
      await SqlConn.write(connectionId, query);
      return true;
    } catch (e) {
      print('[SqlServer] Error al guardar ausentismo en el servidor: $e');
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Genera novedades de tipo LLT (Llegada Tarde) en el servidor central
  Future<void> autogenerarLltEnServidor() async {
    final connected = await connect();
    if (!connected) return;

    try {
      print('[SqlServer] Autogenerando novedades de LLT...');
      const query = """
        INSERT INTO ausentismos (id, cedula_empleado, fecha, sigla_ausencia, observacion, fecha_registro_servidor)
        SELECT 
            CAST(NEWID() AS VARCHAR(36)),
            ra.cedula,
            CONVERT(VARCHAR(10), ra.fecha_hora, 120),
            'LLT',
            'Retardo: ' + CAST(ra.duracion AS VARCHAR(20)) + ' min',
            GETDATE()
        FROM registros_asistencia ra
        WHERE ra.evento = 'ENTRADA' 
          AND ra.tipo = 'RETARDO'
          AND NOT EXISTS (
              SELECT 1 
              FROM ausentismos a 
              WHERE a.cedula_empleado = ra.cedula 
                AND a.fecha = CONVERT(VARCHAR(10), ra.fecha_hora, 120)
                AND a.sigla_ausencia = 'LLT'
          )
      """;
      await SqlConn.write(connectionId, query);
    } catch (e) {
      print('[SqlServer] Error al autogenerar LLT en el servidor: $e');
    } finally {
      await disconnect();
    }
  }

  /// Genera novedades de tipo SC (Sin Justa Causa) en el servidor central para una fecha dada
  Future<void> autogenerarScEnServidor(String fecha) async {
    final connected = await connect();
    if (!connected) return;

    try {
      print('[SqlServer] Autogenerando ausentismos SC para la fecha $fecha...');
      final query = """
        INSERT INTO ausentismos (id, cedula_empleado, fecha, sigla_ausencia, observacion, fecha_registro_servidor)
        SELECT 
            CAST(NEWID() AS VARCHAR(36)),
            ea.cedula,
            '$fecha',
            'SC',
            'Falta sin justa causa',
            GETDATE()
        FROM empleados_asistencia ea
        WHERE ea.estado = 'ACTIVO'
          AND NOT EXISTS (
              SELECT 1 
              FROM registros_asistencia ra 
              WHERE ra.cedula = ea.cedula 
                AND ra.evento = 'ENTRADA' 
                AND CONVERT(VARCHAR(10), ra.fecha_hora, 120) = '$fecha'
          )
          AND NOT EXISTS (
              SELECT 1 
              FROM ausentismos a 
              WHERE a.cedula_empleado = ea.cedula 
                AND a.fecha = '$fecha'
          )
      """;
      await SqlConn.write(connectionId, query);
    } catch (e) {
      print('[SqlServer] Error al autogenerar SC en el servidor: $e');
    } finally {
      await disconnect();
    }
  }

  /// Asegura que existan las tablas de control de dispositivos en SQL Server
  Future<void> asegurarTablasDispositivosEnServidor() async {
    final connected = await connect();
    if (!connected) return;

    try {
      print('[SqlServer] Asegurando tablas de control de tótems...');
      
      // Tabla de dispositivos autorizados
      await SqlConn.write(connectionId, """
        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='dispositivos_autorizados' AND xtype='U')
        BEGIN
          CREATE TABLE dispositivos_autorizados (
              id_dispositivo VARCHAR(100) PRIMARY KEY,
              descripcion VARCHAR(200),
              en_uso INT DEFAULT 0
          );
        END
      """);

      // Insertar los dispositivos autorizados si no están ya en la tabla
      await SqlConn.write(connectionId, """
        IF EXISTS (SELECT * FROM sysobjects WHERE name='dispositivos_autorizados' AND xtype='U')
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM dispositivos_autorizados WHERE id_dispositivo = 'Galapa')
            INSERT INTO dispositivos_autorizados (id_dispositivo, descripcion, en_uso) VALUES ('Galapa', 'Sede Galapa', 0);
          IF NOT EXISTS (SELECT 1 FROM dispositivos_autorizados WHERE id_dispositivo = 'rebolo')
            INSERT INTO dispositivos_autorizados (id_dispositivo, descripcion, en_uso) VALUES ('rebolo', 'Sede Rebolo', 0);
          IF NOT EXISTS (SELECT 1 FROM dispositivos_autorizados WHERE id_dispositivo = 'calle28')
            INSERT INTO dispositivos_autorizados (id_dispositivo, descripcion, en_uso) VALUES ('calle28', 'Sede Calle 28', 0);
          IF NOT EXISTS (SELECT 1 FROM dispositivos_autorizados WHERE id_dispositivo = 'calle39')
            INSERT INTO dispositivos_autorizados (id_dispositivo, descripcion, en_uso) VALUES ('calle39', 'Sede Calle 39', 0);
        END
      """);

      // Tabla de latidos/actividad
      await SqlConn.write(connectionId, """
        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='estado_totems' AND xtype='U')
        CREATE TABLE estado_totems (
            id_dispositivo VARCHAR(100) PRIMARY KEY,
            ultima_sincronizacion DATETIME NOT NULL
        )
      """);
    } catch (e) {
      print('[SqlServer] Error al asegurar tablas de tótems en el servidor: $e');
    } finally {
      await disconnect();
    }
  }

  /// Obtiene los tótems autorizados en el servidor
  Future<List<Map<String, dynamic>>> obtenerDispositivosDisponibles() async {
    final connected = await connect();
    if (!connected) return [];

    try {
      print('[SqlServer] Consultando dispositivos autorizados...');
      final results = await SqlConn.read(connectionId, "SELECT id_dispositivo, descripcion, en_uso FROM dispositivos_autorizados ORDER BY id_dispositivo ASC");
      return results;
    } catch (e) {
      print('[SqlServer] Error al consultar dispositivos autorizados: $e');
      return [];
    } finally {
      await disconnect();
    }
  }

  /// Registra el uso de un dispositivo y libera el anterior en el servidor central
  Future<bool> registrarUsoDispositivo(String idDispositivo, String? idAnterior) async {
    final connected = await connect();
    if (!connected) return false;

    try {
      print('[SqlServer] Registrando uso para $idDispositivo (Anterior: $idAnterior)...');
      
      // Liberar el anterior si aplica
      if (idAnterior != null && idAnterior.isNotEmpty && idAnterior != idDispositivo) {
        await SqlConn.write(connectionId, "UPDATE dispositivos_autorizados SET en_uso = 0 WHERE id_dispositivo = '${idAnterior.replaceAll("'", "''")}'");
      }

      // Marcar el nuevo en uso
      await SqlConn.write(connectionId, "UPDATE dispositivos_autorizados SET en_uso = 1 WHERE id_dispositivo = '${idDispositivo.replaceAll("'", "''")}'");

      // Registrar latido/sincronización inicial en estado_totems
      final safeId = idDispositivo.replaceAll("'", "''");
      await SqlConn.write(connectionId, """
        MERGE estado_totems AS target
        USING (SELECT '$safeId' AS id_dispositivo) AS source
        ON (target.id_dispositivo = source.id_dispositivo)
        WHEN MATCHED THEN
            UPDATE SET ultima_sincronizacion = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (id_dispositivo, ultima_sincronizacion)
            VALUES (source.id_dispositivo, GETDATE());
      """);

      return true;
    } catch (e) {
      print('[SqlServer] Error al registrar uso de dispositivo: $e');
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Reporta el latido/sincronización de este dispositivo al servidor central
  Future<void> reportarSincronizacionTotem(String idDispositivo) async {
    final connected = await connect();
    if (!connected) return;

    try {
      final safeId = idDispositivo.replaceAll("'", "''");
      await SqlConn.write(connectionId, """
        MERGE estado_totems AS target
        USING (SELECT '$safeId' AS id_dispositivo) AS source
        ON (target.id_dispositivo = source.id_dispositivo)
        WHEN MATCHED THEN
            UPDATE SET ultima_sincronizacion = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (id_dispositivo, ultima_sincronizacion)
            VALUES (source.id_dispositivo, GETDATE());
      """);
      print('[SqlServer] Sincronización del dispositivo $idDispositivo reportada con éxito.');
    } catch (e) {
      print('[SqlServer] Error al reportar sincronización del dispositivo: $e');
    } finally {
      await disconnect();
    }
  }

  /// Valida si todos los tótems activos en las últimas 24 horas ya sincronizaron hoy después de las 4:00 PM
  Future<bool> validarSincronizacionTotalHoy() async {
    final connected = await connect();
    if (!connected) return false;

    try {
      print('[SqlServer] Validando estado de sincronización de todos los tótems activos...');
      final results = await SqlConn.read(connectionId, """
        SELECT COUNT(*) as pendientes
        FROM estado_totems
        WHERE ultima_sincronizacion >= DATEADD(day, -1, GETDATE()) -- Activos en últimas 24h
          AND (
            -- Sincronizaron hoy antes de las 16:00
            ultima_sincronizacion < DATEADD(hour, 16, CAST(CONVERT(VARCHAR(10), GETDATE(), 120) AS DATETIME))
            -- O bien, no han sincronizado hoy en lo absoluto
            OR CONVERT(VARCHAR(10), ultima_sincronizacion, 120) < CONVERT(VARCHAR(10), GETDATE(), 120)
          )
      """);

      if (results.isNotEmpty) {
        final val = results.first['pendientes'] ?? results.first['PENDIENTES'];
        final int pendientes = int.tryParse(val.toString()) ?? 0;
        if (pendientes > 0) {
          print('[SqlServer] Validación de sincronización fallida: Hay $pendientes tótems activos pendientes por reportar datos.');
          return false;
        }
      }
      print('[SqlServer] Validación de sincronización exitosa: Todos los tótems activos están al día.');
      return true;
    } catch (e) {
      print('[SqlServer] Error al validar sincronización total de tótems: $e');
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Asegura la existencia de la tabla programaciones_especiales en el servidor central
  Future<void> asegurarTablaProgramacionesEspeciales() async {
    final connected = await connect();
    if (!connected) return;

    try {
      await SqlConn.write(connectionId, """
        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='programaciones_especiales' AND xtype='U')
        BEGIN
          CREATE TABLE programaciones_especiales (
              id INT IDENTITY(1,1) PRIMARY KEY,
              cedula VARCHAR(50) NOT NULL,
              fecha VARCHAR(10) NOT NULL,
              hora_inicio VARCHAR(10) NULL,
              hora_final VARCHAR(10) NULL,
              observacion NVARCHAR(255) NULL,
              id_dispositivo VARCHAR(100) NULL,
              fecha_creacion DATETIME DEFAULT GETDATE(),
              CONSTRAINT UQ_cedula_fecha UNIQUE (cedula, fecha)
          );
        END
      """);
    } catch (e) {
      print('[SqlServer] Error al asegurar tabla programaciones_especiales: $e');
    } finally {
      await disconnect();
    }
  }

  /// Sube o actualiza una programación especial en SQL Server
  Future<bool> guardarProgramacionEspecialServidor({
    required String cedula,
    required String fecha,
    String? horaInicio,
    String? horaFinal,
    String? observacion,
    String? dispositivoId,
  }) async {
    final connected = await connect();
    if (!connected) return false;

    try {
      await asegurarTablaProgramacionesEspeciales();
      await connect();

      final hInicioVal = horaInicio != null && horaInicio.isNotEmpty ? "'$horaInicio'" : "NULL";
      final hFinalVal = horaFinal != null && horaFinal.isNotEmpty ? "'$horaFinal'" : "NULL";
      final obsVal = observacion != null && observacion.isNotEmpty ? "N'${observacion.replaceAll("'", "''")}'" : "NULL";
      final devVal = dispositivoId != null && dispositivoId.isNotEmpty ? "'$dispositivoId'" : "NULL";

      await SqlConn.write(connectionId, """
        MERGE programaciones_especiales AS target
        USING (SELECT '$cedula' AS cedula, '$fecha' AS fecha) AS source
        ON (target.cedula = source.cedula AND target.fecha = source.fecha)
        WHEN MATCHED THEN
            UPDATE SET hora_inicio = $hInicioVal,
                       hora_final = $hFinalVal,
                       observacion = $obsVal,
                       id_dispositivo = $devVal
        WHEN NOT MATCHED THEN
            INSERT (cedula, fecha, hora_inicio, hora_final, observacion, id_dispositivo)
            VALUES ('$cedula', '$fecha', $hInicioVal, $hFinalVal, $obsVal, $devVal);
      """);
      return true;
    } catch (e) {
      print('[SqlServer] Error al guardar programación especial en el servidor: $e');
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Sube o actualiza múltiples programaciones especiales en SQL Server en una sola consulta MERGE en lote
  Future<bool> guardarProgramacionesEspecialesLoteServidor(
    List<Map<String, dynamic>> items,
  ) async {
    if (items.isEmpty) return true;

    final connected = await connect();
    if (!connected) return false;

    try {
      await asegurarTablaProgramacionesEspeciales();
      await connect();

      final valueRows = items.map((p) {
        final cedula = p['cedula']?.toString() ?? '';
        final fecha = p['fecha']?.toString() ?? '';
        final hStart = p['horaInicio']?.toString();
        final hEnd = p['horaFinal']?.toString();
        final obs = p['observacion']?.toString();
        final devId = p['dispositivoId']?.toString();

        final hInicioVal = hStart != null && hStart.isNotEmpty ? "'$hStart'" : "NULL";
        final hFinalVal = hEnd != null && hEnd.isNotEmpty ? "'$hEnd'" : "NULL";
        final obsVal = obs != null && obs.isNotEmpty ? "N'${obs.replaceAll("'", "''")}'" : "NULL";
        final devVal = devId != null && devId.isNotEmpty ? "'$devId'" : "NULL";

        return "('$cedula', '$fecha', $hInicioVal, $hFinalVal, $obsVal, $devVal)";
      }).join(',\n');

      await SqlConn.write(connectionId, """
        MERGE programaciones_especiales AS target
        USING (VALUES
          $valueRows
        ) AS source (cedula, fecha, hora_inicio, hora_final, observacion, id_dispositivo)
        ON (target.cedula = source.cedula AND target.fecha = source.fecha)
        WHEN MATCHED THEN
            UPDATE SET hora_inicio = source.hora_inicio,
                       hora_final = source.hora_final,
                       observacion = source.observacion,
                       id_dispositivo = source.id_dispositivo
        WHEN NOT MATCHED THEN
            INSERT (cedula, fecha, hora_inicio, hora_final, observacion, id_dispositivo)
            VALUES (source.cedula, source.fecha, source.hora_inicio, source.hora_final, source.observacion, source.id_dispositivo);
      """);
      print('[SqlServer] Guardadas ${items.length} programaciones especiales en lote en el servidor.');
      return true;
    } catch (e) {
      print('[SqlServer] Error al guardar programaciones especiales en lote: $e');
      _isConnected = false;
      return false;
    } finally {
      await disconnect();
    }
  }

  /// Descarga programaciones especiales desde SQL Server
  Future<List<Map<String, dynamic>>> obtenerProgramacionesEspecialesServidor() async {
    final connected = await connect();
    if (!connected) return [];

    try {
      await asegurarTablaProgramacionesEspeciales();
      await connect();

      final results = await SqlConn.read(connectionId, """
        SELECT 
          LTRIM(RTRIM(cedula)) AS cedula,
          CONVERT(VARCHAR(10), fecha, 120) AS date,
          hora_inicio,
          hora_final,
          observacion
        FROM programaciones_especiales
        WHERE fecha >= CONVERT(VARCHAR(10), DATEADD(day, -7, GETDATE()), 120)
      """);

      final List<Map<String, dynamic>> output = [];
      for (final rawRow in results) {
        final row = Map<String, dynamic>.from(rawRow);
        output.add({
          'cedula': row['cedula']?.toString().trim(),
          'date': row['date']?.toString().trim(),
          'hora_inicio': row['hora_inicio']?.toString().trim(),
          'hora_final': row['hora_final']?.toString().trim(),
          'observacion': row['observacion']?.toString().trim(),
        });
      }
      return output;
    } catch (e) {
      print('[SqlServer] Error al obtener programaciones especiales del servidor: $e');
      return [];
    } finally {
      await disconnect();
    }
  }

  /// Elimina una o varias programaciones especiales en SQL Server en una sola consulta
  Future<bool> eliminarProgramacionesEspecialesServidor(
    List<Map<String, String>> items,
  ) async {
    if (items.isEmpty) return true;

    final connected = await connect();
    if (!connected) return false;

    try {
      final whereClauses = items.map((item) {
        final cedula = item['cedula'] ?? '';
        final fecha = item['fecha'] ?? '';
        return "(LTRIM(RTRIM(cedula)) = LTRIM(RTRIM('$cedula')) AND fecha = '$fecha')";
      }).join(' OR ');

      await SqlConn.write(connectionId, """
        DELETE FROM programaciones_especiales
        WHERE $whereClauses
      """);
      print('[SqlServer] Eliminadas ${items.length} programaciones especiales en el servidor.');
      return true;
    } catch (e) {
      print('[SqlServer] Error al eliminar programaciones especiales en el servidor: $e');
      _isConnected = false;
      return false;
    } finally {
      await disconnect();
    }
  }
}
