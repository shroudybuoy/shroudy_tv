import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:http/http.dart' as http;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep channel logos in memory for the whole app session so each one is
  // downloaded once and never re-fetched until the app is closed. The size is
  // capped because an unbounded cache is a memory-kill risk on iPad once
  // programme artwork is added to the same cache.
  PaintingBinding.instance.imageCache.maximumSize = 800;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64 MB
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);
  runApp(const ShroudyTvApp());
}

const String _playlistUrl =
    'https://raw.githubusercontent.com/shroudybuoy/TV-Channels/refs/heads/main/channel%20playlist.m3u';

const String _aspectRatioPrefKey = 'aspect_ratio';
const String _favoriteNamesPrefKey = 'favorite_names';

const String _aspectFitToScreen = 'Fit to screen';
const String _aspect16x9 = '16:9';
const String _aspect4x3 = '4:3';

/// "Fit to screen" stretches the stream across the whole player rectangle.
/// Fixed ratios use `cover` so the selected box is filled and overflow is
/// cropped, rather than letterboxed inside it.
VlcVideoFit fitForAspectRatio(String aspect) =>
    aspect == _aspectFitToScreen ? VlcVideoFit.fill : VlcVideoFit.cover;

/// Key used to store and look up a channel's EPG entry. Channels that declare
/// a `tvg-id` are matched by it; the rest fall back to their display name.
String epgKeyFor(ChannelItem channel) {
  final id = channel.tvgId.trim();
  return id.isNotEmpty ? id : channel.name;
}

class ShroudyColors {
  static const darkNavyBg = Color(0xFF040F1E);
  static const cardNavyBg = Color(0xFF071B32);
  static const innerLogoBg = Color(0xFF041222);
  static const primaryRed = Color(0xFFEF4444);
  static const accentBorder = Color(0xFF124A78);
  static const liveIndicator = Color(0xFFFF5A5A);
  static const goldText = Color(0xFFFFD700);
}

class ChannelItem {
  final String name;
  final String logoUrl;
  final String streamUrl;
  final String category;
  final String tvgId;

  ChannelItem({
    required this.name,
    required this.logoUrl,
    required this.streamUrl,
    required this.category,
    required this.tvgId,
  });
}

/// Channel logo with an empty-URL guard. The grid cards used to pass `''`
/// straight to `Image.network`, which threw for every playlist entry that has no
/// `logo=` attribute.
class _ChannelLogo extends StatelessWidget {
  final String url;

  const _ChannelLogo({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) {
      return const Icon(Icons.tv, color: Colors.white, size: 30);
    }
    return Image.network(
      url,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) =>
          const Icon(Icons.tv, color: Colors.white, size: 30),
    );
  }
}

class EpgProgram {
  final DateTime start;
  final DateTime stop;
  final String title;
  final String description;
  final String? imageUrl;

  const EpgProgram({
    required this.start,
    required this.stop,
    required this.title,
    this.description = '',
    this.imageUrl,
  });
}

class EpgData {
  final EpgProgram? now;
  final EpgProgram? next;
  final List<EpgProgram> upcoming;

  const EpgData({
    this.now,
    this.next,
    this.upcoming = const [],
  });
}

/// Result of parsing one M3U body, kept separate from widget state so a
/// refresh replaces the whole listing atomically.
class _ParsedPlaylist {
  final List<ChannelItem> channels;
  final List<String> categories;
  final String? epgUrl;

  const _ParsedPlaylist({
    required this.channels,
    required this.categories,
    this.epgUrl,
  });
}

/// Animated boot/splash screen shown while the playlist and channel logos load.
class BootSplash extends StatefulWidget {
  const BootSplash({super.key});

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> with TickerProviderStateMixin {
  // Gentle "breathing" pulse on the logo badge.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  // One-shot entrance for the whole composition.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void dispose() {
    _pulse.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    final rise = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    final scale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [ShroudyColors.darkNavyBg, ShroudyColors.cardNavyBg],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: fade,
            child: SlideTransition(
              position: rise,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: scale,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [ShroudyColors.primaryRed, Color(0xFFB91C1C)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: ShroudyColors.primaryRed.withAlpha(115),
                            blurRadius: 34,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.live_tv, color: Colors.white, size: 46),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'SHROUDY TV',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'i O S',
                    style: TextStyle(
                      color: Colors.white.withAlpha(150),
                      fontSize: 13,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: 150,
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      backgroundColor: Colors.white.withAlpha(30),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        ShroudyColors.primaryRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ShroudyTvApp extends StatelessWidget {
  const ShroudyTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shroudy TV ios',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: ShroudyColors.darkNavyBg,
        primaryColor: ShroudyColors.primaryRed,
      ),
      home: const MainDashboard(),
    );
  }
}
class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  final List<ChannelItem> _allChannelsList = [];
  final List<String> _categoriesList = ['All'];
  final List<String> _favoritesList = [];

  String _selectedCategory = 'All';
  String _searchQuery = '';
  ChannelItem? _currentChannel;
  bool _isLoading = true;
  final Map<String, EpgData> _epgByChannel = {};
  Timer? _epgRefreshTimer;
  String? _playlistEpgUrl;

  // Playlist loading state. A failed or slow fetch used to leave the app on
  // the splash screen forever, so the request is now bounded by a timeout and
  // the failure is surfaced with a retry action.
  bool _loadingPlaylist = false;
  String? _playlistError;

  // EPG fetching state. A full guide sweep pulls tens of megabytes, so only one
  // sweep may be in flight at a time, and channels that no source can match are
  // retired instead of being retried every cycle.
  bool _epgRunning = false;
  final Set<String> _epgExhaustedKeys = {};

  // Boot splash timing: keep it on screen for at least _minBootDuration so the
  // animation plays out even when the playlist loads almost instantly.
  final DateTime _bootStart = DateTime.now();
  static const Duration _minBootDuration = Duration(milliseconds: 2200);

  // How long the on-screen boot animation is held for.
  static const Duration _epgRefreshInterval = Duration(minutes: 15);

