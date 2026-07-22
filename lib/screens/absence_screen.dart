import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/database_service.dart';
import '../models/employee.dart';
import '../theme/app_colors.dart';

class AbsenceScreen extends StatefulWidget {
  const AbsenceScreen({super.key});

  @override
  State<AbsenceScreen> createState() => _AbsenceScreenState();
}

class _AbsenceScreenState extends State<AbsenceScreen> with SingleTickerProviderStateMixin {
  final _database = DatabaseService();
  DateTime _selectedDate = DateTime.now();
  late TabController _tabController;

  List<Employee> _employees = [];
  List<Map<String, dynamic>> _attendanceRecords = [];
  List<Map<String, dynamic>> _absences = [];
  bool _isLoading = true;
  String _searchQuery = '';

  // Stats
  int _countAsistieron = 0;
  int _countAusentes = 0;
  int _countJustificados = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);

      // 1. Obtener empleados
      final emps = await _database.getAllEmployees();

      // 2. Obtener asistencias del día
      final atts = await _database.getAttendanceByDate(_selectedDate);

      // 3. Obtener ausentismos del día
      final abs = await _database.getAbsencesByDate(dateStr);

      // Calcular estadísticas
      int countAsistieron = 0;
      int countAusentes = 0;
      int countJustificados = 0;

      final attendedIds = atts.map((a) => a['employee_id'] as int).toSet();
      final justifiedIds = abs.map((a) => a['employee_id'] as int).toSet();

      for (final e in emps) {
        if (attendedIds.contains(e.id)) {
          countAsistieron++;
        } else if (justifiedIds.contains(e.id)) {
          countJustificados++;
        } else {
          countAusentes++;
        }
      }

      setState(() {
        _employees = emps;
        _attendanceRecords = atts;
        _absences = abs;
        _countAsistieron = countAsistieron;
        _countAusentes = countAusentes;
        _countJustificados = countJustificados;
      });
    } catch (e) {
      print('Error al cargar datos de ausencias: $e');
    } finally {
      setState(() => _isLoading = false);
    }
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
        _selectedDate = picked;
      });
      await _loadData();
    }
  }

  void _showJustificationDialog(Employee employee, Map<String, dynamic>? existingAbsence) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    String selectedSigla = existingAbsence?['sigla_ausencia'] ?? 'F';
    final noteController = TextEditingController(text: existingAbsence?['observacion'] ?? '');

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2B3A24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(
                existingAbsence != null ? 'Editar Justificación' : 'Justificar Ausencia',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    employee.name,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Tipo de Novedad:',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    dropdownColor: const Color(0xFF2B3A24),
                    value: selectedSigla,
                    isExpanded: true,
                    style: const TextStyle(color: Colors.white),
                    items: const [
                      DropdownMenuItem(value: 'F', child: Text('F - Falta Injustificada')),
                      DropdownMenuItem(value: 'V', child: Text('V - Vacaciones')),
                      DropdownMenuItem(value: 'I', child: Text('I - Incapacidad Médica')),
                      DropdownMenuItem(value: 'P', child: Text('P - Permiso Especial')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() {
                          selectedSigla = val;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Observaciones:',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteController,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Ej. Cita médica familiar, viaje programado...',
                      hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.primary),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                if (existingAbsence != null)
                  TextButton(
                    onPressed: () async {
                      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
                      await _database.deleteAbsence(employee.id!, dateStr);
                      Navigator.of(ctx).pop();
                      _loadData();
                    },
                    child: const Text('Eliminar', style: TextStyle(color: Colors.redAccent)),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
                    await _database.saveAbsence(
                      employee.id!,
                      dateStr,
                      selectedSigla,
                      noteController.text.trim().isNotEmpty ? noteController.text.trim() : null,
                    );
                    Navigator.of(ctx).pop();
                    _loadData();
                  },
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Color _getSiglaColor(String sigla) {
    switch (sigla) {
      case 'F':
        return Colors.redAccent.shade700;
      case 'V':
        return Colors.blue.shade700;
      case 'I':
        return Colors.purple.shade600;
      case 'P':
        return Colors.amber.shade800;
      default:
        return Colors.grey;
    }
  }

  String _getSiglaName(String sigla) {
    switch (sigla) {
      case 'F':
        return 'Falta';
      case 'V':
        return 'Vacaciones';
      case 'I':
        return 'Incapacidad';
      case 'P':
        return 'Permiso';
      default:
        return 'Novedad';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dateFormatted = DateFormat('dd/MM/yyyy').format(_selectedDate);

    // Listas filtradas
    final attendedIds = _attendanceRecords.map((a) => a['employee_id'] as int).toSet();
    final justifiedIds = _absences.map((a) => a['employee_id'] as int).toSet();
    final Map<int, Map<String, dynamic>> absencesMap = {
      for (final a in _absences) a['employee_id'] as int: a,
    };

    final filteredAll = _employees.where((e) {
      return e.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          e.employeeCode.contains(_searchQuery);
    }).toList();

    final filteredAttended = filteredAll.where((e) => attendedIds.contains(e.id)).toList();
    final filteredAbsent = filteredAll.where((e) => !attendedIds.contains(e.id) && !justifiedIds.contains(e.id)).toList();
    final filteredJustified = filteredAll.where((e) => justifiedIds.contains(e.id)).toList();

    return Scaffold(
      backgroundColor: isDark ? AppColors.kioskBackground : AppColors.background,
      appBar: AppBar(
        title: const Text('Gestión de Ausencias'),
        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppColors.primary),
            onPressed: _loadData,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selector de Fecha
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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Fecha de Reporte',
                          style: TextStyle(
                            color: isDark ? Colors.white54 : AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dateFormatted,
                          style: TextStyle(
                            color: isDark ? Colors.white : AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    ElevatedButton.icon(
                      onPressed: _pickDate,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? Colors.white12 : AppColors.border.withOpacity(0.5),
                        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.date_range_rounded, size: 16, color: AppColors.primary),
                      label: const Text('Cambiar Fecha'),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Caja de Búsqueda
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: TextField(
              onChanged: (val) => setState(() => _searchQuery = val),
              style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary),
              decoration: InputDecoration(
                filled: true,
                fillColor: isDark ? AppColors.kioskSurface : Colors.white,
                hintText: 'Buscar por nombre o cédula...',
                hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                prefixIcon: const Icon(Icons.search_rounded, color: Colors.grey),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: isDark ? Colors.white10 : AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.primary),
                ),
              ),
            ),
          ),

          // Pestañas (Tabs)
          TabBar(
            controller: _tabController,
            isScrollable: false,
            indicatorColor: AppColors.primary,
            labelColor: AppColors.primary,
            unselectedLabelColor: isDark ? Colors.white54 : AppColors.textSecondary,
            tabs: [
              Tab(text: 'Todos (${filteredAll.length})'),
              Tab(text: 'Asistió (${filteredAttended.length})'),
              Tab(text: 'Faltó (${filteredAbsent.length})'),
              Tab(text: 'Justif. (${filteredJustified.length})'),
            ],
          ),

          // Contenedor de la lista filtrada
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildEmployeeList(filteredAll, attendedIds, absencesMap),
                      _buildEmployeeList(filteredAttended, attendedIds, absencesMap),
                      _buildEmployeeList(filteredAbsent, attendedIds, absencesMap),
                      _buildEmployeeList(filteredJustified, attendedIds, absencesMap),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeList(
    List<Employee> list,
    Set<int> attendedIds,
    Map<int, Map<String, dynamic>> absencesMap,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (list.isEmpty) {
      return Center(
        child: Text(
          'Sin registros en esta pestaña.',
          style: TextStyle(
            color: isDark ? Colors.white38 : AppColors.textSecondary,
            fontSize: 14,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: list.length,
      itemBuilder: (ctx, index) {
        final emp = list[index];
        final isAttended = attendedIds.contains(emp.id);
        final absence = absencesMap[emp.id];
        final isJustified = absence != null;

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
              backgroundColor: isAttended
                  ? Colors.teal.withOpacity(0.15)
                  : (isJustified ? _getSiglaColor(absence['sigla_ausencia']).withOpacity(0.15) : Colors.red.withOpacity(0.15)),
              child: Icon(
                isAttended
                    ? Icons.check_circle_rounded
                    : (isJustified ? Icons.info_outline_rounded : Icons.cancel_outlined),
                color: isAttended
                    ? Colors.teal
                    : (isJustified ? _getSiglaColor(absence['sigla_ausencia']) : Colors.redAccent),
              ),
            ),
            title: Text(
              emp.name,
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
                  'Cédula: ${emp.employeeCode} • Depto: ${emp.department ?? 'S/D'}',
                  style: TextStyle(
                    color: isDark ? Colors.white54 : AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                if (isJustified && absence['observacion'] != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Obs: ${absence['observacion']}',
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
            trailing: isAttended
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.teal.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'ASISTIÓ',
                      style: TextStyle(color: Colors.tealAccent, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  )
                : Container(
                    child: ElevatedButton(
                      onPressed: () => _showJustificationDialog(emp, absence),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isJustified ? _getSiglaColor(absence['sigla_ausencia']) : Colors.redAccent.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      child: Text(
                        isJustified ? _getSiglaName(absence['sigla_ausencia']).toUpperCase() : 'JUSTIFICAR',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
