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
/// 协议（服务端说明）：
///   `POST {server}/api/bzview2`，{server} 为 http:// 地址（该服务不提供 https）
///   `{"ui": {mid, cookie}, "url": "https://api.bilibili.com/x/player/wbi/playurl?...&fn=1"}`
/// 注意 `url` 是交给服务端转发给 B 站的地址，仍是 https，与服务地址的协议无关。
/// `url.query` 必须包含 `avid` / `bvid` / `cid` / `fn`；`ui` 只要求 mid 与 cookie，
/// 其余字段是为兼容历史实现而保留，服务端可忽略。
/// 响应为 B 站 playurl v2 JSON，`data` 可直接交给 [PlayUrlModel.fromJson]。
///
/// 只实现普通投稿（bzview2）；番剧/课程的 bzview3 协议不在此范围内。
///
/// 调用时机：默认只有用户手动点「解锁高画质」才请求；开启「起播后自动切换」后，
/// 由 VideoDetailController 在首帧稳定、前向缓冲 ≥5 秒时后台调用一次，
/// 不占用起播路径。
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

  /// 测试/依赖注入用：注入后 [request] 使用该实例而不是内部自建的 Dio。
  /// 生产代码保持 null；单测可注入 mock adapter 验证失败分支。
  static Dio? injectedDio;

  /// 清除记录后置位：阻止 [restoreLastRecord] 把刚删掉的旧缓存又读回来。
  /// 进程重启后该标志自然消失，此时缓存也已删空，不会复活。
  static bool _cleared = false;

  /// 重置全部进程内状态（含注入的 Dio），仅供测试/调试调用。
  static void reset() {
    lastRequest = null;
    lastResponse = null;
    lastStatus = null;
    _cooldownUntil = null;
    _unlockedCid = null;
    _cleared = false;
    injectedDio = null;
    _dio = null;
  }

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

  /// 失败后冷却：网络类故障（超时/连不上）只冷却 5 秒，业务类错误 30 秒。
  /// 起播路径优先保证速度，短冷却让偶发抖动能快速自愈。
  static void _enterCooldown({bool networkError = false}) {
    final seconds = networkError ? 5 : 30;
    _cooldownUntil = DateTime.now().add(Duration(seconds: seconds));
    lastStatus = '${lastStatus ?? '失败'}（冷却 $seconds 秒，期间不再尝试）';
  }

  /// 网络类异常判定：超时 / 连不上 / 证书问题，归为可快速重试。
  static bool _isNetworkError(Object e) {
    if (e is! DioException) return false;
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.badCertificate => true,
      _ => false,
    };
  }

  /// 把底层异常映射成可直接展示的中文短句，不把 DioException 原文抛给用户。
  static String friendlyError(Object e) {
    if (e is DioException) {
      return switch (e.type) {
        DioExceptionType.connectionTimeout => '连接服务超时，请稍后重试',
        DioExceptionType.sendTimeout => '请求发送超时，请稍后重试',
        DioExceptionType.receiveTimeout => '服务响应超时，请稍后重试或检查服务地址',
        DioExceptionType.transformTimeout => '响应解析超时，请稍后重试',
        DioExceptionType.connectionError => '无法连接服务，请检查网络或服务地址',
        DioExceptionType.badCertificate => '服务证书校验失败，请检查 HTTPS 配置',
        DioExceptionType.badResponse =>
          '服务返回异常（HTTP ${e.response?.statusCode ?? '未知'}）',
        DioExceptionType.cancel => '请求已取消',
        DioExceptionType.unknown => '请求失败，请稍后重试',
      };
    }
    if (e is FormatException) return e.message;
    return '请求失败，请稍后重试';
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

  static String clipDebug(String value) => value.length <= _maxDebugChars
      ? value
      : '${value.substring(0, _maxDebugChars)}\n…（已截断，原文 ${value.length} 字符）';

  /// 按设置的上限画质裁剪返回流，保证「不高于该画质」
  static void trimToQualityCap(PlayUrlModel model, int cap) {
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

  static Dio get _client {
    final injected = injectedDio;
    if (injected != null) return injected;
    return _dio ??= Dio(
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
  }

  /// 进程重启后回填最近一次请求/响应（只在内存为空时读一次缓存）
  static void restoreLastRecord() {
    if (_cleared) return;
    if (lastRequest == null) {
      final request = GStorage.localCache.get(_cacheKeyRequest);
      if (request is String && request.isNotEmpty) lastRequest = request;
    }
    if (lastResponse == null) {
      final response = GStorage.localCache.get(_cacheKeyResponse);
      if (response is String && response.isNotEmpty) lastResponse = response;
    }
  }

  static Future<void> _persistRecord(String key, String value) async {
    _cleared = false;
    try {
      await GStorage.localCache.put(key, value);
    } catch (_) {
      // 缓存写入失败不影响主流程（记录只用于调试查看）
    }
  }

  /// 清除内存与本地缓存；await 两个删除完成后再返回，避免「清除后复活」竞态。
  static Future<void> clearLastRecord() async {
    lastRequest = null;
    lastResponse = null;
    lastStatus = null;
    _cooldownUntil = null; // 状态行与冷却显示保持一致
    _cleared = true;
    try {
      await GStorage.localCache.deleteAll([
        _cacheKeyRequest,
        _cacheKeyResponse,
      ]);
    } catch (_) {
      // 删不掉也不影响高画质功能；内存字段已清空
    }
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
    if (!isValidServer(server)) {
      lastStatus = '未启用：服务地址必须以 http:// 开头';
      return null;
    }

    try {
      final params = await WbiSign.makSign({
        'avid': ?avid,
        'bvid': ?bvid,
        'cid': cid,
        // 服务端说明要求 url.query 含 fn（视频流格式，1 = mp4）
        'fn': 1,
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
        'session': randomSession(),
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
          'mid': '${userInfo?.mid ?? midFromCookie(cookie)}',
          'vip': userInfo?.vipStatus ?? 0,
          'level': userInfo?.levelInfo?.currentLevel ?? 0,
          'money': userInfo?.money ?? 0,
          'cookie': cookie,
          'csrf': account.csrf,
        },
        'url': url,
      };

      lastRequest = clipDebug(prettyMasked(payload));
      await _persistRecord(_cacheKeyRequest, lastRequest!);

      final res = await _client.post<dynamic>(endpoint(server), data: payload);

      final raw = res.data is String
          ? res.data as String
          : jsonEncode(res.data);
      lastResponse = clipDebug(raw);
      await _persistRecord(_cacheKeyResponse, lastResponse!);

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
      trimToQualityCap(playUrl, Pref.highQualityPlaybackQuality);
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
      lastStatus = '失败：${friendlyError(e)}';
      _enterCooldown(networkError: _isNetworkError(e));
      return null;
    }
  }

  /// 画质菜单点击灰档前的统一前置检查：返回 null 表示可解锁，否则给出提示文案。
  /// header_control 与 pl_player 共用，避免两处判断与文案漂移。
  static String? unlockBlockedReason() {
    if (!configured) {
      return '标灰画质需要bilibili会员（已是会员？请关闭无痕模式）';
    }
    if (_inCooldown) {
      return '高画质服务冷却中，$cooldownSecondsLeft 秒后可重试';
    }
    if (!enabled) {
      return '高画质服务暂不可用，请稍后重试';
    }
    return null;
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

  /// 解析服务只提供 http，因此只接受 http 地址。
  /// 注意：SESSDATA 等登录凭证会以明文发送到该服务。
  static bool isValidServer(String server) {
    final uri = Uri.tryParse(server.trim());
    return uri != null &&
        uri.isScheme('http') &&
        uri.host.isNotEmpty &&
        !uri.host.contains(' ');
  }

  /// 由已校验的服务地址拼出 bzview2 端点。
  static String endpoint(String server) {
    final trimmed = server.trim();
    if (!isValidServer(trimmed)) {
      throw const FormatException('服务地址必须以 http:// 开头');
    }
    return trimmed.endsWith('/')
        ? '${trimmed}api/bzview2'
        : '$trimmed/api/bzview2';
  }

  /// 调试用请求体：cookie / csrf / 余额全部打码，mid 只保留尾 2 位。
  /// 这份文本会被持久化到未加密的 localCache，也能被「复制全部」导出，
  /// 因此任何可复用的登录凭证都不能以明文出现。
  static String prettyMasked(Map<String, dynamic> payload) {
    final ui = Map<String, dynamic>.from(payload['ui'] as Map);
    ui['cookie'] = maskCookie(ui['cookie'] as String? ?? '');
    ui['csrf'] = '***';
    ui['money'] = '***';
    final mid = '${ui['mid'] ?? ''}';
    ui['mid'] = mid.length > 2
        ? '${'*' * (mid.length - 2)}${mid.substring(mid.length - 2)}'
        : '***';
    return const JsonEncoder.withIndent('  ').convert({
      'ui': ui,
      'url': payload['url'],
    });
  }

  static String maskCookie(String cookie) => cookie
      .split(';')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .map((item) {
        final index = item.indexOf('=');
        if (index <= 0) return item;
        return '${item.substring(0, index)}=***';
      })
      .join('; ');

  static int midFromCookie(String cookie) {
    for (final item in cookie.split(';')) {
      final pair = item.trim().split('=');
      if (pair.length == 2 && pair[0] == 'DedeUserID') {
        return int.tryParse(pair[1]) ?? 0;
      }
    }
    return 0;
  }

  static String randomSession() {
    final rnd = Random();
    return List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }
}
