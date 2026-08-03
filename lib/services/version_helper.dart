import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'sql_server_service.dart';

class VersionHelper {
  // Versión local actual de la aplicación
  static const int currentVersionCode = 2;
  static const String currentVersionName = "2.0.0";

  final SqlServerService _sqlServer = SqlServerService();

  /// Compara el link de Drive y lo convierte a formato de descarga directa si es necesario
  static String obtenerEnlaceDescargaDirecta(String url) {
    if (url.contains("drive.google.com/file/d/")) {
      final regExp = RegExp(r'/d/([^/]+)');
      final match = regExp.firstMatch(url);
      if (match != null && match.groupCount >= 1) {
        final fileId = match.group(1);
        return "https://drive.google.com/uc?export=download&id=$fileId";
      }
    }
    return url;
  }

  /// Verifica si hay actualizaciones disponibles en SQL Server
  Future<void> verificarActualizacion(BuildContext context, {bool mostrarAvisoSinNovedades = false}) async {
    try {
      // Primero, asegurarse de que las tablas existan
      await _sqlServer.asegurarTablasDispositivosEnServidor();
      final latestVersion = await _sqlServer.obtenerVersionMasReciente();

      if (latestVersion == null) {
        if (mostrarAvisoSinNovedades && context.mounted) {
          _mostrarMensaje(context, "Sincronización de Versión", "No se encontró información de versiones en el servidor.");
        }
        return;
      }

      final int serverVersionCode = latestVersion['version_code'] as int;
      final String serverVersionName = latestVersion['version_name']?.toString() ?? "1.0.0";
      final String rawUrlApk = latestVersion['url_apk']?.toString() ?? "";

      if (serverVersionCode > currentVersionCode) {
        if (!context.mounted) return;

        final directUrl = obtenerEnlaceDescargaDirecta(rawUrlApk);

        showDialog(
          context: context,
          barrierDismissible: true, // No bloqueante, se puede cerrar pulsando fuera
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.system_update_rounded, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('Actualización Disponible'),
              ],
            ),
            content: Text(
              'Hay una nueva versión de la aplicación disponible en el servidor.\n\n'
              '• Versión Instalada: v$currentVersionName (Build $currentVersionCode)\n'
              '• Versión Nueva: v$serverVersionName (Build $serverVersionCode)\n\n'
              '¿Deseas descargar el APK e instalarlo ahora?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Más tarde', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  final Uri uri = Uri.parse(directUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } else {
                    if (context.mounted) {
                      _mostrarMensaje(context, "Error", "No se pudo abrir el enlace de descarga:\n$directUrl");
                    }
                  }
                },
                child: const Text('Actualizar ahora'),
              ),
            ],
          ),
        );
      } else {
        if (mostrarAvisoSinNovedades && context.mounted) {
          _mostrarMensaje(
            context,
            "Sincronización de Versión",
            "La aplicación ya está actualizada a la versión más reciente:\n"
            "v$currentVersionName (Build $currentVersionCode)",
          );
        }
      }
    } catch (e) {
      debugPrint("[VersionHelper] Error al verificar versión: $e");
      if (mostrarAvisoSinNovedades && context.mounted) {
        _mostrarMensaje(context, "Error de Conexión", "No se pudo comprobar la versión en el servidor:\n$e");
      }
    }
  }

  static void _mostrarMensaje(BuildContext context, String titulo, String mensaje) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Text(mensaje),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
  }
}
