# Endurecimiento del reconocimiento facial

Cambios para eliminar los falsos positivos y hacer auditables los datos de asistencia.

## Antes de compilar

```bash
flutter pub get      # se añadió la dependencia crypto
flutter analyze
flutter run
```

La base de datos local sube a la **versión 16**. La migración es automática e incluye una
limpieza única de la galería biométrica: elimina vectores inválidos y re-normaliza los que
no eran unitarios. No hace falta borrar datos de la app.

---

## 1. Orientación, alineación y recorte

**Archivo:** `lib/services/face_detection_service.dart` (reescrito)

| Antes | Ahora |
|---|---|
| ML Kit leía la orientación EXIF, `img.decodeImage` no. Si la tablet guardaba las fotos rotadas, el bounding box apuntaba a otra región de la imagen. | Se endereza la imagen (`bakeOrientation`) y **el detector corre sobre la imagen ya enderezada**. Las coordenadas corresponden pixel a pixel con lo que se recorta. |
| Recorte rectangular del bounding box + `copyResize` a 112×112 → deformación de aspecto. | **Alineación por landmarks**: transformación de similitud (Procrustes 2D en forma cerrada) que lleva ojos, nariz y boca a la plantilla canónica ArcFace de 112×112, con muestreo bilineal. |
| `enableLandmarks: true` estaba activo pero nunca se usaba. | Se usan los 5 landmarks. El emparejamiento es **por posición en la imagen**, no por la etiqueta izquierda/derecha de ML Kit, así que funciona con o sin espejado de la cámara frontal. |
| El recorte pasaba por JPEG antes de entrar al modelo. | La imagen alineada va **en memoria** al modelo. Sin artefactos de compresión. |
| Sin control de nitidez ni de personas múltiples. | Se rechazan frames movidos (varianza del laplaciano) y frames con un segundo rostro de tamaño comparable. |

Si no hay landmarks suficientes se cae a un recorte **cuadrado** centrado, sin deformación.

## 2. Normalización y validación de embeddings

**Archivos:** `face_recognition_service.dart`, `database_service.dart`, `sync_service.dart`, `face_embedding.dart`

Este era el bug más grave. `cosineDistance` calcula `1 - dot(a,b)`, fórmula válida **solo con
vectores unitarios**. Los vectores descargados de SQL Server se guardaban sin normalizar; uno
con norma mayor que 1 gana todas las comparaciones y produce falsos positivos sistemáticos.

- `FaceRecognitionService.sanitize()` es ahora el punto único de verdad: valida dimensión
  (exactamente 192), descarta no finitos y vectores nulos, y normaliza L2.
- `saveEmbedding()` **rechaza** lo que no pase la validación en lugar de guardarlo.
- La sincronización ya no acepta vectores de 128 o 640 dimensiones "por compatibilidad":
  no son comparables con el modelo actual. Se descartan y se avisa en el log.
- El enrolamiento ya no rellena poses faltantes con `List.filled(192, 0.0)`. Ese relleno
  viajaba al servidor central y volvía a **todos** los tótems en la siguiente sincronización.
  Ahora un enrolamiento incompleto simplemente no se sube.
- La migración v16 limpia lo que ya estaba contaminado.

## 3. Decisión de identidad

**Archivos:** `face_recognition_service.dart`, `attendance_screen.dart`

Tres condiciones, todas obligatorias:

1. **Solo plantillas frontales.** Se compara contra `Frontal` y `Sonrisa`. Las poses de
   perfil (`Izquierda`, `Derecha`, `Arriba`) se siguen capturando para verificar que la
   persona es real, pero no se usan para identificar: son embeddings degradados que quedan
   cerca del promedio poblacional y generan coincidencias cruzadas.
2. **Test de margen.** No basta con que el mejor candidato esté cerca; el mejor candidato de
   *otra persona* tiene que estar al menos `margen` más lejos. Si dos personas compiten por
   el mismo rostro, se rechaza.
3. **Votación multi-frame.** La misma persona debe identificarse en 3 capturas independientes
   (configurable), cada una superando umbral y margen. Cualquier rechazo reinicia el contador.
   Los votos caducan a los 6 segundos.

La galería se construye una sola vez y se cachea 3 minutos, en vez de re-parsear todos los
vectores en cada frame.

## 4. Calibrador

**Archivos:** `lib/services/calibration_service.dart`, `lib/screens/calibration_screen.dart`
**Acceso:** Configuración del Tótem → Calibrar reconocimiento

Sustituye el slider de sensibilidad por una medición sobre la galería real:

- Compara **todas** las plantillas entre sí (en un isolate, no bloquea la UI).
- Reporta la distribución de impostores: mínima, percentiles 0.1% y 1%, media.
- Reporta la distribución genuina y **avisa de que es optimista**, porque se calcula entre
  plantillas enroladas y no entre capturas en vivo.
- Recomienda umbral y margen: si hay separación limpia los coloca en la brecha; si hay
  traslape prioriza cero falsos positivos.
- **Lista los pares de colaboradores más confundibles con nombre y cédula.** Si alguno sale
  con distancia muy baja, revisa que no sea la misma persona enrolada dos veces.
- Prueba en vivo: captura un rostro y muestra distancia, margen, nitidez, número de landmarks
  y si la cámara entrega la foto rotada.

