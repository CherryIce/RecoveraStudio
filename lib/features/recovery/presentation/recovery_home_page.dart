import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../domain/recovery_candidate.dart';
import '../domain/storage_device.dart';
import 'recovery_controller.dart';

class RecoveryHomePage extends StatefulWidget {
  const RecoveryHomePage({
    super.key,
    this.controller,
    this.autoInitialize = true,
  });

  final RecoveryController? controller;
  final bool autoInitialize;

  @override
  State<RecoveryHomePage> createState() => _RecoveryHomePageState();
}

class _RecoveryHomePageState extends State<RecoveryHomePage> {
  late final RecoveryController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? RecoveryController();
    _controller.addListener(_refresh);
    if (widget.autoInitialize) {
      unawaited(_controller.initialize());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickSource() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择磁盘镜像或原始数据文件',
        allowMultiple: false,
        withData: false,
        type: FileType.any,
      );
      final path = result?.files.single.path;
      if (path != null) {
        await _controller.selectImage(path);
      }
    } catch (error) {
      _showMessage('无法打开文件：$error', isError: true);
    }
  }

  Future<void> _authorizeSelectedDevice() async {
    if (_controller.selectedDevice?.isSystemDisk == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('尝试扫描当前启动盘？'),
          content: const Text(
            '这是自用实验模式。扫描本身不会写入源磁盘，但正在运行的 macOS '
            '仍会持续产生写入，可能覆盖误删数据。APFS 加密、SSD TRIM 与文件碎片也可能使原始扫描无法恢复文件。\n\n'
            '请先在“完全磁盘访问”中允许本应用并重启应用。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('我已了解，继续'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    await _controller.authorizeSelectedDevice();
    if (_controller.hasSource) {
      _showMessage('已获得整块磁盘的只读访问权限');
    }
  }

  Future<void> _recoverOne(RecoveryCandidate candidate) async {
    final destination = await _pickDestination();
    if (destination == null) {
      return;
    }
    try {
      final output = await _controller.recoverCandidate(candidate, destination);
      _showMessage('已安全恢复到 ${p.basename(output)}');
    } catch (error) {
      _showMessage('恢复失败：$error', isError: true);
    }
  }

  Future<void> _recoverAll() async {
    final destination = await _pickDestination();
    if (destination == null) {
      return;
    }
    try {
      final outputs = await _controller.recoverAll(destination);
      _showMessage('已恢复 ${outputs.length} 个文件，源数据未被修改');
    } catch (error) {
      _showMessage('批量恢复失败：$error', isError: true);
    }
  }

  Future<String?> _pickDestination() =>
      FilePicker.getDirectoryPath(dialogTitle: '选择恢复文件的保存目录');

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.errorContainer
            : const Color(0xFF153E37),
      ),
    );
  }

  Future<void> _showPreview(RecoveryCandidate candidate) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0E1A1E),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        candidate.suggestedName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<Uint8List>(
                    future: _controller.preview(candidate),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError || snapshot.data == null) {
                        return Center(
                          child: Text('预览失败：${snapshot.error ?? '文件不完整'}'),
                        );
                      }
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ColoredBox(
                          color: const Color(0xFF050A0C),
                          child: Center(
                            child: Image.memory(
                              snapshot.data!,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      '文件签名存在，但图片结构可能已损坏，建议先恢复后使用专业修复工具。',
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 900;
          return Row(
            children: [
              if (desktop) const _DesktopSidebar(),
              Expanded(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.7, -0.9),
                      radius: 1.2,
                      colors: <Color>[Color(0xFF12302E), Color(0xFF071013)],
                    ),
                  ),
                  child: SafeArea(
                    child: _Workspace(
                      controller: _controller,
                      compact: !desktop,
                      onPickSource: _pickSource,
                      onAuthorizeDevice: _authorizeSelectedDevice,
                      onRefreshDevices: _controller.refreshDevices,
                      onRecoverOne: _recoverOne,
                      onRecoverAll: _recoverAll,
                      onPreview: _showPreview,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 236,
      color: const Color(0xFF091316),
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Brand(),
          const SizedBox(height: 38),
          _NavigationItem(
            icon: Icons.manage_search_rounded,
            label: '数据恢复',
            selected: true,
            onTap: () {},
          ),
          _NavigationItem(
            icon: Icons.history_rounded,
            label: '扫描记录',
            selected: false,
            onTap: () {},
          ),
          _NavigationItem(
            icon: Icons.shield_outlined,
            label: '隐私与安全',
            selected: false,
            onTap: () {},
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF101E22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF20353B)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 17,
                      color: Color(0xFF2DD4B5),
                    ),
                    SizedBox(width: 7),
                    Text('本地处理', style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  '扫描和恢复均在设备本地完成，不上传文件内容。',
                  style: TextStyle(
                    color: Color(0xFF8FA4AA),
                    height: 1.45,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'MVP 0.2.0 · 整盘只读模式',
            style: TextStyle(color: Color(0xFF61767C), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _LogoMark(),
        SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recovera',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              Text(
                'DATA RECOVERY STUDIO',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Color(0xFF6F858B),
                  fontSize: 8,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF2DD4B5), Color(0xFF168A7C)],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Color(0x332DD4B5), blurRadius: 18, spreadRadius: 1),
        ],
      ),
      child: const Icon(Icons.restore_page_rounded, color: Color(0xFF06211D)),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? const Color(0xFF16312E) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected
                      ? const Color(0xFF55E2C8)
                      : const Color(0xFF7F949A),
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFFA3B3B7),
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({
    required this.controller,
    required this.compact,
    required this.onPickSource,
    required this.onAuthorizeDevice,
    required this.onRefreshDevices,
    required this.onRecoverOne,
    required this.onRecoverAll,
    required this.onPreview,
  });

  final RecoveryController controller;
  final bool compact;
  final VoidCallback onPickSource;
  final VoidCallback onAuthorizeDevice;
  final VoidCallback onRefreshDevices;
  final ValueChanged<RecoveryCandidate> onRecoverOne;
  final VoidCallback onRecoverAll;
  final ValueChanged<RecoveryCandidate> onPreview;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = compact ? 18.0 : 36.0;
    final candidates =
        controller.summary?.candidates ?? const <RecoveryCandidate>[];

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            24,
            horizontalPadding,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: _WorkspaceWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (compact) ...[const _Brand(), const SizedBox(height: 28)],
                  const _PageHeader(),
                  const SizedBox(height: 24),
                  _SourceAndScope(
                    controller: controller,
                    onPickSource: onPickSource,
                    onAuthorizeDevice: onAuthorizeDevice,
                    onRefreshDevices: onRefreshDevices,
                  ),
                  const SizedBox(height: 18),
                  _ScanPanel(controller: controller),
                  const SizedBox(height: 24),
                  _ResultsHeader(
                    candidateCount: candidates.length,
                    onRecoverAll: onRecoverAll,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (candidates.isEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              14,
              horizontalPadding,
              40,
            ),
            sliver: SliverToBoxAdapter(
              child: _WorkspaceWidth(
                child: _EmptyResults(phase: controller.phase),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              14,
              horizontalPadding,
              40,
            ),
            sliver: SliverList.builder(
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final candidate = candidates[index];
                return _WorkspaceWidth(
                  child: _LazyResultItem(
                    candidate: candidate,
                    recoveredPath: controller.recoveredPaths[candidate.id],
                    first: index == 0,
                    last: index == candidates.length - 1,
                    onRecover: () => onRecoverOne(candidate),
                    onPreview: candidate.canPreview
                        ? () => onPreview(candidate)
                        : null,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _WorkspaceWidth extends StatelessWidget {
  const _WorkspaceWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '数据恢复工作台',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '选择误删数据所在的整块磁盘或移动设备，不需要知道原文件夹和文件名。',
          style: TextStyle(color: Color(0xFF9BAEB3), height: 1.5),
        ),
      ],
    );
  }
}

class _SourceAndScope extends StatelessWidget {
  const _SourceAndScope({
    required this.controller,
    required this.onPickSource,
    required this.onAuthorizeDevice,
    required this.onRefreshDevices,
  });

  final RecoveryController controller;
  final VoidCallback onPickSource;
  final VoidCallback onAuthorizeDevice;
  final VoidCallback onRefreshDevices;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final source = Expanded(
          flex: 3,
          child: _SourceCard(
            controller: controller,
            onPickSource: onPickSource,
            onAuthorizeDevice: onAuthorizeDevice,
            onRefreshDevices: onRefreshDevices,
          ),
        );
        const scope = Expanded(flex: 2, child: _ScopeCard());
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [source, const SizedBox(width: 16), scope],
          );
        }
        return Column(
          children: [
            _SourceCard(
              controller: controller,
              onPickSource: onPickSource,
              onAuthorizeDevice: onAuthorizeDevice,
              onRefreshDevices: onRefreshDevices,
            ),
            const SizedBox(height: 16),
            const _ScopeCard(),
          ],
        );
      },
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.controller,
    required this.onPickSource,
    required this.onAuthorizeDevice,
    required this.onRefreshDevices,
  });

  final RecoveryController controller;
  final VoidCallback onPickSource;
  final VoidCallback onAuthorizeDevice;
  final VoidCallback onRefreshDevices;

  @override
  Widget build(BuildContext context) {
    final selectedDevice = controller.selectedDevice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: _SectionEyebrow(
                    icon: Icons.storage_rounded,
                    label: '选择整块磁盘',
                  ),
                ),
                IconButton(
                  tooltip: '重新检测磁盘',
                  onPressed:
                      controller.isLoadingDevices || controller.isScanning
                      ? null
                      : onRefreshDevices,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '不用选择被删文件，也不用知道原来的文件夹。程序会读取整块设备，查找文件系统已不再列出的数据片段。',
              style: TextStyle(
                color: Color(0xFF8FA3A9),
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            if (controller.isLoadingDevices)
              const LinearProgressIndicator(minHeight: 3)
            else if (controller.deviceError != null)
              _InlineAlert(
                icon: Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
                message: controller.deviceError!,
              )
            else if (controller.devices.isEmpty)
              const _InlineAlert(
                icon: Icons.usb_off_outlined,
                color: Color(0xFFFFBD59),
                message: '没有检测到可扫描的物理磁盘，请连接 U 盘、SD 卡或移动硬盘后刷新。',
              )
            else
              ...controller.devices.map(
                (device) => Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: _DeviceOption(
                    device: device,
                    selected:
                        controller.sourceKind ==
                            RecoverySourceKind.physicalDisk &&
                        selectedDevice?.id == device.id,
                    onTap: controller.isScanning
                        ? null
                        : () => controller.selectDevice(device),
                  ),
                ),
              ),
            if (controller.sourceKind == RecoverySourceKind.diskImage) ...[
              _ImageSourceOption(
                label: controller.sourceLabel ?? '磁盘镜像',
                size: controller.sourceSize,
              ),
              const SizedBox(height: 10),
            ],
            if (controller.isSystemDiskSelected &&
                controller.needsAuthorization) ...[
              const SizedBox(height: 5),
              const _InlineAlert(
                icon: Icons.science_outlined,
                color: Color(0xFFFFBD59),
                message: '自用实验模式：可尝试只读扫描当前启动盘。请先允许“完全磁盘访问”并重启应用；扫描期间尽量停止使用电脑。',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.openFullDiskAccessSettings,
                    icon: const Icon(Icons.settings_outlined, size: 19),
                    label: const Text('打开完全磁盘访问设置'),
                  ),
                  FilledButton.icon(
                    onPressed: controller.isAuthorizing
                        ? null
                        : onAuthorizeDevice,
                    icon: controller.isAuthorizing
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_rounded, size: 19),
                    label: Text(
                      controller.isAuthorizing ? '正在请求权限…' : '尝试只读授权',
                    ),
                  ),
                ],
              ),
            ] else if (controller.needsAuthorization) ...[
              const SizedBox(height: 5),
              _InlineAlert(
                icon: Icons.admin_panel_settings_outlined,
                color: const Color(0xFF55DEC6),
                message: '读取整块磁盘需要 macOS 管理员只读授权。程序不会卸载、格式化或写入源磁盘。',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: controller.isAuthorizing ? null : onAuthorizeDevice,
                icon: controller.isAuthorizing
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_open_rounded, size: 19),
                label: Text(controller.isAuthorizing ? '正在请求权限…' : '授权只读扫描'),
              ),
            ] else if (controller.sourceKind ==
                    RecoverySourceKind.physicalDisk &&
                controller.hasSource) ...[
              const SizedBox(height: 5),
              const _InlineAlert(
                icon: Icons.verified_user_outlined,
                color: Color(0xFF2DD4B5),
                message: '整块设备已准备好，只读扫描不会要求你选择已经删除的文件。',
              ),
            ],
            if (selectedDevice?.isInternal == true &&
                controller.sourceKind == RecoverySourceKind.physicalDisk) ...[
              const SizedBox(height: 10),
              const _InlineAlert(
                icon: Icons.warning_amber_rounded,
                color: Color(0xFFFFBD59),
                message:
                    '内部 SSD 上的 APFS 加密和 TRIM 可能已使部分数据无法恢复。从外置系统启动后再扫描，仍然是更安全的方式。',
              ),
            ],
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: controller.isScanning ? null : onPickSource,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('高级：打开已有磁盘镜像'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceOption extends StatelessWidget {
  const _DeviceOption({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  final StorageDevice device;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? const Color(0xFF2DD4B5) : const Color(0xFF60777D);
    return Material(
      color: selected ? const Color(0xFF132A28) : const Color(0xFF0A1417),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? const Color(0xFF2C8E7D)
                  : const Color(0xFF23363B),
            ),
          ),
          child: Row(
            children: [
              Icon(
                device.isInternal
                    ? Icons.laptop_mac_rounded
                    : Icons.usb_rounded,
                color: accent,
                size: 25,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatBytes(device.size)} · ${device.locationLabel} · ${device.busProtocol}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF80949A),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: accent,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageSourceOption extends StatelessWidget {
  const _ImageSourceOption({required this.label, required this.size});

  final String label;
  final int size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF132A28),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2C8E7D)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.insert_drive_file_outlined,
            color: Color(0xFF2DD4B5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${formatBytes(size)} · 高级镜像模式',
                  style: const TextStyle(
                    color: Color(0xFF80949A),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.radio_button_checked,
            color: Color(0xFF2DD4B5),
            size: 20,
          ),
        ],
      ),
    );
  }
}

