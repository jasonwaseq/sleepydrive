import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'screens/live_monitor_screen.dart';
import 'screens/login_screen.dart';
import 'screens/osm_map_screen.dart';
import 'screens/role_selection_screen.dart';
import 'screens/fleet_operator_dashboard.dart';
import 'services/auth_service.dart';
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
        '/map': (context) => const OSMMapScreen(),
        '/select-role': (context) {
          final args =
              ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

          return RoleSelectionScreen(
            email: args?['email'] as String?,
            password: args?['password'] as String?,
          );
        },
        '/fleet-dashboard': (context) => const FleetOperatorDashboard(),
        '/login': (context) => const LoginScreen(),
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
            return const _SignedInHome();
          }

          return const LoginScreen();
        },
      ),
    );
  }
}

class _SignedInHome extends StatefulWidget {
  const _SignedInHome();

  @override
  State<_SignedInHome> createState() => _SignedInHomeState();
}

class _SignedInHomeState extends State<_SignedInHome> {
  final UserRoleService _userRoleService = UserRoleService();
  final AuthService _authService = AuthService();

  // Cache the future so rebuilds don't re-fire the HTTP call.
  late final Future<String?> _roleFuture = _loadRole();

  Future<String?> _loadRole() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return _userRoleService.fetchRole(user.uid);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _roleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'We could not load your account profile.\n\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () async {
                        await _authService.signOut();
                      },
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final role = snapshot.data;
        if (role == 'operator') {
          return const FleetOperatorDashboard();
        }
        if (role == 'driver') {
          return const LiveMonitorScreen();
        }

        // No role saved yet — push to role selection so it sits on the
        // Navigator stack and can navigate away cleanly.
        return const RoleSelectionScreen(
          email: null,
          password: null,
        );
      },
    );
  }
}
