import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../services/database_service.dart';
import '../models/employee.dart';

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
  DateTime _selectedDate = DateTime.now();

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
    List<Map<String, dynamic>> records;
    if (_selectedEmployeeFilter != null) {
      records = await _database.getAttendanceByEmployee(_selectedEmployeeFilter!.id!);
    } else {
      records = await _database.getAttendanceByDate(_selectedDate);
    }
    setState(() => _records = records);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.orangeAccent,
              onPrimary: Colors.black87,
              surface: Color(0xFF1E1E1E),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _selectedEmployeeFilter = null; // Limpiar filtro por empleado al seleccionar fecha
      });
      _loadRecords();
    }
  }

  // Estadísticas básicas de puntualidad
  String _calculateAverageTime() {
    if (_records.isEmpty) return "--:--";
    int totalMinutes = 0;
    for (final record in _records) {
      final timestamp = DateTime.parse(record['timestamp'] as String);
      totalMinutes += timestamp.hour * 60 + timestamp.minute;
    }
    final avgMinutes = totalMinutes ~/ _records.length;
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
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    try {
      final buffer = StringBuffer();
      // Cabecera CSV
      buffer.writeln('ID Registro,ID Colaborador,Nombre,Código,Departamento,Fecha/Hora,Confianza');

      for (final r in _records) {
        final timestamp = DateTime.parse(r['timestamp'] as String);
        final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp);
        buffer.writeln(
          '${r['id']},${r['employee_id']},"${r['employee_name']}","${r['employee_code']}","${r['employee_department'] ?? ''}","$formattedDate",${r['confidence']}',
        );
      }

      final directory = await getApplicationDocumentsDirectory();
      final dateStr = DateFormat('yyyyMMdd').format(_selectedDate);
      final filePath = '${directory.path}/Reporte_Asistencia_$dateStr.csv';
      final file = File(filePath);
      await file.writeAsString(buffer.toString());

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text('Exportación Exitosa', style: TextStyle(color: Colors.white)),
            content: Text(
              'El reporte se guardó correctamente en:\n\n$filePath',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Entendido', style: TextStyle(color: Colors.orangeAccent)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al exportar: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final avgTime = _calculateAverageTime();

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Reportes de Asistencia'),
        foregroundColor: Colors.white,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_rounded, color: Colors.orangeAccent),
            tooltip: 'Exportar CSV',
            onPressed: _exportToCSV,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sección de Filtros y Estadísticas
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // Filtros
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<Employee>(
                              dropdownColor: const Color(0xFF1E1E1E),
                              value: _selectedEmployeeFilter,
                              hint: const Text('Filtrar por Colaborador', style: TextStyle(color: Colors.white54)),
                              style: const TextStyle(color: Colors.white),
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
                        ElevatedButton.icon(
                          onPressed: _pickDate,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white12,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.calendar_today_rounded, size: 16, color: Colors.orangeAccent),
                          label: Text(
                            DateFormat('dd/MM/yyyy').format(_selectedDate),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 24),
                    // Estadísticas de puntualidad
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            const Text('Registros', style: TextStyle(color: Colors.white54, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text(
                              '${_records.length}',
                              style: const TextStyle(color: Colors.orangeAccent, fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Column(
                          children: [
                            const Text('Promedio Marcado', style: TextStyle(color: Colors.white54, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text(
                              avgTime,
                              style: const TextStyle(color: Colors.orangeAccent, fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Lista de Registros
          Expanded(
            child: _records.isEmpty
                ? const Center(
                    child: Text(
                      'No hay registros para mostrar.',
                      style: TextStyle(color: Colors.white38, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final r = _records[index];
                      final timestamp = DateTime.parse(r['timestamp'] as String);
                      final formattedTime = DateFormat('hh:mm:ss a').format(timestamp);
                      final formattedDate = DateFormat('dd/MM/yyyy').format(timestamp);

                      return Card(
                        color: const Color(0xFF1A1A1A),
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.white12,
                            child: Icon(Icons.fingerprint_rounded, color: Colors.orangeAccent),
                          ),
                          title: Text(
                            r['employee_name'] ?? 'Desconocido',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                'Código: ${r['employee_code'] ?? ''} • Depto: ${r['employee_department'] ?? 'S/D'}',
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$formattedDate - $formattedTime',
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Conf: ${(r['confidence'] as double).toStringAsFixed(2)}',
                              style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
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
