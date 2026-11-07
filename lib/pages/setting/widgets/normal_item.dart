import 'package:PiliPlus/common/widgets/flutter/list_tile.dart';
import 'package:get/get.dart' show Obx;
import 'package:material_ui/material_ui.dart' hide ListTile;

class NormalItem extends StatefulWidget {
  final String? title;
  final ValueGetter<String>? getTitle;
  final String? subtitle;
  final ValueGetter<String>? getSubtitle;
  final Widget? leading;
  final Widget Function(ThemeData theme)? getTrailing;
  final void Function(BuildContext context, VoidCallback setState)? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? titleStyle;

  /// getSubtitle 内部读取 Rx 时置 true，用 Obx 包一层随数据实时刷新
  final bool reactive;

  /// subtitle 需要两行时置 true（ListTile 需显式声明）
  final bool? isThreeLine;

  /// subtitle 最大行数；null 表示不限制（保持原有行为）
  final int? subtitleMaxLines;

  const NormalItem({
    this.title,
    this.getTitle,
    this.subtitle,
    this.getSubtitle,
    this.leading,
    this.getTrailing,
    this.onTap,
    this.contentPadding,
    this.titleStyle,
    this.reactive = false,
    this.isThreeLine,
    this.subtitleMaxLines,
    super.key,
  }) : assert(title != null || getTitle != null);

  @override
  State<NormalItem> createState() => _NormalItemState();
}

class _NormalItemState extends State<NormalItem> {
  @override
  Widget build(BuildContext context) {
    late final theme = Theme.of(context);
    final subtitleStyle = theme.textTheme.labelMedium!.copyWith(
      color: theme.colorScheme.outline,
    );
    Widget subtitleText(String text) => Text(
      text,
      style: subtitleStyle,
      maxLines: widget.subtitleMaxLines,
      overflow: widget.subtitleMaxLines == null ? null : TextOverflow.ellipsis,
    );
    Widget? subtitle;
    if (widget.subtitle case final text?) {
      subtitle = subtitleText(text);
    } else if (widget.getSubtitle case final getSubtitle?) {
      subtitle = widget.reactive
          ? Obx(() => subtitleText(getSubtitle()))
          : subtitleText(getSubtitle());
    }
    return ListTile(
      isThreeLine: widget.isThreeLine,
      contentPadding: widget.contentPadding,
      onTap: widget.onTap == null
          ? null
          : () => widget.onTap!(context, refresh),
      title: Text(
        widget.title ?? widget.getTitle!(),
        style: widget.titleStyle ?? theme.textTheme.titleMedium!,
      ),
      subtitle: subtitle,
      leading: widget.leading,
      trailing: widget.getTrailing?.call(theme),
    );
  }

  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }
}
