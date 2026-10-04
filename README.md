# Implementing iOS-style regular rain

A practical implementation guide based on analysis of **iOS 26.5, build 23F77, WeatherUI 1318**, its rain scene, and the VFX particle pipeline. It explains the configuration, simulation, wind, lighting, projection, and streak rendering needed to reproduce the recovered regular-rain behavior.

This repository contains a reusable Flutter rain library, its two rain atlases, focused host tests, documentation, and numeric reference data. It contains no application launcher, APK, Apple framework binaries, or disassembly dumps. See [artwork provenance](assets/README.md). Static source evidence establishes the behavior described here; identical live iOS pixels, random sequences, and performance have not been demonstrated.

## Use the implementation

Add the package to your Flutter application's `pubspec.yaml` (Dart 3.13.2 / Flutter 3.47.2 or newer):

```yaml
dependencies:
  ios_rain_effect:
    git:
      url: https://github.com/IvanChanPing/ios-rain-implementation-guide.git
      ref: main
```

Import the public library and place the layer in a bounded area, such as a full-screen `Stack`:

```dart
import 'package:ios_rain_effect/ios_rain_effect.dart';

const rain = RainWeatherLayer(
  active: true,
  configuration: IosRainConfiguration(
    windSpeedMetersPerSecond: 4.4704, // 10 mph
    elevationDegrees: 33,
    isPM: false,
  ),
);
```

The package declares and loads its own assets. Your application supplies wind speed, solar elevation, and solar AM/PM; no weather request, location permission, dashboard, or app-specific weather model is included. The configuration's `reference` value is an explicit zero-wind preview input, not live weather. The shipped renderer implements compact regular rain; other layouts remain reference data. Noise and sway remain disabled as in that preset.

| Files | Responsibility |
|---|---|
| `lib/ios_rain_effect.dart` | Public import |
| `lib/src/ios_background_vfx.dart` | Widget lifecycle, two emitters, random sampling, integration, projection and painting |
| `lib/src/ios_rain_configuration.dart` | Wind conversion and full compact solar-lighting interpolation |
| `assets/background/*.png` | Foreground/background four-frame rain atlases |
| `test/ios_rain_runtime_test.dart` | Numeric, geometry, alpha, configuration and pause tests |
| `test/fixtures/ios_rain_compact_reference.json` | Independent recovered parameter and lighting fixture |
| `tool/consumer_check/` | Host test that imports this package and decodes its bundled assets as a dependency |

Run `flutter pub get`, `flutter analyze`, and `flutter test test/ios_rain_runtime_test.dart`. To check dependency packaging, run `flutter pub get` and `flutter test` from `tool/consumer_check`. Neither route builds an APK. For reproducible app dependencies, pin a reviewed commit instead of the moving `main` reference.

## Start here

Implement two independent world-space particle emitters: a distant background layer and a closer foreground layer. Feed them a resolved weather configuration, advance them using elapsed seconds, and paint textured quads aligned with each particle's velocity. Draw the background before the foreground.

The complete numeric reference is [rain-reference.json](rain-reference.json): nine layout presets, exact stored numeric values and native addresses, and ten compact-layout lighting keyframes. The recipe below uses the **compact-phone regular-rain** preset. Other weather conditions and screen layouts must be selected deliberately.

```text
weather condition + layout
    -> preset
    -> wind-dependent base angle + solar lighting
    -> named particle parameters
    -> emitter placement and particle births
    -> lifetime and position integration
    -> velocity-aligned quads
    -> camera projection, atlas sampling, alpha composition
```

## 1. Use runtime parameters, not the scene's authoring defaults

The scene file is a reusable effect template. WeatherUI replaces its authored values with the selected condition/layout configuration. For example, the scene's 1,500/1,000 background/foreground birth rates and three-second lifetime are not the active compact regular-rain settings.

| Parameter | Background | Foreground |
|---|---:|---:|
| Births per second | 3,000 | 320 |
| Lifetime | 2.5 s | 2.5 s |
| Signed velocity range before orientation | −60 to −36 | −120 to −84 |
| Width range, scene units | 0.13–0.18 | 0.23–0.30 |
| Height range | 3.15 × minimum width to 3.75 × maximum width | 3.75 × minimum width to 4.25 × maximum width |
| Direction spread | 2° | 1.25° |
| Emitter depth position | −30 | −4.5 |
| Warmup | 1.5 s | 2 s |
| Noise intensity / scale | 0 / 0 | 0 / 0 |

