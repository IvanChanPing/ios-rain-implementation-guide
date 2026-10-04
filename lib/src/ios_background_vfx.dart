import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'ios_rain_configuration.dart';
export 'ios_rain_configuration.dart';

/// Apple Weather's regular-rain background, recovered from iOS 26.5 (23F77).
///
/// Purpose: replaces the former hand-authored regular-rain animation with the
/// two CPU particle emitters, perspective camera, and four-frame Apple sprite
/// atlases encoded by `WeatherV136_Default_Background.vfx`.
/// Invocation: the weather background owner mounts [RainWeatherLayer] and sets
/// [active] only for the existing regular-rain condition branch.
/// Contract: this widget owns images loaded from the asset bundle, but never
/// disposes images injected through the two debug arguments. Pausing preserves
/// particle state; setting [active] false resets the scene. No network,
/// platform channel, permission, or Android-only API is used.
/// Verification: the staged implementation is covered by deterministic host
/// tests and a Flutter golden preview. Android/device performance and the real
/// app click path remain UNVERIFIED.
/// Visual: full-screen transparent overlay using the compact runtime profile;
/// fine translucent background streaks sit behind larger foreground streaks.
/// Wind controls slant and solar elevation controls tint/alpha. Exact live-iOS
/// RNG replay and Metal pixel parity are not claimed by this Flutter adapter.
class RainWeatherLayer extends StatefulWidget {
  const RainWeatherLayer({
    super.key,
    required this.active,
    this.configuration = IosRainConfiguration.reference,
    this.debugSeed,
    this.debugBackgroundImage,
    this.debugForegroundImage,
  });

  final bool active;
  final IosRainConfiguration configuration;

  /// Effective scene seed captured at mount; null randomizes the production scene.
  final int? debugSeed;
  final ui.Image? debugBackgroundImage;
  final ui.Image? debugForegroundImage;

  @override
  State<RainWeatherLayer> createState() => _RainWeatherLayerState();
}

