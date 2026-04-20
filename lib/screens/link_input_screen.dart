import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'camera_screen.dart';

class LinkInputScreen extends StatefulWidget {
  const LinkInputScreen({super.key});

  @override
  State<LinkInputScreen> createState() => _LinkInputScreenState();
}

class _LinkInputScreenState extends State<LinkInputScreen> {
  final _linkController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLastLink();
  }

  Future<void> _loadLastLink() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('last_link');
    if (saved != null && saved.isNotEmpty) {
      setState(() => _linkController.text = saved);
    }
  }

  Future<void> _saveLink(String link) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_link', link);
  }

  void _submit() {
    final trimmed = _linkController.text.trim();

    if (trimmed.isEmpty) {
      setState(() => _error = 'Введите ссылку');
      return;
    }

    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      setState(() => _error =
          'Укажите корректный URL (должен начинаться с http:// или https://)');
      return;
    }

    _saveLink(trimmed);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(projectLink: trimmed),
      ),
    );
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A1A2E),
              Color(0xFF16213E),
              Color(0xFF0F3460),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Card(
                color: const Color(0xFF1E2A3A).withValues(alpha: 0.95),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                elevation: 8,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF00FF9F),
                              Color(0xFF00B4D8),
                            ],
                          ),
                        ),
                        child: const Center(
                          child: Text('✋', style: TextStyle(fontSize: 32)),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Презентация жестами',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Введите ссылку и управляйте презентацией с камеры.\nНа телефоне откроется только камера.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFFB0BEC5),
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _linkController,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        onSubmitted: (_) => _submit(),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Ссылка на проект',
                          labelStyle:
                              const TextStyle(color: Color(0xFF90A4AE)),
                          hintText: 'https://...?id=ТОКЕН',
                          hintStyle:
                              const TextStyle(color: Color(0xFF546E7A)),
                          errorText: _error,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Color(0xFF37474F)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: Color(0xFF00FF9F), width: 2),
                          ),
                          prefixIcon: const Icon(Icons.link,
                              color: Color(0xFF90A4AE)),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF9F),
                            foregroundColor: const Color(0xFF1A1A2E),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          child: const Text('Открыть камеру'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Большой палец + указательный = рисование  |  Указательный + средний = стирание',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF78909C)),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
