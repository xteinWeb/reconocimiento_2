import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_pkg;
import 'package:file_picker/file_picker.dart';
import '../services/database_service.dart';
import '../services/sql_server_service.dart';
import '../models/employee.dart';
import '../theme/app_colors.dart';

class AttendanceListScreen extends StatefulWidget {
  const AttendanceListScreen({super.key});

  @override
  State<AttendanceListScreen> createState() => _AttendanceListScreenState();
}

class _AttendanceListScreenState extends State<AttendanceListScreen> {
  final _database = DatabaseService();
  final _sqlServer = SqlServerService();

  List<Employee> _employees = [];
  Employee? _selectedEmployeeFilter;
  DateTimeRange _selectedDateRange = DateTimeRange(
    start: DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
    end: DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
  );
  bool _isLoading = false;
  String? _deviceId;

  // Catalog Plantas
  List<Map<String, String>> _availablePlants = [];
  List<String> _selectedPlantCodes = ['PL01', 'PL02', 'PL03', 'PL04', 'PL05', 'PL06'];

  // Filter Category Chip
  String _selectedFilterCategory = 'TODOS'; // 'TODOS', 'ASISTIERON', 'RETARDOS', 'SIN_MARCADOR'

  // Consolidado de evaluación del día por colaborador
  List<Map<String, dynamic>> _evaluatedRecords = [];

  // Stats
  int _totalEvaluados = 0;
  int _totalAsistieron = 0;
  int _totalRetardos = 0;
  int _totalSinMarcador = 0;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final employees = await _database.getAllEmployees();
    final deviceId = await _database.getDeviceId();
    final plants = await _sqlServer.obtenerPlantasDisponibles();

