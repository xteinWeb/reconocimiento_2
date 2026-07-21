import 'package:camera/camera.dart';

class CameraService {
  CameraController? _controller;
  List<CameraDescription>? _cameras;

  Future<void> initialize() async {
    _cameras = await availableCameras();
    if (_cameras == null || _cameras!.isEmpty) return;

    // Usar cámara frontal para reconocimiento facial
    final frontCamera = _cameras!.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras!.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _controller!.initialize();

    // Configurar exposición para evitar sobreexposición
    await _controller!.setExposureMode(ExposureMode.auto);
    await _controller!.setFlashMode(FlashMode.off);
  }

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  Future<XFile?> takePicture() async {
    if (!isInitialized) return null;
    return await _controller!.takePicture();
  }

  void dispose() {
    _controller?.dispose();
    _controller = null;
  }
}
