// Wbi签名 用于生成 REST API 请求中的 w_rid 和 wts 字段
// https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md
// import md5 from 'md5'
// import axios from 'axios'
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

abstract final class WbiSign {
  static Box get _localCache => GStorage.localCache;
  static final RegExp _chrFilter = RegExp(r"[!\'\(\)\*]");
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  static Future<String>? _future;

  /// 拉取失败后的冷却截止时间。
  ///
  /// [_fetchWbiKeys] 失败时会把 [_future] 置空，好让下次调用重新拉取；
  /// 但首页一次加载会并发好几个 [makSign]，若网络或风控导致 userInfo 一直失败，
  /// 每个请求都会各自发一次 userInfo 并等满 receiveTimeout，首屏就被拖住
  /// 十几秒甚至更久（表现为「卡在第一屏」）。失败后先冷却一段时间，
  /// 期间直接用缓存 key 或空串快速返回。
  static const Duration _retryGap = Duration(seconds: 60);
  static DateTime? _retryAfter;

  /// [_future] 属于哪一天：跨天时只重建一次，避免并发请求各拉一次 key。
  static DateTime? _futureDay;

  // 对 imgKey 和 subKey 进行字符顺序打乱编码
  static String getMixinKey(String orig) {
    return String.fromCharCodes(_mixinKeyEncTab.map(orig.codeUnitAt));
  }

  // 为请求参数进行 wbi 签名
  static void encWbi(Map<String, Object> params, String mixinKey) {
    params['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 按照 key 重排参数
    final List<String> keys = params.keys.toList()..sort();
    final queryStr = keys
        .map(
          (i) =>
              '${Uri.encodeComponent(i)}=${Uri.encodeComponent(params[i].toString().replaceAll(_chrFilter, ''))}',
        )
        .join('&');
    params['w_rid'] = md5
        .convert(utf8.encode(queryStr + mixinKey))
        .toString(); // 计算 w_rid
  }

  static String? get _cachedMixinKey {
    final cached = _localCache.get(LocalCacheKey.mixinKey);
    // 历史版本可能把空串写进缓存，判空后当作没有缓存
    return cached is String && cached.isNotEmpty ? cached : null;
  }

  static Future<String> _getWbiKeys() async {
    // 兜底超时：Request 自身是 connect 10s + receive 10s，风控或网络异常时
    // 一次拉取能拖到 20s，首页并发几个签名请求就会把首屏一起拖住
    final resp = await Request()
        .get(Api.userInfo)
        .timeout(const Duration(seconds: 5));
    final wbiUrls = resp.data['data']['wbi_img'];

    final mixinKey = getMixinKey(
      Utils.getFileName(wbiUrls['img_url'], fileExt: false) +
          Utils.getFileName(wbiUrls['sub_url'], fileExt: false),
    );
    // 解析不到 key 时直接抛：空 mixinKey 会让 w_rid 静默算错，
    // 上层只看到 -352 之类的风控错误，查不出根因
    if (mixinKey.isEmpty) {
      throw const FormatException('wbi_img 解析为空');
    }

    await _localCache.put(LocalCacheKey.mixinKey, mixinKey);

    return mixinKey;
  }

  /// 拉取 wbi key；失败时清空 [_future]，避免失败结果被永久缓存。
  ///
  /// 原来直接 `_future ??= _getWbiKeys()`，一旦某次拉取失败，空串会一直缓存
  /// 到进程结束，之后全项目 38 处 [makSign] 都用空 mixinKey 签名，请求集体挂。
  /// 这里保持「不抛异常」的既有契约（调用方都不做 try/catch）：
  /// 有旧 key 就继续用，没有才返回空串，但下次调用一定会重新拉取。
  static Future<String> _fetchWbiKeys() async {
    try {
      final key = await _getWbiKeys();
      _retryAfter = null;
      return key;
    } catch (_) {
      _future = null;
      // 失败后短暂冷却：并发调用不再各自重发 userInfo
      _retryAfter = DateTime.now().add(_retryGap);
      return _cachedMixinKey ?? '';
    }
  }

  static FutureOr<String> getWbiKeys() {
    final nowDate = DateTime.now();
    final cachedDate = DateTime.fromMillisecondsSinceEpoch(
      _localCache.get(LocalCacheKey.timeStamp, defaultValue: 0) as int,
    );
    // 原来只比 `.day`，10/19 与 11/19 会被当成同一天，跨月后继续用旧 key
    final sameDay =
        cachedDate.year == nowDate.year &&
        cachedDate.month == nowDate.month &&
        cachedDate.day == nowDate.day;
    // 刚失败过：直接给出缓存（或空串），不再发请求，避免首页并发请求
    // 各自等满一次超时，把首屏拖成「白屏」
    final retryAfter = _retryAfter;
    if (retryAfter != null && nowDate.isBefore(retryAfter)) {
      return _cachedMixinKey ?? '';
    }
    if (sameDay) {
      final mixinKey = _cachedMixinKey;
      if (mixinKey != null) return mixinKey;
      return _future ??= _fetchWbiKeys();
    }
    // 跨天了，昨天的 key 不能再用。只在「[_future] 不是今天建的」时才重建，
    // 这样首页并发多个签名请求只有第一个真的去拉，其余复用同一个 future
    // （原来直接 `_future = ...`，每个并发请求都会各发一次 userInfo）
    final futureDay = _futureDay;
    final futureIsToday =
        futureDay != null &&
        futureDay.year == nowDate.year &&
        futureDay.month == nowDate.month &&
        futureDay.day == nowDate.day;
    if (_future == null || !futureIsToday) {
      _futureDay = nowDate;
      _future = _localCache
          .put(LocalCacheKey.timeStamp, nowDate.millisecondsSinceEpoch)
          .then((_) => _fetchWbiKeys());
    }
    return _future!;
  }

  static Future<Map<String, Object>> makSign(
    Map<String, Object> params,
  ) async {
    // params 为需要加密的请求参数
    final String mixinKey = await getWbiKeys();
    encWbi(params, mixinKey);
    return params;
  }
}
