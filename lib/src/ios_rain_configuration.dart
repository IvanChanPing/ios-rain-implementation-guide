import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Purpose: resolve Apple's compact-phone regular-rain runtime inputs.
/// Invocation: the host supplies wind speed, solar elevation and solar AM/PM.
/// Contract: the native rain constructor, wind branch and ten lighting keys are
/// from WeatherUI 1318 / iOS 26.5 23F77. Other layout/weather profiles are separate.
/// No I/O, timer, weather-provider model or astronomy dependency is owned here.
/// Contract: the host validates finite inputs and resolves solar phase upstream.
/// Verification: source-table, wind and AM/PM fixtures; device unverified.
/// Visual: wind controls streak slant; solar position controls tint/transparency.
@immutable
class IosRainConfiguration {
  const IosRainConfiguration({
    required this.windSpeedMetersPerSecond,
    required this.elevationDegrees,
    required this.isPM,
  }) : assert(windSpeedMetersPerSecond >= 0),
       assert(elevationDegrees >= -90 && elevationDegrees <= 90);

  /// Explicit deterministic preview input, never substituted for invalid weather.
  static const reference = IosRainConfiguration(
    windSpeedMetersPerSecond: 0,
    elevationDegrees: 33,
    isPM: false,
  );

  final double windSpeedMetersPerSecond;
  final double elevationDegrees;
  final bool isPM;

  double get fallAngleDegrees => _float32(
    _float32(math.min(windSpeedMetersPerSecond / 0.44704, 100) / 100) * -15,
  );

  IosRainLighting get lighting => _lightingAt(elevationDegrees, isPM);

  @override
  bool operator ==(Object other) =>
      other is IosRainConfiguration &&
      other.windSpeedMetersPerSecond == windSpeedMetersPerSecond &&
      other.elevationDegrees == elevationDegrees &&
      other.isPM == isPM;

  @override
  int get hashCode =>
      Object.hash(windSpeedMetersPerSecond, elevationDegrees, isPM);
}

/// Purpose: retain four native straight-sRGB endpoints before birth sampling.
/// Invocation: the emitter caches these only when configuration changes.
/// Contract: components are narrowed to float32 after native-key interpolation;
/// Flutter receives straight ARGB8 and performs backend premultiplication once.
/// Verification: all ten recovered rows are checked against the source fixture.
/// Visual: translucent gray/blue BG streaks and brighter FG streaks.
@immutable
class IosRainLighting {
  const IosRainLighting({
    required this.foregroundStart,
    required this.foregroundEnd,
    required this.backgroundStart,
    required this.backgroundEnd,
  });
  final ui.Color foregroundStart;
  final ui.Color foregroundEnd;
  final ui.Color backgroundStart;
  final ui.Color backgroundEnd;
}

/// One immutable source key: solar phase plus four straight RGBA endpoints.
/// Consumed only by the native-key interpolator; the JSON fixture pins its data.
class _RainLightingKey {
  const _RainLightingKey(
    this.elevation,
    this.isPM,
    this.fgStart,
    this.fgEnd,
    this.bgStart,
    this.bgEnd,
  );
  final double elevation;
  final bool isPM;
  final List<double> fgStart, fgEnd, bgStart, bgEnd;
  double get phase => isPM ? 180 - elevation : elevation;
}

/// Purpose: reproduce 0x1bee297e8 key selection and 0x1bededcfc color lerp.
/// Contract: exact elevation/AM-PM match precedes phase lookup; weight is float32,
/// component interpolation is double, then VFX float4 conversion is applied.
/// Invocation: configuration changes only. Verification: endpoint/midpoint tests.
IosRainLighting _lightingAt(double elevation, bool isPM) {
  for (final key in _compactLighting) {
    if (key.elevation == elevation && key.isPM == isPM) {
      return _mixLighting(key, key, 0);
    }
  }
  final phase = isPM ? 180 - elevation : elevation;
  var upper = _compactLighting.indexWhere((key) => key.phase >= phase);
  if (upper < 0) upper = _compactLighting.length - 1;
  final low = _compactLighting[math.max(0, upper - 1)];
  final high = _compactLighting[upper];
  final distance = high.phase - low.phase;
  final weight = distance == 0 ? 0.0 : _float32((phase - low.phase) / distance);
  return _mixLighting(low, high, weight);
}

/// Purpose: apply source sRGB component interpolation before VFX float narrowing.
/// Invocation: exact-key or bracket selection above; endpoints clamp by t.
/// Contract: no premultiplication here; birth sampling and backend conversion
/// own that later boundary. Verification: source endpoints and midpoint tests.
IosRainLighting _mixLighting(_RainLightingKey a, _RainLightingKey b, double t) {
  ui.Color color(List<double> low, List<double> high) {
    double channel(int index) => _float32(
      t <= 0
          ? low[index]
          : t >= 1
          ? high[index]
          : (1 - t) * low[index] + t * high[index],
    );
    return ui.Color.from(
      red: channel(0),
      green: channel(1),
      blue: channel(2),
      alpha: channel(3),
    );
  }

  return IosRainLighting(
    foregroundStart: color(a.fgStart, b.fgStart),
    foregroundEnd: color(a.fgEnd, b.fgEnd),
    backgroundStart: color(a.bgStart, b.bgStart),
    backgroundEnd: color(a.bgEnd, b.bgEnd),
  );
}