**Ejecútalo después de cada tanda de enrolamientos.**

## 4b. Estado de enrolamiento — quién puede marcar y quién no

**Archivos:** `lib/screens/enrollment_status_screen.dart`, `DatabaseService.obtenerEstadoEnrolamiento()`
**Acceso:** Configuración → Estado de enrolamiento, o desde el calibrador tras la limpieza

Valida plantilla por plantilla con **el mismo criterio que usa el reconocimiento**, así que
lo que aparece como "Enrolado" es exactamente lo que el tótem puede identificar. Cinco estados:

| Estado | Significa | ¿Puede marcar por rostro? |
|---|---|---|
| **Enrolado** | 5 poses válidas, incluida frontal | Sí |
| **Incompleto** | Tiene frontal válida pero menos de 5 poses | Sí, pero el enrolamiento no se puede subir al servidor central |
| **Sin pose frontal** | Tiene plantillas válidas, ninguna frontal | **No** — el matching solo usa poses frontales |
| **Plantillas inválidas** | Todas se descartaron en la limpieza | **No** |
| **Sin enrolar** | Nunca se le capturó el rostro | **No** |

Incluye búsqueda por nombre o cédula, filtro por sección, **exportación a Excel** para que
RRHH trabaje la lista, y un botón por persona que abre el enrolamiento directamente.

La lista de colaboradores (`employee_list_screen`) ahora usa esta misma validación: antes
contaba filas crudas de `face_embeddings` y podía marcar como "enrolado" a alguien cuyas
plantillas estaban corruptas.

## 5. Integridad y auditoría

| Hueco | Estado |
|---|---|
| Marcación por cédula sin ninguna verificación | Exige clave de supervisor. Se registra como `metodo_registro='CEDULA'` con `autorizado_por` y `bypass_motivo`. |
| El diálogo de bypass se auto-confirmaba a los 5 segundos | Sin temporizador. La opción por defecto es cancelar; forzar exige clave de supervisor y queda auditado. |
| Contraseña `'admin2026'` escrita en el código, igual en todas las sedes | `SupervisorAuth`: SHA-256 con sal por dispositivo en `system_config`. Se siembra una vez con la clave anterior para no bloquear los tótems, y Configuración avisa en rojo mientras siga siendo la de fábrica. Corregido también en `special_schedule_screen.dart`. |
| Sin evidencia ante una disputa | Cada marcación facial guarda `margen`, `rival_employee_id` (contra quién compitió) y la foto del rostro alineado en `documentos/evidencias/`. |

Los campos nuevos son locales. `sincronizarAsistenciasPendientes` mapea columnas de forma
explícita, así que la subida a SQL Server sigue funcionando sin cambios en el servidor.

**Liveness quedó pendiente** por decisión tuya. Hoy una foto en la pantalla de un celular
todavía puede marcar. Los landmarks de ojos de ML Kit ya están disponibles para implementar
un reto de parpadeo cuando lo quieras.

---

## Puesta en marcha sugerida

1. `flutter pub get` y compilar.
2. Abrir Configuración → **cambiar la clave de supervisor**.
3. Configuración → Calibrar reconocimiento → **Ejecutar análisis**.
   - Revisar cuántas plantillas se eliminaron por inválidas.
   - Revisar los pares más confundibles.
4. Configuración → **Estado de enrolamiento**, filtro "Requieren acción". Exportar a Excel
   y pasarle la lista a RRHH.
5. **Prueba en vivo con 5 o 6 personas que conserven plantilla vieja.** Este paso decide el
   alcance del re-enrolamiento:
   - Si sus distancias genuinas quedan claramente bajo el umbral recomendado → basta con
     re-enrolar a los que salen en "Requieren acción".
   - Si salen justas o por encima → re-enrolar a todos. Las plantillas viejas se generaron
     con el pipeline anterior (sin alineación) y no son consistentes con lo que la cámara
     produce ahora.
6. Re-enrolar **de una sola tanda**. Una galería mitad vieja y mitad nueva mezcla dos
   representaciones incompatibles y la calibración deja de ser fiable.
7. Volver a calibrar y aplicar la recomendación.

> El calibrador compara plantillas contra plantillas, todas del mismo pipeline, así que
> **no detecta** el desajuste entre plantillas viejas y capturas nuevas. Eso solo lo revela
> la prueba en vivo. Por eso el paso 5 va antes de aplicar el umbral.

## Ajustes que puede que necesites

- **Nitidez mínima** (`minSharpness`, por defecto 5.0 en `face_detection_service.dart`): la
  escala depende de la cámara. Mira el valor real en la prueba en vivo. Si entran frames
  movidos, súbelo; si rechaza rostros buenos, bájalo.
- **Número de votos** (`recognition_votes`, por defecto 3): 3 votos añaden ~1,5 s al flujo.
  Bajar a 2 acelera pero reduce la protección.
- **Rendimiento**: ahora se codifica un JPEG por captura para enderezar la imagen. Si notas
  lentitud en tablets viejas, baja `ResolutionPreset.high` a `medium` en `camera_service.dart`
  y recalibra (el tamaño mínimo de rostro está en píxeles y cambia con la resolución).
