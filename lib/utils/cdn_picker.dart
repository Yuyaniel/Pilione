import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';

/// CDN 择优 + 记忆
///
/// B 站给同一个分片会同时下发 `baseUrl` 与若干 `backupUrl`（不同 CDN 主机），
/// `VideoUtils.getCdnUrl` 只按设置里的 `CDNService` 静态改写主机，不测速。
///
/// 这里只在**这些候选地址里挑**：
/// 1. 播放开始后，对候选主机各发一个 1KB 的 Range 请求，记录 RTT；
/// 2. 记住最快的主机；
/// 3. 下一次取流（换画质 / 下一集 / 重进）时优先用它。
///
/// 绝不凭空拼地址；探测在后台跑，不阻塞起播。
abstract final class CdnPicker {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 3),
      validateStatus: (_) => true,
      headers: {
        'user-agent': BrowserUa.pc,
        'referer': 'https://www.bilibili.com/',
        'origin': 'https://www.bilibili.com',
      },
    ),
  );

  /// host -> 实测 RTT（ms），越小越快
  static final Map<String, int> _rtt = <String, int>{};

  static String? _bestHost;
  static String? _lastProbedPath;
  static bool _probing = false;

  /// 当前记住的最快主机（设置页展示 / 调试用）
  static String? get bestHost => _bestHost;

  /// 在 [urls] 里挑一个地址：命中记忆里的最快主机就用它，否则走原来的逻辑。
  static String pick(Iterable<String> urls, {bool isAudio = false}) {
    final list = urls.where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return '';
    final fallback = VideoUtils.getCdnUrl(list, isAudio: isAudio);
    if (!Pref.enableCdnMemory) return fallback;

    final best = _bestHost;
    if (best == null) return fallback;

    for (final url in list) {
      // 逐个套用原有的 CDNService 改写，保证选出的地址与「正常路径」同构
      final rewritten = VideoUtils.getCdnUrl([url], isAudio: isAudio);
      if (Uri.tryParse(rewritten)?.host == best) return rewritten;
    }
    return fallback;
  }

  /// 后台探速（同一个资源只探一次）
  static void probe(Iterable<String> urls, {bool isAudio = false}) {
    if (!Pref.enableCdnMemory) return;
    final list = urls.where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return;

    final path = Uri.tryParse(list.first)?.path;
    if (path == null || path == _lastProbedPath || _probing) return;
    _lastProbedPath = path;
    _probing = true;
    unawaited(
      _run(list, isAudio).whenComplete(() {
        _probing = false;
      }),
    );
  }

  static Future<void> _run(List<String> urls, bool isAudio) async {
    final hostToUrl = <String, String>{};
    for (final url in urls.take(4)) {
      final rewritten = VideoUtils.getCdnUrl([url], isAudio: isAudio);
      final host = Uri.tryParse(rewritten)?.host;
      if (host == null || hostToUrl.containsKey(host)) continue;
      hostToUrl[host] = rewritten;
    }
    // 只有一台主机就没有择优的意义
    if (hostToUrl.length < 2) return;

    final results = await Future.wait(
      hostToUrl.entries.map((e) async {
        final sw = Stopwatch()..start();
        try {
          final res = await _dio.get<dynamic>(
            e.value,
            options: Options(
              responseType: ResponseType.stream,
              headers: const {'range': 'bytes=0-1023'},
            ),
          );
          if (res.data case final ResponseBody body) {
            await body.stream.listen(null).cancel();
          }
          sw.stop();
          final code = res.statusCode ?? 0;
          if (code >= 200 && code < 400) {
            return MapEntry(e.key, sw.elapsedMilliseconds);
          }
        } catch (_) {}
        return const MapEntry<String, int>('', -1);
      }),
    );

    for (final r in results) {
      if (r.value >= 0) _rtt[r.key] = r.value;
    }
    if (_rtt.isEmpty) return;
    _bestHost = _rtt.entries
        .reduce((a, b) => a.value <= b.value ? a : b)
        .key;
  }

  static void reset() {
    _rtt.clear();
    _bestHost = null;
    _lastProbedPath = null;
  }
}
