import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
// ignore: depend_on_referenced_packages
import 'package:apple_vision_commons/apple_vision_commons.dart';
import 'package:apple_vision_hand/apple_vision_hand.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _isSwitchingCamera = false;
  String _statusText = 'Başlatılıyor...';
  bool _permissionDenied = false;
  bool _isDetecting = false;

  late SyncService _sync;

  static const _cursorSmooth = 0.42;
  static const _eraseSmooth = 0.28;
  double _smoothCursorX = 0.5;
  double _smoothCursorY = 0.5;
  double _smoothEraserX = 0.5;
  double _smoothEraserY = 0.5;

  double? _cursorX;
  double? _cursorY;
  double? _eraserX;
  double? _eraserY;
  double? _pointerX;
  double? _pointerY;
  bool _isPinching = false;
  bool _isErasing = false;
  bool _isPointering = false;
  bool _wasPinching = false;
  bool _wasErasing = false; // ignore: unused_field
  int _pinchReleaseCounter = 0;
  int _twoFingerHeldFrames = 0;
  int _framesSinceDraw = 999;
  int _framesSinceErase = 999;
  static const _gestureLockFrames = 6;
  static const _pinchReleaseFrames = 8;

  List<Map<String, double>> _currentStrokePoints = [];

  hl.HandLandmarkerPlugin? _handPlugin;
  AppleVisionHandController? _appleVisionController;

  Size _lastImageSize = const Size(640, 480);
  List<Offset>? _handSkeletonPoints;

  /// PDF (A4) oranı - telefon çizim alanı PDF ile eşleşir, kenarlara erişim sağlanır
  static const _pdfAspect = 210 / 297;

  (double, double) _camToPdf(double camX, double camY) {
    double x = camX, y = camY;
    if (_cameras.isNotEmpty && _cameras[_cameraIndex].lensDirection == CameraLensDirection.back) {
      y = 1.0 - y;
    }
    final imgW = _lastImageSize.width;
    final imgH = _lastImageSize.height;
    if (imgW <= 0 || imgH <= 0) return (x, y);
    final camAr = imgW / imgH;
    if (camAr > _pdfAspect) {
      final cropW = _pdfAspect / camAr;
      final cropLeft = (1 - cropW) / 2;
      final pdfX = ((x - cropLeft) / cropW).clamp(0.0, 1.0);
      final pdfY = y.clamp(0.0, 1.0);
      return (pdfX, pdfY);
    } else {
      final cropH = camAr / _pdfAspect;
      final cropTop = (1 - cropH) / 2;
      final pdfX = x.clamp(0.0, 1.0);
      final pdfY = ((y - cropTop) / cropH).clamp(0.0, 1.0);
      return (pdfX, pdfY);
    }
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _sync = SyncService(widget.projectLink);
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
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    if (mounted) {
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
    }
  }

  bool get _hasMultipleCameras =>
      _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
      _cameras.any((c) => c.lensDirection == CameraLensDirection.back);

  Future<void> _switchCamera() async {
    if (!_hasMultipleCameras || _controller == null || _isSwitchingCamera) return;
    final isFront = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;
    final targetDirection = isFront ? CameraLensDirection.back : CameraLensDirection.front;
    final newIndex = _cameras.indexWhere((c) => c.lensDirection == targetDirection);
    if (newIndex < 0) return;

    setState(() {
      _isSwitchingCamera = true;
      _statusText = 'Kamera değiştiriliyor...';
    });
    try {
      await _controller!.stopImageStream();
      await _controller!.dispose();
      _controller = null;

      _cameraIndex = newIndex;
      await _initCamera();

      if (mounted) {
        final hasHandTracking = (Platform.isAndroid && _handPlugin != null) ||
            (Platform.isIOS && _appleVisionController != null);
        if (hasHandTracking) {
          await _controller!.startImageStream(_processCameraImage);
        }
        setState(() {
          _isSwitchingCamera = false;
          _statusText = 'Başparmak+İşaret = Çiz | İşaret+Orta = Sil';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSwitchingCamera = false;
          _statusText = 'Kamera hatası: $e';
        });
      }
    }
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
          final isBack = _cameras[_cameraIndex].lensDirection == CameraLensDirection.back;
          final pts = <Offset>[];
          for (final l in lm) {
            final ly = l.y.clamp(0.0, 1.0);
            pts.add(Offset(
              l.x.clamp(0.0, 1.0) * imgW,
              isBack ? imgH - ly * imgH : ly * imgH,
            ));
          }
          _handSkeletonPoints = pts;

          final handSize = math.sqrt(
              math.pow(lm[0].x - lm[9].x, 2) + math.pow(lm[0].y - lm[9].y, 2));

          // Sadece işaret ve başparmak dokunduğunda yaz - daha hassas dokunma, daha toleranslı bırakma
          final pinchStartThreshold = (handSize * 0.10).clamp(0.010, 0.035);
          final pinchReleaseThreshold = (handSize * 0.28).clamp(0.03, 0.09);

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
              _twoFingerHeldFrames >= 3 && _framesSinceDraw >= _gestureLockFrames;

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

          final pointerActive = indexExtended && !middleExtended && ringCurled && pinkyCurled &&
              !pinchActive && !eraseActive;

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
            isPointering: pointerActive,
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
      // Sadece işaret ve başparmak dokunduğunda yaz - daha hassas dokunma, daha toleranslı bırakma
      final pinchStartT = (handSize * 0.10).clamp(0.010, 0.035);
      final pinchReleaseT = (handSize * 0.28).clamp(0.03, 0.09);

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
        if (eraseDist < 0.07) { _twoFingerHeldFrames++; } else { _twoFingerHeldFrames = 0; }
        eraseActive = _twoFingerHeldFrames >= 3 && _framesSinceDraw >= _gestureLockFrames;
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
      final isBack = _cameras[_cameraIndex].lensDirection == CameraLensDirection.back;
      for (final j in order) {
        final p = byJoint[j];
        if (p != null) {
          final py = p.location.y.clamp(0.0, imgSize.height);
          skelPts.add(Offset(
            p.location.x.clamp(0.0, imgSize.width),
            isBack ? imgSize.height - py : py,
          ));
        }
      }
      if (skelPts.length >= 15) _handSkeletonPoints = skelPts;

      final pointerActive = !pinchActive && !eraseActive;

      _updateHandState(_HandResult(
        cursorX: _smoothCursorX, cursorY: _smoothCursorY,
        eraserX: _smoothEraserX, eraserY: _smoothEraserY,
        isPinching: pinchActive, isErasing: eraseActive,
        isPointering: pointerActive,
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
        _pointerX = null; _pointerY = null;
        _isPinching = false; _isErasing = false; _isPointering = false;
        _handSkeletonPoints = null;
        _wasPinching = false; _wasErasing = false;
        _pinchReleaseCounter = 0; _twoFingerHeldFrames = 0;
        _sync.sendPointerHidden();
      });
      return;
    }

    final (pdfCx, pdfCy) = _camToPdf(state.cursorX, state.cursorY);
    final (pdfEx, pdfEy) = _camToPdf(state.eraserX, state.eraserY);

    setState(() {
      _cursorX = pdfCx;
      _cursorY = pdfCy;
      _eraserX = pdfEx;
      _eraserY = pdfEy;
      _isPinching = state.isPinching;
      _isErasing = state.isErasing;
      _isPointering = state.isPointering;

      if (state.isErasing) {
        _pointerX = null;
        _pointerY = null;
        _sync.sendPointerHidden();
        if (_currentStrokePoints.isNotEmpty) {
          _sync.sendDrawEvent(0, 0, isDrawing: false, discardStroke: true);
          _currentStrokePoints = [];
        }
        _sync.sendEraseAtPosition(pdfEx, pdfEy);
      } else if (state.isPinching) {
        _pointerX = pdfCx;
        _pointerY = pdfCy;
        _sync.sendPointerPosition(pdfCx, pdfCy);
        _sync.sendDrawEvent(pdfCx, pdfCy, isDrawing: true);
        _currentStrokePoints.add({'x': pdfCx, 'y': pdfCy});
      } else if (state.isPointering) {
        _pointerX = pdfCx;
        _pointerY = pdfCy;
        _sync.sendPointerPosition(pdfCx, pdfCy);
        final pts = _currentStrokePoints;
        if (pts.length >= 2) {
          final dist = math.sqrt(math.pow(pts.last['x']! - pts.first['x']!, 2) +
              math.pow(pts.last['y']! - pts.first['y']!, 2));
          if (dist < 0.02) {
            _sync.sendTapAtPosition(pts.first['x']!, pts.first['y']!);
          } else {
            _sync.sendDrawEvent(pdfCx, pdfCy, isDrawing: false);
          }
        } else if (pts.length == 1) {
          _sync.sendTapAtPosition(pts.first['x']!, pts.first['y']!);
        }
        _currentStrokePoints = [];
      } else {
        _pointerX = null;
        _pointerY = null;
        _sync.sendPointerHidden();
        final pts = _currentStrokePoints;
        final isTap = pts.length < 2 ||
            (pts.length >= 2 &&
                math.sqrt(math.pow(pts.last['x']! - pts.first['x']!, 2) +
                        math.pow(pts.last['y']! - pts.first['y']!, 2)) <
                    0.02);
        if (isTap && pts.isNotEmpty) {
          _sync.sendTapAtPosition(pts.first['x']!, pts.first['y']!);
        } else if (pts.length >= 2) {
          _sync.sendDrawEvent(pdfCx, pdfCy, isDrawing: false);
        }
        _currentStrokePoints = [];
      }
    });
  }

  Color _colorFromHex(String hex) {
    try {
      return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
    } catch (_) {
      return const Color(0xFF00FF9F);
    }
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _handPlugin?.dispose();
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
    if (_controller == null || _isSwitchingCamera) {
      return Container(
        color: Colors.black,
        child: const Center(child: CircularProgressIndicator(color: Color(0xFF00FF9F))),
      );
    }
    final ctrl = _controller!;
    if (!ctrl.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF00FF9F)));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        double w, h;
        if (screenW / screenH > _pdfAspect) {
          h = screenH;
          w = h * _pdfAspect;
        } else {
          w = screenW;
          h = w / _pdfAspect;
        }
        final left = (screenW - w) / 2;
        final top = (screenH - h) / 2;
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: Container(color: Colors.black)),
            Positioned(
              left: left, top: top, width: w, height: h,
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: ctrl.value.previewSize!.height,
                    height: ctrl.value.previewSize!.width,
                    child: CameraPreview(ctrl),
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
    double drawW, drawH, drawLeft, drawTop;
    if (screenW / screenH > _pdfAspect) {
      drawH = screenH;
      drawW = drawH * _pdfAspect;
      drawLeft = (screenW - drawW) / 2;
      drawTop = 0;
    } else {
      drawW = screenW;
      drawH = drawW / _pdfAspect;
      drawLeft = 0;
      drawTop = (screenH - drawH) / 2;
    }
    final contentRect = Rect.fromLTWH(drawLeft, drawTop, drawW, drawH);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),

          if (_handSkeletonPoints != null && _handSkeletonPoints!.length >= 15)
            Positioned(
              left: drawLeft, top: drawTop, width: drawW, height: drawH,
              child: SkeletonOverlay(
                handPoints: _handSkeletonPoints,
                imageSize: _lastImageSize,
                screenSize: Size(drawW, drawH),
                isPinching: _isPinching,
                isErasing: _isErasing,
              ),
            ),

          RepaintBoundary(
            child: CustomPaint(
              size: Size(screenW, screenH),
              painter: _StrokeOverlayPainter(
                savedStrokes: _sync.cachedStrokes,
                currentPoints: _currentStrokePoints,
                currentColor: _sync.drawColor,
                contentRect: contentRect,
              ),
            ),
          ),

          if (_isErasing && _eraserX != null && _eraserY != null)
            Positioned(
              left: drawLeft + _eraserX! * drawW - 0.09 * drawW,
              top: drawTop + _eraserY! * drawH - 0.09 * drawW,
              child: Container(
                width: 0.18 * drawW, height: 0.18 * drawW,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.7), width: 2),
                ),
              ),
            ),

          if ((_isPointering || _isPinching) && _pointerX != null && _pointerY != null)
            Positioned(
              left: drawLeft + _pointerX! * drawW - 14,
              top: drawTop + _pointerY! * drawH - 14,
              child: IgnorePointer(
                child: CustomPaint(
                  size: const Size(28, 28),
                  painter: _PointerIconPainter(),
                ),
              ),
            )
          else if (!_isErasing && !_isPinching && _cursorX != null && _cursorY != null)
            Positioned(
              left: drawLeft + _cursorX! * drawW - (_isPinching ? 14 : 10),
              top: drawTop + _cursorY! * drawH - (_isPinching ? 14 : 10),
              child: Container(
                width: _isPinching ? 28 : 20,
                height: _isPinching ? 28 : 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                    color: _isPinching ? _colorFromHex(_sync.drawColor).withValues(alpha: 0.25) : Colors.transparent,
                  border: Border.all(
                    color: _isPinching ? _colorFromHex(_sync.drawColor) : Colors.white.withValues(alpha: 0.6),
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
                    const SizedBox(width: 12),
                    Text('${_sync.cachedStrokes.length}', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
                    const Spacer(),
                    if (_hasMultipleCameras)
                      IconButton(
                        onPressed: _isSwitchingCamera ? null : _switchCamera,
                        icon: Icon(
                          _cameras.isNotEmpty && _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                              ? Icons.camera_rear
                              : Icons.camera_front,
                          color: Colors.white,
                          size: 24,
                        ),
                        tooltip: _cameras.isNotEmpty && _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                            ? 'Arka kameraya geç'
                            : 'Ön kameraya geç',
                      ),
                    IconButton(
                      onPressed: () async {
                        await _sync.clearAllStrokes();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.delete_sweep, color: Colors.white, size: 22),
                      tooltip: 'Tümünü sil',
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

}

class _HandResult {
  final double cursorX, cursorY, eraserX, eraserY;
  final bool isPinching, isErasing, isPointering;
  _HandResult({required this.cursorX, required this.cursorY,
    required this.eraserX, required this.eraserY,
    required this.isPinching, required this.isErasing,
    this.isPointering = false});
}

class _StrokeOverlayPainter extends CustomPainter {
  final List<StrokeData> savedStrokes;
  final List<Map<String, double>> currentPoints;
  final String currentColor;
  final Rect contentRect;
  _StrokeOverlayPainter({
    required this.savedStrokes,
    required this.currentPoints,
    this.currentColor = '#00ff9f',
    required this.contentRect,
  });

  Offset _toRect(double x, double y) => Offset(
    contentRect.left + x * contentRect.width,
    contentRect.top + y * contentRect.height,
  );

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
          _toRect(stroke.points[i - 1]['x']!, stroke.points[i - 1]['y']!),
          _toRect(stroke.points[i]['x']!, stroke.points[i]['y']!),
          paint);
      }
    }
    if (currentPoints.length >= 2) {
      final paint = Paint()
        ..color = _parseColor(currentColor)
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      for (int i = 1; i < currentPoints.length; i++) {
        canvas.drawLine(
          _toRect(currentPoints[i - 1]['x']!, currentPoints[i - 1]['y']!),
          _toRect(currentPoints[i]['x']!, currentPoints[i]['y']!),
          paint);
      }
    }
  }

  Color _parseColor(String hex) {
    try { return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16)); }
    catch (_) { return const Color(0xFF00FF9F); }
  }

  @override
  bool shouldRepaint(covariant _StrokeOverlayPainter old) =>
      savedStrokes != old.savedStrokes ||
      currentPoints != old.currentPoints ||
      currentColor != old.currentColor ||
      contentRect != old.contentRect;
}

class _PointerIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const color = Color(0xFFFF4444);
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, 10, Paint()
      ..color = color.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(center, 6, Paint()..color = color);
    canvas.drawCircle(center, 6, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
