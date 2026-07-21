# PROPUESTA TÉCNICA: Sistema de Asistencia por Reconocimiento Facial
## Aplicación Móvil para Control de Presencia de Colaboradores

---

## 1. RESUMEN EJECUTIVO

### 1.1 ¿Qué es?
Un sistema de control de asistencia que utiliza reconocimiento facial para marcar la entrada y salida de colaboradores. Funciona como una aplicación móvil instalada en tablets ubicadas en los puntos de acceso de la empresa.

### 1.2 ¿Por qué?
Los sistemas tradicionales de asistencia (huella dactilar, tarjetas RFID, ficheros manuales) presentan problemas como:
- **Huella dactilar**: sensores que fallan con suciedad, humedad o desgaste
- **Tarjetas RFID**: pérdidas, olvidos, préstamos entre compañeros ("fichaje fantasma")
- **Ficheros manuales**: lentos, propensos a errores, difíciles de auditar
- **Códigos PIN**: olvidos, compartidos, poco seguros

El reconocimiento facial ofrece una alternativa **sin contacto**, **difícil de falsificar** y **natural** para el usuario.

### 1.3 ¿Para quién?
Empresas con personal presencial que necesitan:
- Controlar horarios de entrada/salida
- Evitar el "fichaje fantasma" (un compañero marca por otro)
- Automatizar reportes de asistencia para RRHH
- Reducir filas en los puntos de marcado

---

## 2. PROBLEMA ACTUAL

### 2.1 Situación identificada
En muchas empresas, el control de asistencia es un proceso manual o semiautomatizado que genera:

| Problema | Impacto |
|----------|---------|
| Filas en el reloj checador | Pérdida de tiempo productivo (5-10 min/día por persona) |
| Fichaje por terceros | Pago de horas no trabajadas, falta de control |
| Tarjetas olvidadas | Interrupciones, necesidad de procesos manuales alternos |
| Reportes manuales | Errores, retrasos, dificultad para auditar |
| Hardware costoso | Relojes checadores, tarjetas, sensores de huella |

### 2.2 Caso de uso típico
> María llega a las 8:05 AM. Hay 15 personas en fila esperando marcar con huella dactilar. El sensor no lee bien porque hace calor y sus manos están sudadas. Intenta 3 veces. Finalmente marca a las 8:12 AM. Su jefe le reclama los 12 minutos de retraso. María está frustrada porque en realidad llegó a tiempo.

---

## 3. SOLUCIÓN PROPUESTA

### 3.1 Concepto
Una **tablet Android** instalada en la entrada de la empresa. El colaborador se acerca, mira a la cámara, y en menos de 1 segundo su asistencia queda registrada. Sin filas, sin contacto, sin tarjetas.

### 3.2 Flujo de usuario

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  Llegada    │────▶│  Acercarse   │────▶│  Mirar a    │
│  al trabajo │     │  a la tablet │     │  la cámara  │
└─────────────┘     └──────────────┘     └──────┬──────┘
                                                │
                                                ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  Confirmación│◀────│  Registro    │◀────│  Reconocimiento│
│  en pantalla │     │  en base de  │     │  facial      │
│  (verde/rojo)│     │  datos local │     │  (0.5 seg)   │
└─────────────┘     └──────────────┘     └─────────────┘
```

### 3.3 Ventajas clave

| Aspecto | Sistema tradicional | Sistema propuesto |
|---------|-------------------|-------------------|
| **Velocidad** | 5-15 segundos | 0.5-1 segundo |
| **Contacto** | Sí (huella, teclado) | No (sin contacto) |
| **Falsificación** | Fácil (prestar tarjeta/PIN) | Difícil (rostro único) |
| **Hardware extra** | Reloj checador, tarjetas | Solo tablet |
| **Mantenimiento** | Sensores, tinta, tarjetas | Actualizaciones de software |
| **Higiene** | Comparte superficies | Sin contacto (post-pandemia) |
| **Costo operativo** | Alto (consumibles, reparaciones) | Bajo (electricidad) |

---

## 4. ARQUITECTURA TÉCNICA

### 4.1 Principio fundamental: Edge Computing

Todo el procesamiento ocurre **dentro de la tablet**. No se envían fotos ni datos biométricos a internet. Esto garantiza:

- **Privacidad**: los rostros nunca salen del dispositivo
- **Velocidad**: sin latencia de red
- **Disponibilidad**: funciona sin internet
- **Cumplimiento**: facilita el cumplimiento de GDPR/LGPD

### 4.2 Componentes del sistema

```
┌─────────────────────────────────────────────────────────────┐
│                    TABLET ANDROID                           │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │   CÁMARA    │──│  DETECCIÓN   │──│  RECONOCIMIENTO  │  │
│  │   frontal   │  │  de rostro   │  │  facial (AI)     │  │
│  └─────────────┘  └──────────────┘  └──────────────────┘  │
│         │                  │                    │            │
│         ▼                  ▼                    ▼            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              BASE DE DATOS LOCAL (SQLite)            │  │
│  │  • Empleados enrolados                             │  │
│  │  • Vectores faciales (embeddings)                  │  │
│  │  • Registros de asistencia                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                           │                                │
│                           ▼                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              SINCRONIZACIÓN (opcional, WiFi)         │  │
│  │  • Subir registros a servidor central                │  │
│  │  • Descargar nuevos empleados                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 ¿Qué es un "embedding"?

