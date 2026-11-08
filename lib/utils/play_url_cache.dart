import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// playurl 短时缓存
///
/// 同一个视频（cid + 画质 + 语言 + 账号态）在几分钟内再次取流时直接复用上一次的
/// 结果，省掉「B 站 playurl 往返 + 远端解析」这一整段等待。典型场景：
/// - 返回上一页再进来、重复点同一个视频；
/// - 缓存命中时不再消耗远端解析次数。
///
/// 语义是**一次消费**（[take] 取出即删）：缓存里放的是可变的 [PlayUrlModel]，
/// 播放页会往里写 `lastPlayTime` / 合并轨道，多个页面同时持有同一个实例会互相
/// 污染，所以只交给一个调用方。
abstract final class PlayUrlCache {
  /// 播放地址有效期一般 2 小时，这里只做「短时」缓存，避免拿到过期地址
  static const Duration ttl = Duration(minutes: 5);
  static const int _maxEntries = 6;

  /// 插入顺序即淘汰顺序（LinkedHashMap 语义）
  static final Map<String, _Entry> _cache = <String, _Entry>{};

  static String key({
    required int cid,
    int? avid,
    String? bvid,
    dynamic epid,
    dynamic seasonId,
    required int qn,
    String? language,
    required bool tryLook,
    required String videoType,
    required bool voiceBalance,
    required bool fallback,
  }) {
    return [
      videoType,
      avid ?? '',
      bvid ?? '',
      cid,
      epid ?? '',
      seasonId ?? '',
      qn,
      language ?? '',
      tryLook ? 1 : 0,
      voiceBalance ? 1 : 0,
      fallback ? 1 : 0,
      // 播放地址带账号鉴权，切账号后必须视为不同 key
      Pref.userInfoCache?.mid ?? 0,
    ].join('|');
  }

  /// 取出并删除；过期或不存在返回 null
  static PlayUrlModel? take(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > ttl) return null;
    return entry.data;
  }

  static void put(String key, PlayUrlModel data) {
    if (!Pref.enablePlayUrlCache) return;
    _cache.remove(key);
    _cache[key] = _Entry(data, DateTime.now());
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  static bool contains(String key) => _cache.containsKey(key);

  static void clear() => _cache.clear();
}

class _Entry {
  _Entry(this.data, this.at);

  final PlayUrlModel data;
  final DateTime at;
}
