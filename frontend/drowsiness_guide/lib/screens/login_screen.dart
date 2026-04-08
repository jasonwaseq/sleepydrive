import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drowsiness_guide/app.dart';
import 'package:drowsiness_guide/services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();

  bool _isLoading = false;
  String? _errorText;

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final result = await _authService.signInWithGoogle();

      if (result == null) {
        setState(() {
          _errorText = "Sign-in was cancelled";
        });
      }
    } catch (e, st) {
    debugPrint('Google sign-in error: $e');
    debugPrintStack(stackTrace: st);

    setState(() {
      _errorText = "Google sign-in failed: $e";
    });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = DriverSafetyApp.of(context).isDark;
    final bgTop = isDark ? const Color(0xFF0D1117) : const Color(0xFFCED8E4);
    final bgBottom = isDark ? const Color(0xFF1A2332) : const Color(0xFF7E97B9);
    final textColor = isDark ? Colors.white : Colors.black;
    final subTextColor = isDark
        ? Colors.white.withOpacity(0.7)
        : Colors.black.withOpacity(0.7);
    final buttonColor = const Color(0xFF5E8AD6);

    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Toggle theme',
        onPressed: () => DriverSafetyApp.of(context).toggleTheme(),
        child: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgTop, bgBottom],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "BLINK",
                      style: GoogleFonts.megrim(
                        fontSize: 52,
                        letterSpacing: 12,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const SizedBox(height: 42),
                    SizedBox(
                      width: 290,
                      height: 58,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(isDark ? 0.28 : 0.12),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: isDark ? const Color(0xFF6E95DC) : const Color(0xFF5E8AD6),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          ),
                          onPressed: _isLoading ? null : _handleGoogleSignIn,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_isLoading)
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              else
                                const Icon(Icons.login_rounded, size: 24),
                              const SizedBox(width: 12),
                              Text(
                                _isLoading ? "Signing in..." : "Continue with Google",
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
