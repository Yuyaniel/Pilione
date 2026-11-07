import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:math';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

/// 高画质播放：
/// 把网页版 playurl 的原始参数集与登录凭证交给第三方服务，
/// 由服务端代请求 B 站后返回 playurl 结果，从而在非大会员账号下拿到
/// 1080P 以上的画质。
///
/// 协议（抓包还原）：
///   `POST {server}/api/bzview2`
///   `{"ui": {ua, mid, vip, level, money, cookie, csrf}, "url": "playurl url"}`
/// 响应为 B 站 playurl v2 JSON，`data` 可直接交给 [PlayUrlModel.fromJson]。
abstract final class HighQualityPlayback {
  static const String desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

  static const String _deviceReqJson =
      '{"platform":"web","device":"pc","spmid":"666.25","mobi_app":"web_cn"}';

  static const String _localeJson =
      '{"c_locale":{"language":"zh","script":"Hans"},"always_translate":false}';

  static const int defaultQuality = 116;

  /// 远端比本地短这么多（毫秒）以上就认为是试看片段
  static const int _shortStreamTolerance = 5000;

  /// 最近一次远端请求体（cookie 已打码，便于复制反馈）
  static String? lastRequest;

  /// 最近一次远端响应原文
  static String? lastResponse;

  /// 最近一次结果摘要
  static String? lastStatus;

  /// 请求/响应在 localCache 里的键：只在本机留存，不参与配置导出
  static const String _cacheKeyRequest = LocalCacheKey.highQualityLastRequest;
  static const String _cacheKeyResponse = LocalCacheKey.highQualityLastResponse;

  /// 远端失败后的冷却截止时间，避免每次起播都等超时
  static DateTime? _cooldownUntil;

  /// 本次会话手动解锁的 cid（按需解锁：只有用户手动点「解锁高画质」才请求）
  static int? _unlockedCid;

  /// 该 cid 是否已被手动解锁
  static bool isUnlocked(int? cid) => cid != null && cid == _unlockedCid;

  /// 标记该 cid 走高画质（下次 playurl 请求时生效）
  ///
  /// 同时清空 [lastStatus]，调用方可用「lastStatus 是否被写入」判断本次是否真的发了请求。
  static void unlock(int? cid) {
    _unlockedCid = cid;
    lastStatus = null;
  }

  /// 解锁失败时撤销标记，避免同一视频每次起播都重试一次远端
  static void clearUnlock() => _unlockedCid = null;

  /// 打开视频是否自动请求远端（用户开关，默认关：起播不被远端拖慢）
  static bool get autoOnStartup => Pref.highQualityPlaybackOnStartup;

  /// 功能已开启且服务地址已配置（不包含冷却判断）
  static bool get configured =>
      Pref.highQualityPlayback && Pref.highQualityPlaybackServer.isNotEmpty;

  static bool get enabled => configured && !_inCooldown;

