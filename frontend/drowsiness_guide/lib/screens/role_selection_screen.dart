import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drowsiness_guide/services/auth_service.dart';
import 'package:drowsiness_guide/services/user_role_service.dart';

class RoleSelectionScreen extends StatefulWidget {
  final String? email;
  final String? password;

  const RoleSelectionScreen({
    super.key,
    required this.email,
    required this.password,
  });

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  final AuthService _authService = AuthService();
  final UserRoleService _userRoleService = UserRoleService();
  final TextEditingController _firstNameCtrl = TextEditingController();
  final TextEditingController _lastNameCtrl = TextEditingController();
  final TextEditingController _fleetInviteCtrl = TextEditingController();
  final TextEditingController _deviceIdCtrl = TextEditingController();

  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _fleetInviteCtrl.dispose();
    _deviceIdCtrl.dispose();
    super.dispose();
  }

  Future<User> _ensureAuthenticatedUser() async {
    final existingUser = FirebaseAuth.instance.currentUser;
    if (existingUser != null) {
      return existingUser;
    }

    final email = widget.email?.trim() ?? '';
    final password = widget.password?.trim() ?? '';
    if (email.isEmpty || password.isEmpty) {
      throw Exception('Missing account credentials');
    }

    try {
      final credential = await _authService.createUserWithEmailPassword(
        email: email,
        password: password,
      );
      return credential.user!;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        final credential = await _authService.signInWithEmailPassword(
          email: email,
          password: password,
        );
        return credential.user!;
      }
      rethrow;
    }
  }

  String _routeForRole(String role) {
    return role == 'operator' ? '/fleet-dashboard' : '/dashboard';
  }

  String _friendlyError(Object error) {
    if (error is UserRoleServiceException) {
      if (error.statusCode == 404 && error.message.contains('invite')) {
        return 'That fleet invite code was not found.';
      }
      if (error.statusCode == 401) {
        return 'Your sign-in session expired. Please go back and try again.';
      }
      return 'Your account was created, but the app could not save your role. Please try again.';
    }
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'email-already-in-use':
          return 'An account already exists with this email.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'weak-password':
          return 'Password is too weak.';
        case 'network-request-failed':
          return 'Network error. Check your connection and try again.';
        case 'operation-not-allowed':
          return 'Email/password sign-up is not enabled in Firebase.';
        case 'invalid-credential':
        case 'wrong-password':
        case 'user-not-found':
          return 'The saved account credentials are no longer valid. Please go back and try again.';
      }
    }
    return 'Could not create account: ${error.toString().replaceFirst('Exception: ', '')}';
  }

  Future<void> _saveRoleAndRoute({
    required String role,
    String? fleetInviteCode,
    String? deviceId,
  }) async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    final firstName = _firstNameCtrl.text.trim();
    final lastName = _lastNameCtrl.text.trim();
    final fullName = [firstName, lastName].where((s) => s.isNotEmpty).join(' ');

    try {
      final user = await _ensureAuthenticatedUser();
      await _userRoleService.saveRole(
        uid: user.uid,
        role: role,
        email: user.email ?? widget.email,
        displayName: fullName.isNotEmpty ? fullName : user.displayName,
        fleetInviteCode: fleetInviteCode,
        deviceId: deviceId,
      );

      if (!mounted) return;

      Navigator.pushNamedAndRemoveUntil(
        context,
        _routeForRole(role),
        (route) => false,
      );
    } catch (e) {
      setState(() {
        _errorText = _friendlyError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleBack() async {
    if (FirebaseAuth.instance.currentUser != null) {
      await _authService.signOut();
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _handleDriverSelection() async {
    await _saveRoleAndRoute(
      role: 'driver',
      fleetInviteCode: _fleetInviteCtrl.text,
      deviceId: _deviceIdCtrl.text,
    );
  }

  Future<void> _handleOperatorSelection() async {
    await _saveRoleAndRoute(role: 'operator');
  }

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFFCED8E4);
    const bgBottom = Color(0xFF7E97B9);
    const textColor = Colors.black;
    final subTextColor = Colors.black.withOpacity(0.7);
    final cardColor = Colors.white.withOpacity(0.96);
    final borderColor = Colors.black.withOpacity(0.08);
    const primaryColor = Color(0xFF5E8AD6);

    return Scaffold(
      appBar: AppBar(title: const Text('Choose your role')),
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
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'BLINK',
                        style: GoogleFonts.megrim(
                          fontSize: 44,
                          letterSpacing: 10,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        FirebaseAuth.instance.currentUser == null
                            ? "Select how you'll use the platform"
                            : "Finish setting up your account",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: subTextColor, fontSize: 16),
                      ),
                      const SizedBox(height: 34),
                      Row(
                        children: [
                          Expanded(
                            child: _SetupField(
                              controller: _firstNameCtrl,
                              hint: 'First name',
                              textColor: textColor,
                              hintColor: subTextColor,
                              fillColor: cardColor,
                              borderColor: borderColor,
                              capitalization: TextCapitalization.words,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SetupField(
                              controller: _lastNameCtrl,
                              hint: 'Last name',
                              textColor: textColor,
                              hintColor: subTextColor,
                              fillColor: cardColor,
                              borderColor: borderColor,
                              capitalization: TextCapitalization.words,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _SetupField(
                        controller: _fleetInviteCtrl,
                        hint: 'Fleet invite code',
                        textColor: textColor,
                        hintColor: subTextColor,
                        fillColor: cardColor,
                        borderColor: borderColor,
                      ),
                      const SizedBox(height: 12),
                      _SetupField(
                        controller: _deviceIdCtrl,
                        hint: 'Jetson device ID',
                        textColor: textColor,
                        hintColor: subTextColor,
                        fillColor: cardColor,
                        borderColor: borderColor,
                      ),
                      const SizedBox(height: 18),
                      _RoleCard(
                        title: 'Fleet Driver',
                        subtitle:
                            'Receive fatigue alerts and access your live monitoring tools.',
                        icon: Icons.drive_eta_rounded,
                        cardColor: cardColor,
                        borderColor: borderColor,
                        textColor: textColor,
                        accentColor: primaryColor,
                        onTap: _isLoading ? null : _handleDriverSelection,
                      ),
                      const SizedBox(height: 18),
                      _RoleCard(
                        title: 'Fleet Operator',
                        subtitle:
                            'Monitor drivers, review alerts, and manage your fleet dashboard.',
                        icon: Icons.dashboard_customize_rounded,
                        cardColor: cardColor,
                        borderColor: borderColor,
                        textColor: textColor,
                        accentColor: primaryColor,
                        onTap: _isLoading ? null : _handleOperatorSelection,
                      ),
                      if (_isLoading) ...[
                        const SizedBox(height: 22),
                        const CircularProgressIndicator(),
                      ],
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
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: _isLoading ? null : _handleBack,
                        child: Text(
                          'Back',
                          style: TextStyle(color: subTextColor, fontSize: 15),
                        ),
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

class _RoleCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color cardColor;
  final Color borderColor;
  final Color textColor;
  final Color accentColor;
  final VoidCallback? onTap;

  const _RoleCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.cardColor,
    required this.borderColor,
    required this.textColor,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: accentColor, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: textColor.withOpacity(0.72),
                          fontSize: 14,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: textColor.withOpacity(0.65),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final Color textColor;
  final Color hintColor;
  final Color fillColor;
  final Color borderColor;
  final TextCapitalization capitalization;

  const _SetupField({
    required this.controller,
    required this.hint,
    required this.textColor,
    required this.hintColor,
    required this.fillColor,
    required this.borderColor,
    this.capitalization = TextCapitalization.characters,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: TextStyle(color: textColor),
      textCapitalization: capitalization,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: hintColor),
        filled: true,
        fillColor: fillColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: textColor.withOpacity(0.28)),
        ),
      ),
    );
  }
}
