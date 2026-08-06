import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'database_service.dart';

/// Autenticación de supervisor para acciones sensibles del tótem.
///
/// Reemplaza la contraseña que estaba escrita en el código fuente
/// (`'admin2026'` en device_config_screen.dart), que cualquiera podía leer
/// descompilando el APK y era idéntica en todas las sedes.
///
/// La clave se guarda como SHA-256 con sal por dispositivo en `system_config`.
/// Nunca se almacena ni se transmite en texto plano.
class SupervisorAuth {
  static const String _kHash = 'supervisor_pass_hash';
  static const String _kSalt = 'supervisor_pass_salt';
  static const String _kMigrada = 'supervisor_pass_migrada';

  /// Clave inicial. Solo se usa la primera vez, para no dejar el tótem
  /// bloqueado tras la actualización. Debe cambiarse desde Configuración.
  static const String claveInicial = 'admin2026';

  final DatabaseService _database = DatabaseService();

  // ------------------------------------------------------------------
  // Almacenamiento
  // ------------------------------------------------------------------

  String _hash(String password, String salt) =>
      sha256.convert(utf8.encode('$salt::$password')).toString();

  String _nuevaSal() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Asegura que exista una clave configurada. Si el tótem viene de una
  /// versión anterior, siembra [claveInicial] una única vez.
  Future<void> asegurarInicializada() async {
    final yaMigrada = await _database.getConfig(_kMigrada);
    if (yaMigrada == '1') return;

    final hashActual = await _database.getConfig(_kHash);
    if (hashActual == null || hashActual.isEmpty) {
      await cambiarClave(claveInicial);
    }
    await _database.saveConfig(_kMigrada, '1');
  }

  Future<void> cambiarClave(String nueva) async {
    final salt = _nuevaSal();
    await _database.saveConfig(_kSalt, salt);
    await _database.saveConfig(_kHash, _hash(nueva, salt));
  }

  Future<bool> verificar(String intento) async {
    await asegurarInicializada();
    final salt = await _database.getConfig(_kSalt);
    final hash = await _database.getConfig(_kHash);
    if (salt == null || hash == null) return false;
    return _hash(intento, salt) == hash;
  }

  /// true si el tótem sigue usando la clave inicial de fábrica.
  Future<bool> usaClaveDeFabrica() async => verificar(claveInicial);

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  /// Pide la clave de supervisor. Devuelve true solo si es correcta.
  ///
  /// No hay auto-confirmación ni temporizador: una acción que salta un control
  /// de asistencia requiere que un humano esté presente y la autorice.
  Future<bool> solicitar(
    BuildContext context, {
    required String titulo,
    required String motivo,
  }) async {
    await asegurarInicializada();

    final controller = TextEditingController();
    bool intentoFallido = false;

    final resultado = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) => AlertDialog(
          backgroundColor: const Color(0xFF2B3A24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.shield_outlined, color: Colors.amber, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                motivo,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'Se requiere la autorización de un supervisor. '
                'La acción quedará registrada.',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Clave de supervisor',
                  labelStyle: const TextStyle(color: Colors.amber),
                  errorText: intentoFallido ? 'Clave incorrecta' : null,
                  enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54),
                  ),
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.amber),
                  ),
                ),
                onSubmitted: (_) async {
                  final ok = await verificar(controller.text);
                  if (ok) {
                    if (ctx.mounted) Navigator.of(ctx).pop(true);
                  } else {
                    setLocalState(() => intentoFallido = true);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                'Cancelar',
                style: TextStyle(color: Colors.white60),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: const Color(0xFF2B3A24),
              ),
              onPressed: () async {
                final ok = await verificar(controller.text);
                if (ok) {
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } else {
                  setLocalState(() => intentoFallido = true);
                }
              },
              child: const Text(
                'Autorizar',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    return resultado ?? false;
  }
}
