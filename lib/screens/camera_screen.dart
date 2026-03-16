import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
// ignore: depend_on_referenced_packages
import 'package:apple_vision_commons/apple_vision_commons.dart';
import 'package:apple_vision_hand/apple_vision_hand.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const bool _enableFacePose = true;
  static const int _faceProcessEveryNFrames = 6;
  static const int _poseProcessEveryNFrames = 5;

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _isInitialized = false;
  String _statusText = 'Başlatılıyor...';
  bool _permissionDenied = false;
  bool _isDetecting = false;
  int _frameCounter = 0;

  late SyncService _sync;

  static const _cursorSmooth = 0.15;
  static const _eraseSmooth = 0.25;
  double _smoothCursorX = 0.5;
  double _smoothCursorY = 0.5;
  double _smoothEraserX = 0.5;
  double _smoothEraserY = 0.5;

  double? _cursorX;
  double? _cursorY;
  double? _eraserX;
  double? _eraserY;
  bool _isPinching = false;
  bool _isErasing = false;
  bool _wasPinching = false;
  bool _wasErasing = false; // ignore: unused_field
  int _pinchReleaseCounter = 0;
  int _twoFingerHeldFrames = 0;
  int _framesSinceDraw = 999;
  int _framesSinceErase = 999;
  static const _gestureLockFrames = 3;
  static const _pinchReleaseFrames = 4;

  List<Map<String, double>> _currentStrokePoints = [];

  hl.HandLandmarkerPlugin? _handPlugin;
  AppleVisionHandController? _appleVisionController;

  FaceDetector? _faceDetector;
  bool _isFaceDetecting = false;
  String _faceGesture = '';

  PoseDetector? _poseDetector;
  bool _isPoseDetecting = false;
  Pose? _pose;
  Size _poseImageSize = Size.zero;
  Size _lastImageSize = const Size(640, 480);
  List<Offset>? _handSkeletonPoints;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _sync = SyncService(widget.projectLink);
    if (_enableFacePose) {
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
    }
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
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    if (mounted) {
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
    }
  }

  void _processCameraImage(CameraImage image) {
    if (!mounted) return;
    _lastImageSize = Size(image.width.toDouble(), image.height.toDouble());
    _frameCounter++;

    if (!_isDetecting) {
      if (Platform.isAndroid && _handPlugin != null) {
        _processAndroidImage(image);
      } else if (Platform.isIOS && _appleVisionController != null) {
        _processIOSImage(image);
      }
    }

    if (_enableFacePose &&
        !_isFaceDetecting &&
        _frameCounter % _faceProcessEveryNFrames == 0) {
      _detectFace(image);
    }

    if (_enableFacePose &&
        !_isPoseDetecting &&
        _frameCounter % _poseProcessEveryNFrames == 0) {
      _detectPose(image);
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final camera = _cameras[_cameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    rotation ??= InputImageRotation.rotation0deg;

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
    if (_faceDetector == null) return;
    _isFaceDetecting = true;
    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isFaceDetecting = false;
        return;
      }
      final faces = await _faceDetector!.processImage(inputImage);
      if (!mounted) return;
      if (faces.isEmpty) {
        setState(() => _faceGesture = '');
      } else {
        final face = faces.first;
        final leftEye = (face.leftEyeOpenProbability ?? 1.0) > 0.3;
        final rightEye = (face.rightEyeOpenProbability ?? 1.0) > 0.3;
        final smiling = (face.smilingProbability ?? 0.0) > 0.5;
        final headY = face.headEulerAngleY;

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
            gesture = gesture.isEmpty ? 'Sola bakıyor' : '$gesture | Sola';
          } else if (headY < -20) {
            gesture = gesture.isEmpty ? 'Sağa bakıyor' : '$gesture | Sağa';
          }
        }
        if (gesture.isEmpty) gesture = 'Yüz algılandı';
        setState(() => _faceGesture = gesture);
      }
    } catch (_) {}
    _isFaceDetecting = false;
  }

  Future<void> _detectPose(CameraImage image) async {
    if (_poseDetector == null) return;
    _isPoseDetecting = true;
    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isPoseDetecting = false;
        return;
      }
      final poses = await _poseDetector!.processImage(inputImage);
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

  bool _isFingerExtended(List<dynamic> landmarks, int mcp, int pip, int tip) {
    double lx(int i) => (landmarks[i] as dynamic).x.toDouble();
    double ly(int i) => (landmarks[i] as dynamic).y.toDouble();
    final mcpToTip = math.sqrt(
        math.pow(lx(tip) - lx(mcp), 2) + math.pow(ly(tip) - ly(mcp), 2));
    final mcpToPip = math.sqrt(
        math.pow(lx(pip) - lx(mcp), 2) + math.pow(ly(pip) - ly(mcp), 2));
    return mcpToTip > mcpToPip * 1.2;
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

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
        _handSkeletonPoints = null;
        _updateHandState(null);
      } else {
        final hand = hands.first;
        if (hand.landmarks.length >= 21) {
          final lm = hand.landmarks;

          final imgW = image.width.toDouble();
          final imgH = image.height.toDouble();
          final pts = <Offset>[];
          for (final l in lm) {
            pts.add(Offset(
              l.x.clamp(0.0, 1.0) * imgW,
              l.y.clamp(0.0, 1.0) * imgH,
            ));
          }
          _handSkeletonPoints = pts;

          final handSize = math.sqrt(
              math.pow(lm[0].x - lm[9].x, 2) + math.pow(lm[0].y - lm[9].y, 2));

          final pinchStartThreshold = (handSize * 0.28).clamp(0.025, 0.1);
          final pinchReleaseThreshold = (handSize * 0.4).clamp(0.04, 0.14);

          final pinchDist = math.sqrt(
              math.pow(lm[4].x - lm[8].x, 2) + math.pow(lm[4].y - lm[8].y, 2));

          final indexExtended = _isFingerExtended(lm, 5, 6, 8);
          final middleExtended = _isFingerExtended(lm, 9, 10, 12);
          final ringCurled = !_isFingerExtended(lm, 13, 14, 16);
          final pinkyCurled = !_isFingerExtended(lm, 17, 18, 20);

          final twoFingerDetected =
              indexExtended && middleExtended && ringCurled && pinkyCurled;

          if (twoFingerDetected) {
            _twoFingerHeldFrames++;
          } else {
            _twoFingerHeldFrames = 0;
          }

          final eraseActive =
              _twoFingerHeldFrames >= 2 && _framesSinceDraw >= _gestureLockFrames;

          final rawPinch = pinchDist <
              (_wasPinching ? pinchReleaseThreshold : pinchStartThreshold);

          bool pinchActive;
          if (eraseActive) {
            pinchActive = false;
            _pinchReleaseCounter = 0;
          } else if (rawPinch && _framesSinceErase >= _gestureLockFrames) {
            pinchActive = true;
            _pinchReleaseCounter = 0;
          } else if (_wasPinching && !rawPinch) {
            _pinchReleaseCounter++;
            pinchActive = _pinchReleaseCounter < _pinchReleaseFrames;
          } else {
            pinchActive = false;
            _pinchReleaseCounter = 0;
          }

          if (pinchActive) {
            _framesSinceDraw = 0;
            _framesSinceErase++;
          } else if (eraseActive) {
            _framesSinceErase = 0;
            _framesSinceDraw++;
          } else {
            _framesSinceDraw++;
            _framesSinceErase++;
          }

          _wasPinching = pinchActive;
          _wasErasing = eraseActive;

          double rawCursorX, rawCursorY;
          if (pinchActive) {
            rawCursorX = (lm[8].x + lm[4].x) / 2;
            rawCursorY = (lm[8].y + lm[4].y) / 2;
          } else {
            rawCursorX = lm[8].x;
            rawCursorY = lm[8].y;
          }
          _smoothCursorX = _lerp(_smoothCursorX, rawCursorX, 1.0 - _cursorSmooth);
          _smoothCursorY = _lerp(_smoothCursorY, rawCursorY, 1.0 - _cursorSmooth);

          final rawEraserX = (lm[8].x + lm[12].x) / 2;
          final rawEraserY = (lm[8].y + lm[12].y) / 2;
          _smoothEraserX = _lerp(_smoothEraserX, rawEraserX, 1.0 - _eraseSmooth);
          _smoothEraserY = _lerp(_smoothEraserY, rawEraserY, 1.0 - _eraseSmooth);

          _updateHandState(_HandResult(
            cursorX: _smoothCursorX,
            cursorY: _smoothCursorY,
            eraserX: _smoothEraserX,
            eraserY: _smoothEraserY,
            isPinching: pinchActive,
            isErasing: eraseActive,
          ));
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
        immutable, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888,
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
      if (image.planes.isEmpty) { _updateHandState(null); _isDetecting = false; return; }
      final pngBytes = await _cameraImageToPng(image);
      if (pngBytes == null) { _updateHandState(null); _isDetecting = false; return; }
      final size = Size(image.width.toDouble(), image.height.toDouble());
      final orientation = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
          ? ImageOrientation.downMirrored : ImageOrientation.up;
      final results = await _appleVisionController!.processImage(pngBytes, size, orientation);
      if (!mounted) return;
      if (results == null || results.isEmpty) { _updateHandState(null); _isDetecting = false; return; }
      final handData = results.first;
      Hand? thumbTip = _findPose(handData.poses, FingerJoint.thumbTip);
      Hand? indexTip = _findPose(handData.poses, FingerJoint.indexTip);
      Hand? middleTip = _findPose(handData.poses, FingerJoint.middleTip);
      Hand? wrist = _getPoseByIndex(handData.poses, 0);
      Hand? middleMCP = _findPose(handData.poses, FingerJoint.middleMCP);

      indexTip ??= _getPoseByIndex(handData.poses, 7);
      if (indexTip == null) { _updateHandState(null); _isDetecting = false; return; }

      final imgSize = handData.imageSize;
      final maxDim = math.max(imgSize.width, imgSize.height);

      double handSize = 0.15;
      if (wrist != null && middleMCP != null) {
        handSize = math.sqrt(
            math.pow(wrist.location.x - middleMCP.location.x, 2) +
                math.pow(wrist.location.y - middleMCP.location.y, 2)) / maxDim;
      }
      final pinchStartT = (handSize * 0.28).clamp(0.025, 0.1);
      final pinchReleaseT = (handSize * 0.4).clamp(0.04, 0.14);

      double pinchDist = 1.0;
      if (thumbTip != null) {
        pinchDist = math.sqrt(
            math.pow(thumbTip.location.x - indexTip.location.x, 2) +
                math.pow(thumbTip.location.y - indexTip.location.y, 2)) / maxDim;
      }

      final rawPinch = pinchDist < (_wasPinching ? pinchReleaseT : pinchStartT);

      bool eraseActive = false;
      if (middleTip != null) {
        final eraseDist = math.sqrt(
            math.pow(indexTip.location.x - middleTip.location.x, 2) +
                math.pow(indexTip.location.y - middleTip.location.y, 2)) / maxDim;
        if (eraseDist < 0.08) { _twoFingerHeldFrames++; } else { _twoFingerHeldFrames = 0; }
        eraseActive = _twoFingerHeldFrames >= 2 && _framesSinceDraw >= _gestureLockFrames;
      }

      bool pinchActive;
      if (eraseActive) { pinchActive = false; _pinchReleaseCounter = 0; }
      else if (rawPinch && _framesSinceErase >= _gestureLockFrames) { pinchActive = true; _pinchReleaseCounter = 0; }
      else if (_wasPinching && !rawPinch) { _pinchReleaseCounter++; pinchActive = _pinchReleaseCounter < _pinchReleaseFrames; }
      else { pinchActive = false; _pinchReleaseCounter = 0; }

      if (pinchActive) { _framesSinceDraw = 0; _framesSinceErase++; }
      else if (eraseActive) { _framesSinceErase = 0; _framesSinceDraw++; }
      else { _framesSinceDraw++; _framesSinceErase++; }

      _wasPinching = pinchActive;
      _wasErasing = eraseActive;

      double normX = (indexTip.location.x / imgSize.width).clamp(0.0, 1.0);
      double normY = (indexTip.location.y / imgSize.height).clamp(0.0, 1.0);

      double rawCursorX, rawCursorY;
      if (pinchActive && thumbTip != null) {
        rawCursorX = (((indexTip.location.x + thumbTip.location.x) / 2) / imgSize.width).clamp(0.0, 1.0);
        rawCursorY = (((indexTip.location.y + thumbTip.location.y) / 2) / imgSize.height).clamp(0.0, 1.0);
      } else {
        rawCursorX = normX; rawCursorY = normY;
      }
      _smoothCursorX = _lerp(_smoothCursorX, rawCursorX, 1.0 - _cursorSmooth);
      _smoothCursorY = _lerp(_smoothCursorY, rawCursorY, 1.0 - _cursorSmooth);

      double rawEX = normX, rawEY = normY;
      if (middleTip != null) {
        rawEX = (((indexTip.location.x + middleTip.location.x) / 2) / imgSize.width).clamp(0.0, 1.0);
        rawEY = (((indexTip.location.y + middleTip.location.y) / 2) / imgSize.height).clamp(0.0, 1.0);
      }
      _smoothEraserX = _lerp(_smoothEraserX, rawEX, 1.0 - _eraseSmooth);
      _smoothEraserY = _lerp(_smoothEraserY, rawEY, 1.0 - _eraseSmooth);

      final byJoint = <FingerJoint, Hand>{};
      for (final j in FingerJoint.values) {
        final p = _findPose(handData.poses, j);
        if (p != null) byJoint[j] = p;
      }
      final skelPts = <Offset>[];
      const order = [
        FingerJoint.thumbCMC, FingerJoint.thumbIP, FingerJoint.thumbMP, FingerJoint.thumbTip,
        FingerJoint.indexMCP, FingerJoint.indexPIP, FingerJoint.indexDIP, FingerJoint.indexTip,
        FingerJoint.middleMCP, FingerJoint.middlePIP, FingerJoint.middleDIP, FingerJoint.middleTip,
        FingerJoint.ringMCP, FingerJoint.ringPIP, FingerJoint.ringDIP, FingerJoint.ringTip,
        FingerJoint.littleMCP, FingerJoint.littlePIP, FingerJoint.littleDIP, FingerJoint.littleTip,
      ];
      for (final j in order) {
        final p = byJoint[j];
        if (p != null) {
          skelPts.add(Offset(
            p.location.x.clamp(0.0, imgSize.width),
            p.location.y.clamp(0.0, imgSize.height),
          ));
        }
      }
      if (skelPts.length >= 15) _handSkeletonPoints = skelPts;

      _updateHandState(_HandResult(
        cursorX: _smoothCursorX, cursorY: _smoothCursorY,
        eraserX: _smoothEraserX, eraserY: _smoothEraserY,
        isPinching: pinchActive, isErasing: eraseActive,
      ));
    } catch (_) {
      if (mounted) { _handSkeletonPoints = null; _updateHandState(null); }
    }
    _isDetecting = false;
  }

  void _updateHandState(_HandResult? state) {
    if (state == null) {
      setState(() {
        if (_currentStrokePoints.length >= 2) {
          _sync.sendDrawEvent(0, 0, isDrawing: false);
        }
        _currentStrokePoints = [];
        _cursorX = null; _cursorY = null;
        _eraserX = null; _eraserY = null;
        _isPinching = false; _isErasing = false;
        _handSkeletonPoints = null;
        _wasPinching = false; _wasErasing = false;
        _pinchReleaseCounter = 0; _twoFingerHeldFrames = 0;
        _statusText = 'El algılanmıyor';
      });
      return;
    }

    setState(() {
      _cursorX = state.cursorX;
      _cursorY = state.cursorY;
      _eraserX = state.eraserX;
      _eraserY = state.eraserY;
      _isPinching = state.isPinching;
      _isErasing = state.isErasing;

      if (state.isErasing) {
        if (_currentStrokePoints.isNotEmpty) {
          _sync.sendDrawEvent(0, 0, isDrawing: false);
          _currentStrokePoints = [];
        }
        _sync.sendEraseAtPosition(state.eraserX, state.eraserY);
        _statusText = 'Silgi modu (işaret+orta)';
      } else if (state.isPinching) {
        _sync.sendDrawEvent(state.cursorX, state.cursorY, isDrawing: true);
        _currentStrokePoints.add({'x': state.cursorX, 'y': state.cursorY});
        _statusText = 'Çizim (başparmak+işaret)';
      } else {
        if (_currentStrokePoints.length >= 2) {
          _sync.sendDrawEvent(state.cursorX, state.cursorY, isDrawing: false);
        }
        _currentStrokePoints = [];
        _statusText = 'Başparmak+İşaret = Çiz | İşaret+Orta = Sil';
      }
    });
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _handPlugin?.dispose();
    _faceDetector?.close();
    _poseDetector?.close();
    _sync.destroy();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  Widget _buildCameraPreview() {
    final ctrl = _controller!;
    if (!ctrl.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF00FF9F)));
    }
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: ctrl.value.previewSize!.height,
          height: ctrl.value.previewSize!.width,
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
                        const Icon(Icons.camera_alt, size: 64, color: Color(0xFF00FF9F)),
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(_statusText,
                          style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
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
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
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

    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),

          if (_pose != null || (_handSkeletonPoints != null && _handSkeletonPoints!.length >= 15))
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

          CustomPaint(
            size: Size(screenW, screenH),
            painter: _StrokeOverlayPainter(
              savedStrokes: _sync.cachedStrokes,
              currentPoints: _currentStrokePoints,
            ),
          ),

          if (_isErasing && _eraserX != null && _eraserY != null)
            Positioned(
              left: _eraserX! * screenW - 0.09 * screenW,
              top: _eraserY! * screenH - 0.09 * screenW,
              child: Container(
                width: 0.18 * screenW, height: 0.18 * screenW,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.7), width: 2),
                ),
              ),
            ),

          if (!_isErasing && _cursorX != null && _cursorY != null)
            Positioned(
              left: _cursorX! * screenW - (_isPinching ? 14 : 10),
              top: _cursorY! * screenH - (_isPinching ? 14 : 10),
              child: Container(
                width: _isPinching ? 28 : 20, height: _isPinching ? 28 : 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isPinching ? const Color(0xFF00FF9F).withValues(alpha: 0.25) : Colors.transparent,
                  border: Border.all(
                    color: _isPinching ? const Color(0xFF00FF9F) : Colors.white.withValues(alpha: 0.6),
                    width: _isPinching ? 3 : 1.5,
                  ),
                ),
              ),
            ),

          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2))],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 8),
                    Container(width: 8, height: 8,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                        color: _isPinching ? const Color(0xFF00FF9F) : _isErasing ? Colors.red : (_cursorX != null ? Colors.orange : Colors.grey),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_statusText, style: const TextStyle(color: Colors.white, fontSize: 13), overflow: TextOverflow.ellipsis)),
                    Text('${_sync.cachedStrokes.length}', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _canSwitchCamera() ? _switchCamera : null,
                      icon: const Icon(Icons.cameraswitch, color: Colors.white, size: 24),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_enableFacePose && _faceGesture.isNotEmpty)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.face, color: Colors.yellow, size: 18),
                      const SizedBox(width: 8),
                      Flexible(child: Text(_faceGesture, style: const TextStyle(color: Colors.white, fontSize: 14), textAlign: TextAlign.center)),
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
    return _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
           _cameras.any((c) => c.lensDirection == CameraLensDirection.back);
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

