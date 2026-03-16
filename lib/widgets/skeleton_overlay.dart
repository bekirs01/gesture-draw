import 'package:flutter/material.dart';

class SkeletonOverlay extends StatelessWidget {
  final List<Offset>? handPoints;
  final Size imageSize;
  final Size screenSize;
  final bool isPinching;
  final bool isErasing;

  const SkeletonOverlay({
    super.key,
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
  final List<Offset>? handPoints;
  final Size imageSize;
  final Size screenSize;
  final Offset Function(double x, double y) toScreen;
  final bool isPinching;
  final bool isErasing;

  _SkeletonPainter({
    required this.handPoints,
    required this.imageSize,
    required this.screenSize,
    required this.toScreen,
    required this.isPinching,
    required this.isErasing,
  });

  static const _handColor = Color(0xFF00FF9F);

  @override
  void paint(Canvas canvas, Size size) {
    _drawHand(canvas);
  }

  void _drawHand(Canvas canvas) {
    if (handPoints == null || handPoints!.length < 15) return;

    final maxValidJump = screenSize.shortestSide * 0.28;
    final linePaint = Paint()
      ..color = _handColor
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

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
        if ((a - b).distance <= maxValidJump) {
          canvas.drawLine(a, b, linePaint);
        }
      }
    }

    if (handPoints!.length >= 17) {
      final wrist = toScreen(handPoints![0].dx, handPoints![0].dy);
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
        ..color = _handColor.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawPath(palmPath, palmPaint);
      final palmStroke = Paint()
        ..color = _handColor.withValues(alpha: 0.5)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(palmPath, palmStroke);
    }
  }

  @override
  bool shouldRepaint(covariant _SkeletonPainter oldDelegate) =>
      handPoints != oldDelegate.handPoints ||
      isPinching != oldDelegate.isPinching ||
      isErasing != oldDelegate.isErasing;
}
