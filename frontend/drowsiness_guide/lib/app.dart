import 'package:flutter/material.dart';
import 'screens/live_monitor_screen.dart';
import 'screens/drowsiness_detected_screen.dart';
import 'screens/login_screen.dart';

class DriverSafetyApp extends StatelessWidget {
  const DriverSafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Drowsiness Guide',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,

        scaffoldBackgroundColor: const Color(0xFF0B1220),

        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE5E7EB),
          surface: Color(0xFF0E1628),
        ),

        cardTheme: const CardThemeData(
          color: Color(0xFF0E1628),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFF22304A), width: 1),
          ),
        ),

        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
      ),
      routes: {
        '/': (context) => const LoginScreen(),
        '/dashboard': (context) => const LiveMonitorScreen(),
        '/drowsiness-detected': (context) => const DrowsinessDetectedScreen(),
      },
      initialRoute: '/',
    );
  }
}
