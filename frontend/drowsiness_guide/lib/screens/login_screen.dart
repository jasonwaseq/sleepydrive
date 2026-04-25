import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drowsiness_guide/services/auth_service.dart';
import 'package:drowsiness_guide/services/user_role_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();
  final UserRoleService _userRoleService = UserRoleService();

  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();

  bool _isLoading = false;
  bool _isCreateMode = false;
  String? _errorText;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _routeSignedInUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('No authenticated user found');
    }

    final role = await _userRoleService.fetchRole(user.uid);

    if (!mounted) return;

    if (role == null) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/select-role',
        (route) => false,
      );
      return;
    }

    if (role == 'operator') {
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/fleet-dashboard',
        (route) => false,
      );
    } else {
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/dashboard',
        (route) => false,
      );
    }
  }

  Future<void> _handleEmailAuth() async {
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorText = 'Please enter both email and password';
      });
      return;
    }

    if (_isCreateMode && password.length < 6) {
      setState(() {
        _errorText = 'Password must be at least 6 characters';
      });
      return;
    }

    if (_isCreateMode) {
      Navigator.pushNamed(
        context,
        '/select-role',
        arguments: {'email': email, 'password': password},
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await _authService.signInWithEmailPassword(
        email: email,
        password: password,
      );

      await _routeSignedInUser();
    } on Exception catch (e) {
      setState(() {
        _errorText = _friendlyAuthError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final result = await _authService.signInWithGoogle();

      if (result == null) {
        setState(() {
          _errorText = 'Sign-in was cancelled';
        });
      } else {
        await _routeSignedInUser();
      }
    } catch (e, st) {
      debugPrint('Google sign-in error: $e');
      debugPrintStack(stackTrace: st);

      setState(() {
        _errorText = _friendlyAuthError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _friendlyAuthError(Object error) {
    if (error is UserRoleServiceException) {
      if (error.isNotFound) {
        return 'Account created, but your role is missing. Please choose a role to continue.';
      }
      return 'Authenticated, but the profile service could not be reached.';
    }

    final text = error.toString();

    if (text.contains('invalid-credential')) {
      return 'Invalid email or password';
    }
    if (text.contains('invalid-email')) {
      return 'Please enter a valid email';
    }
    if (text.contains('email-already-in-use')) {
      return 'An account already exists with this email';
    }
    if (text.contains('weak-password')) {
      return 'Password is too weak';
    }
    if (text.contains('user-not-found')) {
      return 'No account found for this email';
    }
    if (text.contains('wrong-password')) {
      return 'Invalid email or password';
    }
    if (text.contains('network-request-failed')) {
      return 'Network error. Check your connection and try again.';
    }
    if (text.contains('too-many-requests')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (text.contains('user-disabled')) {
      return 'This account has been disabled.';
    }
    if (text.contains('operation-not-allowed')) {
      return 'Email/password sign-in is not enabled in Firebase.';
    }
    if (text.contains('No authenticated user found')) {
      return 'Authentication succeeded, but no user session was available.';
    }
    if (text.contains('Failed to fetch user role')) {
      return 'Signed in, but could not load account role';
    }

    return 'Authentication failed: ${text.replaceFirst('Exception: ', '')}';
  }

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFFCED8E4);
    const bgBottom = Color(0xFF7E97B9);
    const textColor = Colors.black;
    final subTextColor = Colors.black.withValues(alpha: 0.7);
    final fieldFill = Colors.white.withValues(alpha: 0.96);
    final hintColor = Colors.black.withValues(alpha: 0.55);
    final borderColor = Colors.black.withValues(alpha: 0.10);
    final focusBorder = Colors.black.withValues(alpha: 0.22);
    const primaryButtonColor = Color(0xFF5E8AD6);

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
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'BLINK',
                        style: GoogleFonts.megrim(
                          fontSize: 52,
                          letterSpacing: 12,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 36),
                      _FlatField(
                        controller: _emailCtrl,
                        hint: 'email',
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
                        hint: 'password',
                        obscure: true,
                        textColor: textColor,
                        hintColor: hintColor,
                        fillColor: fieldFill,
                        borderColor: borderColor,
                        focusBorderColor: focusBorder,
                      ),
                      const SizedBox(height: 22),
                      SizedBox(
                        width: 290,
                        height: 56,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: primaryButtonColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: _isLoading ? null : _handleEmailAuth,
                            child: Text(
                              _isLoading
                                  ? 'Please wait...'
                                  : (_isCreateMode
                                        ? 'Create account'
                                        : 'Log in'),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () {
                                setState(() {
                                  _isCreateMode = !_isCreateMode;
                                  _errorText = null;
                                });
                              },
                        child: Text(
                          _isCreateMode
                              ? 'Already have an account? Log in'
                              : 'Create account',
                          style: TextStyle(
                            color: subTextColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'or',
                        style: TextStyle(color: subTextColor, fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 290,
                        height: 58,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: primaryButtonColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 16,
                              ),
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
                                  _isLoading
                                      ? 'Signing in...'
                                      : 'Continue with Google',
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
                      if (_errorText != null) ...[
                        const SizedBox(height: 18),
                        Text(
                          _errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFFF6B6B),
                            fontSize: 14,
                          ),
                        ),
                      ],
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
        style: TextStyle(color: textColor, fontSize: 18),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: hintColor),
          filled: true,
          fillColor: fillColor,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
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
