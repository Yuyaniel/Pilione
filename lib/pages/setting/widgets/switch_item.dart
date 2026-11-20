import 'dart:async';

import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/flutter/list_tile.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class SetSwitchItem extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String setKey;
  final bool defaultVal;
  final ValueChanged<bool>? onChanged;
  final bool needReboot;
  final Widget? leading;
  final void Function(BuildContext context)? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? titleStyle;
  final bool isSplit;

  /// 该设置键为 true 时本项置灰、不可切换。
  ///
  /// 用于「A 打开后 B 已失效」这类互相覆盖的开关：B 项自己订阅这个键的
  /// 变化并重建，不必让整个设置页跟着刷新。
  final String? disabledBy;

  const SetSwitchItem({
    super.key,
    required this.title,
    this.subtitle,
    required this.setKey,
    this.defaultVal = false,
    this.onChanged,
    this.needReboot = false,
    this.leading,
    this.onTap,
    this.contentPadding,
    this.titleStyle,
    this.isSplit = false,
    this.disabledBy,
  });

  @override
  State<SetSwitchItem> createState() => _SetSwitchItemState();
}

class _SetSwitchItemState extends State<SetSwitchItem> {
  late bool val;
  late bool disabled;
  StreamSubscription<BoxEvent>? _disabledSub;

  void _setVal() {
    val = GStorage.setting.get(widget.setKey, defaultValue: widget.defaultVal);
    _setDisabled();
  }

  void _setDisabled() {
    final key = widget.disabledBy;
    // Box.get 返回 dynamic：显式与 true 比较，避免导入配置写入非 bool 值时
    // `true && <非bool>` 在运行时抛类型错
    disabled =
        key != null &&
        GStorage.setting.get(key, defaultValue: false) == true;
  }

  @override
  void didUpdateWidget(SetSwitchItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.setKey != widget.setKey) {
      _setVal();
    }
    if (oldWidget.disabledBy != widget.disabledBy) {
      _listenDisabled();
      _setDisabled();
    }
  }

  /// 订阅「压制本项的那个开关」，它一变就重建，不必让整个设置页刷新
  void _listenDisabled() {
    _disabledSub?.cancel();
    _disabledSub = null;
    final key = widget.disabledBy;
    if (key == null) return;
    _disabledSub = GStorage.setting.watch(key: key).listen((_) {
      if (!mounted) return;
      setState(_setDisabled);
    });
  }

  @override
  void initState() {
    super.initState();
    _setVal();
    _listenDisabled();
  }

  @override
  void dispose() {
    _disabledSub?.cancel();
    super.dispose();
  }

  Future<void> switchChange([bool? value]) async {
    // 被别的开关压制时不可切换（Switch 已置 null，这里兜住 ListTile 点击）
    if (disabled) return;

    val = value ?? !val;

    if (val && widget.setKey == SettingBoxKey.badCertificateCallback) {
      val = await showConfirmDialog(
        context: context,
        title: const Text('确定禁用 SSL 证书验证？'),
        content: const Text('禁用容易受到中间人攻击'),
      );
      if (!val) return;
    }

    await GStorage.setting.put(widget.setKey, val);

    widget.onChanged?.call(val);
    if (widget.needReboot) SmartDialog.showToast('重启生效');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle =
        widget.titleStyle ??
        theme.textTheme.titleMedium!.copyWith(
          color: disabled || (widget.onTap != null && !val)
              ? theme.colorScheme.outline
              : null,
        );
    final subTitleStyle = theme.textTheme.labelMedium!.copyWith(
      color: disabled
          ? theme.colorScheme.outline.withValues(alpha: .5)
          : theme.colorScheme.outline,
    );

    final switchBtn = Transform.scale(
      scale: 0.8,
      alignment: .centerRight,
      child: Switch(
        // 被压制时显示「关」，与 subtitle「暂不生效」一致；
        // 不改存储值：关掉压制项后用户原来的设置会自动恢复
        value: disabled ? false : val,
        onChanged: disabled ? null : switchChange,
      ),
    );

    Widget child(Widget? trailing) => ListTile(
      contentPadding: widget.contentPadding,
      enabled: disabled ? false : (widget.onTap == null ? true : val),
      onTap: disabled
          ? null
          : (widget.onTap == null ? switchChange : () => widget.onTap!(context)),
      title: Text(widget.title, style: titleStyle),
      subtitle: widget.subtitle != null
          ? Text(widget.subtitle!, style: subTitleStyle)
          : null,
      leading: widget.leading,
      trailing: trailing,
    );

    if (widget.isSplit) {
      return Row(
        children: [
          Expanded(child: child(null)),
          SizedBox(
            height: 25,
            child: VerticalDivider(
              width: 1,
              color: theme.colorScheme.outline.withValues(alpha: .3),
            ),
          ),
          Padding(
            padding: const .only(left: 4, right: 24),
            child: switchBtn,
          ),
        ],
      );
    }

    return child(switchBtn);
  }
}
