import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'screens/fleet_operator_dashboard.dart';
import 'screens/live_monitor_screen.dart';
import 'screens/drowsiness_detected_screen.dart';
import 'screens/login_screen.dart';
import 'screens/osm_map_screen.dart';
import 'screens/role_selection_screen.dart';
import 'services/user_role_service.dart';

class DriverSafetyApp extends StatefulWidget {
  const DriverSafetyApp({super.key});

  static _DriverSafetyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_DriverSafetyAppState>()!;

  @override
  State<DriverSafetyApp> createState() => _DriverSafetyAppState();
}

class _DriverSafetyAppState extends State<DriverSafetyApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  bool get isDark => _themeMode == ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Drowsiness Guide',
      themeMode: _themeMode,

      darkTheme: ThemeData(
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

      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFCED8E4),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF5E8AD6),
          surface: Color(0xFFFFFFFF),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFFFFFFFF),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFFBFCFE0), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
      ),

      routes: {
        '/dashboard': (context) => const LiveMonitorScreen(),
        '/drowsiness-detected': (context) => const DrowsinessDetectedScreen(),
        '/map': (context) => const OSMMapScreen(),
        '/fleet-dashboard': (context) => const FleetOperatorDashboard(),
        '/select-role': (context) {
          final args = ModalRoute.of(context)!.settings.arguments
              as Map<String, String?>?;
          return RoleSelectionScreen(
            email: args?['email'],
            password: args?['password'],
          );
        },
      },

      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasData) {
            return FutureBuilder<String?>(
              future: UserRoleService().fetchRole(snapshot.data!.uid),
              builder: (context, roleSnapshot) {
                if (roleSnapshot.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                if (roleSnapshot.data == 'operator') {
                  return const FleetOperatorDashboard();
                }
                if (roleSnapshot.data == null) {
                  return const RoleSelectionScreen(email: null, password: null);
                }
                return const LiveMonitorScreen();
              },
            );
          }

          return const LoginScreen();
        },
      ),
    );
  }
}
