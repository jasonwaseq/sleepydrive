import 'package:flutter/material.dart';

class DrowsinessDetectedScreen extends StatelessWidget {
  const DrowsinessDetectedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'DROWSINESS DETECTED',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 2.0),
        ),
      ),
      body: const Center(
        child: Text(
          'Drowsiness Detected Page\n(To be implemented)',
          style: TextStyle(fontSize: 18),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
