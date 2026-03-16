import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:apple_vision_commons/apple_vision_commons.dart';
import 'package:apple_vision_hand/apple_vision_hand.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hand_landmarker/hand_landmarker.dart' as hl;
import 'package:permission_handler/permission_handler.dart';
import '../services/sync_service.dart';

class CameraScreen extends StatefulWidget {
  final String projectLink;

  const CameraScreen({super.key, required this.projectLink});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _isInitialized = false;
  String _statusText = 'Başlatılıyor...';
  bool _permissionDenied = false;
  bool _isDetecting = false;

  late SyncService _sync;

  // El takibi state
  double? _pointerX;
  double? _pointerY;
  bool _isPinching = false;
  bool _isErasing = false;
  List<Map<String, double>> _currentStroke = [];
  bool _wasPinching = false;
  bool _wasErasing = false;
  int _frameSkip = 0;

  hl.HandLandmarkerPlugin? _handPlugin;
  AppleVisionHandController? _appleVisionController;

  // Yüz takibi
  late FaceDetector _faceDetector;
  bool _isFaceDetecting = false;
  bool _leftEyeOpen = true;
  bool _rightEyeOpen = true;
  bool _isSmiling = false;
  double? _headAngleY;
  double? _headAngleZ;
  String _faceGesture = '';
  Rect? _faceRect;

  static const _pinchStart = 0.12;
  static const _pinchRelease = 0.15;
  static const _eraseStart = 0.12;
  static const _eraseRelease = 0.16;

  @override
  void initState() {
    super.initState();
    _sync = SyncService(widget.projectLink);
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableTracking: true,
        enableLandmarks: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    _init();
  }