Shared settings:

- Camera position `(0, 0, 100)`, focal length `50`, sensor height `24`.
- Emitter offset `−35`, emitter width `30`, depth extent `8`.
- Configured time scale `1.0`.
- `blowingSpeed = 0`, `blowingAmount = 0`.
- World-space emitters; the recovered scene sets `updateOnGPU = false`.
- Particle pivot `(0.5, 0.5)`, particle angle `π`, velocity stretch factor `0.001`.

Table decimals are readable shorthand. Preserve the full values in the JSON when making numeric fixtures. Birth rates are not visible-particle counts: depth, viewport, and lifetime also determine what is on screen. Rate × lifetime gives nominal populations of 7,500 background and 800 foreground particles before lifetime-edge and capacity headroom.

## 2. Resolve wind and distinguish tilt from sway

For this regular-rain branch, the weather wind speed is converted to miles per hour and capped at 100:

```text
mph = windMetersPerSecond / 0.44704
baseAngleDegrees = f32(f32(min(mph, 100) / 100) * -15)
```

`f32` means round to an IEEE-754 single-precision value. Validate that your incoming wind speed is finite and nonnegative. This branch does not use compass wind direction. User-selected display units must not change the animation.

| Wind | Base angle |
|---|---:|
| 0 mph | 0° |
| 10 mph | −1.5° |
| 50 mph | −7.5° |
| 100 mph and above | −15° |

The native foreground and background placement graphs also contain a periodic sway mechanism:

```text
phase = f32(blowingSpeed * f32(sceneTimeSeconds))
angleDegrees = f32(baseAngleDegrees + f32(blowingAmount * sinf(phase)))
```

`blowingSpeed` controls phase progression; `blowingAmount` controls angular amplitude in degrees. This is a smooth sine oscillation, not a sampled live gust measurement. The angle places and orients the emitter for subsequent births. It is not an instruction to rotate every existing world-space raindrop back toward the center each frame.

The scene template initially has both blowing controls at `1`. **All nine recovered regular-rain presets set both to `0`**, and the application passes those preset values into the scene. Therefore the regular-rain configuration disables this oscillation. Enabling it is a deliberate variation, not the recovered regular-rain setting.

The four rain noise values also come from the selected preset: foreground intensity/scale and background intensity/scale. They reach the respective `ParticleNoise` components through bindings. All four are zero in all nine recovered regular-rain presets. The traced weather-wind updater changes the base angle; it does not populate these six noise/blowing values.

## 3. Place the emitter and initialize new particles

Convert the resolved angle to radians. The placement graph uses:

```text
placementAngle = angleRadians - pi / 2
emitterX = emitterOffset * cos(placementAngle)
emitterY = emitterOffset * sin(placementAngle)
emitterZ = layerDepth
orientation = quaternionAroundZ(angleRadians)
```

At zero wind and offset `−35`, the emitter is above the scene center at approximately `(0, 35, layerDepth)`. Sample the plane's width/depth extent, then transform the sampled position and velocity through the emitter orientation. Preserve the signed velocity interval and the layer's direction spread.

Initialize and retain these values for each particle:

- Position and velocity in world space.
- Inverse lifetime and normalized age.
- Independent width and height samples: the native size mode is planar, not one random factor shared by both dimensions.
- A sampled color between that layer's lighting endpoints.
- One of four horizontal atlas frames, selected at birth.
- Particle angle `π`.

Use a reproducible random generator and explicit seed injection for tests. The scene stores background seed `623276563` and foreground seed `2502535891`, with `randomize = true`. Those authored seeds do not establish the effective seed of a live iOS run. Exact native cross-stage random-number ordering remains unproven; do not claim an identical random sequence from matching distributions.

The native initializer entity order is background `[506,355,478,91,500,493]` and foreground `[106,30,376,251,129,54]`. Native allocation records a born range, then initialization operates over it. A convenient per-particle loop is a porting choice, not proof of identical ECS scheduling.

## 4. Emit and advance using elapsed seconds

Keep a fractional birth accumulator per emitter:

