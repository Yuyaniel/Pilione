import 'package:PiliPlus/models/common/enum_with_label.dart';

enum RcmdMode with EnumWithLabel {
  app('App端推荐'),
  web('Web端推荐'),
  merged('App+Web 合并'),
  desktop('桌面端 / PC'),
  ;

  @override
  final String label;
  const RcmdMode(this.label);
}