    setState(() {
      _employees = employees;
      _deviceId = deviceId;
      _availablePlants = plants;
      if (_selectedPlantCodes.isEmpty && plants.isNotEmpty) {
        _selectedPlantCodes = plants.map((p) => p['code']!).toList();
      }
    });
    await _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() => _isLoading = true);
    try {
      // 1. Filtrar empleados por planta y por filtro individual de colaborador
      List<Employee> targetEmployees = _employees;
      if (_selectedPlantCodes.isNotEmpty) {
        targetEmployees = targetEmployees.where((emp) {
          final pCode = emp.idUnItem?.trim() ?? '';
          if (pCode.isEmpty) return true;
          return _selectedPlantCodes.contains(pCode);
        }).toList();
      }

      if (_selectedEmployeeFilter != null) {
        targetEmployees = targetEmployees.where((e) => e.id == _selectedEmployeeFilter!.id).toList();
      }

      // 2. Consultar asistencias y ausencias locales para el rango seleccionado
      final rawAttendance = await _database.getAttendanceByDateRange(
        _selectedDateRange.start,
        _selectedDateRange.end,
      );
      final rawAbsences = await _database.getAbsencesByDateRange(
        _selectedDateRange.start,
        _selectedDateRange.end,
      );

      // Mapas por cédula
      final Map<String, List<Map<String, dynamic>>> marksByCode = {};
      for (final r in rawAttendance) {
        final code = r['employee_code']?.toString().trim();
        if (code != null && code.isNotEmpty) {
          marksByCode.putIfAbsent(code, () => []).add(r);
        }
      }

      final Map<String, List<Map<String, dynamic>>> absencesByCode = {};
      for (final a in rawAbsences) {
        final code = a['employee_code']?.toString().trim();
        if (code != null && code.isNotEmpty) {
          absencesByCode.putIfAbsent(code, () => []).add(a);
        }
      }

      // 3. Evaluar el estado de cada colaborador en la planta elegida
      final List<Map<String, dynamic>> evaluatedList = [];
      int asistieron = 0;
      int retardos = 0;
      int sinMarcador = 0;

      for (final emp in targetEmployees) {
        final code = emp.employeeCode.trim();
        final empMarks = marksByCode[code] ?? [];
        final empAbsences = absencesByCode[code] ?? [];

        String? horaEntrada;
        String? horaSalida;
        String? duracionRetardo;
        bool isRetardo = false;
        bool isAsistio = false;
        String? siglaAusencia;
        String? obsAusencia;

        if (empMarks.isNotEmpty) {
          isAsistio = true;
          for (final m in empMarks) {
            final evento = m['evento']?.toString() ?? 'ENTRADA';
            final tipo = m['tipo']?.toString() ?? 'NORMAL';
            final timestampStr = m['timestamp']?.toString() ?? '';
            final parsed = DateTime.tryParse(timestampStr);
            final timeFormatted = parsed != null ? DateFormat('hh:mm:ss a').format(parsed) : '';

            if (evento == 'ENTRADA') {
              horaEntrada = timeFormatted;
              if (tipo == 'RETARDO') {
                isRetardo = true;
                duracionRetardo = m['duracion']?.toString();
              }
            } else if (evento == 'SALIDA') {
              horaSalida = timeFormatted;
            }
          }
          if (isRetardo) {
            retardos++;
          } else {
            asistieron++;
          }
        } else if (empAbsences.isNotEmpty) {
          final abs = empAbsences.first;
          siglaAusencia = abs['sigla_ausencia']?.toString();
          obsAusencia = abs['observacion']?.toString() ?? abs['absence_name']?.toString();
          sinMarcador++;
        } else {
          // NO MARCÓ NADA
          sinMarcador++;
        }

        final plantName = SqlServerService.CATALOGO_PLANTAS[emp.idUnItem] ?? emp.idUnItem ?? 'SIN PLANTA';

        evaluatedList.add({
          'employee_id': emp.id,
          'employee_name': emp.name,
          'employee_code': emp.employeeCode,
          'employee_department': emp.department ?? 'S/D',
          'planta': plantName,
          'is_asistio': isAsistio,
          'is_retardo': isRetardo,
          'hora_entrada': horaEntrada,
          'hora_salida': horaSalida,
          'duracion_retardo': duracionRetardo,
          'sigla_ausencia': siglaAusencia,
          'obs_ausencia': obsAusencia,
        });
      }

      evaluatedList.sort((a, b) {
        final bool aNoMarco = a['is_asistio'] == false;
        final bool bNoMarco = b['is_asistio'] == false;
        if (aNoMarco && !bNoMarco) return -1;
        if (!aNoMarco && bNoMarco) return 1;
        return (a['employee_name'] as String).compareTo(b['employee_name'] as String);
      });

      setState(() {
        _evaluatedRecords = evaluatedList;
        _totalEvaluados = targetEmployees.length;
        _totalAsistieron = asistieron;
        _totalRetardos = retardos;
        _totalSinMarcador = sinMarcador;
      });
    } catch (e) {
      print('Error al evaluar marcaciones del tótem: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _openPlantSelectorDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: isDark ? AppColors.kioskSurface : Colors.white,
              title: Text('Seleccionar Plantas', style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary)),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () {
                            setDialogState(() {
                              _selectedPlantCodes = _availablePlants.map((p) => p['code']!).toList();
                            });
                          },
                          child: const Text('Todas', style: TextStyle(color: Colors.amber)),
                        ),
                        TextButton(
                          onPressed: () {
                            setDialogState(() {
                              _selectedPlantCodes.clear();
                            });
                          },
                          child: const Text('Ninguna', style: TextStyle(color: Colors.white70)),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _availablePlants.length,
                        itemBuilder: (context, i) {
                          final plant = _availablePlants[i];
                          final code = plant['code']!;
                          final name = plant['name']!;
                          final isSelected = _selectedPlantCodes.contains(code);

                          return CheckboxListTile(
                            activeColor: AppColors.primary,
                            title: Text(name, style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary, fontSize: 13)),
                            value: isSelected,
                            onChanged: (val) {
                              setDialogState(() {
                                if (val == true) {
                                  _selectedPlantCodes.add(code);
                                } else {
                                  _selectedPlantCodes.remove(code);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {});
                    _loadRecords();
                  },
                  child: const Text('Aplicar Filtro', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _selectedDateRange,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              surface: Color(0xFF2B3A24),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _selectedDateRange = picked;
      });
      await _loadRecords();
    }
  }

  excel_pkg.CellValue _toCellValue(dynamic val) {
    if (val == null) return excel_pkg.TextCellValue('');
    if (val is int) return excel_pkg.IntCellValue(val);
    if (val is double) return excel_pkg.DoubleCellValue(val);
    if (val is bool) return excel_pkg.BoolCellValue(val);
    if (val is DateTime) {
      return excel_pkg.DateTimeCellValue(
        year: val.year,
        month: val.month,
        day: val.day,
        hour: val.hour,
        minute: val.minute,
        second: val.second,
      );
    }
    return excel_pkg.TextCellValue(val.toString());
  }

  Future<void> _exportToExcel() async {
    if (_evaluatedRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay registros para exportar.'),
          backgroundColor: AppColors.primary,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final excel = excel_pkg.Excel.createExcel();
      final String sheetName = excel.getDefaultSheet() ?? 'Sheet1';
      final sheet = excel[sheetName];

      final headers = [
        'Planta / Sede',
        'Cédula',
        'Nombre Empleado',
        'Departamento',
        'Estado Asistencia',
        'Hora Entrada',
        'Hora Salida',
        'Minutos Retardo',
        'Novedad / Ausencia',
        'Observación'
      ];

      sheet.appendRow(headers.map(_toCellValue).toList());

      for (final r in _evaluatedRecords) {
        final isAsistio = r['is_asistio'] == true;
        final isRetardo = r['is_retardo'] == true;
        final sigla = r['sigla_ausencia'];

        final estadoText = isRetardo
            ? 'RETARDO'
            : (isAsistio ? 'ASISTIÓ' : (sigla != null ? 'NOVEDAD ($sigla)' : 'SIN MARCADOR'));

        sheet.appendRow([
          r['planta'],
          r['employee_code'],
          r['employee_name'],
          r['employee_department'],
          estadoText,
          r['hora_entrada'] ?? '',
          r['hora_salida'] ?? '',
          r['duracion_retardo'] ?? '',
          r['sigla_ausencia'] ?? '',
          r['obs_ausencia'] ?? ''
        ].map(_toCellValue).toList());
      }

      final fileBytes = excel.encode();
      if (fileBytes == null) {
        throw Exception('No se pudo generar el archivo Excel.');
      }

      final startStr = DateFormat('yyyyMMdd').format(_selectedDateRange.start);
      final defaultFileName = 'Reporte_Asistencia_Plantas_$startStr.xlsx';

      final String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar Reporte de Asistencia por Planta',
        fileName: defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: Uint8List.fromList(fileBytes),
      );

      setState(() => _isLoading = false);

      if (outputFile != null) {
        final file = File(outputFile);
        if (!await file.exists()) {
          await file.writeAsBytes(fileBytes);
        }

        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF2B3A24),
              title: const Text('Exportación Exitosa', style: TextStyle(color: Colors.white)),
              content: Text(
                'El reporte de plantas se guardó correctamente en:\n\n$outputFile',
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Entendido', style: TextStyle(color: Colors.amber)),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al exportar: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  List<Map<String, dynamic>> get _filteredDisplayRecords {
    return _evaluatedRecords.where((r) {
      final isAsistio = r['is_asistio'] == true;
      final isRetardo = r['is_retardo'] == true;

      if (_selectedFilterCategory == 'ASISTIERON') return isAsistio && !isRetardo;
      if (_selectedFilterCategory == 'RETARDOS') return isRetardo;
      if (_selectedFilterCategory == 'SIN_MARCADOR') return !isAsistio;
      return true; // TODOS
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final startFormatted = DateFormat('dd/MM/yyyy').format(_selectedDateRange.start);
    final endFormatted = DateFormat('dd/MM/yyyy').format(_selectedDateRange.end);
    final displayList = _filteredDisplayRecords;

    return Scaffold(
      backgroundColor: isDark ? AppColors.kioskBackground : AppColors.background,
      appBar: AppBar(
        title: const Text('Asistencia y Marcaciones por Planta'),
        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_rounded, color: AppColors.primary),
            tooltip: 'Exportar Excel',
            onPressed: _exportToExcel,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Bar de Filtros
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Card(
              color: isDark ? AppColors.kioskSurface : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: isDark ? Colors.white10 : AppColors.border, width: 1),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _pickDateRange,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? Colors.white12 : AppColors.border.withOpacity(0.5),
                        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.calendar_today_rounded, size: 16, color: AppColors.primary),
                      label: Text(
                        startFormatted == endFormatted ? startFormatted : '$startFormatted - $endFormatted',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openPlantSelectorDialog,
                        style: OutlinedButton.styleFrom(side: BorderSide(color: isDark ? Colors.white24 : AppColors.border)),
                        icon: const Icon(Icons.factory_rounded, size: 16, color: Colors.amber),
                        label: Text(
                          _selectedPlantCodes.isEmpty ? 'Ninguna Planta' : '${_selectedPlantCodes.length} Plantas',
                          style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary, fontSize: 11, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Chips de Filtro por Categoría
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('Todos ($_totalEvaluados)'),
                  selected: _selectedFilterCategory == 'TODOS',
                  selectedColor: AppColors.primary,
                  labelStyle: TextStyle(color: _selectedFilterCategory == 'TODOS' ? Colors.white : (isDark ? Colors.white70 : Colors.black87), fontSize: 11, fontWeight: FontWeight.bold),
                  onSelected: (val) => setState(() => _selectedFilterCategory = 'TODOS'),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text('Asistieron ($_totalAsistieron)'),
                  selected: _selectedFilterCategory == 'ASISTIERON',
                  selectedColor: Colors.teal,
                  labelStyle: TextStyle(color: _selectedFilterCategory == 'ASISTIERON' ? Colors.white : (isDark ? Colors.white70 : Colors.black87), fontSize: 11, fontWeight: FontWeight.bold),
                  onSelected: (val) => setState(() => _selectedFilterCategory = 'ASISTIERON'),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text('Sin Marcador / Faltas ($_totalSinMarcador)'),
                  selected: _selectedFilterCategory == 'SIN_MARCADOR',
                  selectedColor: Colors.redAccent,
                  labelStyle: TextStyle(color: _selectedFilterCategory == 'SIN_MARCADOR' ? Colors.white : (isDark ? Colors.white70 : Colors.black87), fontSize: 11, fontWeight: FontWeight.bold),
                  onSelected: (val) => setState(() => _selectedFilterCategory = 'SIN_MARCADOR'),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text('Retardos ($_totalRetardos)'),
                  selected: _selectedFilterCategory == 'RETARDOS',
                  selectedColor: Colors.amber.shade800,
                  labelStyle: TextStyle(color: _selectedFilterCategory == 'RETARDOS' ? Colors.white : (isDark ? Colors.white70 : Colors.black87), fontSize: 11, fontWeight: FontWeight.bold),
                  onSelected: (val) => setState(() => _selectedFilterCategory = 'RETARDOS'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Lista de Colaboradores Evaluados
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : displayList.isEmpty
                    ? Center(
                        child: Text(
                          'No hay colaboradores para mostrar con el filtro seleccionado.',
                          style: TextStyle(
                            color: isDark ? Colors.white38 : AppColors.textSecondary,
                            fontSize: 15,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        itemCount: displayList.length,
                        itemBuilder: (context, index) {
                          final r = displayList[index];
                          final isAsistio = r['is_asistio'] == true;
                          final isRetardo = r['is_retardo'] == true;
                          final sigla = r['sigla_ausencia'];
                          final hEntrada = r['hora_entrada'];
                          final hSalida = r['hora_salida'];
                          final obs = r['obs_ausencia'];

                          final bool sinMarcador = !isAsistio && sigla == null;
                          final bool conNovedad = !isAsistio && sigla != null;

                          final Color cardBorderColor = sinMarcador
                              ? Colors.redAccent.withOpacity(0.8)
                              : (conNovedad
                                  ? Colors.purpleAccent.withOpacity(0.7)
                                  : (isRetardo
                                      ? Colors.amber.withOpacity(0.8)
                                      : Colors.teal.withOpacity(0.6)));

                          final Color badgeBg = sinMarcador
                              ? Colors.redAccent
                              : (conNovedad
                                  ? Colors.purple
                                  : (isRetardo
                                      ? Colors.amber.shade800
                                      : Colors.teal));

                          final String badgeText = sinMarcador
                              ? 'SIN MARCADOR (FALTA)'
                              : (conNovedad
                                  ? 'NOVEDAD: $sigla'
                                  : (isRetardo ? 'RETARDO' : 'ASISTIÓ'));

                          return Card(
                            color: isDark ? AppColors.kioskSurface : Colors.white,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: cardBorderColor, width: 1.5),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: badgeBg.withOpacity(0.2),
                                child: Icon(
                                  sinMarcador
                                      ? Icons.person_off_rounded
                                      : (conNovedad
                                          ? Icons.event_busy_rounded
                                          : (isRetardo
                                              ? Icons.timer_rounded
                                              : Icons.check_circle_rounded)),
                                  color: badgeBg,
                                ),
                              ),
                              title: Text(
                                '${r['employee_name']} (${r['employee_code']})',
                                style: TextStyle(
                                  color: isDark ? Colors.white : AppColors.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 2),
                                  Text(
                                    'Planta: ${r['planta']} • Depto: ${r['employee_department']}',
                                    style: TextStyle(
                                      color: isDark ? Colors.white54 : AppColors.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(
                                        isAsistio ? Icons.access_time_rounded : Icons.info_outline,
                                        size: 13,
                                        color: isDark ? Colors.white70 : Colors.black87,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          isAsistio
                                              ? 'Entrada: ${hEntrada ?? "--:--"}  •  Salida: ${hSalida ?? "--:--"}'
                                              : (conNovedad
                                                  ? 'Novedad: $obs'
                                                  : 'Sin marcaciones registradas hoy'),
                                          style: TextStyle(
                                            color: isDark ? Colors.white : Colors.black87,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: badgeBg,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  badgeText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
