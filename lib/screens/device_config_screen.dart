import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/sql_server_service.dart';
import '../services/version_helper.dart';
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

  double _threshold = 0.22;
  int _minFaceSize = 130;
  double _centerTolerance = 0.15;

  final _versionNameController = TextEditingController();
  final _versionCodeController = TextEditingController();
  final _urlApkController = TextEditingController();
  bool _isPublishing = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentDevice();
  }

  Future<void> _loadCurrentDevice() async {
    final devId = await _database.getDeviceId();
    final customIp = await _database.getConfig('sql_server_ip');
    final tStr = await _database.getConfig('recognition_threshold');
    final sStr = await _database.getConfig('min_face_size');
    final cStr = await _database.getConfig('center_tolerance');

    setState(() {
      _currentDeviceId = devId;
      _selectedDeviceId = devId;
      _selectedIp = customIp ?? SqlServerService.ipPublica;
      if (tStr != null) _threshold = double.tryParse(tStr) ?? 0.22;
      if (sStr != null) _minFaceSize = int.tryParse(sStr) ?? 130;
      if (cStr != null) _centerTolerance = double.tryParse(cStr) ?? 0.15;
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

  Future<void> _publicarVersion() async {
    final vName = _versionNameController.text.trim();
    final vCodeStr = _versionCodeController.text.trim();
    final urlApk = _urlApkController.text.trim();

    if (vName.isEmpty || vCodeStr.isEmpty || urlApk.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor, completa todos los campos del publicador.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    final vCode = int.tryParse(vCodeStr);
    if (vCode == null || vCode <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El código de versión debe ser un entero mayor que cero.'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _isPublishing = true);
    try {
      final success = await _sqlServer.publicarNuevaVersion(
        versionCode: vCode,
        versionName: vName,
        urlApk: urlApk,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('¡Nueva versión publicada con éxito en el servidor!'),
            backgroundColor: AppColors.success,
          ),
        );
        _versionNameController.clear();
        _versionCodeController.clear();
        _urlApkController.clear();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al guardar versión en SQL Server.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isPublishing = false);
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _versionNameController.dispose();
    _versionCodeController.dispose();
    _urlApkController.dispose();
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
    return ListView(
      physics: const BouncingScrollPhysics(),
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
        const SizedBox(height: 16),
        
        // Calibración del Entorno
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
              const Row(
                children: [
                  Icon(Icons.tune_rounded, color: AppColors.primary, size: 24),
                  SizedBox(width: 12),
                  Text(
                    'Calibración del Entorno',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // Umbral de Distancia Coseno
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Sensibilidad (Umbral Distancia)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(
                    _threshold.toStringAsFixed(2),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary),
                  ),
                ],
              ),
              const Text(
                'Menores valores reducen falsos positivos pero exigen una pose más exacta.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              Slider(
                value: _threshold.clamp(0.15, 0.45),
                min: 0.15,
                max: 0.45,
                divisions: 30,
                activeColor: AppColors.primary,
                label: _threshold.toStringAsFixed(2),
                onChanged: (val) {
                  setState(() => _threshold = val);
                  _database.saveConfig('recognition_threshold', val.toString());
                },
              ),
              const SizedBox(height: 8),

              // Tamaño Mínimo de Rostro
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Tamaño Mínimo del Rostro', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(
                    '${_minFaceSize}px',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary),
                  ),
                ],
              ),
              const Text(
                'Filtra caras lejanas. El usuario deberá acercarse para ser detectado.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              Slider(
                value: _minFaceSize.toDouble(),
                min: 80,
                max: 250,
                divisions: 17,
                activeColor: AppColors.primary,
                label: '${_minFaceSize}px',
                onChanged: (val) {
                  setState(() => _minFaceSize = val.toInt());
                  _database.saveConfig('min_face_size', val.toInt().toString());
                },
              ),
              const SizedBox(height: 8),

              // Tolerancia de Centrado
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Tolerancia de Centrado', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(
                    '${(_centerTolerance * 100).toInt()}%',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary),
                  ),
                ],
              ),
              const Text(
                'Define qué tan alejado del centro del círculo guía puede estar el rostro.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              Slider(
                value: _centerTolerance,
                min: 0.05,
                max: 0.30,
                divisions: 25,
                activeColor: AppColors.primary,
                label: '${(_centerTolerance * 100).toInt()}%',
                onChanged: (val) {
                  setState(() => _centerTolerance = val);
                  _database.saveConfig('center_tolerance', val.toString());
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Publicar Actualización de App
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
              const Row(
                children: [
                  Icon(Icons.publish_rounded, color: AppColors.primary, size: 24),
                  SizedBox(width: 12),
                  Text(
                    'Publicar Actualización de App',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Completa estos datos para registrar una nueva actualización y notificar a todas las sedes.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Versión actual en ejecución: v${VersionHelper.currentVersionName} (Build ${VersionHelper.currentVersionCode})',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _versionNameController,
                decoration: InputDecoration(
                  labelText: 'Nombre de Versión (Ej: 2.1.0)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  prefixIcon: const Icon(Icons.label_outline_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _versionCodeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Código de Versión (Ej: 3)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  prefixIcon: const Icon(Icons.onetwothree_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlApkController,
                decoration: InputDecoration(
                  labelText: 'Enlace de Google Drive del APK',
                  hintText: 'https://drive.google.com/file/d/...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  prefixIcon: const Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.secondary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _isPublishing ? null : _publicarVersion,
                icon: _isPublishing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_rounded),
                label: const Text('Publicar Nueva Versión en Servidor', style: TextStyle(fontWeight: FontWeight.bold)),
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
        _isLoading
            ? const Center(child: Padding(
                padding: EdgeInsets.all(24.0),
                child: CircularProgressIndicator(),
              ))
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
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
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
