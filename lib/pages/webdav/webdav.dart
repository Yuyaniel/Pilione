import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

typedef _WebDavConfig = ({
  String uri,
  String username,
  String password,
  String directory,
});

class WebDav {
  _WebDavConfig? _clientConfig;
  webdav.Client? _client;

  WebDav._internal();
  static final WebDav _instance = WebDav._internal();
  factory WebDav() => _instance;

  _WebDavConfig _getConfig() {
    String directory = Pref.webdavDirectory;
    if (!directory.endsWith('/')) {
      directory += '/';
    }
    return (
      uri: Pref.webdavUri,
      username: Pref.webdavUsername,
      password: Pref.webdavPassword,
      directory: '$directory${Constants.appName}',
    );
  }

  Future<webdav.Client> _connect(
    _WebDavConfig config, {
    bool force = false,
  }) async {
    final cachedClient = _client;
    if (!force && cachedClient != null && _clientConfig == config) {
      return cachedClient;
    }

    final client =
        webdav.newClient(
            config.uri,
            user: config.username,
            password: config.password,
          )
          ..setHeaders({'accept-charset': 'utf-8'})
          ..setConnectTimeout(12000)
          ..setReceiveTimeout(12000)
          ..setSendTimeout(12000);

    await client.mkdirAll(config.directory);
    _clientConfig = config;
    _client = client;
    return client;
  }

  Future<Pair<bool, String?>> init() async {
    try {
      await _connect(_getConfig(), force: true);

      return Pair(first: true, second: null);
    } catch (e) {
      return Pair(first: false, second: e.toString());
    }
  }

  String _getFileName() {
    return '${Constants.appName.toLowerCase()}_settings_'
        '${DeviceUtils.platformName}.json';
  }

  /// 改名前的应用目录名，恢复时回退读取，避免升级后读不到既有备份
  List<String> _restoreCandidates(_WebDavConfig config) {
    final dir = config.directory;
    final separator = dir.lastIndexOf('/');
    final parent = separator == -1 ? '' : dir.substring(0, separator);
    final platform = DeviceUtils.platformName;
    return [
      '${config.directory}/${_getFileName()}',
      for (final app in Constants.legacyAppNames)
        '$parent/$app/${app.toLowerCase()}_settings_$platform.json',
    ];
  }

  Future<void> backup() async {
    // Keep the payload bound to the same settings snapshot as the connection.
    final config = _getConfig();
    final data = GStorage.exportAllSettings();
    final webdav.Client client;
    try {
      client = await _connect(config);
    } catch (e) {
      SmartDialog.showToast('备份失败，请检查配置: $e');
      return;
    }
    try {
      final path = '${config.directory}/${_getFileName()}';
      try {
        await client.remove(path);
      } catch (_) {}
      await client.write(path, utf8.encode(data));
      SmartDialog.showToast('备份成功');
    } catch (e) {
      SmartDialog.showToast('备份失败: $e');
    }
  }

  Future<void> restore() async {
    final config = _getConfig();
    final webdav.Client client;
    try {
      client = await _connect(config);
    } catch (e) {
      SmartDialog.showToast('恢复失败，请检查配置: $e');
      return;
    }
    try {
      List<int>? data;
      Object? lastError;
      for (final path in _restoreCandidates(config)) {
        try {
          data = await client.read(path);
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (data == null) {
        // 把真实原因暴露出来，避免网络故障被误报成「备份不存在」
        SmartDialog.showToast(
          lastError == null ? '恢复失败: 未找到备份文件' : '恢复失败: $lastError',
        );
        return;
      }
      await GStorage.importAllSettings(utf8.decode(data));
      SmartDialog.showToast('恢复成功');
    } catch (e) {
      SmartDialog.showToast('恢复失败: $e');
    }
  }
}
