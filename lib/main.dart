import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Force iPad configurations to stay flexible for widescreen interfaces
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
          final cleanLine = trimmed.replaceAll('\r', ''); // Clears invisible carriage returns
          if (cleanLine.isEmpty) continue;

          if (cleanLine.toUpperCase().startsWith('#EXTINF:')) {
            currentName = _extractAttribute(cleanLine, 'tvg-name');
            if (currentName.isEmpty) {
              final commaIndex = cleanLine.lastIndexOf(',');
              if (commaIndex >= 0) currentName = cleanLine.substring(commaIndex + 1).trim();
            }
            currentLogo = _extractAttribute(cleanLine, 'logo');
            currentCategory = _extractAttribute(cleanLine, 'group-title');
            if (currentCategory.isEmpty) currentCategory = 'Uncategorized';
            categoriesSet.add(currentCategory);
          } else if (!cleanLine.startsWith('#')) {
            if (cleanLine.startsWith('http://') || cleanLine.startsWith('https://')) {
              _allChannelsList.add(ChannelItem(
                name: currentName.isEmpty ? "Unknown Channel" : currentName,
                logoUrl: currentLogo,
                streamUrl: cleanLine,
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
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: ShroudyColors.primaryRed)),
      );
    }

    final filteredChannels = _allChannelsList.where((ch) {
      final matchesSearch = ch.name.toLowerCase().contains(_searchQuery.toLowerCase());
      if (_selectedCategory == '★ Favorites') {
        return _favoritesList.contains(ch.name) && matchesSearch;
      }
      final matchesCat = _selectedCategory == 'All' || ch.category == _selectedCategory;
      return matchesCat && matchesSearch;
    }).toList();

    return Scaffold(
      body: _currentChannel != null
          ? _buildPremiumSplitPlayerLayoutView(filteredChannels)
          : _buildStandardBrowsingHubView(filteredChannels),
    );
  }

  // 🗂️ View 1: Standard Channel Browsing Hub Grid Matrix
  Widget _buildStandardBrowsingHubView(List<ChannelItem> channels) {
    return Column(
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
            itemBuilder: (context, index) {
              return _buildChannelItemCard(channels[index]);
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
      padding: const EdgeInsets.only(top: 40, left: 16, right: 16, bottom: 12),
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
                    errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white)),
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
  // 📺 View 2: Premium Desktop-Style Split View Player & Information Dashboard
  Widget _buildPremiumSplitPlayerLayoutView(List<ChannelItem> channels) {
    final relatedChannels = _allChannelsList
        .where((ch) => ch.category == _currentChannel!.category && ch.name != _currentChannel!.name)
        .toList();

    return Column(
      children: [
        // Upper Top Row Bar: Title and Custom Back Navigation Button
        Padding(
          padding: const EdgeInsets.only(top: 40, left: 24, right: 24, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  "NOW PLAYING: ${_currentChannel!.name.toUpperCase()}",
                  style: const TextStyle(color: ShroudyColors.primaryRed, fontSize: 20, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => setState(() => _currentChannel = null),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ShroudyColors.cardNavyBg,
                  side: const BorderSide(color: ShroudyColors.accentBorder, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text("← Back", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              )
            ],
          ),
        ),

        // Middle Splitting Core: Live Canvas (Left Pane) & Metadata / EPG (Right Pane)
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // LEFT STACK CANVASES: Video Player Viewport Container Box
                Expanded(
                  flex: 2,
                  child: Container(
                    color: Colors.black,
                    child: VideoCanvasPlayerLayer(
                      key: ValueKey(_currentChannel!.streamUrl),
                      streamUrl: _currentChannel!.streamUrl,
                      channelName: _currentChannel!.name,
                      isFavorited: _favoritesList.contains(_currentChannel!.name),
                      onFavToggle: () => _toggleFavorite(_currentChannel!.name),
                      onClose: () => setState(() => _currentChannel = null),
                    ),
                  ),
                ),
                const SizedBox(width: 24),

                // RIGHT STACK PANELS: Information Roster Core Matching the Desktop UI Screen
                Expanded(
                  flex: 1,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: const BoxDecoration(
                      color: ShroudyColors.cardNavyBg,
                      border: BorderBorder(color: ShroudyColors.accentBorder, width: 1),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("YOU ARE WATCHING", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 16),
                          const Text("CATEGORY", style: TextStyle(color: ShroudyColors.goldText, fontSize: 13, fontWeight: FontWeight.bold)),
                          Text(_currentChannel!.category, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: ShroudyColors.primaryRed, borderRadius: BorderRadius.circular(4)),
                            child: const Text("• LIVE", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 24),
                          const Text("EPG • PROGRAMME GUIDE", style: TextStyle(color: ShroudyColors.primaryRed, fontSize: 11, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          const Text("NOW • EPG not available", style: TextStyle(color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 12),
                          const Text("No programme information is available for this channel.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 20),
                          const Text("NEXT • ———", style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          const Text("UPCOMING PROGRAMMES", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                )
              ],
            ),
          ),
        ),

        // Bottom Grid Section: Related Channels Category Carousel Row Matrix
        const Padding(
          padding: EdgeInsets.only(left: 24, top: 16, bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text("★ CHANNELS FROM SAME CATEGORY", style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ),

        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 24, right: 24, bottom: 20),
            child: relatedChannels.isEmpty
                ? const Center(child: Text("No related channels in this category", style: TextStyle(color: Colors.grey, fontSize: 12)))
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: relatedChannels.length,
                    itemBuilder: (context, idx) {
                      final relChannel = relatedChannels[idx];
                      return Container(
                        width: 140,
                        margin: const EdgeInsets.only(right: 12),
                        child: Card(
                          color: ShroudyColors.cardNavyBg,
                          shape: const RoundedCornerShape(0),
                          child: InkWell(
                            onTap: () => setState(() => _currentChannel = relChannel),
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Container(
                                      color: ShroudyColors.innerLogoBg,
                                      width: double.infinity,
                                      child: Image.network(relChannel.logoUrl, fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white)),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(relChannel.name, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        )
      ],
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

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.streamUrl))
      ..initialize().then((_) => setState(() {}))
      ..play();
    
    // Auto-hide controls overlay sheet after 4 seconds of inactivity
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
          // Forces the streaming video display window to fill 100% of the viewport canvas frame
          Positioned.fill(
            child: _controller.value.isInitialized
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
          if (_showControls)
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

// Custom rigid desktop-style flat boarder component
class BorderBorder extends Border {
  const BorderBorder({required BorderSide color, double width = 1.0}) 
      : super(top: color, bottom: color, left: color, right: color);
}