class _HandResult {
  final double cursorX, cursorY, eraserX, eraserY;
  final bool isPinching, isErasing;
  _HandResult({required this.cursorX, required this.cursorY,
    required this.eraserX, required this.eraserY,
    required this.isPinching, required this.isErasing});
}

class _StrokeOverlayPainter extends CustomPainter {
  final List<StrokeData> savedStrokes;
  final List<Map<String, double>> currentPoints;
  _StrokeOverlayPainter({required this.savedStrokes, required this.currentPoints});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in savedStrokes) {
      if (stroke.points.length < 2) continue;
      final paint = Paint()
        ..color = _parseColor(stroke.color)
        ..strokeWidth = stroke.lineWidth.toDouble() * 1.5
        ..strokeCap = StrokeCap.round ..style = PaintingStyle.stroke;
      for (int i = 1; i < stroke.points.length; i++) {
        canvas.drawLine(
          Offset(stroke.points[i - 1]['x']! * size.width, stroke.points[i - 1]['y']! * size.height),
          Offset(stroke.points[i]['x']! * size.width, stroke.points[i]['y']! * size.height), paint);
      }
    }
    if (currentPoints.length >= 2) {
      final paint = Paint()..color = const Color(0xFF00FF9F)..strokeWidth = 6..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      for (int i = 1; i < currentPoints.length; i++) {
        canvas.drawLine(
          Offset(currentPoints[i - 1]['x']! * size.width, currentPoints[i - 1]['y']! * size.height),
          Offset(currentPoints[i]['x']! * size.width, currentPoints[i]['y']! * size.height), paint);
      }
    }
  }

  Color _parseColor(String hex) {
    try { return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16)); }
    catch (_) { return const Color(0xFF00FF9F); }
  }

  @override
  bool shouldRepaint(covariant _StrokeOverlayPainter old) => true;
}