No se almacenan fotos de los rostros. En su lugar, el sistema extrae un **vector numérico** de 192 números que representa de forma única las características faciales de cada persona. Es como una "huella digital matemática" del rostro.

**Analogía**: Si una foto es como una descripción completa de una persona ("alto, moreno, barba, lentes"), un embedding es como su número de identificación único: compacto, anónimo e irreversible.

### 4.4 Proceso de enrolamiento

Para que el sistema reconozca a un colaborador, primero debe "aprender" su rostro:

1. El colaborador se registra en el sistema (nombre, código, departamento)
2. La app le pide que mire a la cámara en **5 ángulos diferentes**:
   - De frente
   - Giro a la izquierda
   - Giro a la derecha
   - Mirando arriba
   - Sonriendo
3. Para cada ángulo, la app verifica automáticamente que el colaborador realmente giró la cabeza (usando detección de poses de ML Kit)
4. Cada foto se convierte en un embedding y se guarda localmente

**Resultado**: 5 vectores numéricos por colaborador, almacenados en la tablet.

---

## 5. FUNCIONALIDADES PRINCIPALES

### 5.1 Módulo de Enrolamiento
- Formulario de registro de colaborador
- Captura guiada de 5 poses faciales
- Validación automática de ángulos (anti-trampa)
- Detección de calidad de luz
- Almacenamiento local de embeddings

### 5.2 Módulo de Marcado de Asistencia
- Detección de rostro en tiempo real
- Comparación contra base de datos local
- Marcado en menos de 1 segundo
- Modo automático (detecta presencia sin botón)
- Feedback visual (verde = reconocido, rojo = no reconocido)
- Indicador de calidad de luz

### 5.3 Módulo de Reportes
- Visualización de registros por fecha
- Filtro por colaborador
- Exportación de datos (para sincronización con RRHH)
- Estadísticas de puntualidad

---

## 6. CONSIDERACIONES TÉCNICAS

### 6.1 Iluminación
El factor más crítico para el reconocimiento facial es la luz. El sistema incluye:

- **Detección automática** de sobreexposición, contraluz y oscuridad
- **Guía visual** para el usuario ("acércate a la luz", "gírate")
- **Recomendación de instalación**: tablet de espaldas a ventanas, con luz frontal difusa

### 6.2 Anti-spoofing básico
Para evitar que alguien marque con una foto:

- **Validación de poses**: el sistema exige movimiento real de cabeza durante el enrolamiento
- **Detección de vivacidad**: análisis de textura para detectar pantallas vs. rostro real
- **Opcional**: modo estricto que requiere parpadeo para marcar

### 6.3 Privacidad y seguridad

| Aspecto | Medida |
|---------|--------|
| Almacenamiento | Solo embeddings (números), nunca fotos |
| Transmisión | No hay transmisión de datos biométricos |
| Acceso físico | La tablet puede estar en modo quiosco (kiosk mode) |
| Respaldo | Opcional: cifrado de base de datos local |
| Eliminación | Borrado completo al desinstalar la app |

---

## 7. IMPLEMENTACIÓN SUGERIDA

### 7.1 Fases del proyecto

