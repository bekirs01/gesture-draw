import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:apple_vision_commons/apple_vision_commons.dart';
import 'package:apple_vision_hand/apple_vision_hand.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:hand_landmarker/hand_landmarker.dart' as hl;
import '../widgets/skeleton_overlay.dart';
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
  bool _fingersSpread = true;
  static const _pointerSmoothFactor = 0.58;
  double? _prevPointerX;
  double? _prevPointerY;

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

  // Vücut iskelet takibi
  late PoseDetector _poseDetector;
  bool _isPoseDetecting = false;
  Pose? _pose;
  Size _poseImageSize = Size.zero;
  Size _lastImageSize = const Size(640, 480);
  List<Offset>? _handSkeletonPoints;

  static const _pinchStart = 0.055;
  static const _pinchRelease = 0.095;
  static const _eraseStart = 0.055;
  static const _eraseRelease = 0.095;

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
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
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
    _lastImageSize = Size(image.width.toDouble(), image.height.toDouble());

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

    if (!_isPoseDetecting) {
      _detectPose(image);
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final camera = _cameras[_cameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    if (rotation == null) rotation = InputImageRotation.rotation0deg;

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

  Future<void> _detectPose(CameraImage image) async {
    _isPoseDetecting = true;
    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isPoseDetecting = false;
        return;
      }
      final poses = await _poseDetector.processImage(inputImage);
      if (!mounted) return;
      if (poses.isEmpty) {
        setState(() {
          _pose = null;
          _poseImageSize = Size.zero;
        });
      } else {
        setState(() {
          _pose = poses.first;
          _poseImageSize = Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } catch (_) {
      if (mounted) setState(() => _pose = null);
    }
    _isPoseDetecting = false;
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
          final indexPIP = hand.landmarks[6];
          final middleTip = hand.landmarks[12];
          final middlePIP = hand.landmarks[10];
          final ringTip = hand.landmarks[16];

          double _dist(a, b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

          final pinchDistTip = _dist(thumbTip, indexTip);
          final pinchDistPIP = _dist(thumbTip, indexPIP);
          final pinchDist = math.min(pinchDistTip, pinchDistPIP);

          final indexMiddleDistTip = _dist(indexTip, middleTip);
          final indexMiddleDistPIP = _dist(indexPIP, middlePIP);
          final indexMiddleDist = math.min(indexMiddleDistTip, indexMiddleDistPIP);

          final indexRingDist = _dist(indexTip, ringTip);

          final isPinching = _wasPinching
              ? pinchDist < _pinchRelease
              : pinchDist < _pinchStart;
          _wasPinching = isPinching;

          final isErasing = _wasErasing
              ? indexMiddleDist < _eraseRelease
              : indexMiddleDist < _eraseStart;
          _wasErasing = isErasing;

          final avgSpread = (indexMiddleDist + indexRingDist) / 2;
          final fingersSpread = avgSpread > 0.08;

          double ptrX = indexTip.x;
          double ptrY = indexTip.y;

          final imgW = image.width.toDouble();
          final imgH = image.height.toDouble();
          final pts = <Offset>[];
          for (final lm in hand.landmarks) {
            pts.add(Offset(lm.x * imgW, lm.y * imgH));
          }
          if (pts.length >= 21) _handSkeletonPoints = pts;

          _updateHandState(
            _HandState(
              indexTipX: ptrX,
              indexTipY: ptrY,
              isPinching: isPinching,
              isErasing: isErasing,
              fingersSpread: fingersSpread,
            ),
          );
        } else {
          _handSkeletonPoints = null;
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
      Hand? indexPIP = _findPose(handData.poses, FingerJoint.indexPIP);
      Hand? middleTip = _findPose(handData.poses, FingerJoint.middleTip);
      Hand? middlePIP = _findPose(handData.poses, FingerJoint.middlePIP);
      Hand? ringTip = _findPose(handData.poses, FingerJoint.ringTip);
      if (indexTip == null) {
        indexTip = _getPoseByIndex(handData.poses, 7);
      }
      Hand? ptrHand = indexTip ?? thumbTip ?? middleTip;
      if (ptrHand == null) {
        _updateHandState(null);
        return;
      }

      final imgSize = handData.imageSize;
      final maxDim = math.max(imgSize.width, imgSize.height);
      bool isPinching = false;
      bool isErasing = false;
      bool fingersSpread = true;

      double _dist(a, b) => math.sqrt(
          math.pow(a.location.x - b.location.x, 2) +
              math.pow(a.location.y - b.location.y, 2));

      if (thumbTip != null && indexTip != null) {
        final pinchTip = _dist(thumbTip, indexTip) / maxDim;
        final pinchPIP = indexPIP != null
            ? _dist(thumbTip, indexPIP) / maxDim
            : 1.0;
        final pinchNorm = math.min(pinchTip, pinchPIP);
        isPinching = _wasPinching ? pinchNorm < _pinchRelease : pinchNorm < _pinchStart;
        _wasPinching = isPinching;
      } else {
        _wasPinching = false;
      }
      if (middleTip != null && indexTip != null) {
        final eraseTip = _dist(indexTip, middleTip) / maxDim;
        final erasePIP = (indexPIP != null && middlePIP != null)
            ? _dist(indexPIP, middlePIP) / maxDim
            : 1.0;
        final eraseNorm = math.min(eraseTip, erasePIP);
        isErasing = _wasErasing ? eraseNorm < _eraseRelease : eraseNorm < _eraseStart;
        _wasErasing = isErasing;
        if (ringTip != null) {
          final indexRingDist = _dist(indexTip, ringTip);
          final indexMiddleDist = _dist(indexTip, middleTip);
          final spreadNorm = (indexMiddleDist + indexRingDist) / 2 / maxDim;
          fingersSpread = spreadNorm > 0.08;
        }
      } else {
        _wasErasing = false;
      }

      double normX = ptrHand.location.x / imgSize.width;
      double normY = ptrHand.location.y / imgSize.height;
      normX = normX.clamp(0.0, 1.0);
      normY = normY.clamp(0.0, 1.0);

      final pts = <Offset>[];
      final byJoint = <FingerJoint, Hand>{};
      for (final j in FingerJoint.values) {
        final p = _findPose(handData.poses, j);
        if (p != null) byJoint[j] = p;
      }
      final thumbCMC = byJoint[FingerJoint.thumbCMC];
      final indexMCP = byJoint[FingerJoint.indexMCP];
      final middleMCP = byJoint[FingerJoint.middleMCP];
      if (thumbCMC != null && indexMCP != null && middleMCP != null) {
        pts.add(Offset(
          (thumbCMC.location.x + indexMCP.location.x + middleMCP.location.x) / 3,
          (thumbCMC.location.y + indexMCP.location.y + middleMCP.location.y) / 3,
        ));
      }
      final order = [
        FingerJoint.thumbCMC, FingerJoint.thumbIP, FingerJoint.thumbMP, FingerJoint.thumbTip,
        FingerJoint.indexMCP, FingerJoint.indexPIP, FingerJoint.indexDIP, FingerJoint.indexTip,
        FingerJoint.middleMCP, FingerJoint.middlePIP, FingerJoint.middleDIP, FingerJoint.middleTip,
        FingerJoint.ringMCP, FingerJoint.ringPIP, FingerJoint.ringDIP, FingerJoint.ringTip,
        FingerJoint.littleMCP, FingerJoint.littlePIP, FingerJoint.littleDIP, FingerJoint.littleTip,
      ];
      for (final j in order) {
        final p = byJoint[j];
        if (p != null) pts.add(Offset(p.location.x, p.location.y));
      }
      if (pts.length >= 21) _handSkeletonPoints = pts;

      _updateHandState(
        _HandState(
          indexTipX: normX,
          indexTipY: normY,
          isPinching: isPinching,
          isErasing: isErasing,
          fingersSpread: fingersSpread,
        ),
      );
    } catch (_) {
      if (mounted) {
        _handSkeletonPoints = null;
        _updateHandState(null);
      }
    }
    _isDetecting = false;
  }

  void _updateHandState(_HandState? state) {
    if (state == null) {
      setState(() {
        _pointerX = null;
        _pointerY = null;
        _prevPointerX = null;
        _prevPointerY = null;
        _handSkeletonPoints = null;
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

    double smoothX = state.indexTipX;
    double smoothY = state.indexTipY;
    if (_prevPointerX != null && _prevPointerY != null) {
      smoothX = _prevPointerX! + (state.indexTipX - _prevPointerX!) * _pointerSmoothFactor;
      smoothY = _prevPointerY! + (state.indexTipY - _prevPointerY!) * _pointerSmoothFactor;
    }
    _prevPointerX = smoothX;
    _prevPointerY = smoothY;

    setState(() {
      _pointerX = smoothX;
      _pointerY = smoothY;
      _isPinching = state.isPinching;
      _isErasing = state.isErasing;
      _fingersSpread = state.fingersSpread;

      if (state.isErasing) {
        if (_currentStroke.isNotEmpty) _currentStroke = [];
        _sync.erase();
        _statusText = 'İşaret+Orta - Siliniyor';
      } else if (state.isPinching) {
        _currentStroke.add({'x': smoothX, 'y': smoothY});
        _statusText = 'Çizim (başparmak+işaret)';
      } else {
        if (_currentStroke.length >= 2) {
          _sync.saveStroke(_currentStroke);
        }
        _currentStroke = [];
        final spreadText = state.fingersSpread ? 'Parmaklar açık' : 'Parmaklar kapalı';
        _statusText = '$spreadText • Başparmak+İşaret = Çiz | İşaret+Orta = Sil';
      }
    });
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _handPlugin?.dispose();
    _faceDetector.close();
    _poseDetector.close();
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
          if (_pose != null || (_handSkeletonPoints != null && _handSkeletonPoints!.length >= 21))
            Positioned.fill(
              child: SkeletonOverlay(
                pose: _pose,
                handPoints: _handSkeletonPoints,
                imageSize: _poseImageSize.width > 0 ? _poseImageSize : _lastImageSize,
                screenSize: MediaQuery.of(context).size,
                isPinching: _isPinching,
                isErasing: _isErasing,
              ),
            ),
          if (_pointerX != null && _pointerY != null && !_isPinching && !_isErasing)
            Positioned(
              left: _pointerX! * MediaQuery.of(context).size.width - 10,
              top: _pointerY! * MediaQuery.of(context).size.height - 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.3),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
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
                      onPressed: _canSwitchCamera() ? _switchCamera : null,
                      icon: const Icon(Icons.cameraswitch,
                          color: Colors.white, size: 24),
                      tooltip: _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                          ? 'Arka kameraya geç'
                          : 'Ön kameraya geç',
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

  bool _canSwitchCamera() {
    if (_cameras.isEmpty) return false;
    final hasFront = _cameras.any((c) => c.lensDirection == CameraLensDirection.front);
    final hasBack = _cameras.any((c) => c.lensDirection == CameraLensDirection.back);
    return hasFront && hasBack;
  }

  Future<void> _switchCamera() async {
    if (!_isInitialized || _cameras.isEmpty) return;
    final isFront = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;
    final nextIndex = isFront
        ? _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back)
        : _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.front);
    if (nextIndex < 0) return;
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _cameraIndex = nextIndex;
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
  final bool fingersSpread;
  _HandState({
    required this.indexTipX,
    required this.indexTipY,
    required this.isPinching,
    required this.isErasing,
    this.fingersSpread = true,
  });
}
