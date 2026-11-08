import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/extra_hittest_stack.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models_new/live/live_superchat/item.dart';
import 'package:PiliPlus/pages/live_room/superchat/superchat_card.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

const kFullScreenSCWidth = 255.0;

class FullScreenScSize extends StatefulWidget {
  const FullScreenScSize({super.key});

  @override
  State<FullScreenScSize> createState() => _FullScreenScSizeState();
}

class _FullScreenScSizeState extends State<FullScreenScSize> {
  double _width = Pref.fullScreenSCWidth;
  double _opacity = Pref.fullScreenSCOpacity;
  double _scale = Pref.fullScreenSCScale;
  final _randomSC = SuperChatItem.random;
  late EdgeInsets _padding;
  late ColorScheme _colorScheme;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      landscapeLeftMode();
    } else if (Platform.isIOS) {
      landscapeRightMode();
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isMobile) {
      if (Pref.horizontalScreen) {
        fullMode();
      } else {
        portraitUpMode();
      }
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final padding = MediaQuery.viewPaddingOf(context);
    _padding = .only(
      right: padding.right + 17,
      left: padding.left + 25,
      bottom: padding.bottom + 25,
    );
    _colorScheme = ColorScheme.of(context);
  }

  void _onReset() {
    _width = kFullScreenSCWidth;
    _opacity = 1.0;
    _scale = 1.0;
    GStorage.setting.deleteAll({
      SettingBoxKey.fullScreenSCWidth,
      SettingBoxKey.fullScreenSCOpacity,
      SettingBoxKey.fullScreenSCScale,
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('全屏 SuperChat 设置'),
        actions: [
          TextButton(onPressed: _onReset, child: const Text('重置')),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: Padding(padding: _padding, child: _buildBody)),
          _sliders,
        ],
      ),
    );
  }

  Widget get _sliders {
    return Padding(
      padding: const EdgeInsets.fromLTRB(25, 0, 25, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('不透明度: ${_opacity.toStringAsFixed(2)}'),
              ),
              Expanded(
                flex: 7,
                child: Slider(
                  min: 0.1,
                  max: 1.0,
                  value: _opacity,
                  onChanged: (value) => setState(() => _opacity = value),
                  onChangeEnd: (value) => GStorage.setting.put(
                    SettingBoxKey.fullScreenSCOpacity,
                    value,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('缩放: ${_scale.toStringAsFixed(2)}'),
              ),
              Expanded(
                flex: 7,
                child: Slider(
                  min: 0.1,
                  max: 1.0,
                  value: _scale,
                  onChanged: (value) => setState(() => _scale = value),
                  onChangeEnd: (value) => GStorage.setting.put(
                    SettingBoxKey.fullScreenSCScale,
                    value,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget get _buildBody {
    return Align(
      alignment: .bottomLeft,
      child: ExtraHitTestStack(
        clipBehavior: .none,
        children: [
          SizedBox(
            width: _width,
            child: IgnorePointer(
              child: Opacity(
                opacity: _opacity,
                child: Transform.scale(
                  scale: _scale,
                  alignment: .bottomLeft,
                  child: SuperChatCard(
                    item: _randomSC,
                    persistentSC: true,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: -17,
            width: 34,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeRight,
              child: GestureDetector(
                behavior: .opaque,
                onHorizontalDragUpdate: _onHorizontalDragUpdate,
                onHorizontalDragEnd: _onHorizontalDragEnd,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: .circle,
                    color: _colorScheme.secondaryContainer.withValues(
                      alpha: .8,
                    ),
                  ),
                  child: Icon(
                    size: 18,
                    CustomIcons.open_in_full_rotate_45,
                    color: _colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    _width = math.max(25.0, _width + details.delta.dx);
    setState(() {});
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    GStorage.setting.put(SettingBoxKey.fullScreenSCWidth, _width);
  }
}
