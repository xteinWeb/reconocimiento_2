import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../services/database_service.dart';
import '../models/employee.dart';
import '../theme/app_colors.dart';

class AttendanceListScreen extends StatefulWidget {
  const AttendanceListScreen({super.key});

  @override
  State<AttendanceListScreen> createState() => _AttendanceListScreenState();
}

class _AttendanceListScreenState extends State<AttendanceListScreen> {
  final _database = DatabaseService();
  List<Map<String, dynamic>> _records = [];
  List<Employee> _employees = [];
  Employee? _selectedEmployeeFilter;
  DateTimeRange _selectedDateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 7)),
    end: DateTime.now(),
  );
  bool _isLoading = false;

  // Stats
  int _totalEntradasNormal = 0;
  int _totalRetardos = 0;
  int _totalSalidas = 0;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final employees = await _database.getAllEmployees();
    setState(() {
      _employees = employees;
    });
    await _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() => _isLoading = true);
    try {
      List<Map<String, dynamic>> records;
      if (_selectedEmployeeFilter != null) {
        records = await _database.getAttendanceByEmployeeAndDateRange(
          _selectedEmployeeFilter!.id!,
          _selectedDateRange.start,
          _selectedDateRange.end,
        );
      } else {
        records = await _database.getAttendanceByDateRange(
          _selectedDateRange.start,
          _selectedDateRange.end,
        );
      }

      int entradasNormal = 0;
      int retardos = 0;
      int salidas = 0;

      for (final r in records) {
        final String evento = r['evento'] ?? 'ENTRADA';
        final String tipo = r['tipo'] ?? 'NORMAL';
        if (evento == 'ENTRADA') {
          if (tipo == 'RETARDO') {
            retardos++;
          } else {
            entradasNormal++;
          }
        } else if (evento == 'SALIDA') {
          salidas++;
        }
      }

      setState(() {
        _records = records;
        _totalEntradasNormal = entradasNormal;
        _totalRetardos = retardos;
        _totalSalidas = salidas;
      });
    } catch (e) {
      print('Error al cargar marcaciones: $e');
    } finally {
      setState(() => _isLoading = false);
    }
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

  // Promedio de tiempo de las entradas
  String _calculateAverageTime() {
    final entradas = _records.where((r) => r['evento'] == 'ENTRADA').toList();
    if (entradas.isEmpty) return "--:--";
    int totalMinutes = 0;
    for (final record in entradas) {
      final timestamp = DateTime.parse(record['timestamp'] as String);
      totalMinutes += timestamp.hour * 60 + timestamp.minute;
    }
    final avgMinutes = totalMinutes ~/ entradas.length;
    final hour = avgMinutes ~/ 60;
    final minute = avgMinutes % 60;
    return "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}";
  }

  // Exportar registros a CSV
  Future<void> _exportToCSV() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay registros para exportar.'),
          backgroundColor: AppColors.primary,
        ),
      );
      return;
    }

    try {
      final buffer = StringBuffer();
      // Cabecera CSV
      buffer.writeln('ID Registro,ID Colaborador,Nombre,Código,Departamento,Fecha/Hora,Evento,Tipo,Duración Retardo,Confianza');

      for (final r in _records) {
        final timestamp = DateTime.parse(r['timestamp'] as String);
        final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp);
        buffer.writeln(
          '${r['id']},${r['employee_id']},"${r['employee_name']}","${r['employee_code']}","${r['employee_department'] ?? ''}","$formattedDate","${r['evento'] ?? 'ENTRADA'}","${r['tipo'] ?? 'NORMAL'}","${r['duracion'] ?? ''}",${r['confidence']}',
        );
      }

      final directory = await getApplicationDocumentsDirectory();
      final startStr = DateFormat('yyyyMMdd').format(_selectedDateRange.start);
      final endStr = DateFormat('yyyyMMdd').format(_selectedDateRange.end);
      final filePath = '${directory.path}/Reporte_Asistencia_${startStr}_$endStr.csv';
      final file = File(filePath);
      await file.writeAsString(buffer.toString());

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF2B3A24),
            title: const Text('Exportación Exitosa', style: TextStyle(color: Colors.white)),
            content: Text(
              'El reporte se guardó correctamente en:\n\n$filePath',
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
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al exportar: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avgTime = _calculateAverageTime();
    final startFormatted = DateFormat('dd/MM/yyyy').format(_selectedDateRange.start);
    final endFormatted = DateFormat('dd/MM/yyyy').format(_selectedDateRange.end);

    return Scaffold(
      backgroundColor: isDark ? AppColors.kioskBackground : AppColors.background,
      appBar: AppBar(
        title: const Text('Reportes de Asistencia'),
        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_rounded, color: AppColors.primary),
            tooltip: 'Exportar CSV',
            onPressed: _exportToCSV,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sección de Filtros
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Card(
              color: isDark ? AppColors.kioskSurface : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: isDark ? Colors.white10 : AppColors.border,
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        // Combo de Colaborador
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<Employee>(
                              dropdownColor: isDark ? AppColors.kioskSurface : Colors.white,
                              value: _selectedEmployeeFilter,
                              hint: Text(
                                'Filtrar por Colaborador',
                                style: TextStyle(
                                  color: isDark ? Colors.white54 : AppColors.textSecondary,
                                ),
                              ),
                              style: TextStyle(
                                color: isDark ? Colors.white : AppColors.textPrimary,
                              ),
                              items: [
                                const DropdownMenuItem<Employee>(
                                  value: null,
                                  child: Text('Todos los Colaboradores'),
                                ),
                                ..._employees.map((e) {
                                  return DropdownMenuItem<Employee>(
                                    value: e,
                                    child: Text(e.name),
                                  );
                                }),
                              ],
                              onChanged: (Employee? val) {
                                setState(() {
                                  _selectedEmployeeFilter = val;
                                });
                                _loadRecords();
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Botón de Rango de Fechas
                        ElevatedButton.icon(
                          onPressed: _pickDateRange,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark ? Colors.white12 : AppColors.border.withOpacity(0.5),
                            foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.date_range_rounded, size: 16, color: AppColors.primary),
                          label: Text(
                            '$startFormatted - $endFormatted',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Tarjetas de Estadísticas (Dashboard)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                _buildStatCard(
                  title: 'Entradas',
                  value: '$_totalEntradasNormal',
                  subtitle: 'A tiempo',
                  color: Colors.teal,
                ),
                const SizedBox(width: 8),
                _buildStatCard(
                  title: 'Retardos',
                  value: '$_totalRetardos',
                  subtitle: 'Tardanzas',
                  color: Colors.amber.shade800,
                ),
                const SizedBox(width: 8),
                _buildStatCard(
                  title: 'Salidas',
                  value: '$_totalSalidas',
                  subtitle: 'Registradas',
                  color: Colors.blueAccent,
                ),
                const SizedBox(width: 8),
                _buildStatCard(
                  title: 'Prom. H',
                  value: avgTime,
                  subtitle: 'Entrada',
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Lista de Registros
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : _records.isEmpty
                    ? Center(
                        child: Text(
                          'No hay registros para mostrar.',
                          style: TextStyle(
                            color: isDark ? Colors.white38 : AppColors.textSecondary,
                            fontSize: 16,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        itemCount: _records.length,
                        itemBuilder: (context, index) {
                          final r = _records[index];
                          final timestamp = DateTime.parse(r['timestamp'] as String);
                          final formattedTime = DateFormat('hh:mm:ss a').format(timestamp);
                          final formattedDate = DateFormat('dd/MM/yyyy').format(timestamp);
                          final String evento = r['evento'] ?? 'ENTRADA';
                          final String tipo = r['tipo'] ?? 'NORMAL';
                          final String? duracion = r['duracion'];

                          final isEntrada = evento == 'ENTRADA';
                          final isRetardo = tipo == 'RETARDO';

                          return Card(
                            color: isDark ? AppColors.kioskSurface : Colors.white,
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isDark ? Colors.white10 : AppColors.border,
                                width: 1,
                              ),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isEntrada
                                    ? Colors.teal.withOpacity(0.15)
                                    : Colors.blueAccent.withOpacity(0.15),
                                child: Icon(
                                  isEntrada ? Icons.login_rounded : Icons.logout_rounded,
                                  color: isEntrada ? Colors.teal : Colors.blueAccent,
                                ),
                              ),
                              title: Text(
                                r['employee_name'] ?? 'Desconocido',
                                style: TextStyle(
                                  color: isDark ? Colors.white : AppColors.textPrimary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 4),
                                  Text(
                                    'Código: ${r['employee_code'] ?? ''} • Depto: ${r['employee_department'] ?? 'S/D'}',
                                    style: TextStyle(
                                      color: isDark ? Colors.white54 : AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$formattedDate - $formattedTime',
                                    style: TextStyle(
                                      color: isDark ? Colors.white38 : AppColors.textSecondary.withOpacity(0.7),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  // Tipo badge (NORMAL, RETARDO)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: isRetardo
                                          ? Colors.amber.withOpacity(0.15)
                                          : (isEntrada
                                              ? Colors.teal.withOpacity(0.15)
                                              : Colors.blueAccent.withOpacity(0.15)),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      isRetardo ? 'RETARDO' : (isEntrada ? 'NORMAL' : 'SALIDA'),
                                      style: TextStyle(
                                        color: isRetardo
                                            ? Colors.amber.shade400
                                            : (isEntrada ? Colors.tealAccent : Colors.blue.shade300),
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  if (isRetardo && duracion != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      duracion,
                                      style: const TextStyle(
                                        color: Colors.amber,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
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

  Widget _buildStatCard({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Card(
        color: isDark ? AppColors.kioskSurface : Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isDark ? Colors.white10 : AppColors.border,
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0),
          child: Column(
            children: [
              Text(
                title,
                style: TextStyle(
                  color: isDark ? Colors.white54 : AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