```text
accumulator = f32(accumulator + f32(ratePerSecond * dtSeconds))
birthCount = floor(accumulator)
accumulator = min(f32(accumulator - birthCount), largestFloat32BelowOne)
```

The source caps the retained fraction at float bits `0x3f7fffff`. Allocate room before accepting the births. Do not silently drop the configured density to hide a capacity or performance problem.

For the compact preset's constant-velocity path:

```text
position = f32PerComponent(position + velocity * dtSeconds)
normalizedAge = f32(normalizedAge + f32(dtSeconds * inverseLifetime))
remove particle when normalizedAge >= 1
```

These equations summarize the numeric operations; they do not assert the complete native scheduler's birth/update ordering. Preserve rounding at the source operation boundaries when testing numeric parity. Do not add generic gravity or turbulence from another precipitation mode. Culling an offscreen quad must not stop its world-space simulation.

A Flutter ticker supplies elapsed time. Compute the difference between consecutive callbacks and divide microseconds by `1,000,000`. Do not move particles by a fixed distance per frame. A 120 Hz display must not make them fall twice as fast as a 60 Hz display.

Warm up the background for 1.5 seconds and foreground for 2 seconds using 0.125-second steps. Preserve the resulting particles and advanced random state, but restore the scene clock afterward; the native warmup owner saves and restores twelve clock words. Treat large-delta subdivision during ordinary playback as an explicit port policy, not a newly established native scheduler fact.

When birth parameters change, existing particles retain their initialized state and later births use the new configuration. When a scene resumes after being paused or hidden, clear its previous callback timestamp so hidden time is not simulated in one jump. That pause policy is integration guidance for the host application.

## 5. Resolve colors from solar elevation and solar phase

Use the ten compact lighting rows in the JSON. Each contains straight sRGB RGBA foreground-start, foreground-end, background-start, and background-end colors.

The keys are:

```text
AM elevations: -90, -18, -6, 33, 60
PM elevations:  60,  33, -6, -18, -90
```

AM/PM here distinguishes before and after solar transit; it is not simply the phone clock being before or after noon. Morning and evening at the same elevation can differ.

First handle an exact elevation/phase key. Otherwise calculate:

```text
phase = isPM ? 180 - elevation : elevation
t = f32((phase - lower.phase) / (upper.phase - lower.phase))
channel = f32((1 - t) * lower.channel + t * upper.channel)
```

Bracket using phase-ordered keys, clamp outside the table to its endpoint, and handle identical key positions without dividing by zero. Preserve the JSON's full representation of the nominal −18° key. The native component interpolation uses double arithmetic before float narrowing. Birth color sampling between the resolved start/end colors is a separate operation.

For example, at 33° AM, foreground alpha ranges from 0.12 to 0.34 and background alpha from 0.10 to approximately 0.22. Use the complete table rather than a guessed day/night opacity switch.

A host astronomy adapter needs the selected place's coordinates and the correct instant. Convert local civil time to UTC once, respect the astronomy library's longitude convention, and distinguish seconds from radians in sidereal-time APIs. An alternative ephemeris is a host adaptation, not demonstrated equivalence to Apple's upstream astronomy.

## 6. Render velocity-aligned textured quads

Do not paint every drop as an axis-aligned rectangle. The native vertex path aligns the billboard with velocity and stretches it:

```text
n = cameraViewZBasis
xAxis = normalize(cross(normalize(velocity), n))
yAxis = normalize(cross(n, xAxis))
stretch = 1 + max(0, 0.001 * dot(velocity, yAxis) / emitterScale)
yAxis *= stretch
rotate billboard basis by particleAngle
corner = particlePosition
       + xAxis * ((u - 0.5) * width)
       + yAxis * ((v - 0.5) * height)
```

For this world-space scene, emitter scale is one. Project each corner through the camera, not only the particle center. With the normal camera configuration, the vertical projection scale is:

```text
depth = cameraZ - worldZ
scale = viewportHeight * focalLength / sensorHeight / depth
```

Retain the camera's aspect and film-offset conventions. The configured camera `(0,0,100)` replaces the authored scene offset; do not keep the template's `(-0.1,-2.19,100)` position as an extra adjustment. Depth naturally makes the two layers appear at different sizes and speeds.