class _ScopeCard extends StatelessWidget {
  const _ScopeCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionEyebrow(
              icon: Icons.filter_alt_outlined,
              label: '当前识别范围',
            ),
            const SizedBox(height: 17),
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _FormatChip(label: 'JPEG', color: Color(0xFF3DC6FF)),
                _FormatChip(label: 'PNG', color: Color(0xFF8077FF)),
                _FormatChip(label: 'PDF', color: Color(0xFFFF716B)),
                _FormatChip(label: 'ZIP', color: Color(0xFFFFBD59)),
                _FormatChip(label: 'DOCX', color: Color(0xFF4D8DFF)),
                _FormatChip(label: 'XLSX', color: Color(0xFF32C985)),
                _FormatChip(label: 'PPTX', color: Color(0xFFFF875C)),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '当前已支持整盘只读文件签名扫描。NTFS/APFS 目录元数据解析仍在下一阶段，因此暂时不能恢复原文件名和原目录。',
              style: TextStyle(
                color: Color(0xFF80949A),
                height: 1.45,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionEyebrow extends StatelessWidget {
  const _SectionEyebrow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF55DEC6)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({required this.controller});

  final RecoveryController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.progress;
    final fraction = progress?.fraction.clamp(0.0, 1.0) ?? 0.0;
    final scanning = controller.isScanning;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: _SectionEyebrow(
                    icon: Icons.radar_rounded,
                    label: '深度扫描',
                  ),
                ),
                if (scanning) const _ScanningPill(),
                if (controller.phase == RecoveryPhase.completed)
                  const _StatusPill(label: '扫描完成', color: Color(0xFF2DD4B5)),
                if (controller.phase == RecoveryPhase.cancelled)
                  const _StatusPill(label: '已取消', color: Color(0xFFFFBD59)),
              ],
            ),
            const SizedBox(height: 16),
            if (scanning || progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: fraction),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOut,
                  builder: (context, value, child) {
                    return LinearProgressIndicator(
                      value: value,
                      minHeight: 8,
                      backgroundColor: const Color(0xFF17262A),
                      color: const Color(0xFF2DD4B5),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      scanning
                          ? '已扫描 ${formatBytes(progress?.bytesScanned ?? 0)} / ${formatBytes(progress?.totalBytes ?? 0)}'
                          : '共扫描 ${formatBytes(controller.summary?.bytesScanned ?? progress?.bytesScanned ?? 0)}',
                      style: const TextStyle(
                        color: Color(0xFF8FA3A9),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    '${(fraction * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      color: Color(0xFFB5C6CA),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (scanning && (progress?.bytesPerSecond ?? 0) > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '速度 ${formatBytes(progress!.bytesPerSecond.round())}/s'
                  '${progress.estimatedRemaining == null ? '' : '  ·  预计剩余 ${formatDuration(progress.estimatedRemaining!)}'}',
                  style: const TextStyle(
                    color: Color(0xFF6F878D),
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
            if (controller.errorMessage != null) ...[
              _InlineAlert(
                icon: Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
                message: controller.errorMessage!,
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    scanning
                        ? '正在查找文件起止签名，已发现 ${progress?.foundCount ?? 0} 个候选文件。'
                        : '扫描过程只读取源文件，不会对镜像或原始介质执行写操作。',
                    style: const TextStyle(
                      color: Color(0xFFA4B5BA),
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                if (scanning)
                  OutlinedButton.icon(
                    onPressed: controller.cancelScan,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('停止'),
                  )
                else
                  FilledButton.icon(
                    onPressed: controller.hasSource
                        ? controller.startScan
                        : null,
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('开始整盘扫描'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({
    required this.candidateCount,
    required this.onRecoverAll,
  });

  final int candidateCount;
  final VoidCallback onRecoverAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '发现的文件',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (candidateCount > 0)
          OutlinedButton.icon(
            onPressed: onRecoverAll,
            icon: const Icon(Icons.download_done_rounded, size: 18),
            label: Text('全部恢复 ($candidateCount)'),
          ),
      ],
    );
  }
}

class _LazyResultItem extends StatelessWidget {
  const _LazyResultItem({
    required this.candidate,
    required this.recoveredPath,
    required this.first,
    required this.last,
    required this.onRecover,
    required this.onPreview,
  });

  final RecoveryCandidate candidate;
  final String? recoveredPath;
  final bool first;
  final bool last;
  final VoidCallback onRecover;
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    const borderSide = BorderSide(color: Color(0xFF203035));
    final borderRadius = BorderRadius.vertical(
      top: first ? const Radius.circular(18) : Radius.zero,
      bottom: last ? const Radius.circular(18) : Radius.zero,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1A1E),
        borderRadius: borderRadius,
        border: Border(
          left: borderSide,
          top: first ? borderSide : BorderSide.none,
          right: borderSide,
          bottom: borderSide,
        ),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: _ResultTile(
          candidate: candidate,
          recoveredPath: recoveredPath,
          onRecover: onRecover,
          onPreview: onPreview,
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.phase});

  final RecoveryPhase phase;

  @override
  Widget build(BuildContext context) {
    final completed = phase == RecoveryPhase.completed;
    return Card(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
          child: Column(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: const BoxDecoration(
                  color: Color(0xFF152529),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  completed
                      ? Icons.find_in_page_outlined
                      : Icons.manage_search_rounded,
                  color: const Color(0xFF668087),
                  size: 28,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                completed ? '没有发现完整的候选文件' : '扫描结果将在这里显示',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              Text(
                completed
                    ? '数据可能已被覆盖、加密，或暂不属于当前支持的文件格式。'
                    : '选择误删数据所在的整块磁盘并开始扫描。误删后应立即停止向源设备写入新数据。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF7F949A), height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.candidate,
    required this.recoveredPath,
    required this.onRecover,
    required this.onPreview,
  });

  final RecoveryCandidate candidate;
  final String? recoveredPath;
  final VoidCallback onRecover;
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final color = _kindColor(candidate.kind);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final leading = Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_kindIcon(candidate.kind), color: color, size: 22),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                candidate.suggestedName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children:
                    [
                          Text(candidate.typeLabel),
                          Text(formatBytes(candidate.length)),
                          Text(
                            '偏移 0x${candidate.offset.toRadixString(16).toUpperCase()}',
                          ),
                        ]
                        .map(
                          (text) => DefaultTextStyle.merge(
                            style: const TextStyle(
                              color: Color(0xFF7E9399),
                              fontSize: 11,
                            ),
                            child: text,
                          ),
                        )
                        .toList(),
              ),
            ],
          );
          final actions = Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusPill(
                label: candidate.confidence == RecoveryConfidence.high
                    ? '高完整度'
                    : '需验证',
                color: candidate.confidence == RecoveryConfidence.high
                    ? const Color(0xFF2DD4B5)
                    : const Color(0xFFFFBD59),
              ),
              if (onPreview != null)
                IconButton(
                  tooltip: '预览',
                  onPressed: onPreview,
                  icon: const Icon(Icons.visibility_outlined),
                ),
              if (recoveredPath == null)
                FilledButton.tonalIcon(
                  onPressed: onRecover,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('恢复'),
                )
              else
                const _StatusPill(label: '已恢复', color: Color(0xFF2DD4B5)),
            ],
          );

          if (constraints.maxWidth < 680) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    leading,
                    const SizedBox(width: 14),
                    Expanded(child: details),
                  ],
                ),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }

          return Row(
            children: [
              leading,
              const SizedBox(width: 14),
              Expanded(child: details),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ScanningPill extends StatelessWidget {
  const _ScanningPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF2DD4B5).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: Color(0xFF2DD4B5),
            ),
          ),
          SizedBox(width: 6),
          Text(
            '扫描中',
            style: TextStyle(
              color: Color(0xFF2DD4B5),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineAlert extends StatelessWidget {
  const _InlineAlert({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 9),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

IconData _kindIcon(RecoveryFileKind kind) => switch (kind) {
  RecoveryFileKind.jpeg || RecoveryFileKind.png => Icons.image_outlined,
  RecoveryFileKind.pdf => Icons.picture_as_pdf_outlined,
  RecoveryFileKind.zip => Icons.folder_zip_outlined,
  RecoveryFileKind.docx => Icons.description_outlined,
  RecoveryFileKind.xlsx => Icons.table_chart_outlined,
  RecoveryFileKind.pptx => Icons.slideshow_outlined,
};

Color _kindColor(RecoveryFileKind kind) => switch (kind) {
  RecoveryFileKind.jpeg => const Color(0xFF3DC6FF),
  RecoveryFileKind.png => const Color(0xFF8077FF),
  RecoveryFileKind.pdf => const Color(0xFFFF716B),
  RecoveryFileKind.zip => const Color(0xFFFFBD59),
  RecoveryFileKind.docx => const Color(0xFF4D8DFF),
  RecoveryFileKind.xlsx => const Color(0xFF32C985),
  RecoveryFileKind.pptx => const Color(0xFFFF875C),
};

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) {
    return '${kilobytes.toStringAsFixed(kilobytes >= 100 ? 0 : 1)} KB';
  }
  final megabytes = kilobytes / 1024;
  if (megabytes < 1024) {
    return '${megabytes.toStringAsFixed(megabytes >= 100 ? 0 : 1)} MB';
  }
  final gigabytes = megabytes / 1024;
  return '${gigabytes.toStringAsFixed(2)} GB';
}

String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) {
    return '$seconds 秒';
  }
  final minutes = duration.inMinutes;
  if (minutes < 60) {
    return '$minutes 分钟';
  }
  final hours = duration.inHours;
  final remainingMinutes = minutes.remainder(60);
  return remainingMinutes == 0 ? '$hours 小时' : '$hours 小时 $remainingMinutes 分钟';
}
