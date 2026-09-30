# 架构说明

## 分层

```text
Flutter UI
  └── RecoveryController
        ├── PlatformDiskDiscoveryService
        ├── RawDiskAccessService
        └── FileCarver
              ├── 分块只读扫描
              ├── 起止签名匹配
              ├── Office 容器分类
              ├── 图片预览读取
              └── 安全导出
```

`FileCarver` 不依赖 Flutter UI，后续可替换为 Rust/C++ FFI 引擎。现有领域模型和控制器接口将继续作为 UI 与原生恢复引擎之间的边界。

macOS 使用 `diskutil list -plist physical` 枚举整块物理设备，并从根卷的 `APFSPhysicalStores` 反查当前启动盘。启动盘会进入需要二次确认的自用实验模式；用户需先手动授予“完全磁盘访问”并重启应用。原生 Swift 桥接通过系统 `/usr/libexec/authopen -stdoutpipe` 请求指定 `/dev/rdisk*` 的只读授权，文件描述符由桥接持有，扫描引擎通过 FFI `pread` 按设备块大小对齐后直接读取，不再将 `/dev/fd/<n>` 作为普通文件二次打开。允许的设备路径经过严格白名单校验，不接受任意文件路径或写入模式。

## 扫描策略

扫描器使用固定大小的数据块和重叠窗口，避免漏掉跨数据块边界的文件头。每种格式维护一个流式匹配状态，在同一遍顺序读取中寻找起始与结束记录，避免为每个候选文件重复回读最多 128–512 MB 数据。每种文件仍有最大长度限制，防止损坏数据导致无界匹配。

整段读盘和签名匹配运行在独立的 `recovera-deep-scan` Dart Isolate 中。主 Isolate 只接收约 100 ms 一次的进度和最终候选元数据，不传输原始磁盘数据。停止命令通过 Isolate 消息端口送入扫描器，在当前分块结束后安全取消。

当前完整度是启发式结果：JPEG、PNG 找到完整结束标记时标为高完整度；PDF、ZIP/Office 因格式允许增量内容或复杂目录结构，标为需要验证。

## 安全导出

恢复操作只读取源文件。目标文件先写入 `.part`，成功刷新并关闭后再改名；如果恢复失败则删除临时文件。目标目录已有同名文件时自动增加数字后缀，不覆盖用户文件。

## 原生引擎演进

下一阶段把 `FileCarver` 下沉为 Rust crate，并增加：

1. Windows 原生提权和 `CreateFile` 物理磁盘只读句柄桥接。
2. GPT/MBR 分区发现。
3. NTFS MFT、FAT/exFAT 目录项、APFS 快照/元数据解析。
4. 坏扇区重试、镜像制作和断点续扫。
5. iPhone Finder 备份与 Android 合法备份解析。
