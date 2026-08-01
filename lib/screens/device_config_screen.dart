import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/sql_server_service.dart';
import '../theme/app_colors.dart';

class DeviceConfigScreen extends StatefulWidget {
  const DeviceConfigScreen({super.key});

  @override
  State<DeviceConfigScreen> createState() => _DeviceConfigScreenState();
}

class _DeviceConfigScreenState extends State<DeviceConfigScreen> {
  final _database = DatabaseService();
  final _sqlServer = SqlServerService();

  bool _isAuthenticated = false;
  final _passwordController = TextEditingController();
  String? _errorMessage;

  String? _currentDeviceId;
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = false;
  String? _selectedDeviceId;
  String _selectedIp = SqlServerService.ipPublica;

  @override
  void initState() {
    super.initState();
    _loadCurrentDevice();
  }

  Future<void> _loadCurrentDevice() async {
    final devId = await _database.getDeviceId();
    final customIp = await _database.getConfig('sql_server_ip');
    setState(() {
      _currentDeviceId = devId;
      _selectedDeviceId = devId;
      _selectedIp = customIp ?? SqlServerService.ipPublica;
    });
  }

  Future<void> _fetchDevicesFromServer() async {
    setState(() => _isLoading = true);
    try {
      // Primero asegurar que las tablas existan
      await _sqlServer.asegurarTablasDispositivosEnServidor();
      final list = await _sqlServer.obtenerDispositivosDisponibles();
      setState(() {
        _devices = list;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al conectar con servidor: $e'), backgroundColor: AppColors.error),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onIpChanged(String newIp) async {
    setState(() {
      _selectedIp = newIp;
      _devices = [];
    });
    await _database.saveConfig('sql_server_ip', newIp);
    await _sqlServer.disconnect();
    await _fetchDevicesFromServer();
  }

  void _verifyPassword() {
    if (_passwordController.text.trim() == 'admin2026') {
      setState(() {
        _isAuthenticated = true;
        _errorMessage = null;
      });
      _fetchDevicesFromServer();
    } else {
      setState(() {
        _errorMessage = 'Contraseña incorrecta';
      });
    }
  }

  Future<void> _saveConfiguration() async {
    if (_selectedDeviceId == null) return;

    setState(() => _isLoading = true);
    try {
      final success = await _sqlServer.registrarUsoDispositivo(_selectedDeviceId!, _currentDeviceId);
      if (success) {
        await _database.saveDeviceId(_selectedDeviceId!);
        setState(() {
          _currentDeviceId = _selectedDeviceId;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('¡Dispositivo configurado con éxito!'),
              backgroundColor: AppColors.success,
            ),
          );
        }
        _fetchDevicesFromServer(); // Recargar estados
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No se pudo registrar en el servidor central.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración del Tótem'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: isDark ? Colors.white : Colors.black,
      ),
      backgroundColor: isDark ? AppColors.kioskBackground : AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: !_isAuthenticated ? _buildLoginView(isDark) : _buildSelectionView(isDark),
        ),
      ),
    );
  }

  Widget _buildLoginView(bool isDark) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? AppColors.kioskSurface : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: AppColors.secondary),
            const SizedBox(height: 16),
            const Text(
              'Acceso de Administrador',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ingrese la contraseña de seguridad para configurar esta tablet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Contraseña',
                errorText: _errorMessage,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onSubmitted: (_) => _verifyPassword(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.secondary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _verifyPassword,
              child: const Text('Verificar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionView(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Estado actual
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppColors.kioskSurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
          ),
          child: Row(
            children: [
              const Icon(Icons.tablet_android, color: AppColors.primary, size: 36),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Tótem Asignado Actualmente', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(
                      _currentDeviceId ?? 'SIN CONFIGURAR',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.success),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Conexión del Servidor
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppColors.kioskSurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Conexión al Servidor SQL', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _isLoading ? null : () => _onIpChanged(SqlServerService.ipPublica),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                        decoration: BoxDecoration(
                          color: _selectedIp == SqlServerService.ipPublica
                              ? AppColors.primary.withOpacity(0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _selectedIp == SqlServerService.ipPublica
                                ? AppColors.primary
                                : (isDark ? Colors.white10 : Colors.black12),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'IP Pública',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _selectedIp == SqlServerService.ipPublica ? AppColors.primary : (isDark ? Colors.white : Colors.black87),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(SqlServerService.ipPublica, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: _isLoading ? null : () => _onIpChanged(SqlServerService.ipLocal),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                        decoration: BoxDecoration(
                          color: _selectedIp == SqlServerService.ipLocal
                              ? AppColors.primary.withOpacity(0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _selectedIp == SqlServerService.ipLocal
                                ? AppColors.primary
                                : (isDark ? Colors.white10 : Colors.black12),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'IP Local',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _selectedIp == SqlServerService.ipLocal ? AppColors.primary : (isDark ? Colors.white : Colors.black87),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(SqlServerService.ipLocal, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Selecciona un Dispositivo Disponible en SQL Server',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('No se encontraron dispositivos autorizados.'),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _fetchDevicesFromServer,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reintentar'),
                          )
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (context, index) {
                        final dev = _devices[index];
                        final String devId = dev['id_dispositivo'] ?? dev['ID_DISPOSITIVO'];
                        final String desc = dev['descripcion'] ?? dev['DESCRIPCION'] ?? '';
                        final int enUso = int.tryParse(dev['en_uso']?.toString() ?? '0') ?? 0;
                        final bool isCurrent = devId == _currentDeviceId;

                        return Card(
                          color: isDark ? Colors.white.withOpacity(0.03) : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: _selectedDeviceId == devId
                                  ? AppColors.primary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: ListTile(
                            leading: Radio<String>(
                              value: devId,
                              groupValue: _selectedDeviceId,
                              onChanged: (val) {
                                setState(() {
                                  _selectedDeviceId = val;
                                });
                              },
                            ),
                            title: Text(devId, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text(desc),
                            trailing: isCurrent
                                ? const Chip(
                                    label: Text('Asignado a esta Tablet', style: TextStyle(fontSize: 11)),
                                    backgroundColor: Colors.green,
                                    labelStyle: TextStyle(color: Colors.white),
                                  )
                                : enUso == 1
                                    ? const Chip(
                                        label: Text('En Uso (Otra Tablet)', style: TextStyle(fontSize: 11)),
                                        backgroundColor: Colors.orange,
                                        labelStyle: TextStyle(color: Colors.white),
                                      )
                                    : const Chip(
                                        label: Text('Libre', style: TextStyle(fontSize: 11)),
                                        backgroundColor: Colors.blue,
                                        labelStyle: TextStyle(color: Colors.white),
                                      ),
                          ),
                        );
                      },
                    ),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _selectedDeviceId == null || _isLoading ? null : _saveConfiguration,
          child: const Text(
            'Confirmar y Asignar Tótem',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
      ],
    );
  }
}