| Fase | Duración | Entregable |
|------|----------|------------|
| **Fase 1: Prototipo** | 2-3 semanas | App funcional con enrolamiento y marcado básico |
| **Fase 2: Prueba piloto** | 2 semanas | Despliegue en 1-2 sucursales con 10-20 usuarios |
| **Fase 3: Ajustes** | 1 semana | Calibración de umbral, ajuste de iluminación, feedback de usuarios |
| **Fase 4: Escalamiento** | 2-3 semanas | Despliegue masivo, dashboard web para RRHH, sincronización |

### 7.2 Hardware recomendado

| Componente | Especificación mínima | Recomendado |
|-----------|----------------------|-------------|
| Tablet | Android 8.0, 2GB RAM | Android 12+, 4GB RAM, cámara 8MP+ |
| Procesador | Snapdragon 400 | Snapdragon 600+ o equivalente |
| Almacenamiento | 16GB | 32GB+ |
| Conectividad | WiFi | WiFi + opcional 4G |
| Accesorios | — | Soporte de pared, visera anti-reflejo, luz LED difusa |

### 7.3 Costos estimados (por punto de marcado)

| Ítem | Costo aproximado |
|------|-----------------|
| Tablet gama media | $200 - $400 |
| Soporte y accesorios | $30 - $50 |
| Desarrollo (amortizado) | $50 - $100 |
| **Total inicial** | **$280 - $550** |
| Mantenimiento anual | $0 - $50 (solo electricidad) |

Comparación: un reloj checador biométrico tradicional cuesta $300-$800 + mantenimiento.

---

## 8. RIESGOS Y MITIGACIONES

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|-------------|---------|------------|
| Cambios de iluminación durante el día | Alta | Medio | Enrolar en diferentes condiciones de luz; usar luz LED constante |
| Colaboradores con cambios de look (barba, lentes, corte) | Media | Medio | Re-enrolamiento periódico; múltiples ángulos mejora robustez |
| Tablet dañada o robada | Baja | Alto | Modo quiosco; backups automáticos; cámara de seguridad |
| Falsificación con foto de alta calidad | Baja | Alto | Anti-spoofing por detección de vivacidad; ajuste de umbral estricto |
| Rechazo de usuarios por privacidad | Media | Bajo | Comunicación clara: no se almacenan fotos, solo números matemáticos |

---

## 9. BENEFICIOS ESPERADOS

### 9.1 Cuantificables
- **Reducción de tiempo de marcado**: de 5-10 minutos de fila diaria a segundos
- **Eliminación de fichaje fantasma**: ahorro en horas pagadas no trabajadas
- **Reducción de reclamos de RRHH**: registros automáticos, auditables, sin errores humanos
- **Ahorro en hardware**: una tablet reemplaza reloj checador + tarjetas + consumibles

### 9.2 Cualitativos
- **Experiencia de usuario moderna**: sin contacto, rápido, intuitivo
- **Imagen de empresa innovadora**: uso de tecnología de punta
- **Higiene**: sin superficies compartidas (relevante post-pandemia)
- **Escalabilidad**: fácil agregar nuevos puntos de marcado solo con tablets

---

## 10. PRÓXIMOS PASOS

1. **Aprobación de propuesta** por parte de dirección/RRHH
2. **Definición de alcance**: número de tablets, ubicaciones, número de colaboradores
3. **Prueba de concepto**: instalar 1 tablet en 1 ubicación con 5-10 voluntarios
4. **Recolección de métricas**: tiempo de marcado, tasa de reconocimiento, satisfacción de usuarios
5. **Decisión de escalamiento** basada en resultados de la prueba

---

## ANEXO: GLOSARIO

| Término | Definición simple |
|---------|-------------------|
| **Embedding** | Vector numérico (lista de números) que representa un rostro de forma única |
| **TFLite** | Formato de modelo de inteligencia artificial optimizado para dispositivos móviles |
| **ML Kit** | Kit de herramientas de Google para machine learning en dispositivos |
| **Edge Computing** | Procesamiento de datos dentro del dispositivo, sin enviar a la nube |
| **Cosine distance** | Medida de qué tan diferentes son dos embeddings (0 = iguales, 2 = opuestos) |
| **Umbral** | Valor límite que decide si dos embeddings pertenecen a la misma persona |
| **Anti-spoofing** | Técnicas para detectar si el rostro es real o una foto/pantalla |

---

*Documento preparado para presentación a stakeholders*
*Fecha: julio 2026*
