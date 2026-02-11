import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const AlkapuriRunApp());
}

class AlkapuriRunApp extends StatelessWidget {
  const AlkapuriRunApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alkapuri Run',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.deepPurple),
      home: const GameScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Game state enum
// ---------------------------------------------------------------------------
enum GameState { loading, menu, playing, gameOver }

// ---------------------------------------------------------------------------
// Villain data model
// ---------------------------------------------------------------------------
class Villain {
  double x; // absolute px
  double y; // absolute px
  double size;
  double speed; // px per frame
  int imageIndex; // 0 or 1
  bool eaten;

  Villain({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.imageIndex,
    this.eaten = false,
  });
}

// ---------------------------------------------------------------------------
// Main game widget
// ---------------------------------------------------------------------------
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  // ---- state ----
  GameState _gameState = GameState.loading;

  // ---- game loop ----
  late AnimationController _ticker;

  // ---- audio ----
  final AudioPlayer _bgMusic = AudioPlayer();
  final AudioPlayer _sfx = AudioPlayer();
  bool _soundOn = true;

  // ---- score / level / lives ----
  int _score = 0;
  int _level = 1;
  int _lives = 3;
  int _eaten = 0;

  // ---- hero ----
  double _heroX = 0.5; // 0..1 normalised
  static const double _heroSize = 70;

  // ---- villains ----
  final List<Villain> _villains = [];
  final Random _rng = Random();

  // ---- images loaded? ----
  bool _heroImgOk = false;
  bool _v1ImgOk = false;
  bool _v2ImgOk = false;
  bool _bgImgOk = false;

  // ---- drag ----
  double _dragStartGlobalX = 0;
  double _dragStartHeroX = 0;

  // ---- helpers ----
  double get _spawnRate => min(5.0, 1.0 + _level * 0.15);
  double get _baseSpeed => min(12.0, 2.0 + _level * 0.35);
  int get _eatsNeeded => 10 + (_level - 1) * 2;

