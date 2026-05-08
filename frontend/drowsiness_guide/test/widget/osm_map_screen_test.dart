import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drowsiness_guide/screens/osm_map_screen.dart';
import '../helpers/mocks.dart';

/// Full [OSMMapScreen] loads raster map tiles over HTTP. The widget test
/// binding rejects outbound HTTP, which floods errors from tile providers.
/// Exercise injected seams here; verify full map behavior on a device or with
/// dedicated HTTP fakes.
void main() {
  testWidgets('shows error when injected position throws', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OSMMapScreen(
          osmPlacesService: MockOSMPlacesService(),
          getCurrentPosition: () async => throw Exception('fail'),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('Failed to get location'), findsOneWidget);
  });

  testWidgets('shows timeout fallback message when injected location stalls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OSMMapScreen(
          osmPlacesService: MockOSMPlacesService(),
          getCurrentPosition: () => Completer<Never>().future,
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 16));

    // Timeout path should resolve out of the "getting position" state, either
    // by using last known location or by showing an explicit fallback message.
    expect(find.textContaining('Getting current position'), findsNothing);
  });
}
