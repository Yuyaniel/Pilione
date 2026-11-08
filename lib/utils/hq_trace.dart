/// 高画质链路临时埋点。
///
/// Release 包里 `if (kDebugMode)` 的日志会被裁掉，这里用 print 保证
/// adb logcat 能抓到完整流程，统一前缀 `[PILIONE_HQ]` 便于过滤。
void hqLog(String stage, String msg) {
  // ignore: avoid_print
  print('[PILIONE_HQ][$stage] $msg');
}
