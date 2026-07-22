import 'package:flutter/material.dart';
import '../models/employee.dart';
import '../services/database_service.dart';
import '../theme/app_colors.dart';
import 'enrollment_screen.dart';

class EmployeeListScreen extends StatefulWidget {
  const EmployeeListScreen({super.key});

  @override
  State<EmployeeListScreen> createState() => _EmployeeListScreenState();
}

class _EmployeeListScreenState extends State<EmployeeListScreen> {
  final _database = DatabaseService();
  List<Employee> _employees = [];
  Map<int, int> _embeddingsCount = {}; // employeeId -> count
  bool _isLoading = true;

  // Filtros de UI
  final _searchController = TextEditingController();
  String _searchQuery = "";
  String _selectedStatus = "Todos"; // Todos, Enrolados, Pendientes
  String _selectedSection = "Todos"; // Todos, [Sección A, Sección B...]
  List<String> _sections = ["Todos"];

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    setState(() => _isLoading = true);
    try {
      final list = await _database.getAllEmployees();
      final counts = <int, int>{};
      final uniqueSections = <String>{};

      for (final emp in list) {
        if (emp.id != null) {
          final embeddings = await _database.getEmbeddingsByEmployee(emp.id!);
          counts[emp.id!] = embeddings.length;
        }
        if (emp.department != null && emp.department!.isNotEmpty) {
          uniqueSections.add(emp.department!);
        }
      }

      setState(() {
        _employees = list;
        _embeddingsCount = counts;
        _sections = ["Todos", ...uniqueSections.toList()..sort()];
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al cargar colaboradores: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<Employee> _getFilteredEmployees() {
    return _employees.where((emp) {
      // 1. Filtro por nombre o cédula
      final matchesSearch = emp.name.toLowerCase().contains(_searchQuery) ||
          emp.employeeCode.toLowerCase().contains(_searchQuery);

      // 2. Filtro por estado de enrolamiento
      final count = _embeddingsCount[emp.id] ?? 0;
      final isEnrolled = count == 5;
      bool matchesStatus = true;
      if (_selectedStatus == "Enrolados") {
        matchesStatus = isEnrolled;
      } else if (_selectedStatus == "Pendientes") {
        matchesStatus = !isEnrolled;
      }

      // 3. Filtro por departamento / sección
      bool matchesSection = true;
      if (_selectedSection != "Todos") {
        matchesSection = emp.department == _selectedSection;
      }

      return matchesSearch && matchesStatus && matchesSection;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filtered = _getFilteredEmployees();
    final double screenWidth = MediaQuery.of(context).size.width;
    final int crossAxisCount = screenWidth > 900 ? 4 : (screenWidth > 600 ? 3 : 2);
    final double childAspectRatio = screenWidth > 900 ? 1.05 : (screenWidth > 600 ? 0.9 : 0.8);

    return Scaffold(
      backgroundColor: isDark ? AppColors.kioskBackground : AppColors.background,
      appBar: AppBar(
        title: const Text('Lista de Colaboradores'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
      ),
      body: Column(
        children: [
          // Panel de Filtros
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            color: isDark ? AppColors.kioskSurface : Colors.white,
            child: Column(
              children: [
                // Barra de Búsqueda
                TextField(
                  controller: _searchController,
                  style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Buscar por nombre o cédula...',
                    hintStyle: TextStyle(color: isDark ? Colors.white38 : AppColors.textDisabled),
                    prefixIcon: Icon(Icons.search, color: isDark ? AppColors.kioskAccent : AppColors.primary),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: isDark ? Colors.white10 : AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: isDark ? AppColors.kioskAccent : AppColors.primary),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // Filtro por Estado
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedStatus,
                        dropdownColor: isDark ? AppColors.kioskSurface : Colors.white,
                        style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Estado',
                          labelStyle: TextStyle(color: isDark ? Colors.white60 : AppColors.textSecondary),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        items: ["Todos", "Enrolados", "Pendientes"].map((st) {
                          return DropdownMenuItem(value: st, child: Text(st));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedStatus = val);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Filtro por Sección
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedSection,
                        dropdownColor: isDark ? AppColors.kioskSurface : Colors.white,
                        style: TextStyle(color: isDark ? Colors.white : AppColors.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Sección',
                          labelStyle: TextStyle(color: isDark ? Colors.white60 : AppColors.textSecondary),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        items: _sections.map((sec) {
                          return DropdownMenuItem(value: sec, child: Text(sec));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedSection = val);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Grilla de Colaboradores
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No se encontraron colaboradores.',
                          style: TextStyle(
                            fontSize: 16,
                            color: isDark ? Colors.white38 : AppColors.textSecondary,
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: childAspectRatio,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (ctx, index) {
                          final emp = filtered[index];
                          final count = _embeddingsCount[emp.id] ?? 0;
                          final isEnrolled = count == 5;
                          final isIncomplete = count > 0 && count < 5;

                          return Card(
                            elevation: 3,
                            color: isDark ? AppColors.kioskSurface : Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(
                                color: isDark
                                    ? (isEnrolled
                                        ? AppColors.secondary.withOpacity(0.3)
                                        : (isIncomplete
                                            ? AppColors.warning.withOpacity(0.3)
                                            : Colors.white10))
                                    : (isEnrolled
                                        ? AppColors.secondary.withOpacity(0.3)
                                        : (isIncomplete
                                            ? AppColors.warning.withOpacity(0.3)
                                            : AppColors.border)),
                                width: isEnrolled || isIncomplete ? 2 : 1,
                              ),
                            ),
                            child: InkWell(
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => EnrollmentScreen(employee: emp),
                                  ),
                                );
                                _loadEmployees();
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      radius: 26,
                                      backgroundColor: isEnrolled
                                          ? AppColors.secondary.withOpacity(0.15)
                                          : (isIncomplete
                                              ? AppColors.warning.withOpacity(0.15)
                                              : AppColors.error.withOpacity(0.1)),
                                      child: Icon(
                                        isEnrolled
                                            ? Icons.face_rounded
                                            : (isIncomplete
                                                ? Icons.face_retouching_natural
                                                : Icons.face_retouching_off_rounded),
                                        color: isEnrolled
                                            ? AppColors.secondary
                                            : (isIncomplete
                                                ? AppColors.warning
                                                : AppColors.error),
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      emp.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: isDark ? Colors.white : AppColors.textPrimary,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Cédula: ${emp.employeeCode}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? Colors.white54 : AppColors.textSecondary,
                                      ),
                                    ),
                                    if (emp.department != null && emp.department!.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        emp.department!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isDark ? AppColors.accent : AppColors.primary,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 2),
                                    Text(
                                      emp.horarioId != null
                                          ? 'Horario: ${emp.horarioId}'
                                          : 'Sin horario',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: emp.horarioId != null
                                            ? (isDark ? Colors.white70 : AppColors.textSecondary)
                                            : AppColors.error,
                                        fontWeight: emp.horarioId != null
                                            ? FontWeight.normal
                                            : FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isEnrolled
                                            ? AppColors.secondary.withOpacity(0.1)
                                            : (isIncomplete
                                                ? AppColors.warning.withOpacity(0.1)
                                                : AppColors.error.withOpacity(0.1)),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isEnrolled
                                            ? 'Enrolado ($count/5)'
                                            : (isIncomplete
                                                ? 'Incompleto ($count/5)'
                                                : 'Pendiente'),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: isEnrolled
                                              ? AppColors.secondary
                                              : (isIncomplete
                                                  ? AppColors.warning
                                                  : AppColors.error),
                                        ),
                                      ),
                                    ),
                                  ],
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