  static bool get _inCooldown {
    final until = _cooldownUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _cooldownUntil = null;
      return false;
    }
    return true;
  }

  /// 失败后 30 秒内不再尝试，起播优先保证速度
  static void _enterCooldown() {
    _cooldownUntil = DateTime.now().add(const Duration(seconds: 30));
    lastStatus = '${lastStatus ?? '失败'}（冷却 30 秒，期间不再尝试）';
  }

  /// 剩余冷却秒数，0 表示未在冷却
  static int get cooldownSecondsLeft {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  /// 调试记录只保留有限长度，避免长驻内存
  static const int _maxDebugChars = 8000;

  static String _clipDebug(String value) => value.length <= _maxDebugChars
      ? value
      : '${value.substring(0, _maxDebugChars)}\n…（已截断，原文 ${value.length} 字符）';

  /// 按设置的上限画质裁剪返回流，保证「不高于该画质」
  static void _trimToQualityCap(PlayUrlModel model, int cap) {
    if (cap <= 0) return;
    model.dash?.video?.removeWhere((item) => item.id > cap);
    model.supportFormats?.removeWhere((item) => (item.quality ?? 0) > cap);
    model.acceptQuality?.removeWhere((code) => code > cap);
    final codes = model.acceptQuality;
    if (codes != null && codes.isNotEmpty) {
      model.quality = codes.reduce((a, b) => a > b ? a : b);
    }
  }

  static Dio? _dio;

  static Dio get _client =>
      _dio ??= Dio(
        BaseOptions(
          // 起播路径上的前置请求，超时必须短，慢就直接回退本地 playurl
          connectTimeout: const Duration(milliseconds: 2500),
          sendTimeout: const Duration(milliseconds: 2500),
          receiveTimeout: const Duration(seconds: 8),
          headers: const {
            'user-agent': desktopUa,
            'accept': '*/*',
            'accept-language': 'zh-CN,zh;q=0.9',
            'content-type': 'application/json',
            'origin': 'https://www.bilibili.com',
            'referer': 'https://www.bilibili.com/',
          },
        ),
      );

  /// 进程重启后回填最近一次请求/响应（只在内存为空时读一次缓存）
  static void restoreLastRecord() {
    if (lastRequest == null) {
      final request = GStorage.localCache.get(_cacheKeyRequest);
      if (request is String && request.isNotEmpty) lastRequest = request;
    }
    if (lastResponse == null) {
      final response = GStorage.localCache.get(_cacheKeyResponse);
      if (response is String && response.isNotEmpty) lastResponse = response;
    }
  }

  static void _persistRecord(String key, String value) =>
      unawaited(GStorage.localCache.put(key, value));

  static void clearLastRecord() {
    lastRequest = null;
    lastResponse = null;
    lastStatus = null;
    unawaited(GStorage.localCache.delete(_cacheKeyRequest));
    unawaited(GStorage.localCache.delete(_cacheKeyResponse));
  }

  /// 返回 null 表示远端不可用，调用方应回退到正常的 playurl 请求。
  static Future<PlayUrlModel?> request({
    int? avid,
    String? bvid,
    required int cid,
    int? localDurationMs,
  }) async {
    final server = Pref.highQualityPlaybackServer.trim();
    final account = Accounts.video;
    if (server.isEmpty || !account.isLogin) {
      lastStatus = '未启用：服务地址为空或视频账号未登录';
      return null;
    }

    try {
      final params = await WbiSign.makSign({
        'avid': ?avid,
        'bvid': ?bvid,
        'cid': cid,
        'qn': Pref.highQualityPlaybackQuality,
        'fnver': 0,
        'fnval': 4048,
        'fourk': 1,
        'gaia_source': '',
        'from_client': 'BROWSER',
        'is_main_page': true,
        'need_fragment': false,
        'isGaiaAvoided': false,
        'client_attr': 0,
        'version_name': '4.10.6',
        'app_id': 100,
        'session': _randomSession(),
        'voice_balance': 1,
        'try_look': 0,
        'web_location': 1315873,
        'x-bili-device-req-json': _deviceReqJson,
        'x-bili-locale-json': _localeJson,
      });

      final url = Uri.https('api.bilibili.com', Api.ugcUrl, {
        for (final entry in params.entries) entry.key: '${entry.value}',
      }).toString();

      final userInfo = Pref.userInfoCache;
      final cookie = account.cookieJar
          .toJson()
          .entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');

      final payload = <String, dynamic>{
        'ui': {
          'ua': desktopUa,
          'mid': '${userInfo?.mid ?? _midFromCookie(cookie)}',
          'vip': userInfo?.vipStatus ?? 0,
          'level': userInfo?.levelInfo?.currentLevel ?? 0,
          'money': userInfo?.money ?? 0,
          'cookie': cookie,
          'csrf': account.csrf,
        },
        'url': url,
      };

      lastRequest = _clipDebug(_prettyMasked(payload));
      _persistRecord(_cacheKeyRequest, lastRequest!);

      final res = await _client.post<dynamic>(_endpoint(server), data: payload);

      final raw = res.data is String
          ? res.data as String
          : jsonEncode(res.data);
      lastResponse = _clipDebug(raw);
      _persistRecord(_cacheKeyResponse, lastResponse!);

      final body = jsonDecode(raw);
      if (body is! Map) {
        lastStatus = '失败：响应不是 JSON 对象';
        _enterCooldown();
        return null;
      }
      if (body['code'] != 0) {
        lastStatus = '失败：服务端返回 code=${body['code']}'
            '${body['message'] == null ? '' : '，${body['message']}'}';
        _enterCooldown();
        return null;
      }
      final data = body['data'];
      if (data is! Map) {
        lastStatus = '失败：响应缺少 data';
        _enterCooldown();
        return null;
      }
      final playUrl = PlayUrlModel.fromJson(data.cast<String, dynamic>());
      if (playUrl.dash?.video?.isNotEmpty != true) {
        lastStatus = '失败：响应里没有可用视频流（服务端可能判定无需处理）';
        _enterCooldown();
        return null;
      }

      // 「目标画质」是上限：裁掉高于上限的流
      _trimToQualityCap(playUrl, Pref.highQualityPlaybackQuality);
      if (playUrl.dash?.video?.isNotEmpty != true) {
        lastStatus =
            '失败：上限画质 ${_qualityDesc(Pref.highQualityPlaybackQuality)} 低于可用档位';
        return null;
      }

      if (!Pref.highQualityPlaybackIgnoreShort &&
          localDurationMs != null &&
          localDurationMs > 0 &&
          (playUrl.timeLength ?? 0) > 0 &&
          playUrl.timeLength! < localDurationMs - _shortStreamTolerance) {
        lastStatus =
            '已忽略：远端流 ${playUrl.timeLength! ~/ 1000}s 短于本地 ${localDurationMs ~/ 1000}s，疑似试看片段';
        return null;
      }

      final codes = playUrl.acceptQuality ?? const <int>[];
      final highest = codes.isEmpty
          ? playUrl.quality
          : codes.reduce((a, b) => a > b ? a : b);
      lastStatus = '成功：最高 ${_qualityDesc(highest)}'
          '${codes.isEmpty ? '' : '，共 ${codes.length} 档'}';
      return playUrl;
    } catch (e) {
      lastStatus = '失败：$e';
      _enterCooldown();
      return null;
    }
  }

  /// 服务端要求的登录信息，便于确认发出去的是哪个账号
  static String describeAccount() {
    final userInfo = Pref.userInfoCache;
    if (userInfo == null) return '未获取到账号信息';
    final mid = userInfo.mid;
    return 'mid=${mid ?? '-'}　等级=${userInfo.levelInfo?.currentLevel ?? '-'}'
        '　硬币=${userInfo.money ?? '-'}'
        '　大会员=${(userInfo.vipStatus ?? 0) > 0 ? '是' : '否'}';
  }

  static String _qualityDesc(int? code) {
    if (code == null) return '未知';
    for (final quality in VideoQuality.values) {
      if (quality.code == code) return quality.desc;
    }
    return '$code';
  }

  static String _endpoint(String server) =>
      server.endsWith('/') ? '${server}api/bzview2' : '$server/api/bzview2';

  static String _prettyMasked(Map<String, dynamic> payload) {
    final ui = Map<String, dynamic>.from(payload['ui'] as Map);
    ui['cookie'] = _maskCookie(ui['cookie'] as String? ?? '');
    return const JsonEncoder.withIndent('  ').convert({
      'ui': ui,
      'url': payload['url'],
    });
  }

  static String _maskCookie(String cookie) => cookie
      .split(';')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .map((item) {
        final index = item.indexOf('=');
        if (index <= 0) return item;
        return '${item.substring(0, index)}=***';
      })
      .join('; ');

  static int _midFromCookie(String cookie) {
    for (final item in cookie.split(';')) {
      final pair = item.trim().split('=');
      if (pair.length == 2 && pair[0] == 'DedeUserID') {
        return int.tryParse(pair[1]) ?? 0;
      }
    }
    return 0;
  }

  static String _randomSession() {
    final rnd = Random();
    return List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }
}
