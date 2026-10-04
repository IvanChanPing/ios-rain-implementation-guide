// Purpose: check native fixtures and real host-painted geometry/alpha.
// Invocation: flutter test test/ios_rain_runtime_test.dart --no-pub.
// Contract: the numeric oracle is recovered source data; the asymmetric atlas
// detects flipped UVs without relying on a self-generated golden.
// Verification: host only; no device-pixel or performance parity claim.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_rain_effect/ios_rain_effect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> reference;
  late ui.Image atlas;
  setUpAll(() async {
    reference = jsonDecode(
      await File('test/fixtures/ios_rain_compact_reference.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var frame = 0; frame < 4; frame++) {
      for (var quadrant = 0; quadrant < 4; quadrant++) {
        canvas.drawRect(
          Rect.fromLTWH(
            frame * 16.0 + (quadrant & 1) * 8,
            (quadrant >> 1) * 34.0,
            8,
            34,
          ),
          Paint()
            ..color = const [
              Color(0xffff0000),
              Color(0xff008000),
              Color(0xff0000ff),
              Color(0xffffff00),
            ][quadrant],
        );
      }
    }
    final picture = recorder.endRecording();
    atlas = await picture.toImage(64, 68);
    picture.dispose();
  });
  tearDownAll(() => atlas.dispose());

  test('all ten native lighting endpoints retain recovered channels', () {
    final rows =
        (reference['lighting'] as Map<String, dynamic>)['rows'] as List;
    for (final row in rows.cast<Map<String, dynamic>>()) {
      final light = IosRainConfiguration(
        windSpeedMetersPerSecond: 0,
        elevationDegrees: (row['elevation'] as num).toDouble(),
        isPM: row['isPM'] == 1,
      ).lighting;
      for (final pair in [
        (light.foregroundStart, 'fgStart'),
        (light.foregroundEnd, 'fgEnd'),
        (light.backgroundStart, 'bgStart'),
        (light.backgroundEnd, 'bgEnd'),
      ]) {
        final actual = [pair.$1.r, pair.$1.g, pair.$1.b, pair.$1.a];
        final expected = row[pair.$2] as List;
        for (var i = 0; i < 4; i++) {
          expect(actual[i], closeTo((expected[i] as num).toDouble(), 6e-8));
        }
      }
    }
  });

  test('wind uses mph cap independently of display units', () {
    for (final sample in [
      (0.0, 0.0),
      (10.0, -1.5),
      (50.0, -7.5),
      (100.0, -15.0),
      (120.0, -15.0),
    ]) {
      expect(
        IosRainConfiguration(
          windSpeedMetersPerSecond: sample.$1 * .44704,
          elevationDegrees: 33,
          isPM: false,
        ).fallAngleDegrees,
        closeTo(sample.$2, 1e-6),
      );
    }
  });

  test('lighting interpolates elevation and distinguishes morning/evening', () {
    IosRainLighting at(double elevation, bool pm) => IosRainConfiguration(
      windSpeedMetersPerSecond: 0,
      elevationDegrees: elevation,
      isPM: pm,
    ).lighting;
    expect(at(-6, false).foregroundStart.a, closeTo(.09757045083710937, 1e-7));
    expect(at(-6, true).foregroundStart.a, closeTo(.2, 1e-7));
    expect(
      at(13.5, false).foregroundStart.a,
      closeTo((.09757045083710937 + .12) / 2, 1e-7),
    );
    expect(at(90, false).foregroundStart.a, closeTo(.15, 1e-7));
    expect(at(90, true).foregroundStart.a, closeTo(.15, 1e-7));
  });

  test(
    'normalized age removes a birth on its twentieth eighth-second step',
    () {
      final simulation = IosRainSimulation();
      addTearDown(simulation.dispose);
      simulation.advance(.125);
      final first = simulation.backgroundParticles.first;
      for (var i = 0; i < 18; i++) {
        simulation.advance(.125);
      }
      expect(simulation.backgroundParticles.contains(first), isTrue);
      simulation.advance(.125);
      expect(simulation.backgroundParticles.contains(first), isFalse);
      expect(
        simulation.backgroundParticles.length,
        lessThanOrEqualTo(IosRainSpecs.background.maximumLiveCount),
      );
    },
  );

  test('configuration preserves live drops and changes later births', () {
    final simulation = IosRainSimulation()..warmUp();
    addTearDown(simulation.dispose);
    final old = simulation.backgroundParticles.first;
    final color = old.color;
    simulation.configure(
      const IosRainConfiguration(
        windSpeedMetersPerSecond: 22.352,
        elevationDegrees: -6,
        isPM: true,
      ),
    );
    expect(simulation.backgroundParticles.first, same(old));
    expect(simulation.elapsed, 0);
    simulation.advance(.125);
    expect(old.color, color);
    expect(simulation.backgroundParticles.last.velocityX, lessThan(0));
    expect(simulation.backgroundParticles.contains(old), isTrue);
  });

  test('projected quad has native stretch and follows velocity', () {
    final positions = Float32List(8);
    expect(
      writeIosRainQuad(_drop(), const Size(400, 800), positions, 0),
      isTrue,
    );
    expect(positions[2] - positions[0], closeTo(800 * 50 / 24 / 100, 1e-4));
    expect(
      positions[1] - positions[5],
      closeTo(2 * 1.1 * 800 * 50 / 24 / 100, 1e-4),
    );
    writeIosRainQuad(_drop(vx: -10), const Size(400, 800), positions, 0);
    final dx = positions[4] - positions[0], dy = positions[5] - positions[1];
    expect(dx * 100 - dy * -10, closeTo(0, .01));
    expect(
      writeIosRainQuad(_drop(z: 100), const Size(400, 800), positions, 0),
      isFalse,
    );
  });

  testWidgets('actual painter composes atlas corners and alpha once', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: RainWeatherLayer(
            active: true,
            debugSeed: 0,
            debugBackgroundImage: atlas,
            debugForegroundImage: atlas,
          ),
        ),
      ),
    );
    await tester.pump();
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(RainWeatherLayer),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    final IosRainSimulation simulation = (painter as dynamic).simulation;
    simulation.backgroundParticles.clear();
    simulation.foregroundParticles
      ..clear()
      ..add(
        _drop(
          width: 10,
          height: 10,
          color: const Color.fromARGB(128, 255, 255, 255),
        ),
      );
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(200, 200));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 200);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      picture.dispose();
      return data!;
    });
    List<int> pixel(int x, int y) {
      final offset = (y * 200 + x) * 4;
      return List.generate(4, (i) => bytes!.getUint8(offset + i));
    }

    expect(pixel(90, 90), [128, 0, 0, 128]);
    expect(pixel(110, 90), [0, 64, 0, 128]);
    expect(pixel(90, 110), [0, 0, 128, 128]);
    expect(pixel(110, 110), [128, 128, 0, 128]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TickerMode resumes without simulating hidden time', (
    tester,
  ) async {
    Widget scene(bool enabled) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: RainWeatherLayer(
          active: true,
          debugSeed: 0,
          debugBackgroundImage: atlas,
          debugForegroundImage: atlas,
        ),
      ),
    );
    await tester.pumpWidget(scene(true));
    await tester.pump();
    final dynamic painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(RainWeatherLayer),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter;
    final IosRainSimulation simulation = painter.simulation;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(scene(false));
    final before = simulation.elapsed;
    await tester.pump(const Duration(seconds: 10));
    expect(simulation.elapsed, before);
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(simulation.elapsed - before, lessThan(.1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

IosRainParticle _drop({
  double vx = 0,
  double z = 0,
  double width = 1,
  double height = 2,
  Color color = const Color(0xffffffff),
}) => IosRainParticle(
  id: 0,
  x: 0,
  y: 0,
  z: z,
  velocityX: vx,
  velocityY: -100,
  velocityZ: 0,
  width: width,
  height: height,
  life: 2.5,
  frame: 0,
  color: color,
);