final _floatStorage = Float32List(1);
double _float32(double value) {
  _floatStorage[0] = value;
  return _floatStorage[0];
}

// WeatherUI 0x1bef14b9c: stride 0x4c0, RGBA-double offsets 0x1d0/1f0/210/230.
// Full literal precision retained from original constant loads/stores.
const _compactLighting = <_RainLightingKey>[
  _RainLightingKey(
    -90,
    false,
    [
      0.3199999928474426,
      0.3399997651576996,
      0.40000003576278687,
      0.08124256929775486,
    ],
    [
      0.3199999928474426,
      0.3399997651576996,
      0.5989319682121277,
      0.2822246849536896,
    ],
    [
      0.31499993801116943,
      0.32374992966651917,
      0.34999987483024597,
      0.10446344640384726,
    ],
    [
      0.5400000214576721,
      0.5549999475479126,
      0.6000000238418579,
      0.16107342336453548,
    ],
  ),
  _RainLightingKey(
    -17.999999999999996,
    false,
    [
      0.3199999928474426,
      0.3399997651576996,
      0.40000003576278687,
      0.08124256929775486,
    ],
    [
      0.3199999928474426,
      0.3399997651576996,
      0.5989319682121277,
      0.2822246849536896,
    ],
    [
      0.31499993801116943,
      0.32374992966651917,
      0.34999987483024597,
      0.10446344640384726,
    ],
    [
      0.5400000214576721,
      0.5549999475479126,
      0.6000000238418579,
      0.16107342336453548,
    ],
  ),
  _RainLightingKey(
    -6,
    false,
    [0.44999992847442627, 0.46250027418136597, 0.5, 0.09757045083710937],
    [
      0.6299999952316284,
      0.6474999189376831,
      0.699999988079071,
      0.25999999046325684,
    ],
    [0.44999992847442627, 0.4624999165534973, 0.5, 0.11610192805528641],
    [
      0.5400000214576721,
      0.5549999475479126,
      0.6000000238418579,
      0.18338982497348266,
    ],
  ),
  _RainLightingKey(
    33,
    false,
    [0.6000000238418579, 0.637499988079071, 0.75, 0.12],
    [0.8500003814697266, 0.887500524520874, 1, 0.34],
    [0.6439999938011169, 0.6579999923706055, 0.699999988079071, 0.1],
    [0.9200000166893005, 0.940000057220459, 1, 0.2199999988079071],
  ),
  _RainLightingKey(
    60,
    false,
    [0.6800000071525574, 0.7536669373512268, 0.8500000238418579, 0.15],
    [0.850000262260437, 0.915000319480896, 1, 0.36],
    [0.8100000023841858, 0.8492059707641602, 0.8999999761581421, 0.1],
    [0.9000005722045898, 0.9466668367385864, 1, 0.28],
  ),
  _RainLightingKey(
    60,
    true,
    [0.6800000071525574, 0.7536669373512268, 0.8500000238418579, 0.15],
    [0.850000262260437, 0.915000319480896, 1, 0.36],
    [0.8100000023841858, 0.8492059707641602, 0.8999999761581421, 0.1],
    [0.9000005722045898, 0.9466668367385864, 1, 0.28],
  ),
  _RainLightingKey(
    33,
    true,
    [0.6000000238418579, 0.637499988079071, 0.75, 0.12],
    [0.8500003814697266, 0.887500524520874, 1, 0.34],
    [0.6439999938011169, 0.6579999923706055, 0.699999988079071, 0.1],
    [0.9200000166893005, 0.940000057220459, 1, 0.2199999988079071],
  ),
  _RainLightingKey(
    -6,
    true,
    [0.44999992847442627, 0.46250027418136597, 0.5, 0.2],
    [
      0.5400000214576721,
      0.5549999475479126,
      0.6000000238418579,
      0.20000000298023224,
    ],
    [0.44999992847442627, 0.4624999165534973, 0.5, 0.11610192805528641],
    [0.5400000214576721, 0.5549999475479126, 0.6000000238418579, 0.2],
  ),
  _RainLightingKey(
    -17.999999999999996,
    true,
    [
      0.3199999928474426,
      0.33999985456466675,
      0.40000003576278687,
      0.11999999731779099,
    ],
    [0.40000003576278687, 0.42500007152557373, 0.5, 0.20000000298023224],
    [0.31499993801116943, 0.32374992966651917, 0.34999990463256836, 0.11],
    [
      0.5400000214576721,
      0.5549999475479126,
      0.6000000238418579,
      0.15000000596046448,
    ],
  ),
  _RainLightingKey(
    -90,
    true,
    [
      0.3199999928474426,
      0.3399997651576996,
      0.40000003576278687,
      0.08124256929775486,
    ],
    [
      0.3199999928474426,
      0.3399997651576996,
      0.5989319682121277,
      0.2822246849536896,
    ],
    [
      0.31499993801116943,
      0.32374992966651917,
      0.34999987483024597,
      0.10446344640384726,
    ],
    [
      0.5400000214576721,
      0.5549999475479126,
      0.6000000238418579,
      0.16107342336453548,
    ],
  ),
];