The material applies a UV-Y flip using `(scaleX, -scaleY, biasX, biasY + 1)` before atlas coordinates. Compose this with the particle's `π` rotation and screen-Y convention once. Use an asymmetric test texture to expose accidental double flips. Artwork must provide four horizontal frames and transparent margins appropriate to your intended streak shape.

Draw background first, foreground second. Premultiply RGB by alpha exactly once at the appropriate renderer boundary. Apple's birth color path premultiplies; a Flutter implementation supplying straight vertex colors must account for the backend's conversion instead of multiplying alpha twice. Flutter ARGB8 vertex colors and Apple's float/half pipeline have a precision difference.

The recovered rain scene disables optional rain lighting and soft-particle depth branches. The final device-selected Metal blend descriptor and framebuffer output have not been captured. Do not claim pixel identity merely because the shader equations and parameters match.

## 7. Integrate into an application

Keep configuration, simulation, and painting separate. Resolve condition, wind, and solar inputs in one owner, then pass an immutable configuration to both rain layers. Preserve the application's condition routing: regular rain, drizzle, heavy rain, and storms are not interchangeable presets.

Load and retain artwork once, reuse particle and vertex buffers, and dispose owned images with the scene. Pause the ticker with the scene lifecycle. Reproject existing world-space particles on viewport changes rather than respawning the entire effect.

For a Flutter implementation, indexed quad batches must fit the selected index type. A `Uint16` batch can address at most 65,536 vertices: 16,384 four-vertex quads. Keep CPU work and allocations bounded, including the initial warmup.

Background rain is separate from Apple's collision-rain scene. That effect has its own foreground emitter, collision particles, six box colliders, and an orthographic camera. This guide does not claim to implement card-edge impacts or splashes.

## Validation checklist

- Compare configuration against the JSON, including all lighting endpoints and interpolation between keys.
- Check wind at 0, 10, 50, 100, and above 100 mph; verify m/s conversion.
- Check zero blowing/noise in every regular-rain layout; test nonzero sway separately as a deliberate variation.
- Check independent width/height samples, signed velocity ranges, fractional births, and lifetime removal.
- Verify warmup restores scene time while retaining warmed particles.
- Compare one simulated second at 30, 60, and 120 callback rates. This is a recommended timing test, not a claimed completed native-iOS comparison.
- Render an asymmetric atlas at zero and nonzero wind; inspect orientation, UVs, corner projection, and alpha.
- Exercise pause/resume, asset completion after disposal, configuration changes, and viewport resizing.
- Observe actual moving frames on the target device before claiming visual or performance parity.

## Evidence map and limits

Addresses are original unslid virtual addresses for the analyzed version, not stable APIs.

| Stage | Native evidence |
|---|---|
| Compact preset | WeatherUI `0x1bef143d4` |
| Compact lighting table | WeatherUI `0x1bef14b9c` |
| Lighting key selection / color interpolation | `0x1bee297e8` / `0x1bededcfc` |
| Weather wind → base angle | WeatherUI `0x1bee2c5f4` |
| Configuration → rain parameters | `0x1bf061d0c`, `0x1bf0624a8` |
| Named property assignment | WeatherUI `0x1bf060624` → `0x1bf0606ac`; VFX assignment chain |
| Background / foreground emitter placement | `0x1bee53de4` / `0x1bee540ec` |
| Sway clock | Stub `0x1bf52c660` → VFX `_vfx_script_clock_time` at `0x1b168486c` |
| Sway sine | Stub `0x1bf52c080` → libsystem_m `_sinf` at `0x2a4580050` |
| Fractional emission | VFX `0x1b110dc38` |
| Integration / normalized lifetime | VFX `0x1b14ae87c` / `0x1b14afd10` |
| Warmup and clock restoration | VFX `0x1b160da98` |

Configuration field offsets: foreground noise intensity/scale `0xa4/0xa8`, background `0xe4/0xe8`, blowing speed/amount `0x7bc/0x7c0`, base fall angle `0x58`. The full WeatherUI text scan found no direct calls to the six public setters/modify accessors; this does not rule out every indirect or external override.

The nine preset records and ten compact lighting rows are source-derived. Generic ECS callback ordering, effective randomized-seed lifecycle, complete cross-stage random replay, final live blend selection, and matched-device visual parity remain unproven. The compact lighting table must not silently substitute for every other layout's lighting table. This project is independent documentation and is not affiliated with Apple.
