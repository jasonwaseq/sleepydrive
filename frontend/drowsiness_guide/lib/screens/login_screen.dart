import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drowsiness_guide/app.dart'; // ← add this import

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  final String _validEmail = "admin@blink.ai";
  final String _validPassword = "blink123";

  String? _errorText;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _attemptLogin() {
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text.trim();

    if (email == _validEmail && password == _validPassword) {
      Navigator.pushReplacementNamed(context, '/dashboard');
    } else {
      setState(() {
        _errorText = "Invalid username or password";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── Theme-aware colors ──────────────────────────────────────────
    final isDark = DriverSafetyApp.of(context).isDark;
    final bgTop = isDark ? const Color(0xFF0D1117) : const Color(0xFFCED8E4);
    final bgBottom = isDark ? const Color(0xFF1A2332) : const Color(0xFF7E97B9);
    final fieldFill = isDark
        ? const Color(0xFF1E2D40)
        : Colors.white.withOpacity(0.95);
    final textColor = isDark ? Colors.white : Colors.black;
    final hintColor = isDark
        ? Colors.white.withOpacity(0.4)
        : Colors.black.withOpacity(0.55);
    final borderColor = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.12);
    final focusBorder = isDark
        ? Colors.white.withOpacity(0.3)
        : Colors.black.withOpacity(0.25);
    // ───────────────────────────────────────────────────────────────

    return Scaffold(
      // ── Theme toggle button (login screen only) ──────────────────
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Toggle theme',
        onPressed: () => DriverSafetyApp.of(context).toggleTheme(),
        child: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
      ),
      // ─────────────────────────────────────────────────────────────
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
                    const SizedBox(height: 10),
                    Text(
                      "BLINK",
                      style: GoogleFonts.megrim(
                        fontSize: 52,
                        letterSpacing: 12,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 42),
                    _FlatField(
                      controller: _emailCtrl,
                      hint: "email",
                      obscure: false,
                      textColor: textColor,
                      hintColor: hintColor,
                      fillColor: fieldFill,
                      borderColor: borderColor,
                      focusBorderColor: focusBorder,
                    ),
                    const SizedBox(height: 14),
                    _FlatField(
                      controller: _passCtrl,
                      hint: "password",
                      obscure: true,
                      textColor: textColor,
                      hintColor: hintColor,
                      fillColor: fieldFill,
                      borderColor: borderColor,
                      focusBorderColor: focusBorder,
                    ),
                    const SizedBox(height: 26),
                    SizedBox(
                      width: 220,
                      height: 48,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF5E8AD6),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _attemptLogin,
                        child: const Text(
                          "login",
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (_errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _errorText!,
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFFFF6B6B)
                                : Colors.red,
                            fontSize: 14,
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

class _FlatField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Color textColor;
  final Color hintColor;
  final Color fillColor;
  final Color borderColor;
  final Color focusBorderColor;

  const _FlatField({
    required this.controller,
    required this.hint,
    required this.obscure,
    required this.textColor,
    required this.hintColor,
    required this.fillColor,
    required this.borderColor,
    required this.focusBorderColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: TextField(
        controller: controller,
        obscureText: obscure,
        textAlign: TextAlign.center,
        style: TextStyle(color: textColor, fontSize: 20),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: hintColor),
          filled: true,
          fillColor: fillColor,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: focusBorderColor),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
      ),
    );
  }
}
