import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/database_service.dart';
import '../services/sync_service.dart';
import '../models/employee.dart';
import '../theme/app_colors.dart';

class SpecialScheduleScreen extends StatefulWidget {
  const SpecialScheduleScreen({super.key});

  @override
  State<SpecialScheduleScreen> createState() => _SpecialScheduleScreenState();
}

class _SpecialScheduleScreenState extends State<SpecialScheduleScreen> {
  final _database = DatabaseService();
  final _syncService = SyncService();

  bool _isAuthenticated = false;
  final _passwordController = TextEditingController();
  String? _errorMessage;

  List<Map<String, dynamic>> _schedules = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  void _verifyPassword() {
    if (_passwordController.text.trim() == 'admin2026') {
      setState(() {
        _isAuthenticated = true;
        _errorMessage = null;
      });
      _loadSchedules();
    } else {
      setState(() {
        _errorMessage = 'Contraseña incorrecta';
      });
    }
  }

  Future<void> _loadSchedules() async {
    setState(() => _isLoading = true);
    try {
      final list = await _database.getAllSpecialSchedules();
      setState(() {
        _schedules = list;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al cargar programaciones: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _isLoading = true);
    try {
      await _syncService.sincronizarProgramacionesEspeciales();
      await _loadSchedules();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Programaciones sincronizadas con el servidor'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error de sincronización: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showLoadingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF2B3A24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Row(
            children: [
              const CircularProgressIndicator(color: AppColors.kioskAccent),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteSchedule(int id, String employeeName, String dateStr) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B3A24),
        title: const Text('Eliminar Programación', style: TextStyle(color: Colors.white)),
        content: Text(
          '¿Deseas eliminar la programación especial para $employeeName el $dateStr?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _showLoadingDialog('Eliminando programación...');
      try {
        await _syncService.eliminarProgramacionEspecial(id);
      } finally {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Programación eliminada')),
        );
        _loadSchedules();
      }
    }
  }

  Future<void> _deleteGroupSchedules(List<int> ids, String label, String dateStr) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B3A24),
        title: const Text('Eliminar Turno Programado', style: TextStyle(color: Colors.white)),
        content: Text(
          '¿Deseas eliminar la programación de $label (${ids.length} colaborador(es)) para el $dateStr?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Eliminar Todo el Turno'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _showLoadingDialog('Eliminando ${ids.length} programación(es)...');
      try {
        await _syncService.eliminarProgramacionesEspeciales(ids);
      } finally {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Se eliminaron ${ids.length} programaciones')),
        );
        _loadSchedules();
      }
    }
  }

  List<_SpecialScheduleGroup> _groupSchedules(List<Map<String, dynamic>> rawList) {
    final Map<String, List<Map<String, dynamic>>> dateMap = {};
    for (final item in rawList) {
      final date = item['date']?.toString() ?? '';
      dateMap.putIfAbsent(date, () => []).add(item);
    }

    final List<_SpecialScheduleGroup> result = [];

    for (final dateEntry in dateMap.entries) {
      final dateStr = dateEntry.key;
      final itemsForDate = dateEntry.value;

      final Map<String, List<Map<String, dynamic>>> subMap = {};
      for (final item in itemsForDate) {
        final hStart = item['hora_inicio']?.toString() ?? '';
        final hEnd = item['hora_final']?.toString() ?? '';
        final obs = item['observacion']?.toString() ?? '';
        final subKey = '${hStart}_${hEnd}_$obs';
        subMap.putIfAbsent(subKey, () => []).add(item);
      }

      final List<_SpecialScheduleSubGroup> subGroups = [];
      for (final subEntry in subMap.entries) {
        final sample = subEntry.value.first;
        subGroups.add(_SpecialScheduleSubGroup(
          horaInicio: sample['hora_inicio']?.toString(),
          horaFinal: sample['hora_final']?.toString(),
          observacion: sample['observacion']?.toString(),
          items: subEntry.value,
        ));
      }

      result.add(_SpecialScheduleGroup(dateStr: dateStr, subGroups: subGroups));
    }

    result.sort((a, b) => b.dateStr.compareTo(a.dateStr));
    return result;
  }

  void _openCreateModal() async {
    final employees = await _database.getAllEmployees();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E2B1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _CreateSpecialScheduleForm(
        employees: employees,
        onSaved: () {
          _loadSchedules();
          _syncService.sincronizarProgramacionesEspeciales();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (!_isAuthenticated) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Acceso Restringido'),
          backgroundColor: AppColors.kioskBackground,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: Card(
              color: const Color(0xFF2B3A24),
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.admin_panel_settings_rounded, size: 64, color: AppColors.kioskAccent),
                    const SizedBox(height: 16),
                    const Text(
                      'Programación Especial',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ingresa la clave de administración para acceder.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Contraseña de Administrador',
                        labelStyle: const TextStyle(color: Colors.white70),
                        errorText: _errorMessage,
                        prefixIcon: const Icon(Icons.lock, color: AppColors.kioskAccent),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white30),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.kioskAccent),
                        ),
                      ),
                      onSubmitted: (_) => _verifyPassword(),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _verifyPassword,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.kioskAccent,
                        foregroundColor: Colors.black87,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Ingresar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final groupedList = _groupSchedules(_schedules);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Programación Especial'),
        backgroundColor: AppColors.kioskBackground,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Sincronizar ahora',
            onPressed: _isLoading ? null : _syncNow,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateModal,
        backgroundColor: AppColors.kioskAccent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_task),
        label: const Text('Programar Personal', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.kioskAccent))
          : groupedList.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.calendar_today_outlined, size: 80, color: isDark ? Colors.white38 : Colors.grey),
                      const SizedBox(height: 16),
                      Text(
                        'No hay programaciones especiales registradas.',
                        style: TextStyle(fontSize: 16, color: isDark ? Colors.white70 : Colors.black54),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _openCreateModal,
                        icon: const Icon(Icons.add),
                        label: const Text('Crear Programación'),
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.kioskAccent, foregroundColor: Colors.black),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                  itemCount: groupedList.length,
                  itemBuilder: (context, index) {
                    final group = groupedList[index];
                    final dateStr = group.dateStr;
                    DateTime? parsedDate = DateTime.tryParse(dateStr);
                    final formattedDate = parsedDate != null
                        ? DateFormat('EEEE, d "de" MMMM yyyy', 'es').format(parsedDate)
                        : dateStr;

                    return Card(
                      color: const Color(0xFF1E2B1A),
                      margin: const EdgeInsets.only(bottom: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(color: Colors.white12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Date Header
                            Row(
                              children: [
                                const Icon(Icons.calendar_month, color: AppColors.kioskAccent, size: 22),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    formattedDate.toUpperCase(),
                                    style: const TextStyle(
                                      color: AppColors.kioskAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.kioskAccent.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${group.totalEmployees} colaborador(es)',
                                    style: const TextStyle(
                                      color: AppColors.kioskAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),
                            const Divider(color: Colors.white12, height: 1),
                            const SizedBox(height: 12),

                            // Subgroups (Turnos del día)
                            Column(
                              children: group.subGroups.map((subGroup) {
                                final hasOverride = subGroup.hasOverride;
                                final labelHorario = hasOverride
                                    ? 'Horario Especial: ${subGroup.horaInicio} - ${subGroup.horaFinal}'
                                    : 'Horario Habitual del Colaborador';
                                final ids = subGroup.items.map((e) => e['id'] as int).toList();

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2B3A24),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: hasOverride ? Colors.amber.withOpacity(0.4) : Colors.cyan.withOpacity(0.4),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Subgroup Header
                                      Row(
                                        children: [
                                          Icon(
                                            hasOverride ? Icons.access_time_filled : Icons.event_available,
                                            color: hasOverride ? Colors.amber : Colors.cyanAccent,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              labelHorario,
                                              style: TextStyle(
                                                color: hasOverride ? Colors.amberAccent : Colors.cyanAccent,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent, size: 20),
                                            tooltip: 'Eliminar todo este turno',
                                            onPressed: () => _deleteGroupSchedules(ids, labelHorario, formattedDate),
                                          ),
                                        ],
                                      ),

                                      if (subGroup.observacion != null && subGroup.observacion!.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          'Nota: ${subGroup.observacion}',
                                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontStyle: FontStyle.italic),
                                        ),
                                      ],

                                      const SizedBox(height: 10),

                                      // Employee chips / items
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: subGroup.items.map((empMap) {
                                          final empId = empMap['id'] as int;
                                          final empName = empMap['employee_name']?.toString() ?? 'Colaborador';
                                          final empCode = empMap['employee_code']?.toString() ?? '';
                                          final empDept = empMap['employee_department']?.toString();
                                          final isSynced = empMap['is_synced'] ?? 0;

                                          return Chip(
                                            backgroundColor: const Color(0xFF1E2B1A),
                                            side: const BorderSide(color: Colors.white24),
                                            avatar: Icon(
                                              isSynced == 1 ? Icons.cloud_done : Icons.cloud_upload_outlined,
                                              size: 16,
                                              color: isSynced == 1 ? Colors.greenAccent : Colors.orangeAccent,
                                            ),
                                            label: Text(
                                              '$empName ($empCode)${empDept != null && empDept.isNotEmpty ? " • $empDept" : ""}',
                                              style: const TextStyle(color: Colors.white, fontSize: 12),
                                            ),
                                            deleteIcon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                                            onDeleted: () => _deleteSchedule(empId, empName, formattedDate),
                                          );
                                        }).toList(),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class _SpecialScheduleGroup {
  final String dateStr;
  final List<_SpecialScheduleSubGroup> subGroups;

  _SpecialScheduleGroup({required this.dateStr, required this.subGroups});

  int get totalEmployees => subGroups.fold(0, (sum, sg) => sum + sg.items.length);
}

class _SpecialScheduleSubGroup {
  final String? horaInicio;
  final String? horaFinal;
  final String? observacion;
  final List<Map<String, dynamic>> items;

  _SpecialScheduleSubGroup({
    this.horaInicio,
    this.horaFinal,
    this.observacion,
    required this.items,
  });

  bool get hasOverride =>
      horaInicio != null &&
      horaInicio!.isNotEmpty &&
      horaFinal != null &&
      horaFinal!.isNotEmpty;
}

class _CreateSpecialScheduleForm extends StatefulWidget {
  final List<Employee> employees;
  final VoidCallback onSaved;

  const _CreateSpecialScheduleForm({
    required this.employees,
    required this.onSaved,
  });

  @override
  State<_CreateSpecialScheduleForm> createState() => _CreateSpecialScheduleFormState();
}

class _CreateSpecialScheduleFormState extends State<_CreateSpecialScheduleForm> {
  final _database = DatabaseService();

  DateTime _selectedDate = DateTime.now();
  final Set<int> _selectedEmployeeIds = {};
  String _searchQuery = '';
  String _selectedSection = 'TODAS';

  bool _hasOverride = false;
  TimeOfDay _horaInicio = const TimeOfDay(hour: 7, minute: 0);
  TimeOfDay _horaFinal = const TimeOfDay(hour: 17, minute: 0);
  final _obsController = TextEditingController();
  bool _isSaving = false;

  List<String> get _sections {
    final set = <String>{};
    for (final e in widget.employees) {
      if (e.department != null && e.department!.trim().isNotEmpty) {
        set.add(e.department!.trim());
      }
    }
    final list = set.toList()..sort();
    return ['TODAS', ...list];
  }

  List<Employee> get _filteredEmployees {
    return widget.employees.where((e) {
      final matchesSection = _selectedSection == 'TODAS' ||
          (e.department != null && e.department!.trim() == _selectedSection);
      if (!matchesSection) return false;

      if (_searchQuery.trim().isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return e.name.toLowerCase().contains(q) ||
          e.employeeCode.toLowerCase().contains(q) ||
          (e.department != null && e.department!.toLowerCase().contains(q));
    }).toList();
  }

  void _selectAll() {
    setState(() {
      if (_selectedEmployeeIds.length == _filteredEmployees.length) {
        _selectedEmployeeIds.clear();
      } else {
        _selectedEmployeeIds.clear();
        for (final e in _filteredEmployees) {
          if (e.id != null) _selectedEmployeeIds.add(e.id!);
        }
      }
    });
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.kioskAccent,
              onPrimary: Colors.black,
              surface: Color(0xFF2B3A24),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _selectTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _horaInicio : _horaFinal,
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.kioskAccent,
              onPrimary: Colors.black,
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
        if (isStart) {
          _horaInicio = picked;
        } else {
          _horaFinal = picked;
        }
      });
    }
  }

  String _formatTimeOfDay(TimeOfDay tod) {
    final h = tod.hour.toString().padLeft(2, '0');
    final m = tod.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _save() async {
    if (_selectedEmployeeIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor selecciona al menos un colaborador'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final hInicioStr = _hasOverride ? _formatTimeOfDay(_horaInicio) : null;
    final hFinalStr = _hasOverride ? _formatTimeOfDay(_horaFinal) : null;
    final obs = _obsController.text.trim();

    try {
      final List<Map<String, dynamic>> schedulesToSave = _selectedEmployeeIds.map((empId) {
        return {
          'employee_id': empId,
          'date': dateStr,
          'hora_inicio': hInicioStr,
          'hora_final': hFinalStr,
          'observacion': obs.isNotEmpty ? obs : null,
          'is_synced': 0,
        };
      }).toList();

      await _database.saveSpecialSchedulesBatch(schedulesToSave);
      final savedCount = schedulesToSave.length;

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('¡$savedCount programación(es) especial(es) guardada(s)!'),
            backgroundColor: AppColors.success,
          ),
        );
        widget.onSaved();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al guardar: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('EEEE, d "de" MMMM yyyy', 'es').format(_selectedDate);

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white12)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.event_note, color: AppColors.kioskAccent),
                    const SizedBox(width: 12),
                    const Text(
                      'Programar Personal Especial',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Date Selector
                    Card(
                      color: const Color(0xFF2B3A24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        leading: const Icon(Icons.calendar_today, color: AppColors.kioskAccent),
                        title: const Text('Fecha de la programación', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        subtitle: Text(
                          dateStr.toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        trailing: ElevatedButton(
                          onPressed: _selectDate,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.kioskAccent,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Cambiar'),
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Override Switch
                    Card(
                      color: const Color(0xFF2B3A24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          children: [
                            SwitchListTile(
                              activeColor: AppColors.kioskAccent,
                              title: const Text(
                                '¿Modificar horario para este día?',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              subtitle: Text(
                                _hasOverride
                                    ? 'Se aplicarán las horas elegidas abajo'
                                    : 'Cada colaborador usará su horario habitual asignado',
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                              value: _hasOverride,
                              onChanged: (val) => setState(() => _hasOverride = val),
                            ),
                            if (_hasOverride) ...[
                              const Divider(color: Colors.white12),
                              Row(
                                children: [
                                  Expanded(
                                    child: ListTile(
                                      title: const Text('Hora Entrada', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                      subtitle: Text(
                                        _formatTimeOfDay(_horaInicio),
                                        style: const TextStyle(color: AppColors.kioskAccent, fontWeight: FontWeight.bold, fontSize: 18),
                                      ),
                                      onTap: () => _selectTime(true),
                                    ),
                                  ),
                                  Expanded(
                                    child: ListTile(
                                      title: const Text('Hora Salida', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                      subtitle: Text(
                                        _formatTimeOfDay(_horaFinal),
                                        style: const TextStyle(color: AppColors.kioskAccent, fontWeight: FontWeight.bold, fontSize: 18),
                                      ),
                                      onTap: () => _selectTime(false),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Observation
                    TextField(
                      controller: _obsController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Observación (ej: Turno dominical, Media jornada)',
                        labelStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: const Color(0xFF2B3A24),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.kioskAccent),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Employee selection section header
                    Row(
                      children: [
                        Text(
                          'Colaboradores (${_selectedEmployeeIds.length}/${widget.employees.length})',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _selectAll,
                          icon: Icon(
                            _selectedEmployeeIds.length == _filteredEmployees.length ? Icons.deselect : Icons.select_all,
                            color: AppColors.kioskAccent,
                            size: 18,
                          ),
                          label: Text(
                            _selectedEmployeeIds.length == _filteredEmployees.length ? 'Deseleccionar todos' : 'Seleccionar todos',
                            style: const TextStyle(color: AppColors.kioskAccent, fontSize: 12),
                          ),
                        ),
                      ],
                    ),

                    // Filter by Section / Department
                    DropdownButtonFormField<String>(
                      value: _selectedSection,
                      dropdownColor: const Color(0xFF2B3A24),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Filtrar por Sección / Departamento',
                        labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
                        prefixIcon: const Icon(Icons.business_outlined, color: AppColors.kioskAccent, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF2B3A24),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: _sections.map((sec) {
                        return DropdownMenuItem<String>(
                          value: sec,
                          child: Text(
                            sec == 'TODAS' ? 'Todas las secciones (${widget.employees.length})' : 'Sección: $sec',
                            style: const TextStyle(color: Colors.white),
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedSection = val);
                        }
                      },
                    ),

                    const SizedBox(height: 10),

                    // Search field
                    TextField(
                      style: const TextStyle(color: Colors.white),
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: InputDecoration(
                        hintText: 'Buscar colaborador por nombre o cédula...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                        prefixIcon: const Icon(Icons.search, color: Colors.white54),
                        filled: true,
                        fillColor: const Color(0xFF2B3A24),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Employee List
                    Container(
                      constraints: const BoxConstraints(maxHeight: 280),
                      decoration: BoxDecoration(
                        color: const Color(0xFF23321F),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: _filteredEmployees.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16.0),
                                child: Text('No se encontraron colaboradores', style: TextStyle(color: Colors.white54)),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: _filteredEmployees.length,
                              separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                              itemBuilder: (context, index) {
                                final emp = _filteredEmployees[index];
                                final isSelected = emp.id != null && _selectedEmployeeIds.contains(emp.id!);

                                return CheckboxListTile(
                                  activeColor: AppColors.kioskAccent,
                                  checkColor: Colors.black,
                                  value: isSelected,
                                  onChanged: (bool? checked) {
                                    if (emp.id == null) return;
                                    setState(() {
                                      if (checked == true) {
                                        _selectedEmployeeIds.add(emp.id!);
                                      } else {
                                        _selectedEmployeeIds.remove(emp.id!);
                                      }
                                    });
                                  },
                                  title: Text(
                                    emp.name,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                                  ),
                                  subtitle: Text(
                                    'Cédula: ${emp.employeeCode} ${emp.department != null && emp.department!.isNotEmpty ? "• Sec: ${emp.department}" : ""} ${emp.horarioId != null ? "• Horario: ${emp.horarioId}" : ""}',
                                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),

              // Save Button
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.kioskAccent,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    _isSaving ? 'Guardando...' : 'Guardar Programación (${_selectedEmployeeIds.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
