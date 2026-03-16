import 'dart:convert';
import 'package:http/http.dart' as http;

/// desktop-cizim Supabase yapılandırması
/// https://github.com/bekirs01/desktop-cizim
class SupabaseConfig {
  static const String url = 'https://jtnwvkjtiijhebsqucqe.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp0bnd2a2p0aWlqaGVic3F1Y3FlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM0MjczNzIsImV4cCI6MjA4OTAwMzM3Mn0.msQYIAqQZG8tdDqCRGgxSXmxma34MSldbQYiRlbl0UY';
}

class SyncService {
  final String projectLink;
  final int pageNum;
  final String? shareToken;

  SyncService(this.projectLink)
      : shareToken = _extractShareToken(projectLink),
        pageNum = 1;

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

  Future<List<Map<String, dynamic>>> _fetchStrokes() async {
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
      return List<Map<String, dynamic>>.from(strokes);
    }
    return [];
  }

  Future<void> saveStroke(List<Map<String, dynamic>> points) async {
    if (shareToken == null || points.length < 2) return;
    final existing = await _fetchStrokes();
    final newStroke = {
      'points': points,
      'color': '#00ff9f',
      'lineWidth': 4,
    };
    final all = [...existing, newStroke];
    await _upsert(all);
  }

  Future<void> erase() async {
    if (shareToken == null) return;
    await _upsert([]);
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
}
