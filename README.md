# Recovera Studio

Recovera Studio 是一个本地优先、只读扫描的数据恢复工作台。当前 MVP 会自动检测整块物理磁盘，用户不需要知道误删文件原来位于哪个文件夹，也不需要选择已经不存在的文件。

## 当前可用能力

- 自动枚举 macOS 物理磁盘，并支持 Windows 磁盘枚举。
- macOS 通过系统 `authopen` 请求指定 `/dev/rdisk*` 的只读管理员授权。
- 授权后直接对原生文件描述符执行扇区对齐的 `pread`，不对原始设备做二次文件打开。
- 自用版可在明确风险提示后尝试扫描当前 macOS 启动盘，需先授予“完全磁盘访问”并重启应用。
- 对整块磁盘分块扫描，不把设备内容一次性加载到内存。
- 起止签名在同一遍流式扫描中配对，不再为每个候选文件重复回读后续数据。
- 深度扫描在独立 Dart Isolate 中执行，磁盘读取和签名匹配不阻塞 Flutter 界面。
- 扫描界面持续显示运行动画、实时吞吐速度和预计剩余时间。
- `.img`、`.dd`、`.raw`、`.bin` 镜像文件作为高级入口保留。
- 跨分块识别文件起止签名。
- 识别 JPEG、PNG、PDF、ZIP、DOCX、XLSX、PPTX。
- 图片候选文件本地预览。
- 将单个或全部候选文件恢复到用户选择的目录。
- 使用 `.part` 临时文件并自动避开同名文件，避免产生半成品或覆盖已有文件。
- 支持停止扫描；文件内容不上传网络。

## 明确的能力边界

当前版本已经可以读取授权后的整块物理磁盘，但仍属于文件雕刻 MVP，尚未解析 NTFS、APFS、ext4 的删除目录元数据，因此暂时不能恢复原文件名和原目录。碎片化文件、已覆盖数据、TRIM 后的数据、没有密钥的加密数据无法靠当前版本恢复。iPhone/iPad 普通 App 也不能绕过系统沙盒扫描整机存储。

macOS 专业恢复版需要在 App Store 沙盒之外签名和公证，因为沙盒应用不能直接读取原始磁盘设备。授权严格限定为用户选择的 `/dev/rdisk*`，且只申请只读权限。

启动盘的原始扫描是实验性能力。运行中的系统会继续写入磁盘，APFS 加密、SSD TRIM、数据覆盖和文件碎片都可能导致无法恢复。重要数据仍建议关机并从外置系统启动后扫描。

详见：

- [架构说明](docs/ARCHITECTURE.md)
- [产品范围与路线图](docs/ROADMAP.md)
- [安全原则](docs/SAFETY.md)

## 运行

```bash
flutter pub get
flutter run -d macos
```

Android/iOS 工程保留用于后续手机备份导入；物理磁盘恢复应在 Windows/macOS 桌面端执行。

## 验证

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build macos --debug
```

测试会生成临时合成镜像，并验证 diskutil plist 解析、跨分块扫描、文件识别、取消扫描、精确恢复和不覆盖已有文件。
