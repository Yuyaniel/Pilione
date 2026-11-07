import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/slider_dialog.dart';
import 'package:PiliPlus/utils/high_quality_playback.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 实验室：本 fork 自研功能的统一入口。
///
/// 这些项原本分散在「音视频设置」「播放器设置」「动态流设置」里，
/// 集中到这里后原位置不再出现，避免同一开关两处入口。
List<SettingsModel> get labSettings => [
  // ===== 高画质（第三方服务解锁 1080P 以上） =====
  const SwitchModel(
    title: '高画质播放（实验性）',
    subtitle: '非大会员经第三方服务获取1080P以上画质，仅支持普通投稿视频（BV/av）',
    leading: Icon(Icons.hdr_plus_outlined),
    setKey: SettingBoxKey.highQualityPlayback,
    defaultVal: false,
  ),
  const SwitchModel(
    title: '打开视频自动解锁高画质',
    subtitle: '需先开启上方「高画质播放」。关闭时默认按 1080P 起播、起播更快；需要高画质时在画质菜单里手动点「解锁高画质」',
    leading: Icon(Icons.bolt_outlined),
    setKey: SettingBoxKey.highQualityPlaybackOnStartup,
    defaultVal: false,
  ),
  NormalModel(
    title: '高画质服务地址',
    leading: const Icon(Icons.dns_outlined),
    getSubtitle: () => Pref.highQualityPlaybackServer.isEmpty
        ? '未配置，留空表示不启用'
        : '当前使用：${Pref.highQualityPlaybackServer}',
    onTap: _showHighQualityServerDialog,
  ),
  NormalModel(
    title: '高画质目标画质',
    leading: const Icon(Icons.high_quality_outlined),
    getSubtitle: () {
      final code = Pref.highQualityPlaybackQuality;
      var desc = '$code';
      for (final item in VideoQuality.values) {
        if (item.code == code) {
          desc = item.desc;
          break;
        }
      }
      return '当前上限：$desc（不高于该画质）';
    },
    onTap: _showHighQualityQualityDialog,
  ),
  NormalModel.split(
    title: '高画质请求状态',
    leading: const Icon(Icons.info_outline),
    getSubtitle: () {
      final status = HighQualityPlayback.lastStatus ?? '尚未发起请求';
      final left = HighQualityPlayback.cooldownSecondsLeft;
      return left > 0 ? '$status（冷却剩余 ${left}s）' : status;
    },
  ),
  const NormalModel.split(
    title: '高画质所用账号',
    leading: Icon(Icons.person_outline),
    getSubtitle: HighQualityPlayback.describeAccount,
  ),
  NormalModel(
    title: '查看最近一次远端请求',
    leading: const Icon(Icons.upload_outlined),
    getSubtitle: () {
      final request = HighQualityPlayback.lastRequest;
      return request == null
          ? '暂无记录，播放一次视频后可查看'
          : '共 ${request.length} 字符，点击查看/复制';
    },
    onTap: (context, setState) => _showHighQualityTextDialog(
      context,
      title: '最近一次远端请求',
      getContent: () => HighQualityPlayback.lastRequest,
    ),
  ),
  NormalModel(
    title: '查看最近一次远端响应',
    leading: const Icon(Icons.download_outlined),
    getSubtitle: () {
      final response = HighQualityPlayback.lastResponse;
      return response == null
          ? '暂无记录，播放一次视频后可查看'
          : '共 ${response.length} 字符，点击查看/复制';
    },
    onTap: (context, setState) => _showHighQualityTextDialog(
      context,
      title: '最近一次远端响应',
      getContent: () => HighQualityPlayback.lastResponse,
    ),
  ),
  NormalModel(
    title: '清除最近一次远端请求/响应',
    leading: const Icon(Icons.delete_outline),
    getSubtitle: () => '记录只保存在本机、不参与配置导出；清除后不影响高画质功能',
    onTap: (context, setState) async {
      final ok = await showConfirmDialog(
        context: context,
        title: const Text('清除远端请求/响应记录'),
        content: const Text('仅删除最近一次请求与响应的本地副本，不影响高画质功能。'),
      );
      if (!ok) return;
      await HighQualityPlayback.clearLastRecord();
      setState();
      SmartDialog.showToast('已清除');
    },
  ),
  const SwitchModel(
    title: '不忽略过短的远端流（调试）',
    subtitle: '远端返回的流比本地更短（试看片段）时也照单采纳，用于排查问题；可能导致只能播放几秒',
    leading: Icon(Icons.science_outlined),
    setKey: SettingBoxKey.highQualityPlaybackIgnoreShort,
    defaultVal: false,
  ),

  // ===== 自动点赞（进度到位 + 累计观看达标） =====
  const SwitchModel(
    title: '播放到指定进度自动点赞',
    subtitle: '「进度到位」且「实际观看累计达标」才点赞，拖动进度条不会误赞；已点赞的视频会跳过',
    leading: Icon(Icons.thumb_up_alt_outlined),
    setKey: SettingBoxKey.autoLikeOnProgress,
    defaultVal: false,
  ),
  NormalModel(
    title: '自动点赞进度',
    leading: const Icon(Icons.percent_outlined),
    getSubtitle: () => '播放位置达到 ${Pref.autoLikePercent}% 时（需同时满足累计观看）',
    onTap: _showAutoLikePercentDialog,
  ),
  NormalModel(
    title: '自动点赞累计观看',
    leading: const Icon(Icons.timelapse_outlined),
    getSubtitle: () =>
        '实际观看累计达到 ${Pref.autoLikeWatchedPercent}%（拖动与回退不计入）',
    onTap: _showAutoLikeWatchedDialog,
  ),

  // ===== 动态页 =====
  const SwitchModel(
    title: '屏蔽「充电专属」视频',
    subtitle: '动态与转发里不再显示充电专属视频卡片（点开也无法观看的内容）',
    leading: Icon(Icons.battery_charging_full_outlined),
    setKey: SettingBoxKey.hideDynamicsChargeVideo,
    defaultVal: true,
  ),
  const SwitchModel(
    title: 'UP 面板入口显示「分组」',
    subtitle: '关闭后首个入口改为「直播」，点击直接进入关注的直播间列表',
    leading: Icon(Icons.swap_horiz),
    setKey: SettingBoxKey.dynUpPanelShowGroup,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '隐藏「番剧」「专栏」标签',
    subtitle: '动态页顶栏只保留 全部 / 投稿 / UP；需重进动态页或重启后生效',
    leading: Icon(Icons.visibility_off_outlined),
    setKey: SettingBoxKey.hideDynamicsTabs,
    defaultVal: false,
    needReboot: true,
  ),
];

