# Documentación de Tablas de SQL Server — BioAttendance 2.0

Este documento contiene la especificación completa y detallada de todas las tablas de **SQL Server** utilizadas por el sistema de control biométrico de asistencia y gestión de personal **BioAttendance 2.0**.

---

## 🟢 1. Tablas Gestionadas por la Aplicación de Asistencia

Estas tablas son administradas o creadas por la aplicación para el registro biométrico, marcas físicas, ausentismos y programación especial.

---

### 1.1 `registros_asistencia`
Almacena cada evento de marcación física (*Entrada o Salida*) capturado en las tablets/tótems mediante reconocimiento facial o cédula.

| Columna | Tipo de Dato | Nulidad | Descripción |
| :--- | :--- | :---: | :--- |
| `id` | `VARCHAR(36)` | NOT NULL | Identificador único (UUID generado por la app `NEWID()`). |
| `fecha_hora` | `DATETIME` | NOT NULL | Fecha y hora exacta de la marcación. |
| `cedula` | `VARCHAR(50)` | NOT NULL | Cédula o código del empleado. |
| `evento` | `VARCHAR(20)` | NOT NULL | Evento de marcación: `ENTRADA` o `SALIDA`. |
| `duracion` | `FLOAT` | NULL | Minutos de retardo (en caso de `tipo = 'RETARDO'`). |
| `tipo` | `VARCHAR(50)` | NOT NULL | Tipo de marca: `NORMAL`, `RETARDO`, `SALIDA_TEMPRANA`, `NO_PROGRAMADO`. |
| `unidad_negocio` | `VARCHAR(50)` | NULL | Identificador de la sede o unidad de negocio (`ID_UN`). |
| `metodo_registro`| `VARCHAR(20)` | NULL | Método de marcación: `FACIAL` o `CEDULA`. |
| `id_dispositivo` | `VARCHAR(100)`| NULL | Identificador del tótem/dispositivo que capturó la marca (ej: `Galapa`). |
| `fecha_registro_servidor` | `DATETIME` | NULL | Fecha y hora en la que el registro se insertó en el servidor SQL Server. |

---

### 1.2 `empleados_asistencia`
Maestro corporativo de enrolamiento biométrico. Almacena el vector facial de 960 dimensiones (JSON), los datos del colaborador y su estado.

| Columna | Tipo de Dato | Nulidad | Descripción |
| :--- | :--- | :---: | :--- |
| `cedula` | `VARCHAR(50)` | NOT NULL | Cédula del colaborador (Llave Primaria / Única). |
| `nombre` | `VARCHAR(200)`| NULL | Nombre completo del colaborador. |
| `mapa_vector_foto` | `VARCHAR(MAX)` | NULL | Vector numérico bio-facial de 960 posiciones en formato JSON string. |
| `estado` | `VARCHAR(20)` | NULL | Estado del empleado: `ACTIVO` o `INACTIVO`. |
| `horario_id` | `VARCHAR(50)` | NULL | Código del horario predeterminado asignado. |
| `id_seccion` | `VARCHAR(50)` | NULL | Código de la sección o área laboral (ej: `ID0101` o `ADMINISTRATIVO`). |
| `nombre_seccion` | `VARCHAR(200)`| NULL | Nombre descriptivo del departamento (ej: `INNOVACIÓN Y DESARROLLO`). |
| `sede_principal` | `VARCHAR(50)` | NULL | Sede o unidad de negocio asignada (`ID_UN`). |
| `id_un_item` | `VARCHAR(50)` | NULL | Identificador de la planta a la que pertenece el colaborador (`secciones.ID_UN_ITEM`). |
| `tipo` | `VARCHAR(50)` | NULL | Tipo de actividad o cargo. |
| `fecha_ini_contrato` | `VARCHAR(20)` | NULL | Fecha inicio de contrato. |
| `fecha_fin_contrato` | `VARCHAR(20)` | NULL | Fecha fin de contrato. |
| `id_empresa` | `VARCHAR(50)` | NULL | Código de empresa del grupo. |
| `fecha_creacion` | `DATETIME` | NULL | Fecha de registro del enrolamiento en el servidor. |

---

### 1.3 `ausentismos`
Tabla unificada de novedades de personal, ausencias, justificantes y tardanzas.

| Columna | Tipo de Dato | Nulidad | Descripción |
| :--- | :--- | :---: | :--- |
| `id` | `VARCHAR(36)` | NOT NULL | Identificador único (UUID `NEWID()`). |
| `cedula_empleado` | `VARCHAR(50)` | NOT NULL | Cédula del colaborador. |
| `fecha` | `VARCHAR(10)` | NOT NULL | Fecha de la novedad en formato `YYYY-MM-DD`. |
| `sigla_ausencia` | `VARCHAR(10)` | NOT NULL | Código de la novedad: `SC` (Sin checado/Falta), `LLT` (Llegada tarde), `V` (Vacaciones), `I` (Incapacidad), `P` (Permiso), `F` (Falta injustificada). |
| `observacion` | `NVARCHAR(255)` | NULL | Descripción u observación detallada de la novedad. |
| `id_dispositivo` | `VARCHAR(100)`| NULL | Identificador del dispositivo que registró la novedad. |
| `fecha_registro_servidor` | `DATETIME` | NULL | Timestamp de registro en el servidor. |

