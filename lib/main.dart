import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Forces iPad landscape multi-panes to scale smoothly
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp
  ]);
  runApp(const ShroudyTvApp());
}

// 🎨 Premium Theme Color Palettes mapped precisely from your previous builds
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

  ChannelItem({required this.name, required this.logoUrl, required this.streamUrl, required this.category});
}

class ShroudyTvApp extends StatelessWidget {
  const ShroudyTvApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shroudy TV iPad',
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

  @override
  void initState() {
    super.initState();
    _fetchM3uPlaylist();
  }

  // 📥 Asynchronous Background M3U Playlist Parser Engine
  Future<void> _fetchM3uPlaylist() async {
    try {
      final response = await http.get(Uri.parse(
          "https://raw.githubusercontent.com/shroudybuoy/TV-Channels/refs/heads/main/channel%20playlist.m3u"));
      
      if (response.statusCode == 200) {
        final lines = response.body.split('\n');
        String currentName = '';
        String currentLogo = '';
        String currentCategory = 'Uncategorized';

        final categoriesSet = <String>{};

        for (var line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;

          if (trimmed.toUpperCase().startsWith('#EXTINF:')) {
            currentName = _extractAttribute(trimmed, 'tvg-name');
            if (currentName.isEmpty) {
              final commaIndex = trimmed.lastIndexOf(',');
              if (commaIndex >= 0) currentName = trimmed.substring(commaIndex + 1).trim();
            }
            currentLogo = _extractAttribute(trimmed, 'logo');
            currentCategory = _extractAttribute(trimmed, 'group-title');
            if (currentCategory.isEmpty) currentCategory = 'Uncategorized';
            categoriesSet.add(currentCategory);
          } else if (!trimmed.startsWith('#')) {
            if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
              _allChannelsList.add(ChannelItem(
                name: currentName.isEmpty ? "Unknown Channel" : currentName,
                logoUrl: currentLogo,
                streamUrl: trimmed,
                category: currentCategory,
              ));
              currentName = '';
              currentLogo = '';
            }
          }
        }
        
        final prefs = await SharedPreferences.getInstance();
        final savedFavs = prefs.getStringList('favorite_names') ?? [];

        setState(() {
          _favoritesList.addAll(savedFavs);
          _categoriesList.addAll(categoriesSet.toList()..sort());
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  String _extractAttribute(String line, String attributeName) {
    final regExp = RegExp('$attributeName\\s*=\\s*"([^"]*)"', caseSensitive: false);
    final match = regExp.firstMatch(line);
    return match?.group(1)?.trim() ?? '';
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
    await prefs.setStringList('favorite_names', _favoritesList);
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: ShroudyColors.primaryRed)),
      );
    }

    // Filters matching Windows/Android logic perfectly
    final filteredChannels = _allChannelsList.where((ch) {
      final matchesSearch = ch.name.toLowerCase().contains(_searchQuery.toLowerCase());
      if (_selectedCategory == '★ Favorites') {
        return _favoritesList.contains(ch.name) && matchesSearch;
      }
      final matchesCat = _selectedCategory == 'All' || ch.category == _selectedCategory;
      return matchesCat && matchesSearch;
    }).toList();

    return Scaffold(
      body: isLandscape && _currentChannel != null
          ? _buildImmersiveLandscapePlayer()
          : _buildStandardTwoPaneLayout(filteredChannels),
    );
  }

