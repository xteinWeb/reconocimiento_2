import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/employee.dart';
import '../services/database_service.dart';
import '../services/sync_service.dart';
import '../theme/app_colors.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  final _database = DatabaseService();
  final _syncService = SyncService();

  List<Map<String, dynamic>> _records = [];
  bool _isLoading = false;
  bool _isSyncing = false;

  // Stats
  int _totalCount = 0;
  int _pendingCount = 0;
  int _syncedCount = 0;

  // Enrolamientos faciales (tabla employees, is_synced) — distinto de las
  // marcaciones de arriba. Un empleado queda aquí mientras su vector no haya
  // llegado al servidor central.
  List<Employee> _enrolamientosPendientes = [];

  // Filter: null = Todos, 0 = Pendientes, 1 = Sincronizados
  int? _selectedFilter = 0; // Default to pending view

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final counts = await _database.getSyncCounts();
      final records = await _database.getAttendanceWithSyncStatus(
        syncedFilter: _selectedFilter,
      );
      final empleados = await _database.getAllEmployees();

      if (mounted) {
        setState(() {
          _totalCount = counts['total'] ?? 0;
          _pendingCount = counts['pending'] ?? 0;
          _syncedCount = counts['synced'] ?? 0;
          _records = records;
          _enrolamientosPendientes =
              empleados.where((e) => e.isSynced == 0).toList();
        });
      }
    } catch (e) {
      print('Error al cargar datos de sincronización: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _sincronizarPendientes() async {
    // _pendingCount solo cuenta marcaciones (attendance_records). Si hay
    // enrolamientos faciales pendientes (tabla employees), hay que seguir
    // igual: sincronizarAsistenciasPendientes() es la única vía que también
    // sube los enrolamientos, y cortar aquí antes de llamarla los dejaba
    // atascados aunque las marcaciones ya estuvieran al día.
    if (_pendingCount == 0 && _enrolamientosPendientes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay marcaciones ni enrolamientos pendientes por sincronizar.'),
          backgroundColor: AppColors.info,
        ),
      );
      return;
    }

    setState(() => _isSyncing = true);
    try {
      final result = await _syncService.sincronizarAsistenciasPendientes();
      final int success = result['success'] ?? 0;
      final int failed = result['failed'] ?? 0;

      if (mounted) {
        if (failed == 0 && success > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('¡Se sincronizaron con éxito $success marcación(es)!'),
              backgroundColor: AppColors.success,
            ),
          );
        } else if (success > 0 && failed > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Sincronizadas: $success. Fallaron: $failed. Verifica la conexión.'),
              backgroundColor: AppColors.warning,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No se pudo conectar al servidor central SQL Server.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error durante la sincronización: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      await _loadData();
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _sincronizarIndividual(Map<String, dynamic> record) async {
    final success = await _syncService.sincronizarMarcacionIndividual(record);
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Marcación de ${record['employee_name'] ?? 'empleado'} sincronizada.'),
            backgroundColor: AppColors.success,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error de conexión al servidor SQL Server.'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
    await _loadData();
  }

  Future<void> _eliminarMarcacion(Map<String, dynamic> record) async {
    final int recordId = record['id'] as int;
    final name = record['employee_name'] ?? 'empleado';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Marcación Local'),
        content: Text('¿Deseas eliminar la marcación local de $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _database.deleteAttendanceRecord(recordId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Marcación eliminada de la base de datos local.'),
            backgroundColor: AppColors.info,
          ),
        );
      }
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sincronizador Online',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: isDark ? AppColors.kioskSurface : AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isSyncing ? null : _loadData,
            tooltip: 'Actualizar datos',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.kioskBackground : AppColors.background,
        ),
        child: RefreshIndicator(
          onRefresh: _loadData,
          child: Column(
            children: [
              // Summary cards
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildSummaryCard(
                        context,
                        title: 'Total',
                        count: _totalCount,
                        color: AppColors.primary,
                        icon: Icons.assignment_outlined,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSummaryCard(
                        context,
                        title: 'Pendientes',
                        count: _pendingCount,
                        color: _pendingCount > 0 ? AppColors.warning : AppColors.secondary,
                        icon: Icons.cloud_upload_outlined,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSummaryCard(
                        context,
                        title: 'Sincronizados',
                        count: _syncedCount,
                        color: AppColors.success,
                        icon: Icons.cloud_done_outlined,
                      ),
                    ),
                  ],
                ),
              ),

              // Action button to sync all pending
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: (_isSyncing ||
                            (_pendingCount == 0 && _enrolamientosPendientes.isEmpty))
                        ? null
                        : _sincronizarPendientes,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryDark,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: isDark ? Colors.white12 : Colors.grey.shade300,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    icon: _isSyncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.sync_rounded),
                    label: Text(
                      _isSyncing
                          ? 'Sincronizando...'
                          : (_pendingCount > 0 || _enrolamientosPendientes.isNotEmpty
                              ? 'Sincronizar Pendientes ($_pendingCount marc. + ${_enrolamientosPendientes.length} enrol.)'
                              : 'Todo Sincronizado'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Enrolamientos faciales pendientes de subir (distinto de las
              // marcaciones): un empleado enrolado localmente cuyo vector
              // todavía no llegó al servidor central.
              if (_enrolamientosPendientes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    color: isDark ? AppColors.kioskSurface : Colors.white,
                    child: ExpansionTile(
                      leading: const Icon(
                        Icons.face_retouching_natural_outlined,
                        color: AppColors.warning,
                      ),
                      title: Text(
                        'Enrolamientos faciales pendientes de subir '
                        '(${_enrolamientosPendientes.length})',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: isDark ? Colors.white : AppColors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        'Su vector facial todavía no llegó al servidor central',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white60 : AppColors.textSecondary,
                        ),
                      ),
                      children: _enrolamientosPendientes
                          .map(
                            (e) => ListTile(
                              dense: true,
                              leading: const Icon(Icons.person_outline),
                              title: Text(e.name),
                              subtitle: Text('Cédula: ${e.employeeCode}'),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // Filter Chips
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    _buildFilterChip('Pendientes ($_pendingCount)', 0),
                    const SizedBox(width: 8),
                    _buildFilterChip('Sincronizados ($_syncedCount)', 1),
                    const SizedBox(width: 8),
                    _buildFilterChip('Todos ($_totalCount)', null),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Records list
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _records.isEmpty
                        ? _buildEmptyState(isDark)
                        : ListView.builder(
                            padding: const EdgeInsets.all(16.0),
                            itemCount: _records.length,
                            itemBuilder: (context, index) {
                              final record = _records[index];
                              return _buildRecordCard(context, record, isDark);
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(
    BuildContext context, {
    required String title,
    required int count,
    required Color color,
    required IconData icon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isDark ? AppColors.kioskSurface : Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, int? value) {
    final isSelected = _selectedFilter == value;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _selectedFilter = value;
          });
          _loadData();
        }
      },
      selectedColor: AppColors.primary,
      backgroundColor: isDark ? AppColors.kioskSurface : Colors.grey.shade200,
      labelStyle: TextStyle(
        color: isSelected
            ? Colors.white
            : (isDark ? Colors.white70 : AppColors.textPrimary),
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
    );
  }

  Widget _buildRecordCard(BuildContext context, Map<String, dynamic> record, bool isDark) {
    final isSynced = (record['is_synced'] ?? 0) == 1;
    final evento = record['evento'] ?? 'ENTRADA';
    final tipo = record['tipo'] ?? 'NORMAL';
    final name = record['employee_name'] ?? 'Desconocido';
    final code = record['employee_code'] ?? 'Sin Cédula';
    final department = record['employee_department'] ?? '';

    String fechaFormatted = '';
    if (record['timestamp'] != null) {
      try {
        final dt = DateTime.parse(record['timestamp']);
        fechaFormatted = DateFormat('dd/MM/yyyy HH:mm:ss').format(dt);
      } catch (_) {
        fechaFormatted = record['timestamp'].toString();
      }
    }

    final isEntrada = evento == 'ENTRADA';
    final isRetardo = tipo == 'RETARDO';

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: isDark ? AppColors.kioskSurface : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Event Badge (ENTRADA / SALIDA)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isEntrada
                        ? (isRetardo
                            ? AppColors.warning.withOpacity(0.15)
                            : AppColors.success.withOpacity(0.15))
                        : AppColors.primaryDark.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isEntrada ? Icons.login_rounded : Icons.logout_rounded,
                        size: 14,
                        color: isEntrada
                            ? (isRetardo ? AppColors.warning : AppColors.success)
                            : AppColors.primaryDark,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$evento ${isRetardo ? "(RETARDO)" : ""}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isEntrada
                              ? (isRetardo ? AppColors.warning : AppColors.success)
                              : AppColors.primaryDark,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Sync Status Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSynced
                        ? AppColors.success.withOpacity(0.15)
                        : AppColors.warning.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSynced ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                        size: 14,
                        color: isSynced ? AppColors.success : AppColors.warning,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isSynced ? 'Sincronizado' : 'Pendiente',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isSynced ? AppColors.success : AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Employee Info
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.primary.withOpacity(0.2),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryDark,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'C.I: $code ${department.isNotEmpty ? "• $department" : ""}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white60 : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isSynced) ...[
                  IconButton(
                    icon: const Icon(Icons.cloud_upload_rounded),
                    color: AppColors.warning,
                    tooltip: 'Sincronizar ahora',
                    onPressed: () => _sincronizarIndividual(record),
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  color: AppColors.error,
                  tooltip: 'Eliminar marcación local',
                  onPressed: () => _eliminarMarcacion(record),
                ),
              ],
            ),

            const SizedBox(height: 8),
            Divider(height: 1, color: isDark ? Colors.white10 : AppColors.divider),
            const SizedBox(height: 8),

            // Timestamp and duration if retardo
            Row(
              children: [
                Icon(
                  Icons.access_time_rounded,
                  size: 14,
                  color: isDark ? Colors.white60 : AppColors.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  fechaFormatted,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : AppColors.textSecondary,
                  ),
                ),
                if (record['duracion'] != null && record['duracion'].toString().isNotEmpty) ...[
                  const Spacer(),
                  Text(
                    'Retardo: ${record['duracion']}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.warning,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _selectedFilter == 0
                ? Icons.cloud_done_rounded
                : Icons.inbox_rounded,
            size: 64,
            color: isDark ? Colors.white30 : AppColors.textDisabled,
          ),
          const SizedBox(height: 16),
          Text(
            _selectedFilter == 0
                ? '¡No hay marcaciones pendientes!'
                : 'No se encontraron registros de marcaciones.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white70 : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _selectedFilter == 0
                ? 'Todas las marcaciones locales están sincronizadas con SQL Server.'
                : 'Las marcaciones registradas aparecerán aquí.',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : AppColors.textDisabled,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
