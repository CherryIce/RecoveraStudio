import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recovera_studio/app/recovery_app.dart';
import 'package:recovera_studio/features/recovery/domain/recovery_candidate.dart';
import 'package:recovera_studio/features/recovery/domain/storage_device.dart';
import 'package:recovera_studio/features/recovery/presentation/recovery_controller.dart';

void main() {
  testWidgets('shows the recovery workbench initial state', (tester) async {
    await tester.pumpWidget(const RecoveryApp(autoInitialize: false));

    expect(find.text('数据恢复工作台'), findsOneWidget);
    expect(find.text('选择整块磁盘'), findsOneWidget);
    expect(find.text('高级：打开已有磁盘镜像'), findsOneWidget);
    expect(find.text('开始整盘扫描'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('扫描结果将在这里显示'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('扫描结果将在这里显示'), findsOneWidget);
  });

  testWidgets('shows animated scan state with speed and remaining time', (
    tester,
  ) async {
    final controller = RecoveryController();
    controller.phase = RecoveryPhase.scanning;
    controller.progress = const ScanProgress(
      bytesScanned: 1024 * 1024,
      totalBytes: 10 * 1024 * 1024,
      foundCount: 3,
      elapsed: Duration(seconds: 1),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      RecoveryApp(recoveryController: controller, autoInitialize: false),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('扫描中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('速度 1.0 MB/s'), findsOneWidget);
    expect(find.textContaining('预计剩余 9 秒'), findsOneWidget);
    expect(find.textContaining('已发现 3 个候选文件'), findsOneWidget);
  });

  testWidgets('lazily builds a very large scan result set', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final controller = RecoveryController();
    final candidates = List<RecoveryCandidate>.generate(
      100000,
      (index) => RecoveryCandidate(
        id: 'jpeg-$index',
        sourcePath: 'large-scan.img',
        offset: index * 4096,
        length: 2048,
        kind: RecoveryFileKind.jpeg,
        confidence: RecoveryConfidence.high,
      ),
      growable: false,
    );
    controller.phase = RecoveryPhase.completed;
    controller.progress = const ScanProgress(
      bytesScanned: 500 * 1000 * 1000 * 1000,
      totalBytes: 500 * 1000 * 1000 * 1000,
      foundCount: 100000,
      elapsed: Duration(minutes: 30),
    );
    controller.summary = ScanSummary(
      candidates: candidates,
      bytesScanned: 500 * 1000 * 1000 * 1000,
      elapsed: const Duration(minutes: 30),
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      controller.dispose();
    });

    await tester.pumpWidget(
      RecoveryApp(recoveryController: controller, autoInitialize: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('全部恢复 (100000)'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(candidates.first.suggestedName),
      500,
      scrollable: find.byType(Scrollable).last,
    );

    final builtCandidateNames = find.byWidgetPredicate(
      (widget) =>
          widget is Text && (widget.data?.startsWith('recovered_') ?? false),
    );
    expect(builtCandidateNames, findsWidgets);
    expect(builtCandidateNames.evaluate().length, lessThan(50));
    expect(find.text(candidates.last.suggestedName), findsNothing);
  });

  testWidgets(
    'keeps the initial workbench usable on a narrow large-text view',
    (tester) async {
      final controller = RecoveryController();
      const device = StorageDevice(
        id: 'disk9',
        displayName: '测试移动硬盘',
        devicePath: '/dev/rdisk9',
        size: 64 * 1000 * 1000 * 1000,
        isInternal: false,
        isSolidState: false,
        busProtocol: 'USB',
        canReadDirectly: true,
      );
      controller.devices = const <StorageDevice>[device];
      await controller.selectDevice(device);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        controller.dispose();
      });

      await tester.pumpWidget(
        RecoveryApp(recoveryController: controller, autoInitialize: false),
      );
      await tester.pump();

      expect(find.text('数据恢复工作台'), findsOneWidget);
      expect(find.text('测试移动硬盘'), findsOneWidget);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows self-use authorization for the running macOS system disk',
    (tester) async {
      final controller = RecoveryController();
      const device = StorageDevice(
        id: 'disk0',
        displayName: 'APPLE SSD',
        devicePath: '/dev/rdisk0',
        size: 500 * 1000 * 1000 * 1000,
        isInternal: true,
        isSolidState: true,
        busProtocol: 'Apple Fabric',
        canReadDirectly: false,
        isSystemDisk: true,
      );
      controller.devices = const <StorageDevice>[device];
      await controller.selectDevice(device);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        RecoveryApp(recoveryController: controller, autoInitialize: false),
      );

      expect(controller.needsAuthorization, isTrue);
      expect(find.text('打开完全磁盘访问设置'), findsOneWidget);
      expect(find.text('尝试只读授权'), findsOneWidget);
      expect(find.textContaining('自用实验模式'), findsOneWidget);

      await tester.tap(find.text('尝试只读授权'));
      await tester.pumpAndSettle();
      expect(find.text('尝试扫描当前启动盘？'), findsOneWidget);
      expect(find.text('我已了解，继续'), findsOneWidget);
    },
  );
}
