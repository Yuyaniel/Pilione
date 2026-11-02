import 'dart:io' show Directory, File;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<Directory> _cacheDirectoryProvider() async {
  final tmpDirPath = await PathProviderPlatform.instance.getTemporaryPath();
  if (tmpDirPath == null) {
    throw MissingPlatformDirectoryException(
      'Unable to get temporary directory',
    );
  }
  if (PlatformUtils.isDesktop) {
    return Directory(path.join(tmpDirPath, Constants.appName));
  }
  return Directory(tmpDirPath);
}

abstract final class CacheManager {
  static late final DefaultCacheManager manager;

  static Future<void> ensureInitialized() => DefaultCacheManager.init(
    maxNrOfCacheLength: Pref.maxCacheSize.toInt(),
    cacheDirectoryProvider: _cacheDirectoryProvider,
  ).then((i) => manager = i);

  // 获取缓存目录
  @pragma('vm:notify-debugger-on-exception')
  static Future<int> loadApplicationCache() async {
    try {
      if (PlatformUtils.isDesktop) {
        return manager.getTotalLength();
      }

      final Directory tempDirectory = await getTemporaryDirectory();
      if (tempDirectory.existsSync()) {
        return await getTotalSizeOfFilesInDir(tempDirectory);
      }
    } catch (_) {}
    return 0;
  }

  // 计算目录占用：单次递归遍历 + 分批并发取长度，避免逐文件串行 await
  @pragma('vm:notify-debugger-on-exception')
  static Future<int> getTotalSizeOfFilesInDir(Directory file) async {
    final cacheDir = manager.cacheDir;
    var total = manager.getTotalLength();
    final files = <File>[];
    await for (final entity in file.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      // 图片缓存由 cache manager 自行统计，跳过避免重复累加
      if (path.isWithin(cacheDir, entity.path)) continue;
      files.add(entity);
    }
    const batchSize = 64;
    for (var i = 0; i < files.length; i += batchSize) {
      final end = i + batchSize < files.length ? i + batchSize : files.length;
      final sizes = await Future.wait(
        // 扫描期间文件可能被删除，单个失败不能拖垮整页统计
        files.sublist(i, end).map((f) => f.length().catchError((_) => 0)),
      );
      for (final size in sizes) {
        total += size;
      }
    }
    return total;
  }

  // 清除 Library/Caches 目录及文件缓存
  @pragma('vm:notify-debugger-on-exception')
  static Future<void> clearLibraryCache() async {
    try {
      await manager.emptyCache();
      if (PlatformUtils.isDesktop) return;

      final tempDirectory = await getTemporaryDirectory();
      if (tempDirectory.existsSync()) {
        await for (final file in tempDirectory.list(recursive: false)) {
          if (file is Directory && path.equals(file.path, manager.cacheDir)) {
            continue;
          }
          await file.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}