  // =========================================================================
  // Lifecycle
  // =========================================================================
  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(days: 999), // runs forever
    )..addListener(_onTick);

    _preloadImages();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _bgMusic.dispose();
    _sfx.dispose();
    super.dispose();
  }

  // =========================================================================
  // Asset preloading
  // =========================================================================
  void _preloadImages() {
    int done = 0;
    void check() {
      done++;
      if (done >= 4 && mounted) {
        setState(() => _gameState = GameState.menu);
      }
    }

    _tryLoadImage('assets/images/hero.png', (ok) {
      _heroImgOk = ok;
      check();
    });
    _tryLoadImage('assets/images/villain1.png', (ok) {
      _v1ImgOk = ok;
      check();
    });
    _tryLoadImage('assets/images/villain2.png', (ok) {
      _v2ImgOk = ok;
      check();
    });
    _tryLoadImage('assets/images/bg.png', (ok) {
      _bgImgOk = ok;
      check();
    });

    // safety timeout
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _gameState == GameState.loading) {
        setState(() => _gameState = GameState.menu);
      }
    });
  }

  void _tryLoadImage(String path, void Function(bool) cb) {
    final provider = AssetImage(path);
    final stream = provider.resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener(
      (_, __) => cb(true),
      onError: (_, __) => cb(false),
    ));
  }

  // =========================================================================
  // Audio helpers
  // =========================================================================
  Future<void> _playMenuMusic() async {
    if (!_soundOn) return;
    try {
      await _bgMusic.stop();
      await _bgMusic.setReleaseMode(ReleaseMode.loop);
      await _bgMusic.play(AssetSource('sounds/menu.mp3'));
    } catch (_) {}
  }

  Future<void> _playGameMusic() async {
    if (!_soundOn) return;
    try {
      await _bgMusic.stop();
      await _bgMusic.setReleaseMode(ReleaseMode.loop);
      await _bgMusic.play(AssetSource('sounds/game.mp3'));
    } catch (_) {}
  }

  Future<void> _playEatSfx() async {
    if (!_soundOn) return;
    try {
      await _sfx.stop();
      await _sfx.play(AssetSource('sounds/eat.mp3'));
    } catch (_) {}
  }

  void _stopMusic() {
    try {
      _bgMusic.stop();
    } catch (_) {}
  }

  // =========================================================================
  // Game actions
  // =========================================================================
  void _startGame() {
    setState(() {
      _gameState = GameState.playing;
      _score = 0;
      _level = 1;
      _lives = 3;
      _eaten = 0;
      _heroX = 0.5;
      _villains.clear();
    });
    _ticker.reset();
    _ticker.forward(); // start ticking
    _playGameMusic();
  }

  void _gameOver() {
    _ticker.stop();
    _stopMusic();
    setState(() => _gameState = GameState.gameOver);
  }

  void _goToMenu() {
    _ticker.stop();
    _stopMusic();
    setState(() => _gameState = GameState.menu);
    _playMenuMusic();
  }

  void _toggleSound() {
    setState(() {
      _soundOn = !_soundOn;
      if (!_soundOn) {
        _stopMusic();
      } else {
        if (_gameState == GameState.playing) {
          _playGameMusic();
        } else if (_gameState == GameState.menu) {
          _playMenuMusic();
        }
      }
    });
  }

  // =========================================================================
  // Game loop (called every frame via AnimationController listener)
  // =========================================================================
  void _onTick() {
    if (_gameState != GameState.playing) return;

    final size = MediaQuery.of(context).size;
    final w = size.width;
    final h = size.height;

    // --- spawn ---
    if (_rng.nextDouble() < _spawnRate * 0.025) {
      final vSize = 45.0 + _rng.nextDouble() * 30;
      _villains.add(Villain(
        x: vSize / 2 + _rng.nextDouble() * (w - vSize),
        y: -vSize,
        size: vSize,
        speed: _baseSpeed + _rng.nextDouble() * (_level * 0.4),
        imageIndex: _rng.nextInt(2),
      ));
    }

    // --- move villains ---
    for (final v in _villains) {
      v.y += v.speed;
    }

    // --- collision with hero ---
    final heroPixelX = _heroX * w;
    final heroPixelY = h * 0.85;
    final heroRect = Rect.fromCenter(
      center: Offset(heroPixelX, heroPixelY),
      width: _heroSize,
      height: _heroSize,
    );

    for (final v in _villains) {
      if (v.eaten) continue;
      final vRect = Rect.fromCenter(
        center: Offset(v.x, v.y),
        width: v.size,
        height: v.size,
      );
      if (heroRect.overlaps(vRect)) {
        v.eaten = true;
        _score += _level * 10;
        _eaten++;
        _playEatSfx();
        if (_eaten >= _eatsNeeded) {
          _level++;
          _eaten = 0;
        }
      }
    }

    // --- villains that passed the bottom ---
    for (final v in _villains) {
      if (!v.eaten && v.y - v.size / 2 > h) {
        v.eaten = true; // mark so we don't count twice
        _lives--;
        if (_lives <= 0) {
          _gameOver();
          return;
        }
      }
    }

    // --- remove dead / off-screen ---
    _villains.removeWhere((v) => v.eaten || v.y > h + 100);

    setState(() {}); // trigger rebuild
  }

  // =========================================================================
  // Drag handling
  // =========================================================================
  void _onPanStart(DragStartDetails d) {
    _dragStartGlobalX = d.globalPosition.dx;
    _dragStartHeroX = _heroX;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final w = MediaQuery.of(context).size.width;
    final dx = d.globalPosition.dx - _dragStartGlobalX;
    setState(() {
      _heroX = (_dragStartHeroX + dx / w).clamp(0.08, 0.92);
    });
  }

  // =========================================================================
  // Build
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // --- background ---
          _buildBackground(),
          // --- state layers ---
          if (_gameState == GameState.loading) _buildLoading(),
          if (_gameState == GameState.menu) _buildMenu(),
          if (_gameState == GameState.playing) _buildPlaying(),
          if (_gameState == GameState.gameOver) _buildGameOver(),
        ],
      ),
    );
  }

  // ---- background ----
  Widget _buildBackground() {
    if (_bgImgOk) {
      return Image.asset(
        'assets/images/bg.png',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _gradientBg(),
      );
    }
    return _gradientBg();
  }

  Widget _gradientBg() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1a1a2e), Color(0xFF16213e), Color(0xFF0f3460)],
        ),
      ),
    );
  }

  // ---- loading ----
  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.deepPurpleAccent),
          SizedBox(height: 20),
          Text('Loading…',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ---- menu ----
  Widget _buildMenu() {
    return SafeArea(
      child: Center(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'ALKAPURI\nRUN',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 52,
                  height: 1.1,
                  color: Colors.deepPurpleAccent,
                  fontWeight: FontWeight.w900,
                  shadows: [
                    Shadow(
                        color: Colors.black,
                        offset: Offset(3, 3),
                        blurRadius: 8),
                  ],
                ),
              ),
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: _startGame,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30)),
              ),
              child: const Text('START',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 16),
            IconButton(
              onPressed: _toggleSound,
              iconSize: 36,
              icon: Icon(
                _soundOn ? Icons.volume_up : Icons.volume_off,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ---- playing ----
  Widget _buildPlaying() {
    final size = MediaQuery.of(context).size;
    final w = size.width;
    final h = size.height;
    final heroPixelX = _heroX * w;
    final heroPixelY = h * 0.85;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      child: Stack(
        children: [
          // ---- villains ----
          for (final v in _villains)
            if (!v.eaten)
              Positioned(
                left: v.x - v.size / 2,
                top: v.y - v.size / 2,
                width: v.size,
                height: v.size,
                child: _villainWidget(v),
              ),

          // ---- hero ----
          Positioned(
            left: heroPixelX - _heroSize / 2,
            top: heroPixelY - _heroSize / 2,
            width: _heroSize,
            height: _heroSize,
            child: _heroWidget(),
          ),

          // ---- HUD ----
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _hudChip('Score: $_score'),
                      _hudChip('Level: $_level'),
                      _hudChip(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Lives: ',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                            for (int i = 0; i < _lives; i++)
                              const Padding(
                                padding: EdgeInsets.only(left: 2),
                                child: Icon(Icons.favorite,
                                    color: Colors.redAccent, size: 18),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _hudChip('Next: $_eaten / $_eatsNeeded'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hudChip(dynamic content) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: content is Widget
          ? content
          : Text(content.toString(),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
    );
  }

  // ---- hero widget ----
  Widget _heroWidget() {
    if (_heroImgOk) {
      return Image.asset(
        'assets/images/hero.png',
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _heroFallback(),
      );
    }
    return _heroFallback();
  }

  Widget _heroFallback() {
    return CustomPaint(painter: _HeroFallbackPainter());
  }

  // ---- villain widget ----
  Widget _villainWidget(Villain v) {
    final path =
        v.imageIndex == 0 ? 'assets/images/villain1.png' : 'assets/images/villain2.png';
    final imgOk = v.imageIndex == 0 ? _v1ImgOk : _v2ImgOk;

    if (imgOk) {
      return Image.asset(
        path,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _villainFallback(v.imageIndex),
      );
    }
    return _villainFallback(v.imageIndex);
  }

  Widget _villainFallback(int idx) {
    return CustomPaint(painter: _VillainFallbackPainter(idx));
  }

  // ---- game over ----
  Widget _buildGameOver() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.deepPurpleAccent, width: 3),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('GAME OVER',
                style: TextStyle(
                    fontSize: 38,
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 24),
            Text('Score: $_score',
                style: const TextStyle(
                    fontSize: 26,
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Level: $_level',
                style: const TextStyle(
                    fontSize: 22,
                    color: Colors.deepPurpleAccent,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _startGame,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('RESTART',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                ElevatedButton(
                  onPressed: _goToMenu,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('MENU',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Fallback painters (used when PNG assets are missing)
// ===========================================================================

class _HeroFallbackPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    // body
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = const Color(0xFF7B1FA2));
    // outline
    canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // eyes
    final eye = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(cx - r * 0.28, cy - r * 0.15), r * 0.18, eye);
    canvas.drawCircle(Offset(cx + r * 0.28, cy - r * 0.15), r * 0.18, eye);
    final pupil = Paint()..color = Colors.black;
    canvas.drawCircle(Offset(cx - r * 0.22, cy - r * 0.15), r * 0.09, pupil);
    canvas.drawCircle(Offset(cx + r * 0.34, cy - r * 0.15), r * 0.09, pupil);
    // smile
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 0.8, height: r * 0.5),
      0.2,
      2.7,
      false,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _VillainFallbackPainter extends CustomPainter {
  final int idx;
  _VillainFallbackPainter(this.idx);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final color = idx == 0 ? const Color(0xFFD32F2F) : const Color(0xFFFF9800);

    // body
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = color);
    canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // eyes
    final eye = Paint()..color = Colors.yellow;
    canvas.drawCircle(Offset(cx - r * 0.3, cy - r * 0.15), r * 0.18, eye);
    canvas.drawCircle(Offset(cx + r * 0.3, cy - r * 0.15), r * 0.18, eye);
    final pupil = Paint()..color = Colors.black;
    canvas.drawCircle(Offset(cx - r * 0.25, cy - r * 0.15), r * 0.09, pupil);
    canvas.drawCircle(Offset(cx + r * 0.35, cy - r * 0.15), r * 0.09, pupil);
    // frown
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, cy + r * 0.25), width: r * 0.6, height: r * 0.35),
      3.4,
      2.5,
      false,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
