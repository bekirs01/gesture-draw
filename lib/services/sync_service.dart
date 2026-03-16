import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;

class SupabaseConfig {
  static const String url = 'https://jtnwvkjtiijhebsqucqe.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp0bnd2a2p0aWlqaGVic3F1Y3FlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM0MjczNzIsImV4cCI6MjA4OTAwMzM3Mn0.msQYIAqQZG8tdDqCRGgxSXmxma34MSldbQYiRlbl0UY';
}

class StrokeData {
  List<Map<String, double>> points;
  final String color;
  final int lineWidth;

  StrokeData({
    required this.points,
    this.color = '#00ff9f',
    this.lineWidth = 4,
  });

  Map<String, dynamic> toJson() => {
        'points': points,
        'color': color,
        'lineWidth': lineWidth,
      };

  factory StrokeData.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List<dynamic>? ?? [];
    return StrokeData(
      points: rawPoints
          .map((p) => {
                'x': (p['x'] as num).toDouble(),
                'y': (p['y'] as num).toDouble(),
              })
          .toList(),
      color: json['color'] as String? ?? '#00ff9f',
      lineWidth: (json['lineWidth'] as num?)?.toInt() ?? 4,
    );
  }
}

class SyncService {
  final String projectLink;
  final int pageNum;
  final String? shareToken;

  List<StrokeData> _cachedStrokes = [];
  List<Map<String, double>> _currentStrokePoints = [];
  bool _isDrawing = false;

  WebSocket? _realtimeSocket;
  Timer? _heartbeatTimer;
  int _lastBroadcastTime = 0;
  int _lastEraseApplyTime = 0;
  int _lastErasePersistTime = 0;
  static const _broadcastDebounceMs = 50;
  static const _eraseApplyDebounceMs = 40;
  static const _erasePersistDebounceMs = 140;

  static const _eraseRadius = 0.09;
  static const _eraseRadiusSq = _eraseRadius * _eraseRadius;
  static const _minStrokeDist = 0.002;
  static const _dpEpsilon = 0.002;
  bool _erasePersistInFlight = false;
  bool _erasePersistPending = false;

  SyncService(this.projectLink)
      : shareToken = _extractShareToken(projectLink),
        pageNum = 1 {
    if (shareToken != null) {
      _loadInitialStrokes();
      _connectRealtime();
    }
  }

  static String? _extractShareToken(String link) {
    try {
      final uri = Uri.tryParse(link);
      if (uri != null) {
        final id = uri.queryParameters['id'];
        if (id != null && id.isNotEmpty) return id.trim();
      }
      final segments = link.split('/').where((s) => s.isNotEmpty);
      final last = segments.lastOrNull;
      if (last != null &&
          last.length > 3 &&
          !last.startsWith('http') &&
          !last.contains('.')) {
        return last;
      }
    } catch (_) {}
    return null;
  }

  String? get projectId => shareToken;

  List<StrokeData> get cachedStrokes => List.unmodifiable(_cachedStrokes);

  // Bu cihazdaki kamera akışında el koordinatları zaten doğru yönde geliyor.
  // Tekrar aynalama yapınca çizim tersine dönüyor.
  double mirrorX(double camX) => camX;

  Future<void> _loadInitialStrokes() async {
    try {
      final strokes = await _fetchStrokes();
      _cachedStrokes = strokes;
    } catch (_) {}
  }

  Future<void> _connectRealtime() async {
    if (shareToken == null) return;
    try {
      final baseWs = SupabaseConfig.url
              .replaceFirst('https://', 'wss://')
              .replaceFirst('http://', 'ws://');
      final wsUrl = '$baseWs/realtime/v1/websocket?apikey=${SupabaseConfig.anonKey}&vsn=1.0.0';

      _realtimeSocket = await WebSocket.connect(wsUrl);

      final joinMsg = jsonEncode({
        'topic': 'realtime:pdf_page_strokes:$shareToken',
        'event': 'phx_join',
        'payload': {
          'config': {
            'broadcast': {'self': false}
          }
        },
        'ref': '1',
      });
      _realtimeSocket!.add(joinMsg);

      _realtimeSocket!.listen(
        (data) {},
        onError: (_) {},
        onDone: () {},
      );

      _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _realtimeSocket?.add(jsonEncode({
            'topic': 'phoenix',
            'event': 'heartbeat',
            'payload': {},
            'ref': 'hb',
          }));
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _broadcastStrokeProgress(List<Map<String, double>> points) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBroadcastTime < _broadcastDebounceMs) return;
    _lastBroadcastTime = now;

    final payload = {
      'type': 'broadcast',
      'event': 'stroke_progress',
      'payload': {
        'pageNum': pageNum,
        'stroke': {
          'points': points,
          'color': '#00ff9f',
          'lineWidth': 4,
        },
      },
    };
    _sendBroadcast(payload);
  }

