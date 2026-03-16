import 'package:flutter/material.dart';
import 'screens/link_input_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenimApp());
}

class BenimApp extends StatelessWidget {
  const BenimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'El Hareketi Sunum',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00FF9F),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
      ),
      home: const LinkInputScreen(),
    );
  }
}
