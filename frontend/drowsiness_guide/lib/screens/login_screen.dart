import 'package:flutter/material.dart';
import 'live_monitor_screen.dart';
import 'package:google_fonts/google_fonts.dart';

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
    final bgTop = const Color(0xFFCED8E4);   // light blue/gray like your mock
    final bgBottom = const Color(0xFF7E97B9);

    return Scaffold(
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

                    // Title
                    Text(
                        "BLINK",
                        style: GoogleFonts.megrim(
                            fontSize: 52,
                            letterSpacing: 12,   // important for Megrim
                            color: Colors.black,
                        ),
                    ),

                    const SizedBox(height: 42),

                    // Email field
                    _FlatField(
                      controller: _emailCtrl,
                      hint: "email",
                      obscure: false,
                    ),
                    const SizedBox(height: 14),

                    // Password field
                    _FlatField(
                      controller: _passCtrl,
                      hint: "password",
                      obscure: true,
                    ),

                    const SizedBox(height: 26),

                    // Login button
                    SizedBox(
                      width: 220,
                      height: 48,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF5E8AD6), // blue button
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
                            style: const TextStyle(
                                color: Colors.red,
                                fontSize: 14,
                            ),
                            ),
                        )
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

  const _FlatField({
    required this.controller,
    required this.hint,
    required this.obscure,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: TextField(
        controller: controller,
        obscureText: obscure,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.black, fontSize: 20),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.black.withOpacity(0.55)),
          filled: true,
          fillColor: Colors.white.withOpacity(0.95),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: Colors.black.withOpacity(0.12)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: Colors.black.withOpacity(0.12)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: Colors.black.withOpacity(0.25)),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}