class _RainWeatherLayerState extends State<RainWeatherLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final IosRainSimulation _simulation;
  late final Ticker _ticker;
  Duration? _lastElapsed;
  ui.Image? _backgroundImage;
  ui.Image? _foregroundImage;
  bool _ownsBackgroundImage = false;
  bool _ownsForegroundImage = false;
  int _loadGeneration = 0;
  bool _applicationResumed = true;
  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applicationResumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _simulation = IosRainSimulation(
      configuration: widget.configuration,
      seed: widget.debugSeed ?? math.Random().nextInt(1 << 31),
    );
    _ticker = createTicker(_onTick);
    unawaited(_loadImages());
    _syncPlayback(resetWhenInactive: false);
  }

  /// Purpose: freeze hidden Settings captures without catching up hidden time.
  /// Contract: TickerMode transitions preserve particles and reset frame timing;
  /// lifecycle pause and inactive reset still use the same playback gate.
  /// Verification: host tests toggle TickerMode around the retained rain owner.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncPlayback(resetWhenInactive: false);
  }

  @override
  void didUpdateWidget(covariant RainWeatherLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration != widget.configuration) {
      _simulation.configure(widget.configuration);
    }
    if (oldWidget.debugBackgroundImage != widget.debugBackgroundImage ||
        oldWidget.debugForegroundImage != widget.debugForegroundImage) {
      unawaited(_loadImages());
    }
    if (oldWidget.active != widget.active) {
      _syncPlayback(resetWhenInactive: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _applicationResumed = state == AppLifecycleState.resumed;
    _syncPlayback(resetWhenInactive: false);
  }

  /// Purpose: resolve the atlas inside this dependency's asset namespace.
  /// Invocation: the retained foreground/background image loader below.
  /// Contract: package assets are bundled by pubspec; decoded image ownership
  /// remains with this widget. Verification: separate consumer asset test.
  Future<ui.Image> _decodeAsset(String asset) async {
    final key = AssetImage(asset, package: 'ios_rain_effect').keyName;
    final bytes = await rootBundle.load(key);
    final codec = await ui.instantiateImageCodec(Uint8List.sublistView(bytes));
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _loadImages() async {
    final generation = ++_loadGeneration;
    final suppliedBackground = widget.debugBackgroundImage;
    final suppliedForeground = widget.debugForegroundImage;
    ui.Image? loadedBackground;
    ui.Image? loadedForeground;
    try {
      loadedBackground =
          suppliedBackground ??
          await _decodeAsset('assets/background/ios_rain_bg.png');
      loadedForeground =
          suppliedForeground ??
          await _decodeAsset('assets/background/ios_rain_fg.png');
    } catch (_) {
      if (suppliedBackground == null) loadedBackground?.dispose();
      if (suppliedForeground == null) loadedForeground?.dispose();
      rethrow;
    }
    if (!mounted || generation != _loadGeneration) {
      if (suppliedBackground == null) loadedBackground.dispose();
      if (suppliedForeground == null) loadedForeground.dispose();
      return;
    }
    _disposeOwnedImages();
    setState(() {
      _backgroundImage = loadedBackground;
      _foregroundImage = loadedForeground;
      _ownsBackgroundImage = suppliedBackground == null;
      _ownsForegroundImage = suppliedForeground == null;
    });
  }

  void _syncPlayback({required bool resetWhenInactive}) {
    if (widget.active && !_simulation.isWarmedUp) _simulation.warmUp();
    if (widget.active && _applicationResumed && _tickerEnabled) {
      _lastElapsed = null;
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    _ticker.stop();
    _lastElapsed = null;
    if (!widget.active && resetWhenInactive) _simulation.reset();
  }

  void _onTick(Duration elapsed) {
    final previous = _lastElapsed;
    _lastElapsed = elapsed;
    if (previous == null) return;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds > 0) _simulation.advance(seconds);
  }

  void _disposeOwnedImages() {
    if (_ownsBackgroundImage) _backgroundImage?.dispose();
    if (_ownsForegroundImage) _foregroundImage?.dispose();
    _ownsBackgroundImage = false;
    _ownsForegroundImage = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadGeneration += 1;
    _ticker.dispose();
    _simulation.dispose();
    _disposeOwnedImages();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // persistentRainLayer — transparent full-screen rain owner retained in the
    // weather stack while inactive so callers can find one stable scene key.
    return KeyedSubtree(
      key: const ValueKey<String>('weather-scene-rain'),
      child: widget.active
          ? IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  // appleRainReadySurface — full-screen painter; this key is
                  // present only after both Apple sprite sheets are available.
                  key: _backgroundImage != null && _foregroundImage != null
                      ? const ValueKey<String>('weather-scene-apple-rain-ready')
                      : null,
                  painter: _IosRainPainter(
                    simulation: _simulation,
                    backgroundImage: _backgroundImage,
                    foregroundImage: _foregroundImage,
                  ),
                  size: Size.infinite,
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Immutable authored parameters for one Apple rain emitter.
///
/// Contract: compact runtime constructor values override scene defaults. Dynamic
/// wind/lighting live in IosRainConfiguration; birth dimensions remain planar.
/// Verification: source fixture checks rates, ranges, life and per-layer spread.
@immutable
class IosRainEmitterSpec {
  const IosRainEmitterSpec({
    required this.seed,
    required this.rate,
    required this.warmupDuration,
    required this.life,
    required this.velocityMin,
    required this.velocityMax,
    required this.widthMin,
    required this.widthMax,
    required this.heightMin,
    required this.heightMax,
    required this.depth,
    required this.spreadDegrees,
    required this.colorStart,
    required this.colorEnd,
    required this.colorHashAddend,
  });

  final int seed;
  final double rate;
  final double warmupDuration;
  final double life;
  final double velocityMin;
  final double velocityMax;
  final double widthMin;
  final double widthMax;
  final double heightMin;
  final double heightMax;
  final double depth;
  final double spreadDegrees;
  final ui.Color colorStart;
  final ui.Color colorEnd;
  final int colorHashAddend;

  int get maximumLiveCount =>
      (rate * (life + IosRainSpecs.warmupStep)).ceil() + 1;
}

/// Purpose: compact regular-rain runtime profile from WeatherUI 0x1bef143d4.
/// Contract: source-defined scene geometry plus runtime-overridden rates/ranges;
/// no screen-density compensation or fixed scene-default angle is applied.
/// Verification: native constructor fixture; other layout profiles are separate.
abstract final class IosRainSpecs {
  static const double fallAngleDegrees = 0;
  static const double blowingSpeed = 0;
  static const double blowingAmount = 0;
  static const double emitterOffset = -35;
  static const double emitterWidth = 30;
  static const double emitterDepth = 8;
  static const double warmupStep = 0.125;
  static const double piFloat = 3.1415927410125732;
  static const double negativeHalfPiFloat = -1.5707963705062866;
  static const double twoPiFloat = 6.283185005187988;
  static const double cameraX = 0;
  static const double cameraY = 0;
  static const double cameraZ = 100;
  static const double cameraFocalLength = 50;
  static const double cameraSensorSize = 24;

  static const background = IosRainEmitterSpec(
    seed: 623276563,
    rate: 3000,
    warmupDuration: 1.5,
    life: 2.5,
    velocityMin: -60,
    velocityMax: -36,
    widthMin: 0.12999999523162842,
    widthMax: 0.17999999225139618,
    heightMin: 0.40950000286102295,
    heightMax: 0.675000011920929,
    depth: -30,
    spreadDegrees: 2,
    colorStart: ui.Color.from(
      red: 0.6439999938011169,
      green: 0.6579999923706055,
      blue: 0.699999988079071,
      alpha: 0.1,
    ),
    colorEnd: ui.Color.from(
      red: 0.9200000166893005,
      green: 0.940000057220459,
      blue: 1,
      alpha: 0.2199999988079071,
    ),
    colorHashAddend: 0x22249d3a,
  );

  static const foreground = IosRainEmitterSpec(
    seed: 2502535891,
    rate: 320,
    warmupDuration: 2,
    life: 2.5,
    velocityMin: -120,
    velocityMax: -84,
    widthMin: 0.23000000417232513,
    widthMax: 0.30000001192092896,
    heightMin: 0.862500011920929,
    heightMax: 1.2750000953674316,
    depth: -4.5,
    spreadDegrees: 1.25,
    colorStart: ui.Color.from(
      red: 0.6000000238418579,
      green: 0.637499988079071,
      blue: 0.75,
      alpha: 0.12,
    ),
    colorEnd: ui.Color.from(
      red: 0.8500003814697266,
      green: 0.887500524520874,
      blue: 1,
      alpha: 0.34,
    ),
    colorHashAddend: 0x46c28a7a,
  );
}

/// Purpose: retain one CPU rain birth's geometry, color and normalized lifetime.
/// Invocation: emitter initialization creates it; integration updates position/age.
/// Contract: inverse life is float32; size, velocity, frame and color stay fixed
/// across later weather updates. The emitter owns removal at normalized age >=1.
/// Verification: lifetime-boundary and retained-birth host tests.
class IosRainParticle {
  IosRainParticle({
    required this.id,
    required this.x,
    required this.y,
    required this.z,
    required this.velocityX,
    required this.velocityY,
    required this.velocityZ,
    required this.width,
    required this.height,
    required this.life,
    required this.frame,
    required this.color,
  }) : inverseLife = _f32(1 / life);

  final int id;
  double x;
  double y;
  double z;
  final double velocityX;
  final double velocityY;
  final double velocityZ;
  final double width;
  final double height;
  final double life;
  final int frame;
  final ui.Color color;
  final double inverseLife;
  double normalizedAge = 0;
  double get age => normalizedAge * life;
}

/// CPU scene clock and the two Apple continuous emitters.
///
/// Purpose: reproduces the VFX CPU route (`updateOnGPU=false`) with the decoded
/// continuous-spawn accumulator and the engine's exact 0.125-second warmup.
/// Invocation: [RainWeatherLayer] warms once when activated, then calls
/// [advance] with ticker deltas. Tests may call the same methods directly.
/// Contract: a step first advances scene time and spawns `floor(rate * dt +
/// remainder)` particles, retains the clamped fractional remainder, advances
/// all particles, and removes normalized age >=1. Warmup restores the clock.
/// Frame/color hashing retains the source arithmetic. Seed injection permits
/// deterministic host replay; generic ECS scheduling/live seed parity is unproven.
/// Verification: ARM-oracle fixtures cover frame/color arithmetic; host tests
/// cover warmup counts, ranges, reset, projection, and deterministic replay.
class IosRainSimulation extends ChangeNotifier {
  IosRainSimulation({
    IosRainConfiguration configuration = IosRainConfiguration.reference,
    int? seed,
  }) : background = IosRainEmitter(
         IosRainSpecs.background,
         configuration: configuration,
         effectiveSeed: seed == null
             ? null
             : seed ^ IosRainSpecs.background.seed,
       ),
       foreground = IosRainEmitter(
         IosRainSpecs.foreground,
         configuration: configuration,
         effectiveSeed: seed == null
             ? null
             : seed ^ IosRainSpecs.foreground.seed,
       );

  /// Purpose: apply new wind/lighting only to later births, retaining live drops.
  /// Invocation: weather/time updates on the retained widget. No reset/warmup.
  /// Verification: host config-transition test preserves particle identities.
  void configure(IosRainConfiguration configuration) {
    background.configure(configuration);
    foreground.configure(configuration);
    notifyListeners();
  }

  final IosRainEmitter background;
  final IosRainEmitter foreground;
  int simulationIndex = 0;
  double elapsed = 0;
  bool isWarmedUp = false;

  List<IosRainParticle> get backgroundParticles => background.particles;
  List<IosRainParticle> get foregroundParticles => foreground.particles;

  void warmUp() {
    if (isWarmedUp) return;
    final savedTime = elapsed;
    final savedIndex = simulationIndex;
    final steps =
        (IosRainSpecs.foreground.warmupDuration / IosRainSpecs.warmupStep)
            .round();
    final backgroundSteps =
        (IosRainSpecs.background.warmupDuration / IosRainSpecs.warmupStep)
            .round();
    for (var step = 0; step < steps; step += 1) {
      elapsed = _f32(elapsed + IosRainSpecs.warmupStep);
      if (step < backgroundSteps) {
        background.advance(IosRainSpecs.warmupStep, elapsed, simulationIndex);
      }
      foreground.advance(IosRainSpecs.warmupStep, elapsed, simulationIndex);
      simulationIndex = (simulationIndex + 1) & 0xffffffff;
    }
    elapsed = savedTime;
    simulationIndex = savedIndex;
    isWarmedUp = true;
    notifyListeners();
  }

  void advance(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return;
    var remaining = seconds;
    while (remaining > 0) {
      final step = math.min(remaining, IosRainSpecs.warmupStep).toDouble();
      elapsed = _f32(elapsed + step);
      background.advance(step, elapsed, simulationIndex);
      foreground.advance(step, elapsed, simulationIndex);
      simulationIndex = (simulationIndex + 1) & 0xffffffff;
      remaining -= step;
    }
    notifyListeners();
  }

  void reset() {
    background.reset();
    foreground.reset();
    simulationIndex = 0;
    elapsed = 0;
    isWarmedUp = false;
    notifyListeners();
  }
}

/// Purpose: retain CPU particles and reusable draw/birth buffers for one layer.
/// Invocation: scene warmup and ticker steps; configure changes future births.
/// Contract: independent planar size samples are staged before shape samples.
/// The host ordering is explicit, not a claim of a complete native ECS transcript.
/// Capacity includes one full birth-step headroom; render batches stay Uint16-safe.
/// Verification: count, fractional rate, independent-axis and life-boundary tests.
class IosRainEmitter {
  IosRainEmitter(
    this.spec, {
    IosRainConfiguration configuration = IosRainConfiguration.reference,
    int? effectiveSeed,
  }) : effectiveSeed = (effectiveSeed ?? spec.seed) & 0xffffffff,
       _random = IosXoshiro256StarStar(
         (effectiveSeed ?? spec.seed) & 0xffffffff,
       ),
       positions = Float32List(spec.maximumLiveCount * 8),
       textureCoordinates = Float32List(spec.maximumLiveCount * 8),
       colors = Int32List(spec.maximumLiveCount * 4),
       indices = _quadIndices(math.min(spec.maximumLiveCount, 16384)),
       _birthWidths = Float32List(spec.maximumLiveCount),
       _birthHeights = Float32List(spec.maximumLiveCount) {
    configure(configuration);
  }

  final int effectiveSeed;
  late IosRainConfiguration configuration;
  late ui.Color _colorStart, _colorEnd;
  final Float32List _birthWidths, _birthHeights;

  /// Purpose: cache lighting for future births without recoloring live particles.
  /// Invocation: construction and scene configuration updates only.
  /// Contract: this emitter's authored identity selects FG/BG endpoints; no RNG
  /// is consumed. Verification: retained-birth and native lighting fixtures.
  void configure(IosRainConfiguration value) {
    configuration = value;
    final lighting = value.lighting;
    final foreground = spec.seed == IosRainSpecs.foreground.seed;
    _colorStart = foreground
        ? lighting.foregroundStart
        : lighting.backgroundStart;
    _colorEnd = foreground ? lighting.foregroundEnd : lighting.backgroundEnd;
  }

  final IosRainEmitterSpec spec;
  final List<IosRainParticle> particles = <IosRainParticle>[];
  final Float32List positions;
  final Float32List textureCoordinates;
  final Int32List colors;
  final Uint16List indices;
  IosXoshiro256StarStar _random;
  double _spawnRemainder = 0;
  int _nextParticleId = 0;

  void reset() {
    particles.clear();
    _random = IosXoshiro256StarStar(effectiveSeed);
    _spawnRemainder = 0;
    _nextParticleId = 0;
  }

  void advance(double delta, double sceneTime, int simulationIndex) {
    delta = _f32(delta);
    final accumulated = _f32(_spawnRemainder + _f32(spec.rate * delta));
    final spawnCount = accumulated.floor();
    _spawnRemainder = _f32(
      math.min(accumulated - spawnCount, 0.9999999403953552).toDouble(),
    );
    // VFX planar mode consumes distinct successive samples for each axis.
    for (var index = 0; index < spawnCount; index += 1) {
      _birthWidths[index] = _f32(
        spec.widthMin +
            _f32(spec.widthMax - spec.widthMin) * _random.nextUnitFloat24(),
      );
      _birthHeights[index] = _f32(
        spec.heightMin +
            _f32(spec.heightMax - spec.heightMin) * _random.nextUnitFloat24(),
      );
    }
    for (var index = 0; index < spawnCount; index += 1) {
      particles.add(
        _spawn(
          sceneTime,
          simulationIndex,
          _birthWidths[index],
          _birthHeights[index],
        ),
      );
    }

    var writeIndex = 0;
    for (var readIndex = 0; readIndex < particles.length; readIndex += 1) {
      final particle = particles[readIndex];
      particle.normalizedAge = _f32(
        particle.normalizedAge + _f32(delta * particle.inverseLife),
      );
      particle.x = _f32(particle.x + particle.velocityX * delta);
      particle.y = _f32(particle.y + particle.velocityY * delta);
      particle.z = _f32(particle.z + particle.velocityZ * delta);
      if (particle.normalizedAge < 1) {
        particles[writeIndex] = particle;
        writeIndex += 1;
      }
    }
    particles.length = writeIndex;
  }

  IosRainParticle _spawn(
    double sceneTime,
    int simulationIndex,
    double width,
    double height,
  ) {
    final particleId = _nextParticleId;
    _nextParticleId = (_nextParticleId + 1) & 0xffffffff;

    final angleDegrees = configuration.fallAngleDegrees;
    final angle = _f32(_f32(angleDegrees * IosRainSpecs.piFloat) / 180);
    final placementAngle = _f32(angle + IosRainSpecs.negativeHalfPiFloat);
    final emitterX = _f32(
      IosRainSpecs.emitterOffset * _f32(math.cos(placementAngle)),
    );
    final emitterY = _f32(
      IosRainSpecs.emitterOffset * _f32(math.sin(placementAngle)),
    );
    final halfAngle = _f32(angle * 0.5);
    final quaternionZ = _f32(math.sin(halfAngle));
    final quaternionW = _f32(math.cos(halfAngle));
    final sinAngle = _f32(_f32(2 * quaternionZ) * quaternionW);
    final cosAngle = _f32(
      _f32(quaternionW * quaternionW) - _f32(quaternionZ * quaternionZ),
    );

    final localX = _f32(
      (_random.nextUnitFloat24() - 0.5) * IosRainSpecs.emitterWidth,
    );
    final localZ = _f32(
      (_random.nextUnitFloat24() - 0.5) * IosRainSpecs.emitterDepth,
    );
    final magnitude = _f32(
      spec.velocityMin +
          (spec.velocityMax - spec.velocityMin) * _random.nextUnitFloat24(),
    );
    final spread = _f32(
      spec.spreadDegrees *
          IosRainSpecs.piFloat /
          180 *
          _random.nextUnitFloat24(),
    );
    final azimuth = _f32(IosRainSpecs.twoPiFloat * _random.nextUnitFloat24());
    final spreadSin = _f32(math.sin(spread));
    final localVelocityX = _f32(spreadSin * math.cos(azimuth) * magnitude);
    final localVelocityY = _f32(math.cos(spread) * magnitude);
    final localVelocityZ = _f32(spreadSin * math.sin(azimuth) * magnitude);

    final hashInput =
        (particleId + effectiveSeed + simulationIndex) & 0xffffffff;
    final frame = (_hashRandom01(hashInput, 0xac564b05) * 4).floor();
    final colorWeight = _hashRandom01(hashInput, spec.colorHashAddend);

    return IosRainParticle(
      id: particleId,
      x: _f32(emitterX + cosAngle * localX),
      y: _f32(emitterY + sinAngle * localX),
      z: _f32(spec.depth + localZ),
      velocityX: _f32(cosAngle * localVelocityX - sinAngle * localVelocityY),
      velocityY: _f32(sinAngle * localVelocityX + cosAngle * localVelocityY),
      velocityZ: localVelocityZ,
      width: width,
      height: height,
      life: spec.life,
      frame: frame,
      color: _interpolateColor(_colorStart, _colorEnd, colorWeight),
    );
  }
}

/// VFX's `RandomNumberGeneratorXoshiro`, including its recovered seed mapping.
///
/// Verification: constants and the xoshiro256** transition come from VFX
/// functions 0x1b1699214 and 0x1b11433b0 respectively.
class IosXoshiro256StarStar {
  IosXoshiro256StarStar(int seed)
    : _state0 = _u64(
        BigInt.from(seed) + BigInt.parse('76e15d3efefdcbbf', radix: 16),
      ),
      _state1 = _u64(
        BigInt.from(seed) * -BigInt.parse('3affb1bbe3add04d', radix: 16) -
            BigInt.parse('3affb1bbe3add04d', radix: 16),
      ),
      _state2 = _u64(
        BigInt.parse('77710069854ee241', radix: 16) - BigInt.from(seed),
      ),
      _state3 = _u64(
        BigInt.from(seed) * BigInt.parse('39109bb02acbe635', radix: 16),
      );

  BigInt _state0;
  BigInt _state1;
  BigInt _state2;
  BigInt _state3;

  BigInt nextUint64() {
    final result = _u64(
      _rotateLeft64(_u64(_state1 * BigInt.from(5)), 7) * BigInt.from(9),
    );
    final shifted = _u64(_state1 << 17);
    _state2 = _u64(_state2 ^ _state0);
    _state3 = _u64(_state3 ^ _state1);
    _state1 = _u64(_state1 ^ _state2);
    _state0 = _u64(_state0 ^ _state3);
    _state2 = _u64(_state2 ^ shifted);
    _state3 = _rotateLeft64(_state3, 45);
    return result;
  }

  double nextUnitFloat24() =>
      _f32((nextUint64() & BigInt.from(0xffffff)).toInt() / 16777216);
}

/// Perspective-projection and one-call-per-layer quad renderer.
///
/// Purpose: compose velocity billboard, stretch, pi rotation, camera and UV once.
/// Contract: projected corners drive culling; simulation continues off screen.
/// Vertices use float32 positions/ARGB8 colors, not Metal half-color precision.
/// Visual: streaks align with travel; BG precedes FG with source-derived alpha.
/// Verification: asymmetric atlas, projection and premultiplied pixel fixtures.
class _IosRainPainter extends CustomPainter {
  _IosRainPainter({
    required this.simulation,
    required this.backgroundImage,
    required this.foregroundImage,
  }) : _backgroundPaint = _atlasPaint(backgroundImage),
       _foregroundPaint = _atlasPaint(foregroundImage),
       super(repaint: simulation);

  final IosRainSimulation simulation;
  final ui.Image? backgroundImage;
  final ui.Image? foregroundImage;
  final Paint? _backgroundPaint;
  final Paint? _foregroundPaint;

  @override
  void paint(Canvas canvas, Size size) {
    final background = backgroundImage;
    final backgroundPaint = _backgroundPaint;
    final foreground = foregroundImage;
    final foregroundPaint = _foregroundPaint;
    if (background != null && backgroundPaint != null) {
      _paintEmitter(
        canvas,
        size,
        simulation.background,
        background,
        backgroundPaint,
      );
    }
    if (foreground != null && foregroundPaint != null) {
      _paintEmitter(
        canvas,
        size,
        simulation.foreground,
        foreground,
        foregroundPaint,
      );
    }
  }

  void _paintEmitter(
    Canvas canvas,
    Size size,
    IosRainEmitter emitter,
    ui.Image atlas,
    Paint paint,
  ) {
    var visibleCount = 0;
    final frameWidth = atlas.width / 4;
    final frameHeight = atlas.height.toDouble();
    for (final particle in emitter.particles) {
      final offset = visibleCount * 8;
      if (!writeIosRainQuad(particle, size, emitter.positions, offset)) {
        continue;
      }
      final left = particle.frame * frameWidth;
      final right = left + frameWidth;
      // Native material flips V. Particle pi rotation is already in geometry.
      emitter.textureCoordinates
        ..[offset] = left
        ..[offset + 1] = frameHeight
        ..[offset + 2] = right
        ..[offset + 3] = frameHeight
        ..[offset + 4] = left
        ..[offset + 5] = 0
        ..[offset + 6] = right
        ..[offset + 7] = 0;
      final color = particle.color.toARGB32().toSigned(32);
      final colorOffset = visibleCount * 4;
      emitter.colors
        ..[colorOffset] = color
        ..[colorOffset + 1] = color
        ..[colorOffset + 2] = color
        ..[colorOffset + 3] = color;
      visibleCount += 1;
    }
    if (visibleCount == 0) return;

    for (var first = 0; first < visibleCount; first += 16384) {
      final count = math.min(16384, visibleCount - first);
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.sublistView(
          emitter.positions,
          first * 8,
          (first + count) * 8,
        ),
        textureCoordinates: Float32List.sublistView(
          emitter.textureCoordinates,
          first * 8,
          (first + count) * 8,
        ),
        colors: Int32List.sublistView(
          emitter.colors,
          first * 4,
          (first + count) * 4,
        ),
        indices: Uint16List.sublistView(emitter.indices, 0, count * 6),
      );
      canvas.drawVertices(vertices, BlendMode.modulate, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IosRainPainter oldDelegate) =>
      oldDelegate.simulation != simulation ||
      oldDelegate.backgroundImage != backgroundImage ||
      oldDelegate.foregroundImage != foregroundImage;
}

/// Purpose: translate the active native orientation-0 velocity billboard.
/// Invocation: the actual painter and host geometry fixtures share this function.
/// Contract: camera=(0,0,100), focal50/sensor24; velocity stretch .001, pivot .5,
/// pi rotation then projection. No random calls, per-particle allocations or I/O.
/// Returns false for a clipped/invalid quad; never kills the simulated particle.
/// Float32 vertex packing is retained; Metal half arithmetic is a parity boundary.
/// Verification: known-axis, wind-alignment, depth/aspect and four-corner tests.
/// Visual: the long streak axis follows projected travel without a guessed flip.
bool writeIosRainQuad(
  IosRainParticle particle,
  Size viewport,
  Float32List positions,
  int offset,
) {
  final depth = IosRainSpecs.cameraZ - particle.z;
  if (!depth.isFinite ||
      depth <= .1 ||
      depth >= 10000 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return false;
  }
  final vx = particle.velocityX, vy = particle.velocityY;
  final planarSpeed = math.sqrt(vx * vx + vy * vy);
  if (!planarSpeed.isFinite || planarSpeed == 0) return false;
  final xx = vy / planarSpeed, xy = -vx / planarSpeed;
  final yx = vx / planarSpeed, yy = vy / planarSpeed;
  final stretch = 1 + math.max(0.0, .001 * (vx * yx + vy * yy));
  final cosine = _f32(math.cos(IosRainSpecs.piFloat));
  final sine = _f32(math.sin(IosRainSpecs.piFloat));
  final axisXX = xx * cosine + yx * sine;
  final axisXY = xy * cosine + yy * sine;
  final axisYX = (yx * cosine - xx * sine) * stretch;
  final axisYY = (yy * cosine - xy * sine) * stretch;
  final scale =
      viewport.height *
      IosRainSpecs.cameraFocalLength /
      IosRainSpecs.cameraSensorSize /
      depth;
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (var vertex = 0; vertex < 4; vertex++) {
    final dx = ((vertex & 1) - .5) * particle.width;
    final dy = ((vertex >> 1) - .5) * particle.height;
    final x =
        viewport.width / 2 +
        (particle.x + axisXX * dx + axisYX * dy - IosRainSpecs.cameraX) * scale;
    final y =
        viewport.height / 2 -
        (particle.y + axisXY * dx + axisYY * dy - IosRainSpecs.cameraY) * scale;
    positions[offset + vertex * 2] = x;
    positions[offset + vertex * 2 + 1] = y;
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  return maxX >= 0 &&
      minX <= viewport.width &&
      maxY >= 0 &&
      minY <= viewport.height;
}

Paint? _atlasPaint(ui.Image? image) {
  if (image == null) return null;
  return Paint()
    ..shader = ui.ImageShader(
      image,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      _identityMatrix,
    )
    ..filterQuality = ui.FilterQuality.low;
}

final Float64List _identityMatrix = Float64List.fromList(<double>[
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
]);
final Float32List _floatScratch = Float32List(1);
final ByteData _hashScratch = ByteData(4);

double _f32(double value) {
  _floatScratch[0] = value;
  return _floatScratch[0];
}

BigInt _u64(BigInt value) => value.toUnsigned(64);

BigInt _rotateLeft64(BigInt value, int amount) =>
    _u64((_u64(value) << amount) | (_u64(value) >> (64 - amount)));

double _hashRandom01(int input, int addend) {
  final state = (input * 0x2c9277b5 + addend) & 0xffffffff;
  final mixed = ((state >>> ((state >>> 28) + 4)) ^ state) & 0xffffffff;
  final word = (mixed * 0x108ef2d9) & 0xffffffff;
  final bits = ((word >>> 31) ^ (word >>> 9)) | 0x3f800000;
  _hashScratch.setUint32(0, bits, Endian.little);
  return _hashScratch.getFloat32(0, Endian.little) - 1;
}

ui.Color _interpolateColor(ui.Color start, ui.Color end, double amount) {
  final red = _f32(start.r + _f32(end.r - start.r) * amount);
  final green = _f32(start.g + _f32(end.g - start.g) * amount);
  final blue = _f32(start.b + _f32(end.b - start.b) * amount);
  final alpha = _f32(start.a + _f32(end.a - start.a) * amount);
  return ui.Color.from(
    alpha: alpha.clamp(0, 1).toDouble(),
    red: red.clamp(0, 1).toDouble(),
    green: green.clamp(0, 1).toDouble(),
    blue: blue.clamp(0, 1).toDouble(),
  );
}

Uint16List _quadIndices(int quadCount) {
  final output = Uint16List(quadCount * 6);
  for (var index = 0; index < quadCount; index += 1) {
    final vertex = index * 4;
    final offset = index * 6;
    output
      ..[offset] = vertex
      ..[offset + 1] = vertex + 1
      ..[offset + 2] = vertex + 2
      ..[offset + 3] = vertex + 1
      ..[offset + 4] = vertex + 3
      ..[offset + 5] = vertex + 2;
  }
  return output;
}