Future<void> _showHighQualityTextDialog(
  BuildContext context, {
  required String title,
  required String? Function() getContent,
}) async {
  final content = getContent();
  if (content == null || content.isEmpty) {
    SmartDialog.showToast('暂无记录');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: SingleChildScrollView(
          child: SelectableText(
            content,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: content));
            SmartDialog.showToast('已复制');
          },
          child: const Text('复制全部'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Future<void> _showHighQualityServerDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  String server = Pref.highQualityPlaybackServer;
  final res = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('高画质服务地址'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: server,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'http://mxd.indevs.in',
            ),
            onChanged: (value) => server = value,
          ),
          const SizedBox(height: 12),
          const Text(
            '必须以 http:// 开头，留空表示不启用。'
            '登录凭证（SESSDATA 等）会明文发送到该地址，'
            '请只填写自己信任或自建的服务。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final value = server.trim();
            if (value.isNotEmpty && !HighQualityPlayback.isValidServer(value)) {
              SmartDialog.showToast('服务地址必须以 http:// 开头');
              return;
            }
            Navigator.pop(context, value);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.highQualityPlaybackServer, res);
    setState();
  }
}

Future<void> _showHighQualityQualityDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '高画质目标画质',
      value: Pref.highQualityPlaybackQuality,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.highQualityPlaybackQuality, res);
    setState();
  }
}

Future<void> _showAutoLikePercentDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('自动点赞进度'),
      min: 10,
      max: 100,
      divisions: 90,
      precise: 0,
      value: Pref.autoLikePercent.toDouble(),
      suffix: '%',
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.autoLikePercent, res.toInt());
    setState();
  }
}

Future<void> _showAutoLikeWatchedDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('自动点赞累计观看'),
      min: 10,
      max: 100,
      divisions: 18,
      precise: 0,
      value: Pref.autoLikeWatchedPercent.toDouble(),
      suffix: '%',
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.autoLikeWatchedPercent,
      res.toInt(),
    );
    setState();
  }
}
