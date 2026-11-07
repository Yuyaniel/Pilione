import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract final class UrlUtils {
  static const _redirectTimeout = Duration(seconds: 4);
  static const _redirectCacheLimit = 100;

  // 短链 → 真实地址，按插入顺序做简单的 LRU
  static final Map<String, String?> _redirectCache = <String, String?>{};

  // 302重定向路由截取
  static Future<String?> parseRedirectUrl(
    String url, [
    bool returnOri = false,
  ]) async {
    if (_redirectCache.containsKey(url)) {
      return _redirectCache[url];
    }

    String? redirectUrl = await _fetchRedirect(url);
    // 一次重试，覆盖偶发的网络抖动
    redirectUrl ??= await _fetchRedirect(url);
    if (redirectUrl == null) {
      // 失败结果不缓存：网络恢复后下次仍会重新尝试
      return returnOri ? url : null;
    }
    if (redirectUrl.endsWith('/')) {
      redirectUrl = redirectUrl.substring(0, redirectUrl.length - 1);
    }
    if (_redirectCache.length >= _redirectCacheLimit) {
      _redirectCache.remove(_redirectCache.keys.first);
    }
    _redirectCache[url] = redirectUrl;
    return redirectUrl;
  }

  static Future<String?> _fetchRedirect(String url) async {
    try {
      final response = await Request.dio
          .head(
            url,
            options: Options(
              followRedirects: false,
              validateStatus: (status) {
                return 200 <= status! && status < 400;
              },
              extra: {'account': AnonymousAccount()},
            ),
          )
          .timeout(_redirectTimeout);
      String? redirectUrl = response.headers['location']?.firstOrNull;
      if (kDebugMode) debugPrint('redirectUrl: $redirectUrl');
      if (redirectUrl != null && !redirectUrl.startsWith('http')) {
        redirectUrl = Uri.parse(url).resolve(redirectUrl).toString();
      }
      return redirectUrl;
    } catch (_) {
      return null;
    }
  }

  // 匹配url路由跳转
  static Future<void> matchUrlPush(
    String pathSegment,
    String redirectUrl,
  ) async {
    final matchRes = IdUtils.matchAvorBv(input: pathSegment);
    if (matchRes.isNotEmpty) {
      final aid = matchRes.av;
      final bvid = matchRes.bv;
      final res = await SearchHttp.ab2cWithDimension(aid: aid, bvid: bvid);
      final cid = res?.cid;
      if (cid != null) {
        PageUtils.toVideoPage(
          aid: aid,
          bvid: bvid,
          cid: cid,
          dimension: res!.dimension,
          // title: res.title,
        );
      }
    } else {
      if (redirectUrl.isNotEmpty) {
        PageUtils.handleWebview(redirectUrl);
      } else {
        SmartDialog.showToast('matchUrlPush: $pathSegment');
      }
    }
  }
}
