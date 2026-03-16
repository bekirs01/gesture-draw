import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class SkeletonOverlay extends StatelessWidget {
  final Pose? pose;
  final List<Offset>? handPoints;
  final Size imageSize;
  final Size screenSize;
  final bool isPinching;
  final bool isErasing;

  const SkeletonOverlay({
    super.key,
    this.pose,
    this.handPoints,
    required this.imageSize,
    required this.screenSize,
    this.isPinching = false,
    this.isErasing = false,
  });

  Offset _toScreen(double x, double y) {
    final scaleX = screenSize.width / imageSize.width;
    final scaleY = screenSize.height / imageSize.height;
    final scale = scaleX > scaleY ? scaleX : scaleY;
    final offsetX = (screenSize.width - imageSize.width * scale) / 2;
    final offsetY = (screenSize.height - imageSize.height * scale) / 2;
    final sx = x * scale + offsetX;
    final sy = y * scale + offsetY;
    return Offset(sx, sy);
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SkeletonPainter(
        pose: pose,
        handPoints: handPoints,
        imageSize: imageSize,
        screenSize: screenSize,
        toScreen: _toScreen,
        isPinching: isPinching,
        isErasing: isErasing,
      ),
      size: screenSize,
    );
  }
}

class _SkeletonPainter extends CustomPainter {
  final Pose? pose;
  final List<Offset>? handPoints;
  final Size imageSize;
  final Size screenSize;
  final Offset Function(double x, double y) toScreen;
  final bool isPinching;
  final bool isErasing;

  _SkeletonPainter({
    required this.pose,
    required this.handPoints,
    required this.imageSize,
    required this.screenSize,
    required this.toScreen,
    required this.isPinching,
    required this.isErasing,
  });

  static const _bodyColor = Color(0xFF00E5FF);
  static const _bodyGlow = Color(0x6600E5FF);
  static const _pinchColor = Color(0xFFFFD600);
  static const _eraseColor = Color(0xFFFF1744);
  static const _jointColor = Color(0xFFFFFFFF);
  static const _liteHandRender = true;

  // Parmak renkleri: başparmak kırmızı, işaret cyan, orta sarı, yüzük mavi, serçe mor
  static const _thumbColor = Color(0xFFFF0000);
  static const _indexColor = Color(0xFF00FFFF);
  static const _middleColor = Color(0xFFFFFF00);
  static const _ringColor = Color(0xFF0080FF);
  static const _pinkyColor = Color(0xFF8000FF);
  static const _wristColor = Color(0xFFFFFFFF);
  static const _palmColor = Color(0xFF00FF9F);

  static Color _fingerColor(int idx) {
    if (idx == 0) return _wristColor;
    if (idx <= 4) return _thumbColor;
    if (idx <= 8) return _indexColor;
    if (idx <= 12) return _middleColor;
    if (idx <= 16) return _ringColor;
    return _pinkyColor;
  }

  static Color _connectionColor(int a, int b) {
    final isPalm = (a == 5 && b == 9) || (a == 9 && b == 13) || (a == 13 && b == 17);
    if (isPalm) return _palmColor;
    return _fingerColor(a < b ? a : b);
  }

  void _drawGlowLine(Canvas canvas, Offset a, Offset b, Color color, Color glow, double width) {
    final glowPaint = Paint()
      ..color = glow
      ..strokeWidth = width + 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawLine(a, b, glowPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a, b, linePaint);
  }

  void _drawGlowPoint(Canvas canvas, Offset p, Color color, double radius) {
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(p, radius + 4, glowPaint);

    final pointPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(p, radius, pointPaint);

    final ringPaint = Paint()
      ..color = _jointColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(p, radius, ringPaint);
  }

  void _drawPoseLine(Canvas canvas, PoseLandmark? a, PoseLandmark? b) {
    if (a == null || b == null || a.likelihood < 0.4 || b.likelihood < 0.4) return;
    _drawGlowLine(canvas, toScreen(a.x, a.y), toScreen(b.x, b.y), _bodyColor, _bodyGlow, 2.5);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _drawBody(canvas);
    _drawHand(canvas);
  }