  Future<void> _init() async {
    setState(() => _permissionDenied = false);
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      if (mounted) {
        setState(() {
          _statusText = 'Kamerayı kullanmak için izin verin';
          _permissionDenied = true;
        });
      }
      return;
    }
    setState(() => _statusText = 'Kamera açılıyor...');
    await _startCamera();
  }

  Future<void> _requestPermissionAndStart() async {
    setState(() => _statusText = 'İzin isteniyor...');
    final status = await Permission.camera.request();
    if (status.isGranted) {
      setState(() => _permissionDenied = false);
      await _startCamera();
    } else if (mounted) {
      setState(() {
        _statusText = 'Kamerayı kullanmak için izin verin';
        _permissionDenied = true;
      });
    }
  }

  Future<void> _startCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _statusText = 'Kamera bulunamadı');
        return;
      }

      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;

      if (Platform.isAndroid) {
        try {
          _handPlugin = hl.HandLandmarkerPlugin.create(
            numHands: 1,
            minHandDetectionConfidence: 0.3,
            delegate: hl.HandLandmarkerDelegate.gpu,
          );
        } catch (_) {
          _handPlugin = hl.HandLandmarkerPlugin.create(
            numHands: 1,
            minHandDetectionConfidence: 0.3,
            delegate: hl.HandLandmarkerDelegate.cpu,
          );
        }
      } else if (Platform.isIOS) {
        _appleVisionController = AppleVisionHandController();
      }

      await _initCamera();
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _statusText = 'Başparmak+İşaret = Çiz | İşaret+Orta = Sil';
        });
      }

      final hasHandTracking = (Platform.isAndroid && _handPlugin != null) ||
          (Platform.isIOS && _appleVisionController != null);
      if (hasHandTracking) {
        await _controller!.startImageStream(_processCameraImage);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = 'Hata: $e');
      }
    }
  }

  Future<void> _initCamera() async {
    final cam = _cameras[_cameraIndex];
    _controller = CameraController(
      cam,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
  }

  void _processCameraImage(CameraImage image) {
    if (!mounted) return;
    _frameSkip++;
    if (_frameSkip % 2 != 0) return;

    if (!_isDetecting) {
      if (Platform.isAndroid && _handPlugin != null) {
        _processAndroidImage(image);
      } else if (Platform.isIOS && _appleVisionController != null) {
        _processIOSImage(image);
      }
    }

    if (!_isFaceDetecting) {
      _detectFace(image);
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final camera = _cameras[_cameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotation.rotation0deg;
    } else {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _detectFace(CameraImage image) async {
    _isFaceDetecting = true;
    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isFaceDetecting = false;
        return;
      }
      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted) return;
      if (faces.isEmpty) {
        setState(() {
          _faceGesture = '';
          _faceRect = null;
          _leftEyeOpen = true;
          _rightEyeOpen = true;
          _isSmiling = false;
          _headAngleY = null;
          _headAngleZ = null;
        });
      } else {
        final face = faces.first;
        final leftEye = (face.leftEyeOpenProbability ?? 1.0) > 0.3;
        final rightEye = (face.rightEyeOpenProbability ?? 1.0) > 0.3;
        final smiling = (face.smilingProbability ?? 0.0) > 0.5;
        final headY = face.headEulerAngleY;
        final headZ = face.headEulerAngleZ;

        String gesture = '';
        if (!leftEye && !rightEye) {
          gesture = 'Gözler kapalı';
        } else if (!leftEye && rightEye) {
          gesture = 'Sol göz kırptı';
        } else if (leftEye && !rightEye) {
          gesture = 'Sağ göz kırptı';
        }

        if (smiling) {
          gesture = gesture.isEmpty ? 'Gülümsüyor' : '$gesture + Gülümsüyor';
        }

        if (headY != null) {
          if (headY > 20) {
            gesture = gesture.isEmpty ? 'Sola bakıyor' : '$gesture | Sola bakıyor';
          } else if (headY < -20) {
            gesture = gesture.isEmpty ? 'Sağa bakıyor' : '$gesture | Sağa bakıyor';
          }
        }

        if (headZ != null) {
          if (headZ > 15) {
            gesture = gesture.isEmpty ? 'Sola eğildi' : '$gesture | Sola eğildi';
          } else if (headZ < -15) {
            gesture = gesture.isEmpty ? 'Sağa eğildi' : '$gesture | Sağa eğildi';
          }
        }

        if (gesture.isEmpty) gesture = 'Yüz algılandı';

        final screenSize = MediaQuery.of(context).size;
        final imageSize = Size(image.width.toDouble(), image.height.toDouble());
        final isFront = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

        double scaleX = screenSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
        double scaleY = screenSize.height / (Platform.isIOS ? imageSize.height : imageSize.width);

        double left = face.boundingBox.left * scaleX;
        double top = face.boundingBox.top * scaleY;
        double right = face.boundingBox.right * scaleX;
        double bottom = face.boundingBox.bottom * scaleY;
        if (isFront) {
          final tmp = left;
          left = screenSize.width - right;
          right = screenSize.width - tmp;
        }

        setState(() {
          _leftEyeOpen = leftEye;
          _rightEyeOpen = rightEye;
          _isSmiling = smiling;
          _headAngleY = headY;
          _headAngleZ = headZ;
          _faceGesture = gesture;
          _faceRect = Rect.fromLTRB(left, top, right, bottom);
        });
      }
    } catch (_) {}
    _isFaceDetecting = false;
  }

  void _processAndroidImage(CameraImage image) {
    if (_handPlugin == null) return;
    _isDetecting = true;
    try {
      final hands = _handPlugin!.detect(
        image,
        _cameras[_cameraIndex].sensorOrientation,
      );
      if (!mounted) return;
      if (hands.isEmpty) {
        _updateHandState(null);
      } else {
        final hand = hands.first;
        if (hand.landmarks.length >= 21) {
          final thumbTip = hand.landmarks[4];
          final indexTip = hand.landmarks[8];
          final middleTip = hand.landmarks[12];

          final pinchDist = math.sqrt(
            math.pow(thumbTip.x - indexTip.x, 2) + math.pow(thumbTip.y - indexTip.y, 2),
          );
          final indexMiddleDist = math.sqrt(
            math.pow(indexTip.x - middleTip.x, 2) + math.pow(indexTip.y - middleTip.y, 2),
          );

          final isPinching = _wasPinching
              ? pinchDist < _pinchRelease
              : pinchDist < _pinchStart;
          _wasPinching = isPinching;

          final isErasing = _wasErasing
              ? indexMiddleDist < _eraseRelease
              : indexMiddleDist < _eraseStart;
          _wasErasing = isErasing;

          final isFrontCamera = _cameraIndex < _cameras.length &&
              _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;
          final x = isFrontCamera ? 1.0 - indexTip.x : indexTip.x;
          _updateHandState(
            _HandState(
              indexTipX: x,
              indexTipY: indexTip.y,
              isPinching: isPinching,
              isErasing: isErasing,
            ),
          );
        } else {
          _updateHandState(null);
        }
      }
    } catch (_) {}
    _isDetecting = false;
  }

  Hand? _findPose(List<Hand> poses, FingerJoint joint) {
    try {
      return poses.firstWhere((h) => h.joint == joint);
    } catch (_) {
      return null;
    }
  }

  /// Yedek: Apple Vision sabit sırada 7. eleman indexTip olabilir (tüm eklemler algılanırsa)
  Hand? _getPoseByIndex(List<Hand> poses, int index) {
    if (poses.length >= 8 && index < poses.length) return poses[index];
    return null;
  }

  Uint8List _bgraToRgba(Uint8List bgra, int width, int height, int bytesPerRow) {
    final rgba = Uint8List(width * height * 4);
    for (int y = 0; y < height; y++) {
      final srcRow = y * bytesPerRow;
      final dstRow = y * width * 4;
      for (int x = 0; x < width; x++) {
        final si = srcRow + x * 4;
        final di = dstRow + x * 4;
        rgba[di] = bgra[si + 2];
        rgba[di + 1] = bgra[si + 1];
        rgba[di + 2] = bgra[si];
        rgba[di + 3] = bgra[si + 3];
      }
    }
    return rgba;
  }

  Future<Uint8List?> _cameraImageToPng(CameraImage image) async {
    try {
      final w = image.width;
      final h = image.height;
      final plane = image.planes[0];
      final rgba = _bgraToRgba(plane.bytes, w, h, plane.bytesPerRow);
      final immutable = await ui.ImmutableBuffer.fromUint8List(rgba);
      final descriptor = ui.ImageDescriptor.raw(
        immutable,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      immutable.dispose();
      if (byteData == null) return null;
      return byteData.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _processIOSImage(CameraImage image) async {
    if (_appleVisionController == null || _isDetecting) return;
    _isDetecting = true;
    try {
      if (image.planes.isEmpty) {
        _updateHandState(null);
        return;
      }
      final pngBytes = await _cameraImageToPng(image);
      if (pngBytes == null) {
        _updateHandState(null);
        _isDetecting = false;
        return;
      }
      final size = Size(image.width.toDouble(), image.height.toDouble());
      final orientation = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
          ? ImageOrientation.downMirrored
          : ImageOrientation.up;
      final results = await _appleVisionController!.processImage(pngBytes, size, orientation);
      if (!mounted) return;
      if (results == null || results.isEmpty) {
        _updateHandState(null);
        return;
      }
      final handData = results.first;
      Hand? thumbTip = _findPose(handData.poses, FingerJoint.thumbTip);
      Hand? indexTip = _findPose(handData.poses, FingerJoint.indexTip);
      Hand? middleTip = _findPose(handData.poses, FingerJoint.middleTip);
      if (indexTip == null) {
        indexTip = _getPoseByIndex(handData.poses, 7);
      }
      if (indexTip == null) {
        _updateHandState(null);
        return;
      }

      final imgSize = handData.imageSize;
      bool isPinching = false;
      bool isErasing = false;
      if (thumbTip != null) {
        final pinchDist = math.sqrt(
          math.pow(thumbTip.location.x - indexTip!.location.x, 2) +
              math.pow(thumbTip.location.y - indexTip.location.y, 2),
        );
        final maxDim = math.max(imgSize.width, imgSize.height);
        final pinchNorm = pinchDist / maxDim;
        isPinching = _wasPinching ? pinchNorm < _pinchRelease : pinchNorm < _pinchStart;
        _wasPinching = isPinching;
      } else {
        _wasPinching = false;
      }
      if (middleTip != null) {
        final indexMiddleDist = math.sqrt(
          math.pow(indexTip!.location.x - middleTip.location.x, 2) +
              math.pow(indexTip.location.y - middleTip.location.y, 2),
        );
        final maxDim = math.max(imgSize.width, imgSize.height);
        final eraseNorm = indexMiddleDist / maxDim;
        isErasing = _wasErasing ? eraseNorm < _eraseRelease : eraseNorm < _eraseStart;
        _wasErasing = isErasing;
      } else {
        _wasErasing = false;
      }

      double normX = indexTip.location.x / imgSize.width;
      double normY = indexTip.location.y / imgSize.height;
      if (_cameras[_cameraIndex].lensDirection == CameraLensDirection.front) {
        normX = 1.0 - normX;
      }
      normX = normX.clamp(0.0, 1.0);
      normY = normY.clamp(0.0, 1.0);

      _updateHandState(
        _HandState(
          indexTipX: normX,
          indexTipY: normY,
          isPinching: isPinching,
          isErasing: isErasing,
        ),
      );
    } catch (_) {
      if (mounted) _updateHandState(null);
    }
    _isDetecting = false;
  }

  void _updateHandState(_HandState? state) {
    if (state == null) {
      setState(() {
        _pointerX = null;
        _pointerY = null;
        if (_currentStroke.length >= 2) {
          _sync.saveStroke(_currentStroke);
        }
        _currentStroke = [];
        _isPinching = false;
        _isErasing = false;
        _statusText = 'El algılanmıyor';
      });
      return;
    }

    setState(() {
      _pointerX = state.indexTipX;
      _pointerY = state.indexTipY;
      _isPinching = state.isPinching;
      _isErasing = state.isErasing;

      if (state.isErasing) {
        if (_currentStroke.isNotEmpty) _currentStroke = [];
        _sync.erase();
        _statusText = 'İşaret+Orta - Siliniyor';
      } else if (state.isPinching) {
        _currentStroke.add({'x': state.indexTipX, 'y': state.indexTipY});
        _statusText = 'Çizim (başparmak+işaret)';
      } else {
        if (_currentStroke.length >= 2) {
          _sync.saveStroke(_currentStroke);
        }
        _currentStroke = [];
        _statusText = 'Başparmak+İşaret = Çiz | İşaret+Orta = Sil';
      }
    });
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _handPlugin?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  Widget _buildCameraPreview() {
    final ctrl = _controller!;
    final size = ctrl.value.previewSize;
    if (size == null) return const Center(child: CircularProgressIndicator(color: Color(0xFF00FF9F)));
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.height,
          height: size.width,
          child: CameraPreview(ctrl),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!_permissionDenied)
                        const CircularProgressIndicator(color: Color(0xFF00FF9F))
                      else
                        const Icon(Icons.camera_alt,
                            size: 64, color: Color(0xFF00FF9F)),
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _statusText,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (_permissionDenied) ...[
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _requestPermissionAndStart,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('İzin Ver'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF9F),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 32, vertical: 16),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),
          if (_pointerX != null && _pointerY != null)
            Positioned(
              left: _pointerX! * MediaQuery.of(context).size.width - 12,
              top: _pointerY! * MediaQuery.of(context).size.height - 12,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isPinching
                      ? const Color(0xFF00FF9F)
                      : _isErasing
                          ? Colors.red
                          : Colors.white.withValues(alpha: 0.7),
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          // Yüz çerçevesi
          if (_faceRect != null)
            Positioned(
              left: _faceRect!.left,
              top: _faceRect!.top,
              child: Container(
                width: _faceRect!.width,
                height: _faceRect!.height,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _isSmiling ? const Color(0xFF00FF9F) : Colors.yellow,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _leftEyeOpen ? '👁' : '😑',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          _rightEyeOpen ? '👁' : '😑',
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (_isSmiling) ...[
                          const SizedBox(width: 2),
                          const Text('😊', style: TextStyle(fontSize: 12)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // Üst bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_ios,
                          color: Colors.white, size: 20),
                      tooltip: 'Geri',
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isPinching
                            ? const Color(0xFF00FF9F)
                            : _isErasing
                                ? Colors.red
                                : const Color(0xFF00FF9F),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusText,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: _cameras.length > 1 ? _switchCamera : null,
                      icon: const Icon(Icons.cameraswitch,
                          color: Colors.white, size: 24),
                      tooltip: 'Ön/Arka kamera',
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Yüz gesture bilgisi alt bar
          if (_faceGesture.isNotEmpty)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.face, color: Colors.yellow, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _faceGesture,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _switchCamera() async {
    if (!_isInitialized || _cameras.length < 2) return;
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initCamera();
    if (mounted) setState(() {});
    final hasHandTracking = (Platform.isAndroid && _handPlugin != null) ||
        (Platform.isIOS && _appleVisionController != null);
    if (hasHandTracking) {
      await _controller!.startImageStream(_processCameraImage);
    }
  }
}

class _HandState {
  final double indexTipX;
  final double indexTipY;
  final bool isPinching;
  final bool isErasing;
  _HandState({
    required this.indexTipX,
    required this.indexTipY,
    required this.isPinching,
    required this.isErasing,
  });
}
