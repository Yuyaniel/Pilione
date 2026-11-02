import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/dynamic/up_panel_position.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/live_follow/view.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

class UpPanel extends StatefulWidget {
  const UpPanel({
    super.key,
    required this.upData,
    required this.dynamicsController,
  });

  final FollowUpModel upData;
  final DynamicsController dynamicsController;

  @override
  State<UpPanel> createState() => _UpPanelState();
}

class _UpPanelState extends State<UpPanel> {
  late final controller = widget.dynamicsController;
  late final isTop = controller.upPanelPosition == UpPanelPosition.top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upData = widget.upData;
    final upList = upData.upList;
    // 首个入口可在「分组」与「直播」之间切换，由实验室开关控制
    final showGroup = Pref.dynUpPanelShowGroup;
    final entryLabel = showGroup ? '分组' : '直播';
    final Widget scrollView = CustomScrollView(
      scrollDirection: isTop ? .horizontal : .vertical,
      physics: const AlwaysScrollableScrollPhysics(),
      controller: controller.scrollController,
      slivers: [
        // 布局与 upItemBuild 完全同构（38px 圆 + spacing4 + 两行文字占位），
        // 保证图标中心线与 UP 头像中心线处于同一水平线。
        SliverToBoxAdapter(
          child: SizedBox(
            height: 76,
            width: isTop ? 70 : null,
            child: InkWell(
              onTap: () => showGroup
                  ? Get.toNamed('/follow')
                  : Get.to(const LiveFollowPage()),
              child: Column(
                spacing: 4,
                mainAxisSize: .min,
                mainAxisAlignment: .center,
                children: [
                  Padding(
                    padding: const .symmetric(horizontal: 4),
                    child: CircleAvatar(
                      radius: 19,
                      backgroundColor: theme.colorScheme.secondaryContainer,
                      child: Icon(
                        showGroup
                            ? Icons.folder_shared_outlined
                            : Icons.live_tv_outlined,
                        size: 22,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const .symmetric(horizontal: 4),
                    child: Text(
                      isTop ? '$entryLabel\n' : entryLabel,
                      maxLines: 2,
                      textAlign: .center,
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                        height: 1.1,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: upItemBuild(theme, UpItem(face: '', uname: '全部动态', mid: -1)),
        ),
        StreamBuilder<BoxEvent>(
          stream: GStorage.setting.watch().where(
            (event) => event.key == SettingBoxKey.dynamicsShowSelfUp,
          ),
          builder: (context, _) {
            if (!Pref.dynamicsShowSelfUp) {
              return const SliverToBoxAdapter(child: SizedBox.shrink());
            }
            return SliverToBoxAdapter(
              child: Obx(
                () => upItemBuild(
                  theme,
                  UpItem(
                    uname: '我',
                    face: controller.accountService.face.value,
                    mid: Accounts.main.mid,
                  ),
                ),
              ),
            );
          },
        ),
        if (upList != null && upList.isNotEmpty)
          SliverList.builder(
            itemCount: upList.length,
            itemBuilder: (context, index) {
              return upItemBuild(theme, upList[index]);
            },
          ),
        if (!isTop) const SliverToBoxAdapter(child: SizedBox(height: 200)),
      ],
    );
    return scrollView;
  }

  void _onSelect(UpItem item) {
    item.hasUpdate = false;
    controller.onSelectUp(item.mid);
    setState(() {});
  }

  Widget upItemBuild(ThemeData theme, UpItem item) {
    final currentMid = controller.currentMid;
    final isLive = item is LiveUserItem;
    final isCurrent = isLive || currentMid == item.mid || currentMid == -1;

    final isAll = item.mid == -1;
    void toMemberPage() => Get.toNamed('/member?mid=${item.mid}');

    Widget avatar;
    if (isAll) {
      avatar = ClipOval(
        child: Image.asset(
          width: 38,
          height: 38,
          fit: .cover,
          cacheWidth: 38.cacheSize(context),
          Assets.logoDark,
        ),
      );
    } else {
      avatar = Padding(
        padding: const .symmetric(horizontal: 4),
        child: NetworkImgLayer(
          width: 38,
          height: 38,
          src: item.face,
          type: .avatar,
        ),
      );
      if (isLive) {
        avatar = Stack(
          clipBehavior: .none,
          children: [
            avatar,
            Positioned(
              top: isLive && !isTop ? -5 : 0,
              right: -6,
              child: Badge(
                label: const Text(' Live '),
                textColor: theme.colorScheme.onSecondaryContainer,
                backgroundColor: theme.colorScheme.secondaryContainer
                    .withValues(alpha: 0.75),
              ),
            ),
          ],
        );
      } else if (item.hasUpdate ?? false) {
        avatar = Stack(
          clipBehavior: .none,
          children: [
            avatar,
            Positioned(
              top: 0,
              right: 4,
              child: Badge(
                smallSize: 8,
                backgroundColor: theme.colorScheme.primary,
              ),
            ),
          ],
        );
      }
    }

    return SizedBox(
      height: 76,
      width: isTop ? 70 : null,
      child: InkWell(
        onTap: () {
          feedBack();
          if (isLive) {
            PageUtils.toLiveRoom(item.roomId);
          } else {
            _onSelect(item);
          }
        },
        // onDoubleTap: isLive ? () => _onSelect(data) : null,
        onLongPress: !isAll ? toMemberPage : null,
        onSecondaryTap: !isAll && !PlatformUtils.isMobile ? toMemberPage : null,
        child: Opacity(
          opacity: isCurrent ? 1 : 0.6,
          child: Column(
            spacing: 4,
            mainAxisSize: .min,
            mainAxisAlignment: .center,
            children: [
              avatar,
              Padding(
                padding: const .symmetric(horizontal: 4),
                child: Text(
                  isTop ? '${remarkedName(item.mid, item.uname!)}\n' : remarkedName(item.mid, item.uname!),
                  maxLines: 2,
                  textAlign: .center,
                  style: TextStyle(
                    color: currentMid == item.mid
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                    height: 1.1,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
