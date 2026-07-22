import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../models/employee.dart';
import '../models/face_embedding.dart';
import '../services/camera_service.dart';
import '../services/face_detection_service.dart';
import '../services/face_recognition_service.dart';
import '../services/database_service.dart';
import '../services/light_quality_service.dart';
import '../services/sync_service.dart';

import '../theme/app_colors.dart';

class EnrollmentScreen extends StatefulWidget {
  final Employee employee;
  const EnrollmentScreen({super.key, required this.employee});

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen> {
  final _cameraService = CameraService();
  final _faceDetection = FaceDetectionService();
  final _faceRecognition = FaceRecognitionService();
  final _database = DatabaseService();
  final _lightQuality = LightQualityService();
  final _syncService = SyncService();

  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _deptController = TextEditingController();

  int _currentPoseIndex = 0;
  bool _isProcessing = false;
  bool _isCapturing = false;
  String _status = "Pulsa 'Iniciar Captura' para registrar las 5 poses";
  String _lightStatus = "";
  Color _lightColor = Colors.grey;

  int? _employeeId;
  bool _showForm = true;

  final List<Map<String, dynamic>> _poses = [
    {
      'name': 'Frontal',
      'yawMin': -8.0,
      'yawMax': 8.0,
      'pitchMin': -8.0,
      'pitchMax': 8.0,
      'emoji': '🙂',
      'description': 'Mira de frente',
    },
    {
      'name': 'Izquierda',
      'yawMin': -45.0,
      'yawMax': -10.0,
      'pitchMin': -12.0,
      'pitchMax': 12.0,
      'emoji': '👉',
      'description': 'Gira la cabeza a la izquierda',
    },
    {
      'name': 'Derecha',
      'yawMin': 10.0,
      'yawMax': 45.0,
      'pitchMin': -12.0,
      'pitchMax': 12.0,
      'emoji': '👈',
      'description': 'Gira la cabeza a la derecha',
    },
    {
      'name': 'Arriba',
      'yawMin': -12.0,
      'yawMax': 12.0,
      'pitchMin': -35.0,
      'pitchMax': -8.0,
      'emoji': '👆',
      'description': 'Mira hacia arriba ligeramente',
    },
    {
      'name': 'Sonrisa',
      'yawMin': -8.0,
      'yawMax': 8.0,
      'pitchMin': -8.0,
      'pitchMax': 8.0,
      'emoji': '😊',
      'description': 'Sonríe de frente',
    },
  ];

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.employee.name;
    _codeController.text = widget.employee.employeeCode;
    _deptController.text = widget.employee.department ?? '';
    _employeeId = widget.employee.id;
    _initialize();
  }