---

### 1.4 `programaciones_especiales`
Guarda las asignaciones de horarios especiales/turnos temporales creados por administradores para colaboradores específicos en fechas concretas.

| Columna | Tipo de Dato | Nulidad | Descripción |
| :--- | :--- | :---: | :--- |
| `id` | `INT IDENTITY` | NOT NULL | ID autoincremental (Llave Primaria). |
| `cedula` | `VARCHAR(50)` | NOT NULL | Cédula del colaborador. |
| `fecha` | `VARCHAR(10)` | NOT NULL | Fecha del turno especial (`YYYY-MM-DD`). |
| `hora_inicio` | `VARCHAR(10)` | NULL | Hora inicio personalizada (ej: `07:00`). Si es NULL, usa su horario habitual. |
| `hora_final` | `VARCHAR(10)` | NULL | Hora fin personalizada (ej: `17:00`). |
| `observacion` | `NVARCHAR(255)` | NULL | Nota sobre la programación especial. |
| `id_dispositivo` | `VARCHAR(100)`| NULL | Dispositivo desde donde se programó. |
| `fecha_creacion` | `DATETIME` | NULL | Timestamp de creación. |

> **Restricción Unívoca**: `CONSTRAINT UQ_cedula_fecha UNIQUE (cedula, fecha)` evita duplicados de programación para la misma persona en el mismo día.

---

### 1.5 `dispositivos_autorizados`
Catálogo de tótems o tablets autorizados para operar en la organización.

| Columna | Tipo de Dato | Nulidad | Descripción |
| :--- | :--- | :---: | :--- |
| `id_dispositivo` | `VARCHAR(100)`| NOT NULL | Nombre/ID del dispositivo (Llave Primaria, ej: `Galapa`, `rebolo`). |
| `descripcion` | `VARCHAR(200)`| NULL | Descripción de la ubicación o sede. |
| `en_uso` | `INT` | NULL | Estado del dispositivo (1 = En uso, 0 = Disponible). |

---

### 1.6 `estado_totems`
Registro de latidos (*heartbeat*) y última sincronización reportada por cada tablet.

| Columna | Tipo de Dato | Nulidad | Descripción |
| :--- | :--- | :---: | :--- |
| `id_dispositivo` | `VARCHAR(100)`| NOT NULL | ID del dispositivo (Llave Primaria). |
| `ultima_sincronizacion` | `DATETIME` | NOT NULL | Fecha y hora del último reporte de actividad. |

---

## 🔵 2. Tablas del ERP Corporativo (Consultadas por la App)

Tablas existentes en el ERP empresarial que la aplicación lee en modo lectura o sincronización.

---

### 2.1 `empleados`
* **Descripción**: Maestro de empleados del ERP.
* **Campos clave consultados**: `ID_EMPLEADO`, `ID_LEGAL`, `ESTADO` (`ACTIVO`/`INACTIVO`), `ID_EMPRESA`, `ID_UN`, `ID_UN_ITEM`.

### 2.2 `IDENTIFICACIONES_LEGALES`
* **Descripción**: Almacena nombres legales de personas.
* **Campos clave consultados**: `ID_LEGAL`, `NOMBRE`, `NOMBRE2`, `APELLIDO`, `APELLIDO2`.

### 2.3 `itm_empleados_Secciones` & `empleados_secciones`
* **Descripción**: Relación de empleados con su área o sección laboral.
* **Campos clave consultados**: `ID_EMPLEADO`, `ID_UN`, `ID_SECCION`, `ID_ACTIVIDAD`, `TIPO` (`PRINCIPAL`).

### 2.4 `secciones`
* **Descripción**: Catálogo de departamentos y áreas de la compañía.
* **Campos clave consultados**: `ID_SECCION`, `ID_UN`, `DESCRIPCION` (ej: `INNOVACIÓN Y DESARROLLO`), `ID_UN_ITEM` (*Define la planta/sede a la que pertenece la sección y el trabajador*).

### 2.5 `ITM_EMPLEADOS_TURNOS`
* **Descripción**: Asignaciones de horarios/turnos habituales por empleado.
* **Campos clave consultados**: `ID_EMPLEADO`, `ID_HORARIO`, `FECHA`, `ESTADO`.

### 2.6 `itm_horarios`
* **Descripción**: Plantillas de horarios (*días y franjas horarias*).
* **Campos clave consultados**: `ID_HORARIO`, `INICIO`, `FINAL`, `TIPO`, `LUNES`, `MARTES`, `MIERCOLES`, `JUEVES`, `VIERNES`, `SABADO`, `DOMINGO`.

### 2.7 `ITM_DOMINIOS`
* **Descripción**: Tabla de dominios de configuración del ERP.
* **Campos clave consultados**: `VALOR1` (sigla), `VALOR2` (nombre) filtrando por `ID_DOMINIO = 'AUSENCIAS'`.
