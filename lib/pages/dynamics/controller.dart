import 'dart:async';

import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' show TabController;

class DynamicsController
    extends CommonDataController<FollowUpModel, FollowUpModel>
    with GetSingleTickerProviderStateMixin, AccountMixin {
  late final TabController tabController;

  /// 本次会话的标签列表：只在控制器存活期间确定一次。
  /// 这样 TabController.length 与 TabBar / TabBarView 的项数永远一致，
  /// 运行中切换「隐藏番剧/专栏」不会造成长度不匹配，改动在重启后生效。
  late final List<DynamicsTabType> visibleTabs = Pref.visibleDynamicsTabs;

  final Set<int> tempBannedList = <int>{};

  String? _offset;
  late int _page = 1;
  late bool _isEnd = false;
  Set<UpItem>? _cacheUpList;
  late int hostMid = -1, currentMid = -1;
  late bool showLiveUp = Pref.expandDynLivePanel;
  late final _showAllUp = Pref.dynamicsShowAllFollowedUp;

  final upPanelPosition = Pref.upPanelPosition;

  @override
  final AccountService accountService = Get.find<AccountService>();

  DynamicsTabController? get controller {
    try {
      return Get.find<DynamicsTabController>(
        tag: visibleTabs[tabController.index].name,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void onInit() {
    super.onInit();
    final defaultIndex = visibleTabs.indexOf(Pref.defaultDynamicType);
    tabController = TabController(
      vsync: this,
      length: visibleTabs.length,
      // 默认标签可能被隐藏，这里换成可见列表里的下标
      initialIndex: defaultIndex < 0 ? 0 : defaultIndex,
    );
    queryData();
  }

  void _jumpToTab(int mid) {
    if (mid == -1) {
      tabController.index = 0;
      return;
    }
    // UP 标签的位置随「隐藏番剧/专栏」变化，不能写死索引
    final upIndex = visibleTabs.indexOf(DynamicsTabType.up);
    tabController.index = upIndex < 0 ? 0 : upIndex;
  }

  void onSelectUp(int mid) {
    if (currentMid == mid) {
      _jumpToTab(mid);
      if (mid == -1) {
        singleRefresh();
      }
      controller?.onReload();
      return;
    }

    if (mid != -1) {
      hostMid = mid;
      try {
        Get.find<DynamicsTabController>(
          tag: DynamicsTabType.up.name,
        ).onReload();
      } catch (_) {}
    }

    currentMid = mid;
    _jumpToTab(mid);
  }

  Future<void> singleRefresh() {
    if (_showAllUp) {
      _page = 1;
      _cacheUpList = null;
    }
    _offset = null;
    _isEnd = false;
    return super.onRefresh();
  }

  @override
  Future<void> onRefresh() {
    return _showRefreshFor(controller);
  }

  @override
  Future<void> showRefresh() =>
      _showRefreshFor(controller);

  Future<void> _showRefreshFor(DynamicsTabController? ctr) {
    final refreshState = ctr?.refreshKey.currentState;
    if (refreshState != null) {
      return ctr!.showRefresh();
    }
    return Future.wait([
      singleRefresh(),
      if (ctr case final tabCtr?) tabCtr.onRefresh(),
    ]);
  }

  @override
  Future<void> animateToTop() {
    return Future.wait([
      if (controller case final ctr?) ctr.animateToTop(),
      scrollController.animToTop(),
    ]);
  }

  @override
  void toTopOrRefresh() {
    final ctr = controller;
    if (ctr?.scrollController.hasClients == true) {
      if (ctr!.scrollController.position.pixels == 0) {
        if (scrollController.hasClients &&
            scrollController.position.pixels != 0) {
          scrollController.animToTop();
        }
        EasyThrottle.throttle(
          topOrRefreshThrottleKey,
          const Duration(milliseconds: 500),
          showRefresh,
        );
      } else {
        animateToTop();
      }
    } else {
      super.toTopOrRefresh();
    }
  }

  @override
  void toTopAndRefresh() {
    EasyThrottle.throttle(
      topAndRefreshThrottleKey,
      const Duration(milliseconds: 500),
      () async {
        final ctr = controller;
        final shouldScrollChild =
            ctr?.scrollController.hasClients == true &&
            ctr!.scrollController.position.pixels != 0;
        final shouldScrollParent =
            scrollController.hasClients &&
            scrollController.position.pixels != 0;
        if (shouldScrollChild || shouldScrollParent) {
          await animateToTop();
        }
        await _showRefreshFor(ctr);
      },
    );
  }

  @override
  void onClose() {
    tabController.dispose();
    super.onClose();
  }

  @override
  void onChangeAccount(bool isLogin) => onReload();

  @override
  Future<LoadingState<FollowUpModel>> customGetData() {
    if (_offset == null) {
      return DynamicsHttp.followUp();
    }
    if (_showAllUp) {
      return DynamicsHttp.followings(
        vmid: Accounts.main.mid,
        pn: _page,
        orderType: 'attention',
        ps: 50,
      );
    } else {
      return DynamicsHttp.dynUpList(_offset);
    }
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!isRefresh && _isEnd) return Future.value();
    return super.queryData(isRefresh);
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<FollowUpModel> response) {
    final res = response.response;

    if (_showAllUp) {
      if (res.upList?.isNotEmpty != true) {
        _isEnd = true;
      }
    } else {
      _offset = res.offset;
      if (res.hasMore != true || _offset.isNullOrEmpty) {
        _isEnd = true;
      }
    }

    if (isRefresh) {
      if (_showAllUp) {
        _offset = '';
        _cacheUpList = res.upList?.toSet();
      }
      loadingState.value = response;
    } else {
      if (_showAllUp) {
        _page++;
      }

      if (res.upList case final upList? when upList.isNotEmpty) {
        if (_showAllUp && _cacheUpList != null) {
          upList.removeWhere(_cacheUpList!.contains);
        }
        loadingState
          ..value.data.addAllUpList(upList)
          ..refresh();
      }
    }

    return true;
  }
}