  // 📱 Optimized Two-Pane Dashboard Grid Layout (YouTube/iPad Native Style)
  Widget _buildStandardTwoPaneLayout(List<ChannelItem> channels) {
    return Column(
      children: [
        if (_currentChannel != null) _buildEmbeddedPortraitPlayerView(),
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
            itemBuilder: (context, index) {
              final channel = channels[index];
              return _buildChannelItemCard(channel);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryAndSearchHeaderRow() {
    final finalCategories = ['All', if (_favoritesList.isNotEmpty) '★ Favorites'] + 
        _categoriesList.sublist(1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              hintText: "Search channels...",
              hintStyle: const TextStyle(color: Colors.grey),
              fillColor: ShroudyColors.cardNavyBg,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildChannelItemCard(ChannelItem channel) {
    return Card(
      color: ShroudyColors.cardNavyBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      child: InkWell(
        onTap: () => setState(() => _currentChannel = channel),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: ShroudyColors.innerLogoBg,
                  width: double.infinity,
                  child: Image.network(channel.logoUrl, fit: BoxFit.contain, 
                    errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 6),
              Text(channel.name, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              const Text("● LIVE", style: TextStyle(color: ShroudyColors.liveIndicator, fontSize: 8, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmbeddedPortraitPlayerView() {
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: 240,
      child: VideoCanvasPlayerLayer(
        key: ValueKey(_currentChannel!.streamUrl),
        streamUrl: _currentChannel!.streamUrl,
        channelName: _currentChannel!.name,
        isFavorited: _favoritesList.contains(_currentChannel!.name),
        onFavToggle: () => _toggleFavorite(_currentChannel!.name),
        onClose: () => setState(() => _currentChannel = null),
      ),
    );
  }

  Widget _buildImmersiveLandscapePlayer() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: VideoCanvasPlayerLayer(
        key: ValueKey(_currentChannel!.streamUrl),
        streamUrl: _currentChannel!.streamUrl,
        channelName: _currentChannel!.name,
        isFavorited: _favoritesList.contains(_currentChannel!.name),
        onFavToggle: () => _toggleFavorite(_currentChannel!.name),
        onClose: () => setState(() => _currentChannel = null),
      ),
    );
  }
}

// ============================================================
// HARDWARE-ACCELERATED VIDEO PLAYER CANVAS LAYER
// ============================================================
class VideoCanvasPlayerLayer extends StatefulWidget {
  final String streamUrl;
  final String channelName;
  final bool isFavorited;
  final VoidCallback onFavToggle;
  final VoidCallback onClose;

  const VideoCanvasPlayerLayer({
    super.key, 
    required this.streamUrl, 
    required this.channelName, 
    required this.isFavorited, 
    required this.onFavToggle, 
    required this.onClose
  });

  @override
  State<VideoCanvasPlayerLayer> createState() => _VideoCanvasPlayerLayerState();
}

class _VideoCanvasPlayerLayerState extends State<VideoCanvasPlayerLayer> {
  late VideoPlayerController _controller;
  bool _showControls = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  void _initializePlayer() {
    // FIX: Forces custom HTTP header routing parameters so servers cannot block your iPad app
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.streamUrl),
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
      httpHeaders: {
        // Masks your iPad application requests to match an official desktop VLC/Mozilla browser engine layout
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 VLC/3.0.16',
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
    );

    _controller.initialize().then((_) {
      if (mounted) {
        setState(() => _hasError = false);
        _controller.play();
      }
    }).catchError((error) {
      // Catches and logs connection timeouts gracefully
      if (mounted) {
        setState(() => _hasError = true);
      }
    });

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        children: [
          Positioned.fill(
            child: _hasError
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, color: ShroudyColors.primaryRed, size: 42),
                        SizedBox(height: 8),
                        Text("Stream Unavailable", style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
                        Text("Server timeout or invalid link protocol", style: TextStyle(color: Colors.grey, fontSize: 11)),
                      ],
                    ),
                  )
                : _controller.value.isInitialized
                    ? FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(
                          width: _controller.value.size.width,
                          height: _controller.value.size.height,
                          child: VideoPlayer(_controller),
                        ),
                      )
                    : const Center(child: CircularProgressIndicator(color: ShroudyColors.primaryRed)),
          ),
          if (_showControls && !_hasError)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent, Colors.black87],
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white), 
                          onPressed: widget.onClose
                        ),
                        Text(
                          widget.channelName, 
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)
                        ),
                        IconButton(
                          icon: Icon(
                            widget.isFavorited ? Icons.star : Icons.star_border, 
                            color: widget.isFavorited ? ShroudyColors.goldText : Colors.white
                          ), 
                          onPressed: widget.onFavToggle
                        ),
                      ],
                    ),
                    IconButton(
                      icon: Icon(
                        _controller.value.isPlaying ? Icons.pause : Icons.play_arrow, 
                        color: Colors.white, 
                        size: 48
                      ),
                      onPressed: () => setState(() => _controller.value.isPlaying ? _controller.pause() : _controller.play()),
                    ),
                    const SizedBox(height: 20)
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
