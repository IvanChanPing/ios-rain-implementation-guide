// Purpose: check actual dependency asset packaging without a demo application.
// Invocation: run flutter test from tool/consumer_check.
// Contract: real bundle bytes are decoded; images and codecs are disposed here.
// Verification: host asset/import contract only, not device visual parity.
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_rain_effect/ios_rain_effect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'consumer imports public API and decodes both bundled rain atlases',
    () async {
      const layer = RainWeatherLayer(active: true);
      expect(layer.configuration, IosRainConfiguration.reference);
      for (final name in ['ios_rain_bg.png', 'ios_rain_fg.png']) {
        final key = AssetImage(
          'assets/background/$name',
          package: 'ios_rain_effect',
        ).keyName;
        final bytes = await rootBundle.load(key);
        final codec = await ui.instantiateImageCodec(
          Uint8List.sublistView(bytes),
        );
        try {
          final frame = await codec.getNextFrame();
          expect(frame.image.width, 64);
          expect(frame.image.height, 68);
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
    },
  );
}
