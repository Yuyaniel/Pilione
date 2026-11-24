import 'dart:async';

import 'package:media_kit/media_kit.dart'
    show NativePlayer, PlayerState, VideoParams;
import 'package:material_ui/material_ui.dart';

/// 播放信息浮层
///
/// 与对话框不同，它常驻在画面上（Overlay），只有再次点击控件
/// 或点击浮层本身才会关闭，便于持续观察码率变化。
abstract final class PlayerInfoOverlay {
  static OverlayEntry? _entry;

  static bool get isShowing => _entry != null;

  static void toggle(BuildContext context, {required NativePlayer player}) {
    if (_entry != null) {
      hide();
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (context) => _PlayerInfoLayer(
        player: player,
        onTap: hide,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void hide() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    // entry 可能已随 overlay 一起被移除，重复 remove 会触发断言
    if (entry.mounted) entry.remove();
  }
}

class _PlayerInfoLayer extends StatelessWidget {
  const _PlayerInfoLayer({required this.player, required this.onTap});

  final NativePlayer player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: GestureDetector(
            onTap: onTap,
            child: _PlayerInfoBox(player: player),
          ),
        ),
      ),
    );
  }
}

class _PlayerInfoBox extends StatefulWidget {
  const _PlayerInfoBox({required this.player});

  final NativePlayer player;

  @override
  State<_PlayerInfoBox> createState() => _PlayerInfoBoxState();
}

class _PlayerInfoBoxState extends State<_PlayerInfoBox> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 码率是实时值，每秒刷新
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      // 播放器已释放（切画质重建播放器时可能出现），本帧先不渲染，
      // 页面 dispose 时会调用 PlayerInfoOverlay.hide()
      return const SizedBox.shrink();
    }
    final params = state.videoParams;
    final video = state.track.video;

    final width = params.w ?? video.w;
    final height = params.h ?? video.h;
    final fps = video.fps;

    final lines = <String>[
      if (width != null && height != null && width > 0 && height > 0)
        '分辨率: ${width}x$height'
      else
        '分辨率: -',
      '帧率: ${fps == null ? '-' : fps.toStringAsFixed(1)}',
      '视频码率: ${_formatBitrate(player)}',
      'HDR: ${_formatHdr(params)}',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                line,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.4,
                  shadows: [
                    Shadow(blurRadius: 2, color: Colors.black54),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 判断当前流的 HDR 类型，只给三种结果：HDR10 / HLG / SDR。
///
/// 只看传递函数（mpv `video-params/gamma`），因为它是唯一有决定权的字段：
/// `pq`（SMPTE ST 2084）是 HDR10 的亮度曲线，`hlg` 是广播 HDR，其余
/// （`bt.1886`、`srgb`）都是 SDR。原色 bt.2020 单独出现不算 HDR —— 4K SDR
/// 也常标它，所以不参与判定，也不显示出来，免得每次都要对照含义。
String _formatHdr(VideoParams params) {
  final gamma = (params.gamma ?? '').toLowerCase();
  if (gamma.contains('pq') || gamma.contains('smpte2084')) return 'HDR10';
  if (gamma.contains('hlg') || gamma.contains('arib-std-b67')) return 'HLG';
  return 'SDR';
}

/// 实时视频码率，mpv 的 `video-bitrate` 单位为 bit/s
String _formatBitrate(NativePlayer player) {
  final String raw;
  try {
    raw = player.getProperty('video-bitrate');
  } catch (_) {
    // 播放器已释放时读取原生属性会抛异常
    return '-';
  }
  final bps = double.tryParse(raw);
  if (bps == null || bps <= 0) return '-';
  if (bps >= 1000 * 1000) {
    return '${(bps / 1000 / 1000).toStringAsFixed(2)} Mbps';
  }
  return '${(bps / 1000).toStringAsFixed(0)} kbps';
}