  Future<void> _initialize() async {
    await _cameraService.initialize();
    await _faceRecognition.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _startEnrollment() async {
    try {
      final db = await _database.database;
      await db.delete(
        'face_embeddings',
        where: 'employee_id = ?',
        whereArgs: [_employeeId],
      );
    } catch (e) {
      print('[Enrollment] Error al limpiar embeddings locales anteriores: $e');
    }

    setState(() {
      _showForm = false;
      _isCapturing = true;
      _status = "Mira directo a la cámara para iniciar";
    });
    _startDetectionLoop();
  }

  void _startDetectionLoop() {
    Timer.periodic(const Duration(milliseconds: 600), (timer) async {
      if (!mounted || !_isCapturing || _currentPoseIndex >= _poses.length) {
        timer.cancel();
        return;
      }

      if (_isProcessing) return;
      setState(() => _isProcessing = true);

      try {
        final file = await _cameraService.takePicture();
        if (file == null) {
          setState(() => _isProcessing = false);
          return;
        }

        final bytes = await file.readAsBytes();
        final lightResult = _lightQuality.analyzeImage(bytes);

        setState(() {
          _lightStatus = lightResult.feedback;
          _lightColor = lightResult.feedbackColor;
        });

        if (lightResult.isOverexposed ||
            lightResult.isBacklit ||
            lightResult.isTooDark) {
          setState(() {
            _status = lightResult.feedback;
            _isProcessing = false;
          });
          return;
        }

        final result = await _faceDetection.detectFace(file.path);
        if (result == null) {
          setState(() {
            _status = "No se detecta rostro";
            _isProcessing = false;
          });
          return;
        }

        final pose = _poses[_currentPoseIndex];

        // Anti-spoofing / Pose verify
        final isPoseMatch = result.isValidPose({
          'yawMin': pose['yawMin']!,
          'yawMax': pose['yawMax']!,
          'pitchMin': pose['pitchMin']!,
          'pitchMax': pose['pitchMax']!,
        });

        if (isPoseMatch) {
          final cropped = await _faceDetection.cropFace(
            file.path,
            result.boundingBox,
          );
          if (cropped != null) {
            final embedding = _faceRecognition.getEmbedding(cropped);
            await _database.saveEmbedding(
              _employeeId!,
              embedding,
              pose['name'] as String,
            );

            setState(() {
              _currentPoseIndex++;
              if (_currentPoseIndex < _poses.length) {
                _status =
                    "Paso completado. Siguiente: ${_poses[_currentPoseIndex]['description']}";
              } else {
                _status = "🎉 ¡Enrolamiento completado localmente!";
                _isCapturing = false;
                _subirAlServidor();
              }
            });
          }
        } else {
          setState(() {
            _status =
                "${pose['description']}\n(Ángulos actual: Yaw: ${result.yaw.toStringAsFixed(0)}°, Pitch: ${result.pitch.toStringAsFixed(0)}°)";
          });
        }
      } catch (e) {
        setState(() {
          _status = "Error en procesamiento: $e";
        });
      } finally {
        setState(() => _isProcessing = false);
      }
    });
  }

  Future<void> _subirAlServidor() async {
    setState(() {
      _status = "Sincronizando enrolamiento con SQL Server central...";
    });
    try {
      final embeddings = await _database.getEmbeddingsByEmployee(_employeeId!);

      // Orden esperado por el servidor central de SQL Server
      final expectedPoses = [
        'Frontal',
        'Izquierda',
        'Derecha',
        'Arriba',
        'Sonrisa',
      ];
      final sortedPoses = <List<double>>[];

      for (final poseName in expectedPoses) {
        final match = embeddings.firstWhere(
          (e) => e.angleType == poseName,
          orElse: () => FaceEmbedding(
            employeeId: _employeeId!,
            embedding: List.filled(192, 0.0),
            angleType: poseName,
            createdAt: DateTime.now(),
          ),
        );
        sortedPoses.add(match.embedding);
      }

      final success = await _syncService.subirEnrolamiento(
        cedula: _codeController.text.trim(),
        nombre: _nameController.text.trim(),
        poses: sortedPoses,
        departamento: _deptController.text.isEmpty
            ? null
            : _deptController.text.trim(),
      );

      setState(() {
        if (success) {
          _status =
              "🎉 ¡Enrolamiento completado y sincronizado con SQL Server!";
        } else {
          _status = "⚠️ Guardado localmente. Error de conexión con SQL Server.";
        }
      });
    } catch (e) {
      setState(() {
        _status = "⚠️ Error al sincronizar: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? AppColors.kioskBackground
          : AppColors.background,
      appBar: AppBar(
        title: const Text('Enrolamiento Guiado'),
        foregroundColor: isDark ? Colors.white : AppColors.textPrimary,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _showForm ? _buildForm() : _buildCaptureUI(),
    );
  }

  Widget _buildForm() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.assignment_ind_outlined,
            size: 80,
            color: isDark ? AppColors.kioskAccent : AppColors.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Enrolar Colaborador',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Detalles del colaborador para el enrolamiento de 5 poses faciales.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white60 : AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _nameController,
            readOnly: true,
            style: TextStyle(
              color: isDark ? Colors.white : AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              labelText: 'Nombre Completo',
              labelStyle: TextStyle(
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
              prefixIcon: Icon(
                Icons.person,
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? Colors.white24 : AppColors.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? AppColors.kioskAccent : AppColors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _codeController,
            readOnly: true,
            style: TextStyle(
              color: isDark ? Colors.white : AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              labelText: 'Código de Empleado (Cédula)',
              labelStyle: TextStyle(
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
              prefixIcon: Icon(
                Icons.badge,
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? Colors.white24 : AppColors.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? AppColors.kioskAccent : AppColors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _deptController,
            readOnly: true,
            style: TextStyle(
              color: isDark ? Colors.white : AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              labelText: 'Sección',
              labelStyle: TextStyle(
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
              prefixIcon: Icon(
                Icons.business,
                color: isDark ? Colors.white60 : AppColors.textSecondary,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? Colors.white24 : AppColors.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? AppColors.kioskAccent : AppColors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: _startEnrollment,
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? AppColors.kioskAccent
                  : AppColors.primary,
              foregroundColor: isDark ? Colors.black87 : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text(
              'Siguiente: Captura Biométrica',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureUI() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _cameraService.isInitialized
                  ? CameraPreview(_cameraService.controller!)
                  : const Center(
                      child: CircularProgressIndicator(
                        color: Colors.tealAccent,
                      ),
                    ),
              Center(
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    border: Border.all(color: _lightColor, width: 3),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _lightColor.withOpacity(0.2),
                        blurRadius: 15,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_lightStatus.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _lightColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _lightColor, width: 1),
                  ),
                  child: Text(
                    _lightStatus,
                    style: TextStyle(
                      color: _lightColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: _poses.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final pose = entry.value;
                  final isDone = idx < _currentPoseIndex;
                  final isCurrent = idx == _currentPoseIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: isCurrent ? 46 : 38,
                    height: isCurrent ? 46 : 38,
                    decoration: BoxDecoration(
                      color: isDone
                          ? Colors.teal
                          : (isCurrent ? Colors.tealAccent : Colors.white12),
                      shape: BoxShape.circle,
                      border: isCurrent
                          ? Border.all(color: Colors.white, width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        isDone ? '✓' : pose['emoji'] as String,
                        style: TextStyle(
                          fontSize: isCurrent ? 20 : 16,
                          color: isDone || isCurrent
                              ? Colors.black87
                              : Colors.white38,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              Text(
                _status,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              if (_currentPoseIndex >= _poses.length)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black87,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      minimumSize: const Size(double.infinity, 50),
                    ),
                    child: const Text(
                      'Finalizar y Regresar',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _faceDetection.dispose();
    _faceRecognition.dispose();
    _nameController.dispose();
    _codeController.dispose();
    _deptController.dispose();
    super.dispose();
  }
}