  void _broadcastStrokeComplete(List<StrokeData> strokes) {
    final payload = {
      'type': 'broadcast',
      'event': 'stroke',
      'payload': {
        'pageNum': pageNum,
        'strokes': strokes.map((s) => s.toJson()).toList(),
      },
    };
    _sendBroadcast(payload);
  }

  void _sendBroadcast(Map<String, dynamic> payload) {
    try {
      _realtimeSocket?.add(jsonEncode({
        'topic': 'realtime:pdf_page_strokes:$shareToken',
        'event': 'broadcast',
        'payload': payload,
        'ref': 'b',
      }));
    } catch (_) {}
  }

  void sendDrawEvent(double camX, double camY, {required bool isDrawing}) {
    if (shareToken == null) return;

    final docX = mirrorX(camX);
    final docY = camY;

    if (isDrawing) {
      _isDrawing = true;
      final last = _currentStrokePoints.lastOrNull;
      final dist = last != null
          ? math.sqrt(math.pow(docX - last['x']!, 2) + math.pow(docY - last['y']!, 2))
          : double.infinity;
      if (dist > _minStrokeDist) {
        _currentStrokePoints.add({'x': docX, 'y': docY});
        _broadcastStrokeProgress(_currentStrokePoints);
      }
    } else if (_isDrawing) {
      _isDrawing = false;
      if (_currentStrokePoints.length >= 2) {
        final simplified = simplifyPoints(_currentStrokePoints, _dpEpsilon);
        _saveStroke(simplified);
      }
      _currentStrokePoints = [];
    }
  }

  void sendEraseAtPosition(double camX, double camY) {
    if (shareToken == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastEraseApplyTime < _eraseApplyDebounceMs) return;
    _lastEraseApplyTime = now;

    final docX = mirrorX(camX);
    final docY = camY;

    final modified = _eraseLayerAtPosition(_cachedStrokes, docX, docY);
    _cachedStrokes = modified;
    _scheduleErasePersist();
  }

