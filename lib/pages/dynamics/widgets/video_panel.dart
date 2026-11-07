// 视频or合集
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/svg/play_icon.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

Widget videoSeasonWidget(
  BuildContext context, {
  required int floor,
  required ThemeData theme,
  required DynamicItemModel item,
  required bool isSave,
  required bool isDetail,
}) {
  // type archive  ugcSeason
  // archive 视频/显示发布人
  // ugcSeason 合集/不显示发布人

  DynamicArchiveModel? video = switch (item.type) {
    'DYNAMIC_TYPE_AV' => item.modules.moduleDynamic?.major?.archive,
    'DYNAMIC_TYPE_UGC_SEASON' => item.modules.moduleDynamic?.major?.ugcSeason,
    'DYNAMIC_TYPE_PGC' ||
    'DYNAMIC_TYPE_PGC_UNION' => item.modules.moduleDynamic?.major?.pgc,
    'DYNAMIC_TYPE_COURSES_SEASON' => item.modules.moduleDynamic?.major?.courses,
    _ => null,
  };

  if (video == null) {
    return const SizedBox.shrink();
  }

  // 屏蔽「充电专属」视频：「充电专属」与「抢先看」两种徽标形态都算，
  // 非充电用户点开也无法观看，纯噪音。覆盖正图与转发内嵌卡片（统一走本入口）。
  // 仅限 AV 类型：番剧/纪录片的「抢先看」（PGC）不在此列；
  // hasOnlyFansVideoBadge 同时兜底徽标文案变动的情况。
  if (Pref.hideDynamicsChargeVideo &&
      item.type == 'DYNAMIC_TYPE_AV' &&
      (item.hasChargeOnlyBadge || item.hasOnlyFansVideoBadge)) {
    return const SizedBox.shrink();
  }

  EdgeInsets padding;
  if (floor == 1) {
    padding = const EdgeInsets.symmetric(horizontal: 12);
  } else {
    padding = EdgeInsets.zero;
  }
  return Padding(
    padding: padding,
    child: Column(
      spacing: 6,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (video.cover case final cover?)
          Stack(
            clipBehavior: Clip.none,
            children: [
              LayoutBuilder(
                builder: (context, constraints) => NetworkImgLayer(
                  width: constraints.maxWidth,
                  height: constraints.maxWidth / Style.aspectRatio,
                  src: cover,
                  quality: 40,
                ),
              ),
              if (video.badge?.text case final badge?)
                PBadge(
                  text: badge,
                  top: 8.0,
                  right: 10.0,
                  bottom: null,
                  left: null,
                  type: switch (badge) {
                    '充电专属' => PBadgeType.error,
                    _ => PBadgeType.primary,
                  },
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 70,
                  alignment: Alignment.bottomLeft,
                  padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black54,
                      ],
                    ),
                    borderRadius: .vertical(bottom: Style.imgRadius),
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: theme.textTheme.labelMedium!.fontSize,
                      color: Colors.white,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (video.durationText case final durationText?) ...[
                          DecoratedBox(
                            decoration: const BoxDecoration(
                              color: Colors.black45,
                              borderRadius: .all(.circular(4)),
                            ),
                            child: Text(' $durationText '),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (video.stat case final stat?) ...[
                          Text('${NumUtils.numFormat(stat.play)}播放'),
                          const SizedBox(width: 6),
                          Text('${NumUtils.numFormat(stat.danmu)}弹幕'),
                        ],
                        const Spacer(),
                        const PlayIcon(size: 50),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (video.title case final title?)
          Text(
            title,
            maxLines: isDetail ? null : 1,
            style: const TextStyle(fontWeight: FontWeight.bold),
            overflow: isDetail ? null : TextOverflow.ellipsis,
          ),
      ],
    ),
  );
}
