import 'package:flutter/material.dart';
import 'attendance_screen.dart';
import 'attendance_list_screen.dart';
import 'employee_list_screen.dart';
import 'absence_screen.dart';
import '../services/sync_service.dart';
import '../theme/app_colors.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _syncService = SyncService();
  bool _isSyncing = false;

  Future<void> _sincronizarDatos() async {
    setState(() => _isSyncing = true);
    try {
      await _syncService.sincronizarDesdeSqlServer();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('¡Datos sincronizados con éxito desde SQL Server!'),
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
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [AppColors.kioskBackground, const Color(0xFF131D10)]
                : [AppColors.background, const Color(0xFFECE7E1)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 32.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Center(
                  child: Hero(
                    tag: 'appLogo',
                    child: Icon(
                      Icons.face_unlock_outlined,
                      size: 100,
                      color: isDark ? AppColors.kioskAccent : AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Registro de asistencia',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : AppColors.textPrimary,
                    letterSpacing: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Sistema de Control de Asistencia Facial',
                  style: TextStyle(
                    fontSize: 16,
                    color: isDark ? Colors.white70 : AppColors.textSecondary,
                    fontWeight: FontWeight.w300,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _buildOptionCard(
                  context,
                  icon: Icons.people_alt_rounded,
                  title: 'Lista de Colaboradores',
                  subtitle: 'Ver, enrolar y gestionar personal',
                  color: AppColors.accent,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const EmployeeListScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildOptionCard(
                  context,
                  icon: Icons.camera_front_rounded,
                  title: 'Marcar Asistencia',
                  subtitle: 'Escanear rostro para entrada/salida',
                  color: AppColors.secondary,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AttendanceScreen()),
                  ),
                ),
                const SizedBox(height: 16),
                _buildOptionCard(
                  context,
                  icon: Icons.sync_rounded,
                  title: 'Sincronizar Servidor',
                  subtitle: _isSyncing
                      ? 'Sincronizando...'
                      : 'Actualizar empleados y horarios',
                  color: AppColors.accent,
                  trailing: _isSyncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        )
                      : null,
                  onPressed: _isSyncing ? () {} : _sincronizarDatos,
                ),
                const SizedBox(height: 16),
                _buildOptionCard(
                  context,
                  icon: Icons.assessment_rounded,
                  title: 'Panel de Reportes',
                  subtitle: 'Estadísticas, filtrado y exportación',
                  color: AppColors.primaryDark,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AttendanceListScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildOptionCard(
                  context,
                  icon: Icons.calendar_today_rounded,
                  title: 'Gestión de Ausencias',
                  subtitle: 'Visualizar y justificar faltas diarias',
                  color: AppColors.secondary,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AbsenceScreen()),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOptionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onPressed,
    Widget? trailing,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: 4,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: isDark ? AppColors.kioskSurface : Colors.white,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 18.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 30, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? Colors.white60
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              trailing ??
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 18,
                    color: isDark ? Colors.white30 : AppColors.textDisabled,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