  void _scheduleErasePersist() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastErasePersistTime < _erasePersistDebounceMs) {
      _erasePersistPending = true;
      return;
    }
    if (_erasePersistInFlight) {
      _erasePersistPending = true;
      return;
    }
    _persistEraseState();
  }

  void _persistEraseState() async {
    _erasePersistInFlight = true;
    _erasePersistPending = false;
    _lastErasePersistTime = DateTime.now().millisecondsSinceEpoch;
    final snapshot = List<StrokeData>.from(_cachedStrokes);
    try {
      await _upsert(snapshot.map((s) => s.toJson()).toList());
      _broadcastStrokeComplete(snapshot);
    } catch (_) {
      // Sessiz geç: bir sonraki döngüde tekrar denenecek.
    } finally {
      _erasePersistInFlight = false;
      if (_erasePersistPending) {
        _persistEraseState();
      }
    }
  }

  List<StrokeData> _eraseLayerAtPosition(
      List<StrokeData> strokes, double ex, double ey) {
    final result = <StrokeData>[];
    for (final stroke in strokes) {
      final segments = _splitStrokeByEraser(stroke.points, ex, ey);
      for (final seg in segments) {
        if (seg.length >= 2) {
          result.add(StrokeData(
            points: seg,
            color: stroke.color,
            lineWidth: stroke.lineWidth,
          ));
        }
      }
    }
    return result;
  }

  List<List<Map<String, double>>> _splitStrokeByEraser(
      List<Map<String, double>> points, double ex, double ey) {
    final segments = <List<Map<String, double>>>[];
    var currentSeg = <Map<String, double>>[];

    for (final p in points) {
      final dx = p['x']! - ex;
      final dy = p['y']! - ey;
      final distSq = dx * dx + dy * dy;
      if (distSq < _eraseRadiusSq) {
        if (currentSeg.length >= 2) segments.add(List.from(currentSeg));
        currentSeg = [];
      } else {
        currentSeg.add(p);
      }
    }
    if (currentSeg.length >= 2) segments.add(currentSeg);
    return segments;
  }

  void _saveStroke(List<Map<String, double>> points) async {
    final stroke = StrokeData(points: points);
    try {
      final existing = await _fetchStrokes();
      final all = [...existing, stroke];
      _cachedStrokes = all;
      await _upsert(all.map((s) => s.toJson()).toList());
      _broadcastStrokeComplete(all);
    } catch (_) {
      _cachedStrokes.add(stroke);
      await _upsert([stroke.toJson()]);
      _broadcastStrokeComplete(_cachedStrokes);
    }
  }

  Future<List<StrokeData>> _fetchStrokes() async {
    if (shareToken == null) return [];
    final res = await http.get(
      Uri.parse(
          '${SupabaseConfig.url}/rest/v1/pdf_page_strokes?share_token=eq.$shareToken&page_num=eq.$pageNum&select=strokes'),
      headers: {
        'apikey': SupabaseConfig.anonKey,
        'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
      },
    );
    if (res.statusCode != 200) return [];
    final list = jsonDecode(res.body) as List<dynamic>?;
    if (list == null || list.isEmpty) return [];
    final strokes = list.first['strokes'];
    if (strokes is List) {
      return strokes
          .map((s) => StrokeData.fromJson(s as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<void> _upsert(List<Map<String, dynamic>> strokes) async {
    if (shareToken == null) return;
    final body = jsonEncode({
      'share_token': shareToken,
      'page_num': pageNum,
      'strokes': strokes,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    await http.post(
      Uri.parse('${SupabaseConfig.url}/rest/v1/pdf_page_strokes'),
      headers: {
        'apikey': SupabaseConfig.anonKey,
        'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal,resolution=merge-duplicates',
      },
      body: body,
    );
  }

  Future<void> clearAllStrokes() async {
    if (shareToken == null) return;
    _cachedStrokes = [];
    _currentStrokePoints = [];
    _isDrawing = false;
    try {
      await _upsert([]);
      _broadcastStrokeComplete([]);
    } catch (_) {}
  }

  void destroy() {
    _heartbeatTimer?.cancel();
    _realtimeSocket?.close();
    _realtimeSocket = null;
  }
}

List<Map<String, double>> simplifyPoints(
    List<Map<String, double>> points, double epsilon) {
  if (points.length <= 2) return points;

  var maxDist = 0.0;
  var maxIdx = 0;

  final start = points.first;
  final end = points.last;

  for (int i = 1; i < points.length - 1; i++) {
    final d = _perpendicularDistance(points[i], start, end);
    if (d > maxDist) {
      maxDist = d;
      maxIdx = i;
    }
  }

  if (maxDist > epsilon) {
    final left = simplifyPoints(points.sublist(0, maxIdx + 1), epsilon);
    final right = simplifyPoints(points.sublist(maxIdx), epsilon);
    return [...left.sublist(0, left.length - 1), ...right];
  } else {
    return [start, end];
  }
}

double _perpendicularDistance(
    Map<String, double> point, Map<String, double> lineStart, Map<String, double> lineEnd) {
  final dx = lineEnd['x']! - lineStart['x']!;
  final dy = lineEnd['y']! - lineStart['y']!;
  final lenSq = dx * dx + dy * dy;
  if (lenSq == 0) {
    return math.sqrt(math.pow(point['x']! - lineStart['x']!, 2) +
        math.pow(point['y']! - lineStart['y']!, 2));
  }

  var t = ((point['x']! - lineStart['x']!) * dx +
          (point['y']! - lineStart['y']!) * dy) /
      lenSq;
  t = t.clamp(0.0, 1.0);
  final projX = lineStart['x']! + t * dx;
  final projY = lineStart['y']! + t * dy;
  return math.sqrt(
      math.pow(point['x']! - projX, 2) + math.pow(point['y']! - projY, 2));
}