  // Fullscreen state is owned HERE (not inside VideoCanvasPlayerLayer) so
  // that toggling it only changes the layout around the player. The player
  // widget itself is kept alive via _playerKey across the transition, which
  // prevents VLC from tearing down its native surface and re-buffering the
  // live stream.
  bool _isPlayerFullscreen = false;
  final GlobalKey _playerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _fetchM3uPlaylist();
    _epgRefreshTimer = Timer.periodic(_epgRefreshInterval, (_) => _fetchEpg());
  }

  // Waits out the remaining minimum boot time (if any), then reveals the UI.
  Future<void> _finishBoot() async {
    final remaining = _minBootDuration - DateTime.now().difference(_bootStart);
    if (remaining > Duration.zero) await Future.delayed(remaining);
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _fetchM3uPlaylist() async {
    if (_loadingPlaylist) return;
    setState(() {
      _loadingPlaylist = true;
      _playlistError = null;
    });
    try {
      final response = await http
          .get(Uri.parse(_playlistUrl))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw StateError(
          'Playlist request failed (HTTP ${response.statusCode}).',
        );
      }

      final parsed = _parsePlaylist(response.body);
      final prefs = await SharedPreferences.getInstance();

      if (!mounted) return;
      setState(() {
        _allChannelsList
          ..clear()
          ..addAll(parsed.channels);
        _categoriesList
          ..clear()
          ..add('All')
          ..addAll(parsed.categories);
        _playlistEpgUrl = parsed.epgUrl;
        _favoritesList
          ..clear()
          ..addAll(prefs.getStringList(_favoriteNamesPrefKey) ?? const []);
      });

      _fetchEpg();
      await _finishBoot();
    } catch (e) {
      debugPrint('Playlist error: $e');
      if (!mounted) return;
      setState(() => _playlistError = '$e');
      await _finishBoot();
    } finally {
      if (mounted) setState(() => _loadingPlaylist = false);
    }
  }

  // Pure: no widget state is touched here, so a re-parse cannot leave half
  // populated lists behind when the playlist changes shape between fetches.
  _ParsedPlaylist _parsePlaylist(String body) {
    final channels = <ChannelItem>[];
    final categoriesSet = <String>{};
    String? epgUrl;

    final lines = body.split('\n');

    // Use the EPG URL declared by the playlist header.
    for (final header in lines.take(10).map((l) => l.trim())) {
      if (header.toUpperCase().startsWith('#EXTM3U')) {
        final declaredEpg = _extractAttribute(header, 'x-tvg-url');
        if (declaredEpg.isNotEmpty) {
          epgUrl = declaredEpg;
          break;
        }
      }
    }

    String currentName = '';
    String currentLogo = '';
    String currentCategory = 'Uncategorized';
    String currentTvgId = '';

    for (final raw in lines) {
      final cleanLine = raw.trim().replaceAll('\r', '');
      if (cleanLine.isEmpty) continue;

      if (cleanLine.toUpperCase().startsWith('#EXTINF:')) {
        currentName = _extractAttribute(cleanLine, 'tvg-name');

        if (currentName.isEmpty) {
          final commaIndex = cleanLine.lastIndexOf(',');
          if (commaIndex >= 0) {
            currentName = cleanLine.substring(commaIndex + 1).trim();
          }
        }

        currentLogo = _extractAttribute(cleanLine, 'logo');
        currentCategory = _extractAttribute(cleanLine, 'group-title');
        currentTvgId = _extractAttribute(cleanLine, 'tvg-id');

        if (currentCategory.isEmpty) currentCategory = 'Uncategorized';
        categoriesSet.add(currentCategory);
      } else if (!cleanLine.startsWith('#')) {
        if (cleanLine.startsWith('http://') || cleanLine.startsWith('https://')) {
          channels.add(
            ChannelItem(
              name: currentName.isEmpty ? 'Unknown Channel' : currentName,
              logoUrl: currentLogo,
              streamUrl: cleanLine,
              category: currentCategory,
              tvgId: currentTvgId,
            ),
          );
          currentName = '';
          currentLogo = '';
          currentTvgId = '';
          currentCategory = 'Uncategorized';
        }
      }
    }

    final categories = categoriesSet.toList()..sort();
    return _ParsedPlaylist(channels: channels, categories: categories, epgUrl: epgUrl);
  }


  // EPG --------------------------------------------------------------------

  /// Guides to try, de-duplicated: the source declared by the playlist header
  /// first, then the public fallbacks. Ordered cheapest-first so the sparse
  /// guides cannot bury the comprehensive one — a later source's title wins
  /// when merging.
  ///
  /// `iptv-epg.org/files/epg-in.xml.gz` is deliberately excluded: every one of
  /// its 30,168 programmes is a `<title>No Data</title>` placeholder, so it only
  /// ever cost bandwidth and overwrote real titles.
  List<String> get _epgSourceUrls => <String>{
        if (_playlistEpgUrl != null && _playlistEpgUrl!.isNotEmpty) _playlistEpgUrl!,
        'https://epgshare01.online/epgshare01/epg_ripper_IN2.xml.gz',
        'https://epgshare01.online/epgshare01/epg_ripper_IN1.xml.gz',
      }.toList();

  /// Runs a guide sweep on a background isolate.
  ///
  /// The Indian guide alone expands to about 65 MB of XML. Fetching and
  /// regex-matching that on the platform thread stalled the whole UI once a
  /// minute and pushed iPad memory toward the jetsam limit, so the work now
  /// happens in `compute()` and only the small matched result crosses back.
  Future<void> _fetchEpg() async {
    if (_epgRunning || _allChannelsList.isEmpty) return;

    final pending = _allChannelsList
        .where((ch) => !_epgExhaustedKeys.contains(epgKeyFor(ch)))
        .toList();
    if (pending.isEmpty) return;

    _epgRunning = true;
    final request = _EpgRequest(
      urls: _epgSourceUrls,
      channels: pending
          .map((ch) => _EpgChannelQuery(name: ch.name, tvgId: ch.tvgId))
          .toList(),
    );

    try {
      final result = await compute(_runEpgSweep, request)
          .timeout(const Duration(minutes: 3));
      if (!mounted) return;
      setState(() {
        _epgByChannel.addAll(result.byChannel);
        // Channels no source could match are retired for the session instead of
        // being re-attempted by every later sweep.
        _epgExhaustedKeys.addAll(result.exhaustedKeys);
      });
      debugPrint(
        'EPG sweep: ${_epgByChannel.length}/${_allChannelsList.length} channels '
        'matched, ${_epgExhaustedKeys.length} retired',
      );
    } catch (e) {
      debugPrint('EPG sweep failed: $e');
    } finally {
      _epgRunning = false;
    }
  }


  @override
  void dispose() {
    _epgRefreshTimer?.cancel();
    super.dispose();
  }

  String _extractAttribute(String line, String attributeName) {
    final regExp = RegExp('$attributeName\\s*=\\s*"([^"]*)"', caseSensitive: false);
    return regExp.firstMatch(line)?.group(1)?.trim() ?? '';
  }

  Future<void> _toggleFavorite(String name) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_favoritesList.contains(name)) {
        _favoritesList.remove(name);
      } else {
        _favoritesList.add(name);
      }
    });
    await prefs.setStringList(_favoriteNamesPrefKey, _favoritesList);
  }

  void _setPlayerFullscreen(bool value) {
    if (_isPlayerFullscreen == value) return;
    setState(() => _isPlayerFullscreen = value);
    SystemChrome.setEnabledSystemUIMode(
      value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  // Leaves the player: runs an orderly, awaited native teardown (stop VLC, then
  // release the shared audio session) BEFORE the widget unmounts, so the iOS
  // main thread is never left tearing down a live audio session mid-frame.
  Future<void> _closePlayer() async {
    final playerState =
        _playerKey.currentState as _VideoCanvasPlayerLayerState?;
    await playerState?.shutdown();
    if (!mounted) return;
    _setPlayerFullscreen(false);
    setState(() => _currentChannel = null);
  }

  // Single widget instance reused by both the split view and the fullscreen
  // body. The stable GlobalKey is what lets Flutter reparent the Element
  // (and its underlying VLC platform view) between the two layouts without
  // destroying and recreating it.
  Widget _buildPlayer({required bool isFullscreen}) {
    final channel = _currentChannel;
    if (channel == null) return const SizedBox.shrink();
    return VideoCanvasPlayerLayer(
      key: _playerKey,
      streamUrl: channel.streamUrl,
      channelName: channel.name,
      isFavorited: _favoritesList.contains(channel.name),
      isFullscreen: isFullscreen,
      onFavToggle: () => _toggleFavorite(channel.name),
      onClose: _closePlayer,
      onFullscreenChanged: _setPlayerFullscreen,
      onPrevious: _playPreviousChannel,
      onNext: _playNextChannel,
    );
  }

  List<ChannelItem> _getFilteredChannels() {
    final query = _searchQuery.trim().toLowerCase();
    bool matchesSearch(ChannelItem ch) =>
        query.isEmpty || ch.name.toLowerCase().contains(query);

    // The Favorites tab stays scoped to favorites even while searching.
    if (_selectedCategory == '★ Favorites') {
      return _allChannelsList
          .where((ch) => _favoritesList.contains(ch.name) && matchesSearch(ch))
          .toList();
    }

    // A non-empty search is global: it spans every category, not just the
    // selected tab, so a channel is found no matter which category it lives in.
    if (query.isNotEmpty) {
      return _allChannelsList.where(matchesSearch).toList();
    }

    // No search: fall back to the selected category (or all).
    return _allChannelsList
        .where((ch) =>
            _selectedCategory == 'All' || ch.category == _selectedCategory)
        .toList();
  }

  // Switches to the previous/next channel within the list the user is
  // currently browsing, wrapping around at the ends. If the playing channel
  // is no longer in that filtered list, we fall back to the full channel list
  // so the buttons never dead-end.
  void _stepChannel(int delta) {
    final current = _currentChannel;
    if (current == null) return;

    var channels = _getFilteredChannels();
    var index = channels.indexWhere((ch) => ch.streamUrl == current.streamUrl);
    if (index == -1) {
      channels = _allChannelsList;
      index = channels.indexWhere((ch) => ch.streamUrl == current.streamUrl);
    }
    if (channels.isEmpty || index == -1) return;

    final nextIndex = (index + delta) % channels.length;
    setState(() => _currentChannel = channels[nextIndex]);
  }

  void _playPreviousChannel() => _stepChannel(-1);

  void _playNextChannel() => _stepChannel(1);

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const BootSplash();
    }

    final filteredChannels = _getFilteredChannels();

    Widget body;
    if (_playlistError != null && _allChannelsList.isEmpty) {
      body = _buildPlaylistFailureView();
    } else if (_currentChannel == null) {
      body = _buildStandardBrowsingHubView(filteredChannels);
    } else if (_isPlayerFullscreen) {
      // Same widget instance (same GlobalKey) as inside the split view, so
      // its Element — and the VLC platform view under it — is reparented
      // rather than recreated. That is what keeps the live stream playing
      // through the fullscreen transition.
      body = ColoredBox(
        color: Colors.black,
        child: _buildPlayer(isFullscreen: true),
      );
    } else {
      body = _buildPremiumSplitPlayerLayoutView(filteredChannels);
    }

    return PopScope(
      canPop: !_isPlayerFullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isPlayerFullscreen) {
          _setPlayerFullscreen(false);
        }
      },
      child: Scaffold(body: body),
    );
  }

  /// Shown when the playlist could not be loaded. Previously a failed request
  /// silently revealed an empty grid with no way back.
  Widget _buildPlaylistFailureView() {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, color: ShroudyColors.primaryRed, size: 54),
              const SizedBox(height: 18),
              const Text(
                'Channel list could not be loaded',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Check the iPad connection and try again.',
                style: TextStyle(color: Colors.white.withAlpha(170), fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              ElevatedButton.icon(
                onPressed: _loadingPlaylist ? null : _fetchM3uPlaylist,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ShroudyColors.primaryRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                ),
                icon: const Icon(Icons.refresh),
                label: Text(_loadingPlaylist ? 'Loading…' : 'Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStandardBrowsingHubView(List<ChannelItem> channels) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildCategoryAndSearchHeaderRow(),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 1.0,
              ),
              itemCount: channels.length,
              itemBuilder: (context, index) => _buildChannelItemCard(channels[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryAndSearchHeaderRow() {
    final finalCategories = [
      'All',
      if (_favoritesList.isNotEmpty) '★ Favorites',
      ..._categoriesList.sublist(1),
    ];

    return Container(
      padding: const EdgeInsets.only(top: 12, left: 16, right: 16, bottom: 12),
      child: Column(
        children: [
          SizedBox(
            height: 45,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: finalCategories.length,
              itemBuilder: (context, i) {
                final cat = finalCategories[i];
                final isSelected = cat == _selectedCategory;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(cat, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    selected: isSelected,
                    selectedColor: ShroudyColors.primaryRed,
                    backgroundColor: ShroudyColors.cardNavyBg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    onSelected: (val) => setState(() => _selectedCategory = cat),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (val) => setState(() => _searchQuery = val),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search channels...',
              hintStyle: const TextStyle(color: Colors.grey),
              fillColor: ShroudyColors.cardNavyBg,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelItemCard(ChannelItem channel) {
    return Card(
      color: ShroudyColors.cardNavyBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: InkWell(
        onTap: () => setState(() => _currentChannel = channel),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: ShroudyColors.innerLogoBg,
                  width: double.infinity,
                  child: _ChannelLogo(url: channel.logoUrl),
                ),
              ),
              const SizedBox(height: 6),
              Text(channel.name, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              const Text('● LIVE', style: TextStyle(color: ShroudyColors.liveIndicator, fontSize: 8, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildEpgPanel(ChannelItem channel) {
    final data = _epgByChannel[epgKeyFor(channel)];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(
            child: Text(
              'YOU ARE WATCHING',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 110,
              height: 76,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ShroudyColors.innerLogoBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ShroudyColors.accentBorder),
              ),
              child: channel.logoUrl.trim().isEmpty
                  ? const Icon(Icons.tv, color: Colors.white, size: 34)
                  : Image.network(
                      channel.logoUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.tv, color: Colors.white, size: 34),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              channel.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'PROGRAMME GUIDE',
            style: TextStyle(
              color: Color.fromARGB(255, 71, 24, 243),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),

          if (data?.now != null)
            _buildLiveNowCard(data!.now!, channel.logoUrl)
          else
            const Text(
              'No LIVE NOW programme found.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),

          const SizedBox(height: 16),

          if (data?.next != null) ...[
            const Text(
              'NEXT',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            _buildEpgProgrammeRow(data!.next!, channel.logoUrl),
          ],

          const SizedBox(height: 18),

          if (data?.upcoming.isNotEmpty == true) ...[
            const Text(
              'UPCOMING',
              style: TextStyle(
                color: Colors.lightBlueAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...data!.upcoming.skip(1).take(5).map(
              (program) => _buildEpgProgrammeRow(program, channel.logoUrl),
            ),
          ] else if (data != null) ...[
            const Text(
              'No additional upcoming programmes found.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],

          if (data == null) ...[
            const SizedBox(height: 10),
            const Text(
              'EPG is loading or this channel could not be matched.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveNowCard(EpgProgram program, String channelLogoUrl) {
    final imageUrl = (program.imageUrl?.trim().isNotEmpty == true)
        ? program.imageUrl!.trim()
        : channelLogoUrl.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ShroudyColors.innerLogoBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.greenAccent.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LIVE NOW',
            style: TextStyle(
              color: Color.fromARGB(255, 241, 59, 4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Container(
                width: double.infinity,
                height: 150,
                color: Colors.black,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Container(
                    color: Colors.black26,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.live_tv,
                      color: Colors.white54,
                      size: 34,
                    ),
                  ),
                ),
              ),
            )
          else
            Container(
              height: 130,
              width: double.infinity,
              color: Colors.black26,
              alignment: Alignment.center,
              child: const Icon(Icons.live_tv, color: Colors.white54, size: 34),
            ),
          const SizedBox(height: 9),
          Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${_formatEpgTime(program.start)} – ${_formatEpgTime(program.stop)}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          if (program.description.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              program.description.trim(),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEpgProgrammeRow(EpgProgram program, String channelLogoUrl) {
    final imageUrl = (program.imageUrl?.trim().isNotEmpty == true)
        ? program.imageUrl!.trim()
        : channelLogoUrl.trim();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: ShroudyColors.innerLogoBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                imageUrl,
                width: 72,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 72,
                  height: 48,
                  color: Colors.black26,
                  alignment: Alignment.center,
                  child: const Icon(Icons.tv, color: Colors.white54, size: 22),
                ),
              ),
            )
          else
            Container(
              width: 72,
              height: 48,
              color: Colors.black26,
              alignment: Alignment.center,
              child: const Icon(Icons.tv, color: Colors.white54, size: 22),
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  program.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatEpgTime(program.start)} – ${_formatEpgTime(program.stop)}',
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                ),
                if (program.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    program.description.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatEpgTime(DateTime value) {
    final local = value.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _buildPremiumSplitPlayerLayoutView(List<ChannelItem> channels) {
    final relatedChannels = _allChannelsList
        .where((ch) => ch.category == _currentChannel!.category && ch.name != _currentChannel!.name)
        .toList();

    return SafeArea(
      bottom: false,
      child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, left: 24, right: 24, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '📺  Shroudy TV',
                  style: const TextStyle(color: Color.fromARGB(255, 230, 189, 101), fontSize: 20, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: _closePlayer,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ShroudyColors.cardNavyBg,
                  side: const BorderSide(color: ShroudyColors.accentBorder, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text('← Back', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: Container(
                    color: Colors.black,
                    child: _buildPlayer(isFullscreen: false),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 1,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: const BoxDecoration(
                      color: ShroudyColors.cardNavyBg,
                      border: Border.fromBorderSide(
                        BorderSide(color: ShroudyColors.accentBorder),
                      ),
                    ),
                    child: _buildEpgPanel(_currentChannel!),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 24, top: 16, bottom: 8),
          child: Align(alignment: Alignment.centerLeft, child: Text('★ CHANNELS FROM SAME CATEGORY', style: TextStyle(color: Color.fromARGB(255, 248, 203, 1), fontSize: 13, fontWeight: FontWeight.bold))),
        ),
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 24, right: 24, bottom: 20),
            child: relatedChannels.isEmpty
                ? const Center(child: Text('No related channels in this category', style: TextStyle(color: Colors.grey, fontSize: 12)))
                : GridView.builder(
                    padding: const EdgeInsets.only(right: 0),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.15,
                    ),
                    itemCount: relatedChannels.length,
                    itemBuilder: (context, idx) {
                      final relChannel = relatedChannels[idx];
                      return Card(
                        color: ShroudyColors.cardNavyBg,
                        margin: EdgeInsets.zero,
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                        child: InkWell(
                          onTap: () => setState(() => _currentChannel = relChannel),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              children: [
                                Expanded(
                                  child: Container(
                                    color: ShroudyColors.innerLogoBg,
                                    width: double.infinity,
                                    child: _ChannelLogo(url: relChannel.logoUrl),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  relChannel.name,
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
      ),
    );
  }
}
class VideoCanvasPlayerLayer extends StatefulWidget {
  final String streamUrl;
  final String channelName;
  final bool isFavorited;
  final bool isFullscreen;

  final VoidCallback onFavToggle;
  final VoidCallback onClose;
  final ValueChanged<bool> onFullscreenChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const VideoCanvasPlayerLayer({
    super.key,
    required this.streamUrl,
    required this.channelName,
    required this.isFavorited,
    required this.isFullscreen,
    required this.onFavToggle,
    required this.onClose,
    required this.onFullscreenChanged,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  State<VideoCanvasPlayerLayer> createState() => _VideoCanvasPlayerLayerState();
}

class _VideoCanvasPlayerLayerState extends State<VideoCanvasPlayerLayer>
    with WidgetsBindingObserver {
  late VlcPlayerController _controller;

  bool _showControls = true;
  bool _isPlaying = false;
  // Set when the user pauses. On live streams VLC may ignore pause(), so this
  // is the source of truth for the button icon; _togglePlayPause force-stops the
  // stream if VLC is still playing shortly after a pause request.
  bool _userPaused = false;
  String? _errorText;

  // Buffering overlay state is kept separately from VLC's raw playback state.
  // Some live IPTV streams can leave VLC reporting opening/buffering even
  // after the video is usable, or can remain in that state indefinitely.
  // The watchdog prevents the spinner from becoming permanent.
  bool _showBuffering = true;
  Timer? _bufferingTimer;
  static const Duration _bufferingWatchdog = Duration(seconds: 12);

  VlcVideoFit _currentFit = VlcVideoFit.fill;
  String _selectedAspectRatio = _aspectFitToScreen;
  int? _selectedAudioTrackId;
  int? _selectedSubtitleTrackId;

  List<VlcTrackDescription> _audioTracks = [];
  List<VlcTrackDescription> _subtitleTracks = [];

  Timer? _controlsTimer;

  // Shared gesture state so the normal and fullscreen views stay in sync.
  // Volume drives the real iOS device volume (0..100) via
  // `flutter_volume_controller`. Brightness goes through `screen_brightness`;
  // on iOS that writes a screen-wide setting, so it is restored whenever the app
  // stops being visible — see didChangeAppLifecycleState.
  final ValueNotifier<int> _volumeNotifier = ValueNotifier<int>(100);
  final ValueNotifier<double> _brightnessNotifier = ValueNotifier<double>(1.0);
  StreamSubscription<double>? _volumeSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createController(widget.streamUrl);
    _showControlsTemporarily();
    _syncInitialBrightness();
    _syncInitialVolume();
    _restoreAspectRatio();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A dimmed screen survives the app being force-quit or crashing, because iOS
    // brightness is not scoped to one app. Hand the system value back as soon as
    // the player stops being visible, and re-read it on return.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(
        ScreenBrightness.instance
            .resetApplicationScreenBrightness()
            .catchError((Object e) => debugPrint('brightness restore on hide: $e')),
      );
    } else if (state == AppLifecycleState.resumed) {
      _syncInitialBrightness();
    }
  }

  /// The aspect ratio is a user preference, so it outlives the stream it was
  /// chosen for. Audio and subtitle track ids are per-media and are not kept.
  Future<void> _restoreAspectRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_aspectRatioPrefKey);
      if (saved == null || !mounted || saved == _selectedAspectRatio) return;
      setState(() {
        _selectedAspectRatio = saved;
        _currentFit = fitForAspectRatio(saved);
      });
    } catch (e) {
      debugPrint('Could not restore aspect ratio: $e');
    }
  }

  void _syncInitialVolume() {
    // Hide the native volume HUD so our own overlay indicator is the only one.
    FlutterVolumeController.updateShowSystemUI(false);
    // emitOnStart seeds the notifier with the device's current volume and then
    // keeps it in sync if the user changes volume with the physical buttons.
    _volumeSubscription = FlutterVolumeController.addListener(
      (volume) {
        if (!mounted) return;
        _volumeNotifier.value = (volume.clamp(0.0, 1.0) * 100).round();
      },
      emitOnStart: true,
    );
  }

  @override
  void didUpdateWidget(VideoCanvasPlayerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Channel switches used to be handled by giving the widget a
    // ValueKey(streamUrl), which recreated the State. Now that the parent
    // owns a stable GlobalKey across fullscreen transitions, we have to
    // detect the URL change ourselves and rebuild the controller in place.
    if (oldWidget.streamUrl == widget.streamUrl) return;
    unawaited(_switchToStream(widget.streamUrl));
  }

  Future<void> _switchToStream(String url) async {
    final outgoing = _controller;
    outgoing.removeListener(_playerListener);

    _tracksLoaded = false;
    _audioTracks = [];
    _subtitleTracks = [];
    _selectedAudioTrackId = null;
    _selectedSubtitleTrackId = null;
    _errorText = null;
    _bufferingTimer?.cancel();

    // The replacement is created first so the widget tree always has a live
    // controller to build against while the outgoing one winds down.
    _createController(url);
    _showControlsTemporarily();

    // Then stop the old player before releasing it, matching shutdown(): VLC and
    // the volume plugin share the single iOS AVAudioSession, and letting go of a
    // still-running player can block the platform thread.
    try {
      await outgoing.stop();
    } catch (e) {
      debugPrint('switch stop: $e');
    }
    outgoing.dispose();
  }

  Future<void> _syncInitialBrightness() async {
    try {
      final current = await ScreenBrightness.instance.application;
      if (!mounted) return;
      _brightnessNotifier.value = current.clamp(0.0, 1.0);
    } catch (e) {
      debugPrint('Could not read application brightness: $e');
    }
  }

  void _createController(String url) {
    _controller = VlcPlayerController(
      mediaSource: VlcMediaSource(
        uri: Uri.parse(url),
        mediaOptions: const [
          ':network-caching=1000',
          ':live-caching=1000',
          ':file-caching=1000',
          ':http-reconnect=true',
          ':clock-jitter=0',
          ':clock-synchro=0',
        ],
      ),
      autoPlay: true,
    );
    _controller.addListener(_playerListener);
    // Assigned directly rather than through setState: both call sites run inside
    // the frame that is about to rebuild this widget.
    _isPlaying = true;
    _userPaused = false;
    _showBuffering = true;
    _scheduleBufferingWatchdog();
  }

  void _scheduleBufferingWatchdog() {
    _bufferingTimer?.cancel();
    if (!_showBuffering || _userPaused || !mounted) return;
    _bufferingTimer = Timer(_bufferingWatchdog, () {
      if (!mounted) return;
      // If VLC has not reached a usable playing state after the watchdog
      // period, stop showing the endless spinner. VLC continues attempting
      // the stream in the background, so a later playing event can restore
      // normal state without changing the UI.
      if (!_controller.value.isPlaying && !_userPaused) {
        setState(() => _showBuffering = false);
      }
    });
  }

  void _stopBufferingIndicator() {
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    if (_showBuffering && mounted) {
      setState(() => _showBuffering = false);
    }
  }

  void _playerListener() {
    if (!mounted) return;

    final value = _controller.value;
    final playing = value.isPlaying;

    // isPlaying is the important signal here. A number of live IPTV inputs
    // keep VLC's state at buffering/opening even though frames are already
    // being rendered. Never keep the spinner over a stream that VLC reports
    // as actually playing.
    final loadingState = value.state == VlcPlaybackState.opening ||
        value.state == VlcPlaybackState.buffering;
    if (playing || !loadingState || _userPaused) {
      _stopBufferingIndicator();
    } else if (!_showBuffering) {
      _showBuffering = true;
      _scheduleBufferingWatchdog();
      setState(() {});
    }

    // Surface real VLC failures. The player used to read an `errorMessage`
    // extension that always returned null, so a dead stream showed a black
    // screen with no explanation.
    final errorText = value.hasError
        ? (value.errorDescription ?? value.error?.code ?? 'Playback failed')
        : null;
    if (errorText != _errorText) {
      setState(() => _errorText = errorText);
    }

    // Do not call setState on every VLC update unless something actually
    // changed. Excess rebuilds can interfere with native player controls.
    if (_isPlaying != playing) {
      _isPlaying = playing;
      setState(() {});
    }

    _loadTracksOnce();
  }

  bool _tracksLoaded = false;
  bool _tracksLoadInFlight = false;

  Future<void> _loadTracksOnce() async {
    // Guarded because the player listener fires on every VLC update: without it
    // each event started another retry loop against the native track query.
    if (_tracksLoaded || _tracksLoadInFlight || !mounted) return;
    _tracksLoadInFlight = true;

    try {
      // Native VLC can expose tracks a little after playback starts. Retry a few
      // times instead of permanently leaving the settings dialog empty.
      for (int attempt = 0; attempt < 5 && mounted; attempt++) {
        try {
          final aud = await _controller.getAudioTracks();
          final sub = await _controller.getSubtitleTracks();

          if (aud.isNotEmpty || sub.isNotEmpty) {
            _tracksLoaded = true;
            if (mounted) {
              setState(() {
                _audioTracks = aud;
                _subtitleTracks = sub;
              });
            }
            return;
          }
        } catch (e) {
          debugPrint('Track query attempt ${attempt + 1}: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('Media tracks are not ready yet: $e');
    } finally {
      _tracksLoadInFlight = false;
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    // Skip the setState when controls are already visible so a drag start
    // doesn't rebuild the whole player Stack for nothing.
    if (!_showControls) setState(() => _showControls = true);
    _scheduleControlsHide();
  }

  Future<void> _togglePlayPause() async {
    _showControlsTemporarily();
    final value = _controller.value;
    // Want to pause unless we already consider it paused (user-paused, or VLC
    // itself reports a paused/stopped/ended/idle state).
    final wantPause = !(_userPaused || _isPausedState(value.state));
    try {
      if (wantPause) {
        // Flip the UI immediately so the button feels responsive even before
        // the native state event arrives.
        setState(() {
          _userPaused = true;
          _showBuffering = false;
        });
        _bufferingTimer?.cancel();
        await _controller.pause();
        // Live IPTV inputs frequently ignore pause() (canPause == false), so the
        // picture keeps running. Verify shortly after: if VLC is still active,
        // force stop(), which reliably freezes a live stream. play() re-opens it
        // at the live edge on resume.
        Future.delayed(const Duration(milliseconds: 600), () async {
          if (!mounted || !_userPaused) return;
          if (!_isPausedState(_controller.value.state)) {
            await _controller.stop();
          }
        });
      } else {
        setState(() {
          _userPaused = false;
          _showBuffering = true;
        });
        _scheduleBufferingWatchdog();
        await _controller.play();
      }
    } catch (e) {
      debugPrint('VLC play/pause error: $e');
    }
  }

  // True only for states where playback is NOT active, i.e. tapping should
  // resume. opening/buffering/playing all count as "active" so we pause them.
  static bool _isPausedState(VlcPlaybackState state) {
    return state == VlcPlaybackState.paused ||
        state == VlcPlaybackState.stopped ||
        state == VlcPlaybackState.ended ||
        state == VlcPlaybackState.idle;
  }

  void _toggleFullscreen() {
    _showControlsTemporarily();
    // Fullscreen ownership lives in _MainDashboardState so the VlcPlayer
    // widget is never unmounted across the transition (which would tear
    // down the platform view and force VLC to re-buffer the live stream).
    widget.onFullscreenChanged(!widget.isFullscreen);
  }

  Future<void> _openPlayerSettingsDialog() async {
    await _loadTracksOnce();
    if (!mounted) return;

    String tempAspect = _selectedAspectRatio;
    int? tempAudio = _selectedAudioTrackId;
    int? tempSubtitle = _selectedSubtitleTrackId;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF071B32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: const Row(
                children: [
                  Icon(Icons.settings, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Text(
                    'Player Settings',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDropdownRow(
                    label: 'Aspect Ratio:',
                    value: tempAspect,
                    items: const [_aspectFitToScreen, _aspect16x9, _aspect4x3],
                    onChanged: (val) => setDialogState(() => tempAspect = val!),
                  ),
                  const SizedBox(height: 12),
                  _buildDropdownRow(
                    label: 'Audio Track:',
                    value: tempAudio ?? -1,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('Default', style: TextStyle(color: Colors.white)),
                      ),
                      ..._audioTracks.map(
                        (t) => DropdownMenuItem(
                          value: t.id,
                          child: Text(t.name, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setDialogState(() => tempAudio = val == -1 ? null : val as int?),
                    isCustomItems: true,
                  ),
                  const SizedBox(height: 12),
                  _buildDropdownRow(
                    label: 'Subtitles:',
                    value: tempSubtitle ?? -1,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('None', style: TextStyle(color: Colors.white)),
                      ),
                      ..._subtitleTracks.map(
                        (t) => DropdownMenuItem(
                          value: t.id,
                          child: Text(t.name, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setDialogState(() => tempSubtitle = val == -1 ? null : val as int?),
                    isCustomItems: true,
                  ),
                ],
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      await _applySettings(tempAspect, tempAudio, tempSubtitle);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                    child: const Text(
                      'Apply & Save',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDropdownRow({
    required String label,
    required dynamic value,
    required List<dynamic> items,
    required ValueChanged<dynamic> onChanged,
    bool isCustomItems = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF040F1E),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24),
          ),
          width: 140,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<dynamic>(
              isExpanded: true,
              value: value,
              dropdownColor: const Color(0xFF040F1E),
              icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
              onChanged: onChanged,
              items: isCustomItems
                  ? items.cast<DropdownMenuItem<dynamic>>()
                  : items
                      .map(
                        (item) => DropdownMenuItem<dynamic>(
                          value: item,
                          child: Text(
                            item.toString(),
                            style: const TextStyle(color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _applySettings(String aspect, int? audioId, int? subtitleId) async {
    final newFit = fitForAspectRatio(aspect);

    if (mounted) {
      setState(() {
        _selectedAspectRatio = aspect;
        _selectedAudioTrackId = audioId;
        _selectedSubtitleTrackId = subtitleId;
        _currentFit = newFit;
      });
    }

    // The button offers to save, so the preference has to survive the next
    // channel switch. Track ids are media-specific and are deliberately not
    // persisted.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_aspectRatioPrefKey, aspect);
    } catch (e) {
      debugPrint('Could not save aspect ratio: $e');
    }

    try {
      // Apply the selected audio track. null means leave the current track alone.
      if (audioId != null) {
        await _controller.setAudioTrack(audioId);
      }

      // Selecting "None" must actually disable subtitles.
      if (subtitleId == null) {
        await _controller.disableSubtitle();
      } else {
        await _controller.setSubtitleTrack(subtitleId);
      }
    } catch (e) {
      debugPrint('Track selection error: $e');
    }

    _showControlsTemporarily();
  }

  // True once shutdown() has torn down the native audio/VLC resources. dispose()
  // checks this so it does not repeat (and race) the same native calls.
  bool _shutDown = false;

  // Orderly teardown, awaited BEFORE the widget is unmounted. VLC and
  // flutter_volume_controller share the single iOS AVAudioSession; the volume
  // plugin's onCancel calls setActive(false), which deadlocks the main thread
  // if VLC's audio unit is still running. So we stop VLC first (releasing the
  // session), await it, and only then cancel the volume listener.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    _controlsTimer?.cancel();
    _controlsTimer = null;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    try {
      await _controller.stop();
    } catch (e) {
      debugPrint('shutdown stop: $e');
    }
    await _volumeSubscription?.cancel();
    _volumeSubscription = null;
    FlutterVolumeController.removeListener();
    try {
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (e) {
      debugPrint('shutdown updateShowSystemUI: $e');
    }
    try {
      await ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (e) {
      debugPrint('shutdown resetBrightness: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlsTimer?.cancel();
    _bufferingTimer?.cancel();
    if (!_shutDown) {
      // Fallback for the rare path where the widget is removed without an
      // awaited shutdown(). Stop VLC before touching the shared audio session
      // so the volume plugin's setActive(false) never races a live audio unit.
      unawaited(_controller.stop().catchError(
        (Object e) => debugPrint('dispose stop: $e'),
      ));
      _volumeSubscription?.cancel();
      FlutterVolumeController.removeListener();
      FlutterVolumeController.updateShowSystemUI(true);
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (Object e) => debugPrint('resetApplicationScreenBrightness: $e'),
      );
    }
    _volumeNotifier.dispose();
    _brightnessNotifier.dispose();
    _controller.removeListener(_playerListener);
    _controller.dispose();
    super.dispose();
  }

  Widget _buildVideoWidget(VlcVideoFit fit) {
    final player = VlcPlayer(
      controller: _controller,
      backgroundColor: Colors.black,
      fit: fit,
    );

    switch (_selectedAspectRatio) {
      case _aspect16x9:
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRect(child: player),
          ),
        );
      case _aspect4x3:
        return Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRect(child: player),
          ),
        );
      default:
        return Positioned.fill(child: player);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // VLC video. The selected aspect ratio changes the actual widget
        // bounds instead of merely cropping the source.
        _buildVideoWidget(_currentFit),

        // Left/right vertical drag: brightness / volume.
        _VideoGestureLayer(
          volumeNotifier: _volumeNotifier,
          brightnessNotifier: _brightnessNotifier,
          onActivity: _showControlsTemporarily,
        ),

        // Transparent touch layer ABOVE the video. This is deliberate:
        // touching anywhere on the video immediately reveals controls.
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _showControlsTemporarily(),
            child: const SizedBox.expand(),
          ),
        ),

        if (_errorText != null)
          Positioned.fill(
            child: Container(
              color: Colors.black.withAlpha(200),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: ShroudyColors.primaryRed, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    'This channel stopped responding.\n$_errorText',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_switchToStream(widget.streamUrl)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: ShroudyColors.accentBorder, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                    ),
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    label: const Text(
                      'Retry',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (_showControls)
          Positioned.fill(
            child: Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: IgnorePointer(
                            child: Text(
                              widget.channelName,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(blurRadius: 5, color: Colors.black),
                                  Shadow(blurRadius: 10, color: Colors.black),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Top-right back button: exits fullscreen. Only shown
                        // in fullscreen, where there is no other chrome to
                        // leave with (the split view has its own Back button).
                        if (widget.isFullscreen)
                          _playerIconButton(
                            icon: Icons.arrow_back,
                            tooltip: 'Exit Fullscreen',
                            onPressed: () => widget.onFullscreenChanged(false),
                          ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      // LEFT: previous / play-pause / next
                      _playerIconButton(
                        icon: Icons.skip_previous,
                        tooltip: 'Previous Channel',
                        onPressed: widget.onPrevious,
                      ),
                      // Icon reflects the user's pause intent first (so it flips
                      // instantly), falling back to VLC's reported state.
                      ValueListenableBuilder<VlcPlayerValue>(
                        valueListenable: _controller,
                        builder: (context, value, _) {
                          final paused = _userPaused || _isPausedState(value.state);
                          return _playerIconButton(
                            icon: paused ? Icons.play_arrow : Icons.pause,
                            tooltip: paused ? 'Play' : 'Pause',
                            onPressed: _togglePlayPause,
                          );
                        },
                      ),
                      _playerIconButton(
                        icon: Icons.skip_next,
                        tooltip: 'Next Channel',
                        onPressed: widget.onNext,
                      ),

                      const Spacer(),

                      // MIDDLE: favorite
                      _playerIconButton(
                        icon: widget.isFavorited ? Icons.star : Icons.star_border,
                        tooltip: 'Favorite',
                        iconColor: widget.isFavorited ? ShroudyColors.goldText : Colors.white,
                        onPressed: widget.onFavToggle,
                      ),

                      const Spacer(),

                      // RIGHT: settings / fullscreen
                      _playerIconButton(
                        icon: Icons.settings,
                        tooltip: 'Player Settings',
                        onPressed: _openPlayerSettingsDialog,
                      ),
                      _playerIconButton(
                        icon: widget.isFullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        tooltip: widget.isFullscreen
                            ? 'Exit Fullscreen'
                            : 'Fullscreen',
                        onPressed: _toggleFullscreen,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _playerIconButton({
    required IconData icon,
    required String tooltip,
    required FutureOr<void> Function() onPressed,
    Color iconColor = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () async {
            _showControlsTemporarily();
            await onPressed();
          },
          child: Tooltip(
            message: tooltip,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(120),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 25),
            ),
          ),
        ),
      ),
    );
  }
}

enum _GestureSide { volume, brightness }

/// Transparent overlay that turns vertical drags on the left half of the
/// video into brightness changes (via the `screen_brightness` plugin, which
/// is app-scoped so it does not touch the system-wide setting) and vertical
/// drags on the right half into device volume changes.
class _VideoGestureLayer extends StatefulWidget {
  final ValueNotifier<int> volumeNotifier;
  final ValueNotifier<double> brightnessNotifier;
  // Called on gesture activity so the parent can reveal its own controls and
  // keep both the indicators and the player chrome on the same hide schedule.
  final VoidCallback onActivity;

  const _VideoGestureLayer({
    required this.volumeNotifier,
    required this.brightnessNotifier,
    required this.onActivity,
  });

  @override
  State<_VideoGestureLayer> createState() => _VideoGestureLayerState();
}

class _VideoGestureLayerState extends State<_VideoGestureLayer> {
  static const double _minBrightness = 0.02;
  static const double _dragRangePx = 220.0;

  _GestureSide? _activeSide;
  double _startY = 0;
  double _startValue = 0;
  bool _showIndicator = false;
  Timer? _hideTimer;

  // In-flight guards: at most one native call per stream is pending, and
  // the latest requested value is replayed once the current call resolves.
  // Prevents 60+ queued platform-channel calls during a fast drag while
  // still guaranteeing the final finger position is applied.
  bool _volumeCallInFlight = false;
  int? _pendingVolume;
  bool _brightnessCallInFlight = false;
  double? _pendingBrightness;

  void _onStart(DragStartDetails d, _GestureSide side) {
    _hideTimer?.cancel();
    widget.onActivity();
    final sideChanged = _activeSide != side;
    _activeSide = side;
    _startY = d.globalPosition.dy;
    _startValue = side == _GestureSide.volume
        ? widget.volumeNotifier.value / 100.0
        : widget.brightnessNotifier.value;
    // Always rebuild when the side changes so the indicator flips to the
    // correct edge even if the previous drag's hide timer hadn't fired yet.
    if (sideChanged || !_showIndicator) {
      setState(() => _showIndicator = true);
    }
  }

  void _onUpdate(DragUpdateDetails d, _GestureSide side) {
    if (_activeSide != side) return;
    // Dragging up increases the value; dragging down decreases it.
    final delta = (_startY - d.globalPosition.dy) / _dragRangePx;

    // Notifier is updated on EVERY value change so the on-screen indicator
    // tracks the finger 1:1. Only the native call is throttled (via the
    // in-flight guard below) — decoupling the two is what keeps the visual
    // smooth even when the platform channel is slow.
    if (side == _GestureSide.volume) {
      final next = ((_startValue + delta) * 100).round().clamp(0, 100);
      if (next != widget.volumeNotifier.value) {
        widget.volumeNotifier.value = next;
        _requestVolume(next);
      }
    } else {
      final next = (_startValue + delta).clamp(_minBrightness, 1.0);
      if (next != widget.brightnessNotifier.value) {
        widget.brightnessNotifier.value = next;
        _requestBrightness(next);
      }
    }

    _hideTimer?.cancel();
    widget.onActivity();
    if (!_showIndicator) setState(() => _showIndicator = true);
  }

  void _requestVolume(int v) {
    if (_volumeCallInFlight) {
      _pendingVolume = v;
      return;
    }
    _volumeCallInFlight = true;
    // Drive the real iOS device volume (0.0..1.0) instead of VLC's internal
    // volume, so the gesture matches the hardware buttons and the system mixer.
    FlutterVolumeController.setVolume((v / 100).clamp(0.0, 1.0)).then(
      (_) {
        _volumeCallInFlight = false;
        final pending = _pendingVolume;
        _pendingVolume = null;
        if (pending != null && pending != v && mounted) _requestVolume(pending);
      },
      onError: (Object e) {
        debugPrint('Device setVolume error: $e');
        _volumeCallInFlight = false;
        _pendingVolume = null;
      },
    );
  }

  void _requestBrightness(double b) {
    if (_brightnessCallInFlight) {
      _pendingBrightness = b;
      return;
    }
    _brightnessCallInFlight = true;
    ScreenBrightness.instance.setApplicationScreenBrightness(b).then(
      (_) {
        _brightnessCallInFlight = false;
        final pending = _pendingBrightness;
        _pendingBrightness = null;
        if (pending != null && pending != b && mounted) {
          _requestBrightness(pending);
        }
      },
      onError: (Object e) {
        debugPrint('setApplicationScreenBrightness error: $e');
        _brightnessCallInFlight = false;
        _pendingBrightness = null;
      },
    );
  }

  void _onEnd(DragEndDetails d, _GestureSide side) {
    _hideTimer?.cancel();
    // Match the player chrome's 4s auto-hide so the brightness/volume
    // indicator disappears together with the other controls instead of
    // vanishing on its own shorter timer.
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _activeSide = null;
        _showIndicator = false;
      });
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) => _onStart(d, _GestureSide.brightness),
                onVerticalDragUpdate: (d) => _onUpdate(d, _GestureSide.brightness),
                onVerticalDragEnd: (d) => _onEnd(d, _GestureSide.brightness),
                onVerticalDragCancel: () {
                  if (_activeSide == _GestureSide.brightness) {
                    _onEnd(DragEndDetails(), _GestureSide.brightness);
                  }
                },
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) => _onStart(d, _GestureSide.volume),
                onVerticalDragUpdate: (d) => _onUpdate(d, _GestureSide.volume),
                onVerticalDragEnd: (d) => _onEnd(d, _GestureSide.volume),
                onVerticalDragCancel: () {
                  if (_activeSide == _GestureSide.volume) {
                    _onEnd(DragEndDetails(), _GestureSide.volume);
                  }
                },
              ),
            ),
          ],
        ),
        if (_showIndicator && _activeSide != null)
          IgnorePointer(
            child: Align(
              alignment: _activeSide == _GestureSide.volume
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                // ValueListenableBuilder keeps the indicator reactive during
                // the drag without rebuilding the whole gesture layer.
                child: _activeSide == _GestureSide.volume
                    ? ValueListenableBuilder<int>(
                        valueListenable: widget.volumeNotifier,
                        builder: (_, v, _) => _indicatorBody(
                          icon: v == 0
                              ? Icons.volume_off
                              : (v < 50 ? Icons.volume_down : Icons.volume_up),
                          fraction: (v / 100.0).clamp(0.0, 1.0),
                          label: '$v%',
                        ),
                      )
                    : ValueListenableBuilder<double>(
                        valueListenable: widget.brightnessNotifier,
                        builder: (_, b, _) => _indicatorBody(
                          icon: Icons.brightness_6,
                          fraction: ((b - _minBrightness) /
                                  (1.0 - _minBrightness))
                              .clamp(0.0, 1.0),
                          label: '${(b * 100).round()}%',
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _indicatorBody({
    required IconData icon,
    required double fraction,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(170),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 26),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            width: 6,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: fraction,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// EPG fetching and matching.
//
// Everything in this section runs inside `compute()`, i.e. on a background
// isolate. That imposes two rules: the types passed in and out must be plain
// data (no closures, no widget or platform-view references), and the helpers
// must be top-level functions rather than `State` methods.
// -----------------------------------------------------------------------------

class _EpgChannelQuery {
  final String name;
  final String tvgId;

  const _EpgChannelQuery({required this.name, required this.tvgId});

  String get key => tvgId.trim().isNotEmpty ? tvgId.trim() : name;
}

class _EpgRequest {
  final List<String> urls;
  final List<_EpgChannelQuery> channels;

  const _EpgRequest({required this.urls, required this.channels});
}

class _EpgResult {
  final Map<String, EpgData> byChannel;
  final Set<String> exhaustedKeys;

  const _EpgResult({required this.byChannel, required this.exhaustedKeys});
}

/// Download every guide, parse it, and merge whatever matches the playlist.
Future<_EpgResult> _runEpgSweep(_EpgRequest request) async {
  final merged = <String, EpgData>{};
  final matchedThisSweep = <String>{};

  for (final url in request.urls) {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('EPG source HTTP ${response.statusCode}: $url');
        continue;
      }

      final xml = _decodeGuide(response.bodyBytes);
      final programmes = _parseGuideProgrammes(xml);
      final byName = _indexGuideByName(xml, programmes);

      for (final channel in request.channels) {
        final matched =
            _matchChannelProgrammes(channel, programmes, byName);
        if (matched == null || matched.isEmpty) continue;

        final data = buildEpgData(matched);
        if (!hasUsefulEpgData(data)) continue;

        matchedThisSweep.add(channel.key);
        final previous = merged[channel.key];
        merged[channel.key] = previous == null ? data : mergeEpgData(previous, data);
      }

      debugPrint(
        'EPG source parsed: ${programmes.length} XMLTV IDs, '
        '${merged.length} matched channels from $url',
      );

      // Release the parsed guide before the next source is decoded, so the
      // isolate holds one multi-megabyte tree at a time rather than all of them.
      programmes.clear();
      byName.clear();
    } catch (e) {
      debugPrint('EPG source failed $url: $e');
    }
  }

  final exhausted = <String>{
    for (final channel in request.channels)
      if (!matchedThisSweep.contains(channel.key)) channel.key,
  };

  return _EpgResult(byChannel: merged, exhaustedKeys: exhausted);
}

/// Guides are served gzipped, but a mirror can fall back to plain XML.
String _decodeGuide(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    return utf8.decode(gzip.decode(bytes), allowMalformed: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Map<String, List<EpgProgram>> _parseGuideProgrammes(String xml) {
  final programmes = <String, List<EpgProgram>>{};

  // Match programme elements regardless of attribute ordering and support both
  // single- and double-quoted XML attributes.
  final programmeRegex = RegExp(
    r'''<programme\b([^>]*)>(.*?)</programme\s*>''',
    caseSensitive: false,
    dotAll: true,
  );

  for (final m in programmeRegex.allMatches(xml)) {
    final attrs = m.group(1)!;
    final body = m.group(2)!;

    final channelId = _attrValue(_channelIdAttr, attrs);
    final startRaw = _attrValue(_startAttr, attrs);
    final stopRaw = _attrValue(_stopAttr, attrs);

    if (channelId == null || channelId.isEmpty || startRaw == null || stopRaw == null) {
      continue;
    }

    final start = parseXmltvDate(startRaw);
    final stop = parseXmltvDate(stopRaw);
    if (start == null || stop == null || !stop.isAfter(start)) continue;

    // Prefer the English XMLTV title when the provider supplies one; otherwise
    // retain the provider's first title.
    final title = englishXmlText(body, 'title');
    if (title.isEmpty || _isPlaceholderTitle(title)) continue;

    (programmes[channelId] ??= []).add(
      EpgProgram(
        start: start,
        stop: stop,
        title: title,
        description: _usableDescription(englishXmlText(body, 'desc')),
        imageUrl: xmlIconUrl(body),
      ),
    );
  }

  return programmes;
}

/// Some guides fill unfilled slots with a placeholder entry instead of omitting
/// it. iptv-epg.org alone publishes thousands of `<title>No Data</title>`
/// blocks, and because that source is merged last it overwrites the real titles
/// already collected from other providers.
bool _isPlaceholderTitle(String title) {
  const placeholders = {
    '', 'nodata', 'noinfo', 'noinformation', 'unknown', 'na', 'none', 'tbd',
    'notavailable', 'programme', 'epg',
  };
  final normalised = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  return placeholders.contains(normalised);
}

/// Placeholder descriptions are a bare link back to the provider's help page.
String _usableDescription(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('http') && !trimmed.contains(' ')) return '';
  if (_isPlaceholderTitle(trimmed)) return '';
  return trimmed;
}

/// Normalised display-name index, because most playlist entries carry no
/// `tvg-id` that matches the guide's channel ids.
Map<String, List<EpgProgram>> _indexGuideByName(
  String xml,
  Map<String, List<EpgProgram>> programmes,
) {
  final channelRegex = RegExp(
    r'''<channel\b[^>]*\bid\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</channel\s*>''',
    caseSensitive: false,
    dotAll: true,
  );
  final displayRegex = RegExp(
    r'''<display-name\b[^>]*>(.*?)</display-name\s*>''',
    caseSensitive: false,
    dotAll: true,
  );

  final byName = <String, List<EpgProgram>>{};

  for (final m in channelRegex.allMatches(xml)) {
    final id = (m.group(2) ?? '').trim();
    final body = m.group(3) ?? '';
    if (id.isEmpty || !programmes.containsKey(id)) continue;

    final dm = displayRegex.firstMatch(body);
    if (dm == null) continue;

    final display = decodeXmlText(_stripTags(dm.group(1) ?? ''));
    final key = epgNameKey(display);
    if (key.isNotEmpty) {
      (byName[key] ??= <EpgProgram>[]).addAll(programmes[id]!);
    }
  }

  return byName;
}

List<EpgProgram>? _matchChannelProgrammes(
  _EpgChannelQuery channel,
  Map<String, List<EpgProgram>> programmes,
  Map<String, List<EpgProgram>> byName,
) {
  List<EpgProgram>? matched;

  // 1. Exact tvg-id match, then a case-insensitive retry.
  final id = channel.tvgId.trim();
  if (id.isNotEmpty) {
    matched = programmes[id];
    if (matched == null) {
      for (final entry in programmes.entries) {
        if (entry.key.toLowerCase() == id.toLowerCase()) {
          matched = entry.value;
          break;
        }
      }
    }
  }

  // 2. Exact normalised channel-name match.
  final channelKey = epgNameKey(channel.name);
  matched ??= byName[channelKey];

  // 3. Fuzzy normalised-name match for provider naming differences.
  if (matched == null && channelKey.isNotEmpty) {
    int bestScore = 0;
    for (final entry in byName.entries) {
      final epgKey = entry.key;
      int score;

      if (epgKey == channelKey) {
        score = 100;
      } else if (epgKey.contains(channelKey) || channelKey.contains(epgKey)) {
        score = 80;
      } else {
        final overlap =
            epgTokens(channelKey).intersection(epgTokens(epgKey)).length;
        score = overlap >= 2 ? 50 + overlap : 0;
      }

      if (score > bestScore) {
        bestScore = score;
        matched = entry.value;
      }
    }
  }

  return matched;
}

EpgData buildEpgData(List<EpgProgram> source) {
  if (source.isEmpty) return const EpgData();

  final sorted = List<EpgProgram>.from(source)
    ..sort((a, b) => a.start.compareTo(b.start));

  final now = DateTime.now();
  EpgProgram? current;
  final future = <EpgProgram>[];

  for (final program in sorted) {
    if (!program.start.isAfter(now) && program.stop.isAfter(now)) {
      current ??= program;
    } else if (program.start.isAfter(now)) {
      future.add(program);
    }
  }

  return EpgData(
    now: current,
    next: future.isNotEmpty ? future.first : null,
    upcoming: future.take(6).toList(),
  );
}

bool hasUsefulEpgData(EpgData data) =>
    data.now != null || data.next != null || data.upcoming.isNotEmpty;

EpgProgram? mergeEpgProgram(EpgProgram? preferred, EpgProgram? fallback) {
  if (preferred == null) return fallback;
  if (fallback == null) return preferred;
  return EpgProgram(
    start: preferred.start,
    stop: preferred.stop,
    title: preferred.title,
    description: preferred.description.isNotEmpty
        ? preferred.description
        : fallback.description,
    imageUrl: preferred.imageUrl?.isNotEmpty == true
        ? preferred.imageUrl
        : fallback.imageUrl,
  );
}

EpgData mergeEpgData(EpgData oldData, EpgData newData) {
  final allUpcoming = <String, EpgProgram>{
    for (final p in [...oldData.upcoming, ...newData.upcoming])
      '${p.start.millisecondsSinceEpoch}|${p.stop.millisecondsSinceEpoch}|${p.title}': p,
  };

  final upcoming = allUpcoming.values.toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  return EpgData(
    now: mergeEpgProgram(newData.now, oldData.now),
    next: mergeEpgProgram(newData.next, oldData.next),
    upcoming: upcoming.take(6).toList(),
  );
}

/// Normalises provider/channel naming differences so the same channel still
/// matches when the M3U and XMLTV labels disagree.
String epgNameKey(String value) {
  var v = value.toLowerCase().trim().replaceAll('&amp;', '&');
  v = v.replaceAll(RegExp(r'\bsony entertainment television\b'), 'set');
  v = v.replaceAll(RegExp(r'\bsony hd\b'), 'set hd');
  v = v.replaceAll(RegExp(r'\bfull hd\b'), ' ');
  v = v.replaceAll(RegExp(r'\bhigh definition\b'), ' ');
  v = v.replaceAll(RegExp(r'\b(\d+\s*)?(hd|sd)\b'), ' ');
  v = v.replaceAll(RegExp(r'\b(india|indian|tv channel|channel)\b'), ' ');
  v = v.replaceAll(RegExp(r'\s+'), ' ').trim();

  return v.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

Set<String> epgTokens(String value) {
  const ignored = {
    'tv', 'television', 'channel', 'india', 'hd', 'sd',
    'english', 'hindi', 'live', 'network',
  };

  return value
      .split(RegExp(r'[^a-z0-9]+'))
      .where((e) => e.length >= 2 && !ignored.contains(e))
      .toSet();
}

DateTime? parseXmltvDate(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  try {
    return DateTime.parse(value).toLocal();
  } catch (_) {}

  // XMLTV commonly uses: yyyyMMddHHmmss +0000 / yyyyMMddHHmmss -0500
  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?$',
  ).firstMatch(value);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final sign = match.group(7);

  if (sign == null) {
    return DateTime(year, month, day, hour, minute, second);
  }

  final offset = Duration(
    hours: int.tryParse(match.group(8) ?? '0') ?? 0,
    minutes: int.tryParse(match.group(9) ?? '0') ?? 0,
  );
  final utc = DateTime.utc(year, month, day, hour, minute, second);
  return (sign == '+') ? utc.subtract(offset).toLocal() : utc.add(offset).toLocal();
}

String decodeXmlText(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.tryParse(m.group(1)!) ?? 32),
      );
}

String _stripTags(String value) => value.replaceAll(RegExp(r'<[^>]*>'), '').trim();

String _cleanEpgText(String value) => decodeXmlText(_stripTags(value));

/// Returns the English text of [tag] when the provider marks one up, otherwise
/// the first non-empty value.
String englishXmlText(String body, String tag) {
  final matches = RegExp(
    '<$tag\\b([^>]*)>(.*?)</$tag\\s*>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(body);

  String? firstText;
  for (final match in matches) {
    final attrs = match.group(1) ?? '';
    final text = _cleanEpgText(match.group(2) ?? '');
    if (text.isEmpty) continue;
    firstText ??= text;

    final lang = (_attrValue(_langAttr, attrs) ?? '').toLowerCase();
    if (lang == 'en' ||
        lang.startsWith('en-') ||
        lang.startsWith('en_') ||
        lang == 'eng' ||
        lang == 'english') {
      return text;
    }
  }
  return firstText ?? '';
}

String? xmlIconUrl(String body) {
  final match = RegExp(
    r'''<icon\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1''',
    caseSensitive: false,
  ).firstMatch(body);
  final value = (match?.group(2) ?? '').trim();
  return value.isEmpty ? null : decodeXmlText(value);
}

// Pre-compiled attribute patterns: the 65 MB guides contain tens of thousands
// of elements, so building these per element would dominate the parse time.
RegExp _attrPattern(String name) =>
    RegExp('''\\b$name\\s*=\\s*(?:"([^"]*)"|'([^']*)')''');

final RegExp _channelIdAttr = _attrPattern('channel');
final RegExp _startAttr = _attrPattern('start');
final RegExp _stopAttr = _attrPattern('stop');
final RegExp _langAttr = _attrPattern('lang');

String? _attrValue(RegExp pattern, String text) {
  final m = pattern.firstMatch(text);
  if (m == null) return null;
  return (m.group(1) ?? m.group(2) ?? '').trim();
}
