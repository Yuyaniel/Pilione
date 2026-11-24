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

/// 判断并描述当前流的 HDR 类型。
///
/// mpv 的 `video-params` 里三件事共同决定 HDR：
/// - `gamma`（传递函数）：`pq` 是 HDR10 / Dolby Vision 的基础，
///   `hlg` 是广播 HDR，其余（`bt.1886`、`srgb`）都是 SDR；
/// - `primaries`（原色坐标）：`bt.2020` 是宽色域，HDR 常见，但 4K SDR
///   也可能标它，所以单独出现不能算 HDR；
/// - `sig-peak`（信号峰值）：>1 表示亮度超过 SDR 的 100 nit 参考白。
///
/// 只有传递函数是 `pq`/`hlg` 才认定为 HDR；否则输出 SDR，并在括号里带上
/// 原色与传递函数，方便对照排查偏色问题。
String _formatHdr(VideoParams params) {
  final gamma = (params.gamma ?? '').toLowerCase();
  final primaries = (params.primaries ?? '').toLowerCase();
  final peak = params.sigPeak;
  final peakText =
      peak == null || peak <= 0 ? null : '${peak.toStringAsFixed(1)}x';

  final bool isHdr;
  final String kind;
  if (gamma.contains('pq') || gamma.contains('smpte2084')) {
    isHdr = true;
    // bt.2020 + PQ 且峰值远超 1 的，通常是 HDR10 母版；带杜比视界的流
    // mpv 会在 primaries 里保留 bt.2020，这里不额外区分，避免误判。
    kind = primaries.contains('2020') ? 'HDR10' : 'HDR(PQ)';
  } else if (gamma.contains('hlg') || gamma.contains('arib-std-b67')) {
    isHdr = true;
    kind = 'HLG';
  } else {
    isHdr = false;
    kind = 'SDR';
  }

  if (!isHdr) {
    if (primaries.isEmpty && gamma.isEmpty) return 'SDR';
    return 'SDR(${_shortName(primaries)}/${_shortName(gamma)})';
  }
  final parts = <String>[kind];
  if (peakText != null) parts.add(peakText);
  if (primaries.isNotEmpty) parts.add(_shortName(primaries));
  return parts.join(' ');
}

/// 把 mpv 的 bt.2020ncl / smpte2084 之类压成短名，避免撑爆浮层宽度
String _shortName(String raw) {
  if (raw.isEmpty) return '-';
  return switch (raw) {
    'bt.2020ncl' || 'bt.2020nc' || 'bt.2020' => 'bt2020',
    'bt.709' => 'bt709',
    'smpte2084' => 'PQ',
    'arib-std-b67' => 'HLG',
    'bt.1886' => '1886',
    _ => raw,
  };
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
