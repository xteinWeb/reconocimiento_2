import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/camera_service.dart';
import '../services/face_detection_service.dart';
import '../services/face_recognition_service.dart';
import '../services/database_service.dart';
import '../services/light_quality_service.dart';
import '../models/employee.dart';

enum ScanState { idle, success, failure }

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final _cameraService = CameraService();
  final _faceDetection = FaceDetectionService();
  final _faceRecognition = FaceRecognitionService();
  final _database = DatabaseService();
  final _lightQuality = LightQualityService();

  String _status = "Mira a la cámara para marcar";
  String _lightStatus = "";
  Color _lightColor = Colors.grey;
  bool _isProcessing = false;
  bool _isAutoMode = true; // Habilitado por defecto para facilitar el flujo
  Timer? _autoTimer;

  // Estado del resultado de escaneo para feedback visual
  ScanState _scanState = ScanState.idle;
  Employee? _recognizedEmployee;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _cameraService.initialize();
    await _faceRecognition.initialize();
    if (mounted) {
      setState(() {});
      if (_isAutoMode) {
        _startAutoTimer();
      }
    }
  }

  void _startAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(seconds: 2), (_) => _markAttendance());
  }

  Future<void> _markAttendance() async {
    if (_isProcessing || !mounted) return;
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

      if (lightResult.isOverexposed || lightResult.isBacklit || lightResult.isTooDark) {
        setState(() {
          _status = lightResult.feedback;
          _isProcessing = false;
        });
        return;
      }

      final detection = await _faceDetection.detectFace(file.path);
      if (detection == null) {
        setState(() {
          _status = "Buscando rostro...";
          _isProcessing = false;
        });
        return;
      }

      final cropped = await _faceDetection.cropFace(file.path, detection.boundingBox);
      if (cropped == null) {
        setState(() {
          _status = "Ajustando encuadre...";
          _isProcessing = false;
        });
        return;
      }

      final currentEmbedding = _faceRecognition.getEmbedding(cropped);
      final allEmbeddings = await _database.getAllEmbeddings();

      if (allEmbeddings.isEmpty) {
        setState(() {
          _status = "No hay colaboradores enrolados en el dispositivo.";
          _scanState = ScanState.failure;
          _isProcessing = false;
        });
        return;
      }

      final (matchedId, distance) = _faceRecognition.findNearest(currentEmbedding, allEmbeddings);
      const threshold = 0.65; // Umbral de distancia coseno

      if (distance < threshold && matchedId != null) {
        final employee = await _database.getEmployeeById(matchedId);
        if (employee != null) {
          await _database.insertAttendance(matchedId, DateTime.now(), distance);
          setState(() {
            _scanState = ScanState.success;
            _recognizedEmployee = employee;
            _status = "¡Asistencia registrada!";
          });
          // Limpiar el estado de éxito después de 3 segundos
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) {
              setState(() {
                _scanState = ScanState.idle;
                _recognizedEmployee = null;
                _status = "Mira a la cámara para marcar";
              });
            }
          });
        }
      } else {
        setState(() {
          _scanState = ScanState.failure;
          _status = "Rostro no reconocido.";
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _scanState == ScanState.failure) {
            setState(() {
              _scanState = ScanState.idle;
              _status = "Mira a la cámara para marcar";
            });
          }
        });
      }
    } catch (e) {
      setState(() => _status = "Error: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _toggleAutoMode(bool value) {
    setState(() {
      _isAutoMode = value;
      if (_isAutoMode) {
        _status = "Modo automático activado...";
        _startAutoTimer();
      } else {
        _autoTimer?.cancel();
        _status = "Presiona Marcar para escanear";
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Color ringColor = Colors.white;
    if (_scanState == ScanState.success) {
      ringColor = Colors.greenAccent;
    } else if (_scanState == ScanState.failure) {
      ringColor = Colors.redAccent;
    } else if (_lightStatus.isNotEmpty) {
      ringColor = _lightColor;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Marcado de Asistencia'),
        foregroundColor: Colors.white,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Row(
            children: [
              const Text('Auto', style: TextStyle(color: Colors.white70, fontSize: 13)),
              Switch(
                value: _isAutoMode,
                onChanged: _toggleAutoMode,
                activeColor: Colors.cyanAccent,
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _cameraService.isInitialized
                    ? CameraPreview(_cameraService.controller!)
                    : const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),

                // Overlay de cámara según estado de escaneo
                if (_scanState == ScanState.success)
                  Container(color: Colors.green.withOpacity(0.15)),
                if (_scanState == ScanState.failure)
                  Container(color: Colors.red.withOpacity(0.15)),

                // Ring guía de la cara
                Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 255,
                    height: 255,
                    decoration: BoxDecoration(
                      border: Border.all(color: ringColor, width: 3.5),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: ringColor.withOpacity(0.2),
                          blurRadius: 15,
                          spreadRadius: 3,
                        )
                      ],
                    ),
                    child: _scanState == ScanState.success
                        ? const Center(
                            child: Icon(Icons.check_circle_outline_rounded,
                                color: Colors.greenAccent, size: 80),
                          )
                        : (_scanState == ScanState.failure
                            ? const Center(
                                child: Icon(Icons.error_outline_rounded,
                                    color: Colors.redAccent, size: 80),
                              )
                            : null),
                  ),
                ),

                // Tarjeta de confirmación del empleado en caso de éxito
                if (_scanState == ScanState.success && _recognizedEmployee != null)
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Card(
                      color: const Color(0xFF1E1E1E),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(color: Colors.greenAccent, width: 1.5),
                      ),
                      elevation: 10,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        child: Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor: Colors.green,
                              radius: 26,
                              child: Icon(Icons.person, color: Colors.white, size: 30),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _recognizedEmployee!.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Código: ${_recognizedEmployee!.employeeCode}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                                  ),
                                  if (_recognizedEmployee!.department != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Depto: ${_recognizedEmployee!.department}',
                                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: _lightColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _lightColor, width: 1),
                    ),
                    child: Text(
                      _lightStatus,
                      style: TextStyle(color: _lightColor, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (!_isAutoMode) ...[
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _markAttendance,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black87,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      minimumSize: const Size(double.infinity, 50),
                    ),
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87),
                          )
                        : const Icon(Icons.camera_front_rounded),
                    label: const Text('Marcar Asistencia', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _cameraService.dispose();
    _faceDetection.dispose();
    _faceRecognition.dispose();
    super.dispose();
  }
}
