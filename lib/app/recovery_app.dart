import 'package:flutter/material.dart';

import '../features/recovery/presentation/recovery_home_page.dart';
import '../features/recovery/presentation/recovery_controller.dart';

class RecoveryApp extends StatelessWidget {
  const RecoveryApp({
    super.key,
    this.recoveryController,
    this.autoInitialize = true,
  });

  final RecoveryController? recoveryController;
  final bool autoInitialize;

  static const Color background = Color(0xFF071013);
  static const Color surface = Color(0xFF0E1A1E);
  static const Color primary = Color(0xFF2DD4B5);

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
      surface: surface,
    );

    return MaterialApp(
      title: 'Recovera Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: background,
        dividerColor: const Color(0xFF203035),
        cardTheme: const CardThemeData(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFF203035)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF111F23),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF294047)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF294047)),
          ),
        ),
      ),
      home: RecoveryHomePage(
        controller: recoveryController,
        autoInitialize: autoInitialize,
      ),
    );
  }
}