  void _drawBody(Canvas canvas) {
    if (pose == null) return;
    final lm = pose!.landmarks;

    final pairs = [
      [PoseLandmarkType.nose, PoseLandmarkType.leftEye],
      [PoseLandmarkType.leftEye, PoseLandmarkType.leftEar],
      [PoseLandmarkType.nose, PoseLandmarkType.rightEye],
      [PoseLandmarkType.rightEye, PoseLandmarkType.rightEar],
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder],
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow],
      [PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist],
      [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow],
      [PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist],
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip],
      [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip],
      [PoseLandmarkType.leftHip, PoseLandmarkType.rightHip],
      [PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee],
      [PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle],
      [PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee],
      [PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle],
      [PoseLandmarkType.leftAnkle, PoseLandmarkType.leftHeel],
      [PoseLandmarkType.leftAnkle, PoseLandmarkType.leftFootIndex],
      [PoseLandmarkType.rightAnkle, PoseLandmarkType.rightHeel],
      [PoseLandmarkType.rightAnkle, PoseLandmarkType.rightFootIndex],
      [PoseLandmarkType.leftHeel, PoseLandmarkType.leftFootIndex],
      [PoseLandmarkType.rightHeel, PoseLandmarkType.rightFootIndex],
    ];

    for (final pair in pairs) {
      _drawPoseLine(canvas, lm[pair[0]], lm[pair[1]]);
    }

    final majorJoints = [
      PoseLandmarkType.nose,
      PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftElbow, PoseLandmarkType.rightElbow,
      PoseLandmarkType.leftWrist, PoseLandmarkType.rightWrist,
      PoseLandmarkType.leftHip, PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee, PoseLandmarkType.rightKnee,
      PoseLandmarkType.leftAnkle, PoseLandmarkType.rightAnkle,
    ];

    for (final type in majorJoints) {
      final p = lm[type];
      if (p != null && p.likelihood >= 0.4) {
        _drawGlowPoint(canvas, toScreen(p.x, p.y), _bodyColor, 5);
      }
    }

    final minorJoints = [
      PoseLandmarkType.leftEye, PoseLandmarkType.rightEye,
      PoseLandmarkType.leftEar, PoseLandmarkType.rightEar,
      PoseLandmarkType.leftHeel, PoseLandmarkType.rightHeel,
      PoseLandmarkType.leftFootIndex, PoseLandmarkType.rightFootIndex,
    ];

    for (final type in minorJoints) {
      final p = lm[type];
      if (p != null && p.likelihood >= 0.4) {
        _drawGlowPoint(canvas, toScreen(p.x, p.y), _bodyColor, 3);
      }
    }
  }

  void _drawFilledSegment(Canvas canvas, Offset a, Offset b, Color color, double widthAtA, double widthAtB) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = (dx * dx + dy * dy).clamp(1.0, double.infinity);
    final perpX = -dy / len;
    final perpY = dx / len;

    final path = Path()
      ..moveTo(a.dx + perpX * widthAtA, a.dy + perpY * widthAtA)
      ..lineTo(a.dx - perpX * widthAtA, a.dy - perpY * widthAtA)
      ..lineTo(b.dx - perpX * widthAtB, b.dy - perpY * widthAtB)
      ..lineTo(b.dx + perpX * widthAtB, b.dy + perpY * widthAtB)
      ..close();

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);
  }

  void _drawHand(Canvas canvas) {
    if (handPoints == null || handPoints!.length < 15) return;

    if (_liteHandRender) {
      final maxValidJump = screenSize.shortestSide * 0.30;

      const connections = [
        [0, 1], [1, 2], [2, 3], [3, 4],
        [0, 5], [5, 6], [6, 7], [7, 8],
        [0, 9], [9, 10], [10, 11], [11, 12],
        [0, 13], [13, 14], [14, 15], [15, 16],
        [0, 17], [17, 18], [18, 19], [19, 20],
        [5, 9], [9, 13], [13, 17],
      ];

      for (final c in connections) {
        if (c[0] < handPoints!.length && c[1] < handPoints!.length) {
          final a = toScreen(handPoints![c[0]].dx, handPoints![c[0]].dy);
          final b = toScreen(handPoints![c[1]].dx, handPoints![c[1]].dy);
          if ((a - b).distance > maxValidJump) continue;
          final color = _connectionColor(c[0], c[1]);
          final paint = Paint()
            ..color = color
            ..strokeWidth = 3.0
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round;
          canvas.drawLine(a, b, paint);
        }
      }

      const tipIndices = {4, 8, 12, 16, 20};
      for (int i = 0; i < handPoints!.length; i++) {
        final p = toScreen(handPoints![i].dx, handPoints![i].dy);
        final color = _fingerColor(i);
        final pointPaint = Paint()..color = color..style = PaintingStyle.fill;
        final radius = tipIndices.contains(i) ? 5.0 : 3.0;
        canvas.drawCircle(p, radius, pointPaint);
        if (tipIndices.contains(i)) {
          final ringPaint = Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5;
          canvas.drawCircle(p, radius, ringPaint);
        }
      }
      return;
    }

    final fingerGroups = [
      [0, 1, 2, 3, 4],
      [0, 5, 6, 7, 8],
      [0, 9, 10, 11, 12],
      [0, 13, 14, 15, 16],
      [0, 17, 18, 19, 20],
    ];

    final palmConnections = [
      [5, 9], [9, 13], [13, 17],
    ];

    final scale = (screenSize.width / imageSize.width + screenSize.height / imageSize.height) / 2;
    final baseW = 5.0 * scale.clamp(0.8, 1.5);

    for (final group in fingerGroups) {
      for (int i = 0; i < group.length - 1; i++) {
        final idx0 = group[i];
        final idx1 = group[i + 1];
        if (idx0 < handPoints!.length && idx1 < handPoints!.length) {
          final p0 = handPoints![idx0];
          final p1 = handPoints![idx1];
          final sp0 = toScreen(p0.dx, p0.dy);
          final sp1 = toScreen(p1.dx, p1.dy);
          final w0 = i == 0 ? baseW * 1.2 : baseW - i * 0.8;
          final w1 = baseW - (i + 1) * 0.8;
          final segColor = _connectionColor(idx0, idx1);
          _drawFilledSegment(canvas, sp0, sp1, segColor, w0.clamp(2.0, 8.0), w1.clamp(1.5, 6.0));
          _drawGlowLine(canvas, sp0, sp1, segColor, segColor.withValues(alpha: 0.5), 3.5);
        }
      }
    }

    for (final c in palmConnections) {
      if (c[0] < handPoints!.length && c[1] < handPoints!.length) {
        final p0 = handPoints![c[0]];
        final p1 = handPoints![c[1]];
        final sp0 = toScreen(p0.dx, p0.dy);
        final sp1 = toScreen(p1.dx, p1.dy);
        _drawFilledSegment(canvas, sp0, sp1, _palmColor.withValues(alpha: 0.5), baseW * 0.6, baseW * 0.6);
        _drawGlowLine(canvas, sp0, sp1, _palmColor.withValues(alpha: 0.7), _palmColor.withValues(alpha: 0.4), 2.0);
      }
    }

    final wrist = handPoints!.isNotEmpty ? toScreen(handPoints![0].dx, handPoints![0].dy) : null;
    if (wrist != null && handPoints!.length >= 17) {
      final mcp5 = toScreen(handPoints![5].dx, handPoints![5].dy);
      final mcp9 = toScreen(handPoints![9].dx, handPoints![9].dy);
      final mcp13 = toScreen(handPoints![13].dx, handPoints![13].dy);
      final mcp17 = toScreen(handPoints![17].dx, handPoints![17].dy);
      final palmPath = Path()
        ..moveTo(wrist.dx, wrist.dy)
        ..lineTo(mcp5.dx, mcp5.dy)
        ..lineTo(mcp9.dx, mcp9.dy)
        ..lineTo(mcp13.dx, mcp13.dy)
        ..lineTo(mcp17.dx, mcp17.dy)
        ..close();
      final palmPaint = Paint()
        ..color = _palmColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawPath(palmPath, palmPaint);
    }

    final tipIndices = [4, 8, 12, 16, 20];
    final pipIndices = [2, 6, 10, 14, 18];
    final mcpIndices = [1, 5, 9, 13, 17];

    for (int i = 0; i < handPoints!.length; i++) {
      final p = handPoints![i];
      final sp = toScreen(p.dx, p.dy);
      final ptColor = _fingerColor(i);
      if (tipIndices.contains(i)) {
        _drawGlowPoint(canvas, sp, ptColor, 8);
      } else if (pipIndices.contains(i)) {
        _drawGlowPoint(canvas, sp, ptColor, 7);
      } else if (mcpIndices.contains(i) || i == 0) {
        _drawGlowPoint(canvas, sp, ptColor, 7);
      } else {
        _drawGlowPoint(canvas, sp, ptColor, 6);
      }
    }

    if (isPinching && handPoints!.length > 8) {
      final thumbSp = toScreen(handPoints![4].dx, handPoints![4].dy);
      final indexSp = toScreen(handPoints![8].dx, handPoints![8].dy);
      _drawGlowLine(canvas, thumbSp, indexSp, _pinchColor, _pinchColor.withValues(alpha: 0.6), 5);
      final mid = Offset(
        (handPoints![4].dx + handPoints![8].dx) / 2,
        (handPoints![4].dy + handPoints![8].dy) / 2,
      );
      final sp = toScreen(mid.dx, mid.dy);
      final glowPaint = Paint()
        ..color = _pinchColor.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawCircle(sp, 18, glowPaint);
      final innerPaint = Paint()
        ..color = _pinchColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(sp, 8, innerPaint);
    }

    if (isErasing && handPoints!.length > 12) {
      final indexSp = toScreen(handPoints![8].dx, handPoints![8].dy);
      final middleSp = toScreen(handPoints![12].dx, handPoints![12].dy);
      _drawGlowLine(canvas, indexSp, middleSp, _eraseColor, _eraseColor.withValues(alpha: 0.5), 5);
      final center = Offset(
        (handPoints![8].dx + handPoints![12].dx) / 2,
        (handPoints![8].dy + handPoints![12].dy) / 2,
      );
      final sp = toScreen(center.dx, center.dy);
      final glowPaint = Paint()
        ..color = _eraseColor.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
      canvas.drawCircle(sp, 20, glowPaint);
      final ringPaint = Paint()
        ..color = _eraseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawCircle(sp, 14, ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SkeletonPainter oldDelegate) =>
      pose != oldDelegate.pose ||
      handPoints != oldDelegate.handPoints ||
      isPinching != oldDelegate.isPinching ||
      isErasing != oldDelegate.isErasing;
}
