import 'dart:async';
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
import 'package:get/get.dart' show RxInt;

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

  /// 番剧 playview 的 locale 参数，必须与网页那份完全一致（zh-Hans），
  /// 否则服务端重放时 w_rid 对应的参数集不同，会判 invalid。
  static const String _pgcLocaleJson =
      '{"c_locale":{"language":"zh-Hans"},"always_translate":false}';

  static const int defaultQuality = 116;

  /// 远端比本地短这么多（毫秒）以上就认为是试看片段
  static const int _shortStreamTolerance = 5000;

  /// 最近一次远端请求体（cookie 已打码，便于复制反馈）
  static String? lastRequest;

  /// 最近一次远端响应原文
  static String? lastResponse;

  /// 最近一次结果摘要
  static String? lastStatus;

  /// 今日剩余解析次数 = 100 - 服务端 today；-1 表示尚未获取
  static final RxInt remaining = RxInt(-1);

  /// 查询时的账号 mid：切换账号后旧数值不再可信
  static int? _quotaMid;

  /// 进行中的次数查询，并发调用共享同一个结果
  static Future<int?>? _quotaFuture;

  /// 当前账号的剩余次数；账号已切换或从未查询时返回 -1
  static int get remainingCount {
    final currentMid = Pref.userInfoCache?.mid;
    if (_quotaMid != null && currentMid != null && currentMid != _quotaMid) {
      return -1;
    }
    return remaining.value;
  }

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
    remaining.value = -1;
    _quotaMid = null;
    _quotaFuture = null;
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
      final cookie = _currentCookie(account);

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
      // 服务端已计一次解析，后台刷新剩余次数（与提示共用同一次请求）
      unawaited(refreshRemaining());
      return playUrl;
    } catch (e) {
      lastStatus = '失败：${friendlyError(e)}';
      _enterCooldown(networkError: _isNetworkError(e));
      return null;
    }
  }

  /// 番剧/课程解析：服务端代请求 `ogv/player/playview`。
  ///
  /// 返回 null 表示远端不可用，调用方应回退官方 [Api.ogvUrl]。
  /// 只对非 DRM 内容有效；DRM 番剧响应里没有 `video_info`，会返回 null。
  static Future<PlayUrlModel?> requestPgc({
    required int epId,
    required int seasonId,
    required int cid,
    int? qn,
    bool iic = false,
  }) async {
    if (epId <= 0 || cid <= 0) {
      lastStatus = '未启用：缺少 ep_id 或 cid';
      return null;
    }
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
      // 按浏览器真实请求补全参数：playview 必须带 wbi 签名（w_rid/wts），
      // 否则服务端会直接返回 code=2 参数错误。
      final query = await WbiSign.makSign({
        'biz_type': 'ogv',
        'scene': 'normal',
        'from_client': 'BROWSER',
        'ep_id': epId,
        'season_id': seasonId,
        'qn': _ogvQn(qn ?? Pref.highQualityPlaybackQuality),
        'fnver': 0,
        'fnval': 4048,
        'drm_tech_type': 2,
        'version_name': '4.10.10',
        'app_id': 100,
        'web_location': '666.25',
        'x-bili-locale-json': _pgcLocaleJson,
        'x-bili-device-req-json': _deviceReqJson,
      });
      final url = Uri.https('api.bilibili.com', Api.ogvUrl, {
        for (final entry in query.entries) entry.key: '${entry.value}',
      }).toString();

      final userInfo = Pref.userInfoCache;
      final cookie = _currentCookie(account);
      final payload = <String, dynamic>{
        // 脚本原逻辑：官方响应里出现 AreaLimitPanel 说明区域受限，服务端据此选线路
        'iic': iic,
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

      Future<Response<dynamic>> post() => _client.post<dynamic>(
        endpointPgc(server),
        data: payload,
        // 番剧 playview 比 UGC 慢，放宽接收超时；
        // 服务端 gunicorn keep-alive 只有 5s，复用连接容易被 RST，固定用完即关
        options: Options(
          receiveTimeout: const Duration(seconds: 20),
          headers: const {'connection': 'close'},
        ),
      );

      Response<dynamic> res;
      try {
        res = await post();
      } on DioException catch (e) {
        // 与 IMZCC/PiliNara 的处理一致：失败换连接重试一次
        if (_isNetworkError(e)) {
          res = await post();
        } else {
          rethrow;
        }
      }

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

      // 与开发者脚本一致：去掉 need_login / need_vip，
      // 避免播放器仍按未登录/未付费处理
      _stripGates(data);

      // OGV playview 的流在 data.video_info；兼容部分实现直接返回 dash/durl
      final source = data['video_info'] is Map
          ? data['video_info'] as Map
          : data;
      final playUrl = PlayUrlModel.fromJson(source.cast<String, dynamic>());
      final hasVideo =
          playUrl.dash?.video?.isNotEmpty == true ||
          playUrl.durl?.isNotEmpty == true;
      if (!hasVideo) {
        lastStatus = '失败：响应里没有可用视频流（可能是 DRM 或权限不足）';
        _enterCooldown();
        return null;
      }

      trimToQualityCap(playUrl, Pref.highQualityPlaybackQuality);
      if (playUrl.dash?.video?.isNotEmpty == true) {
        final codes = playUrl.acceptQuality ?? const <int>[];
        final highest = codes.isEmpty
            ? (playUrl.quality ?? 0)
            : codes.reduce((a, b) => a > b ? a : b);
        lastStatus = '成功：最高 ${_qualityDesc(highest)}'
            '${codes.isEmpty ? '' : '，共 ${codes.length} 档'}';
      } else {
        lastStatus = '成功：durl 流';
      }
      unawaited(refreshRemaining());
      return playUrl;
    } catch (e) {
      // 服务端返回 4xx/5xx 时 Dio 会抛异常，这里把响应体记下来便于排查
      if (e is DioException && e.response != null) {
        lastResponse = clipDebug(
          'HTTP ${e.response!.statusCode}: ${e.response!.data}',
        );
        await _persistRecord(_cacheKeyResponse, lastResponse!);
      }
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

  /// playview 可接受的 qn：HDR Vivid(129) 等新档位可能被拒，映射到最接近的档位
  static int _ogvQn(int qn) {
    const supported = [127, 126, 125, 120, 116, 112, 80, 74, 64, 32, 16];
    if (supported.contains(qn)) return qn;
    return qn > 127 ? 120 : 80;
  }

  /// 由已校验的服务地址拼出 bzview3 端点（番剧/课程）。
  static String endpointPgc(String server) {
    final trimmed = server.trim();
    if (!isValidServer(trimmed)) {
      throw const FormatException('服务地址必须以 http:// 开头');
    }
    return trimmed.endsWith('/')
        ? '${trimmed}api/bzview3'
        : '$trimmed/api/bzview3';
  }

  /// 由已校验的服务地址拼出 bzusta 端点（查询当日已用次数）。
  static String quotaEndpoint(String server) {
    final trimmed = server.trim();
    if (!isValidServer(trimmed)) {
      throw const FormatException('服务地址必须以 http:// 开头');
    }
    return trimmed.endsWith('/')
        ? '${trimmed}api/bzusta'
        : '$trimmed/api/bzusta';
  }

  /// 去掉 playview 响应里的 need_login / need_vip 标记。
  /// 开发者脚本用字符串替换实现，这里在解析后的 Map 上做同样的事。
  static void _stripGates(Map data) {
    data.remove('need_login');
    data.remove('need_vip');
    if (data['video_info'] case final Map info) {
      info.remove('need_login');
      info.remove('need_vip');
    }
  }

  /// 当前视频账号的 cookie 串
  static String _currentCookie(Account account) => account.cookieJar
      .toJson()
      .entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');

  /// 查询今日剩余解析次数（100 - today）。
  /// 失败返回 null 并保留上一次的值，不打扰用户；并发调用共享同一次请求。
  static Future<int?> refreshRemaining() {
    final pending = _quotaFuture;
    if (pending != null) return pending;
    return _quotaFuture = _doRefreshRemaining().whenComplete(() {
      _quotaFuture = null;
    });
  }

  static Future<int?> _doRefreshRemaining() async {
    final server = Pref.highQualityPlaybackServer.trim();
    final account = Accounts.video;
    if (server.isEmpty || !account.isLogin || !isValidServer(server)) {
      return null;
    }
    try {
      final cookie = _currentCookie(account);
      final mid = Pref.userInfoCache?.mid ?? midFromCookie(cookie);
      final res = await _client.post<dynamic>(
        quotaEndpoint(server),
        data: {
          'ui': {'mid': '$mid', 'cookie': cookie},
        },
      );
      final body = res.data is String
          ? jsonDecode(res.data as String)
          : res.data;
      if (body is Map && body['code'] == 0 && body['today'] is num) {
        final left = 100 - (body['today'] as num).toInt();
        remaining.value = left < 0 ? 0 : (left > 100 ? 100 : left);
        _quotaMid = mid;
        return remaining.value;
      }
    } catch (_) {
      // 次数查询失败不影响播放，保留上次值
    }
    return null;
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
