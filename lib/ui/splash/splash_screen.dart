import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../providers.dart';
import '../../domain/services/backup_service.dart' show appDisplayName;
import '../theme.dart';

/// Started by main() before the database opens. The boot splash
/// ([BootSplashApp]) and [SplashScreen] use it so the branding is one
/// continuous screen and its minimum duration counts from app start.
final Stopwatch bootClock = Stopwatch();

/// Shown the moment the window opens, while the database is still being
/// opened (no services exist yet). Looks exactly like [SplashScreen].
class BootSplashApp extends StatelessWidget {
  final bool dark;
  const BootSplashApp({super.key, this.dark = true});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: appDisplayName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(dark ? AppColors.darkPalette : AppColors.lightPalette),
        home: const _BootSplash(),
      );
}

class _BootSplash extends StatefulWidget {
  const _BootSplash();
  @override
  State<_BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<_BootSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _bg = _gridController(this);

  @override
  void dispose() {
    _bg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SplashView(bg: _bg, fadeIn: true, error: null, onRetry: null);
}

const _gridPeriod = Duration(seconds: 18);

/// Grid animation, continuing from where the boot splash was.
AnimationController _gridController(TickerProvider vsync) {
  final c = AnimationController(vsync: vsync, duration: _gridPeriod);
  if (bootClock.isRunning) c.value = (bootClock.elapsedMilliseconds % _gridPeriod.inMilliseconds) / _gridPeriod.inMilliseconds;
  return c..repeat();
}

/// Startup screen: AL-AQSA CCTV & SOLAR SYSTEM branding over the animated perspective grid
/// (the same branding and animation the app opened with before), then the
/// Dashboard. There is no sign-in: this is a single-computer offline shop
/// application, so the session is opened for the shop owner automatically.
class SplashScreen extends ConsumerStatefulWidget {
  /// How long the branding stays on screen (at least), in addition to the
  /// time needed to open the session.
  final Duration minimumDuration;
  const SplashScreen({
    super.key,
    this.minimumDuration = const Duration(milliseconds: 1400),
  });

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bg = _gridController(this);
  Timer? _timer;
  bool _minimumElapsed = false;
  bool _sessionReady = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Time already spent on the boot splash counts towards the minimum.
    final left = widget.minimumDuration - (bootClock.isRunning ? bootClock.elapsed : Duration.zero);
    _timer = Timer(left.isNegative ? Duration.zero : left, () {
      _minimumElapsed = true;
      _finish();
    });
    _openSession();
  }

  Future<void> _openSession() async {
    setState(() => _error = null);
    try {
      final app = ref.read(servicesProvider);
      await app.auth.openLocalSession();
      // Decode the Dashboard's data now, behind the splash, instead of
      // freezing the first Dashboard frame.
      await app.warmUp();
      if (!mounted) return;
      _sessionReady = true;
      _finish();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _finish() {
    if (!mounted || !_minimumElapsed || !_sessionReady) return;
    final app = ref.read(servicesProvider);
    ref.read(navProvider.notifier).state = NavItem.dashboard;
    ref.read(currentUserProvider.notifier).state = app.ctx.session.user;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SplashView(
        bg: _bg,
        // Already faded in on the boot splash: no second fade.
        fadeIn: !bootClock.isRunning,
        error: _error,
        onRetry: _openSession,
      );
}

class _SplashView extends StatelessWidget {
  final Animation<double> bg;
  final bool fadeIn;
  final String? error;
  final VoidCallback? onRetry;
  const _SplashView({required this.bg, required this.fadeIn, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final err = error;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: bg,
              builder:
                  (_, __) => CustomPaint(painter: _GridPainter(c, bg.value)),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: fadeIn ? const Duration(milliseconds: 650) : Duration.zero,
                curve: Curves.easeOutCubic,
                builder:
                    (_, t, child) => Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 24 * (1 - t)),
                        child: child,
                      ),
                    ),
                child: Container(
                  key: const ValueKey('splash-card'),
                  width: 420,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: c.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: c.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 40,
                        offset: const Offset(0, 20),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const AppLogoFull(height: 150),
                      const SizedBox(height: 16),
                      Text(
                        appDisplayName,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: c.text,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Security & Solar Business Suite',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textMuted),
                      ),
                      const SizedBox(height: 26),
                      if (err == null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 4,
                            color: c.accent,
                            backgroundColor: c.border,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Opening your shop data…',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.textMuted, fontSize: 12.5),
                        ),
                      ] else ...[
                        Text(
                          err,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.danger),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The official AL-AQSA CCTV & SOLAR SYSTEM logo (assets/branding), shown
/// unchanged on its original white background.
const officialLogoAsset = 'assets/branding/al_aqsa_logo.png';
const officialIconAsset = 'assets/branding/al_aqsa_icon_square.png';

/// Square app icon (sidebar, small places).
class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 36});
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.18),
        child: Image.asset(
          officialIconAsset,
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          semanticLabel: appDisplayName,
          errorBuilder: (_, __, ___) => SizedBox(width: size, height: size, child: Icon(Icons.videocam_rounded, size: size * 0.6)),
        ),
      );
}

/// The full portrait logo (splash, dashboard).
class AppLogoFull extends StatelessWidget {
  final double height;
  const AppLogoFull({super.key, this.height = 140});
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: EdgeInsets.all(height * 0.04),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(height * 0.08)),
          child: Image.asset(
            officialLogoAsset,
            height: height,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            semanticLabel: appDisplayName,
            errorBuilder: (_, __, ___) => SizedBox(height: height, width: height * 0.86),
          ),
        ),
      );
}

/// Slowly drifting perspective grid background.
class _GridPainter extends CustomPainter {
  final AppColors c;
  final double t;
  _GridPainter(this.c, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [c.primary.withValues(alpha: 0.25), c.bg],
          radius: 1.1,
          center: const Alignment(0, -0.4),
        ).createShader(Offset.zero & size),
    );
    final paint =
        Paint()
          ..color = c.accent.withValues(alpha: 0.07)
          ..strokeWidth = 1;
    final horizon = size.height * 0.45;
    final cx = size.width / 2;
    for (var k = -20; k <= 20; k++) {
      final x = cx + k * 80.0;
      canvas.drawLine(
        Offset(cx + k * 8.0, horizon),
        Offset(x, size.height),
        paint,
      );
    }
    for (var k = 0; k < 14; k++) {
      final f = ((k + t) / 14);
      final y = horizon + math.pow(f, 2) * (size.height - horizon);
      canvas.drawLine(
        Offset(0, y.toDouble()),
        Offset(size.width, y.toDouble()),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.t != t || old.c != c;
}
