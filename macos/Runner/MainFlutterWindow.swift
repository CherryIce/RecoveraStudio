import Cocoa
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var rawDiskAccessBridge: RawDiskAccessBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let bridge = RawDiskAccessBridge(
      messenger: flutterViewController.engine.binaryMessenger)
    rawDiskAccessBridge = bridge

    super.awakeFromNib()
  }
}

private final class RawDiskAccessBridge {
  private let channel: FlutterMethodChannel
  private let authorizationQueue = DispatchQueue(
    label: "com.starburst.tools.recovera.raw-disk-authorization",
    qos: .userInitiated)
  private var openHandles = Set<Int32>()
  private let handleLock = NSLock()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "recovera/raw_disk",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    handleLock.lock()
    let handles = openHandles
    openHandles.removeAll()
    handleLock.unlock()
    for handle in handles {
      Darwin.close(handle)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "openFullDiskAccessSettings":
      let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
      ]
      let opened = candidates.compactMap(URL.init(string:)).contains {
        NSWorkspace.shared.open($0)
      }
      if opened {
        result(nil)
      } else {
        result(FlutterError(
          code: "settings_unavailable",
          message: "无法打开“完全磁盘访问”设置。",
          details: nil))
      }

    case "authorizeRawDisk":
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        isAllowedRawDiskPath(path)
      else {
        result(FlutterError(
          code: "invalid_path",
          message: "只允许读取 /dev/rdisk* 原始磁盘设备。",
          details: nil))
        return
      }
      authorizationQueue.async { [weak self] in
        guard let self else { return }
        do {
          let descriptor = try self.openAuthorizedReadOnly(path: path)
          self.handleLock.lock()
          self.openHandles.insert(descriptor)
          self.handleLock.unlock()
          DispatchQueue.main.async {
            result(Int(descriptor))
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "authorization_failed",
              message: error.localizedDescription,
              details: nil))
          }
        }
      }

    case "closeRawDisk":
      guard
        let arguments = call.arguments as? [String: Any],
        let number = arguments["handle"] as? NSNumber
      else {
        result(FlutterError(
          code: "invalid_handle",
          message: "磁盘句柄无效。",
          details: nil))
        return
      }
      let descriptor = number.int32Value
      handleLock.lock()
      let wasOpen = openHandles.remove(descriptor) != nil
      handleLock.unlock()
      if wasOpen {
        Darwin.close(descriptor)
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isAllowedRawDiskPath(_ path: String) -> Bool {
    path.range(
      of: #"^/dev/rdisk[0-9]+$"#,
      options: .regularExpression) != nil
  }

  private func openAuthorizedReadOnly(path: String) throws -> Int32 {
    var sockets = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      throw RawDiskAccessError.systemCall("socketpair", errno)
    }

    let parentSocket = sockets[0]
    let childSocket = sockets[1]
    let childOutput = FileHandle(
      fileDescriptor: childSocket,
      closeOnDealloc: false)
    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
    process.arguments = ["-stdoutpipe", path]
    process.standardOutput = childOutput
    process.standardError = errorPipe

    do {
      try process.run()
    } catch {
      Darwin.close(parentSocket)
      Darwin.close(childSocket)
      throw error
    }

    childOutput.closeFile()
    defer { Darwin.close(parentSocket) }

    do {
      let descriptor = try receiveFileDescriptor(from: parentSocket)
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        Darwin.close(descriptor)
        let message = readError(pipe: errorPipe)
        throw RawDiskAccessError.authorization(
          message.isEmpty ? "用户取消了只读磁盘授权。" : message)
      }
      return descriptor
    } catch {
      process.waitUntilExit()
      let message = readError(pipe: errorPipe)
      if !message.isEmpty {
        throw RawDiskAccessError.authorization(message)
      }
      throw error
    }
  }

  private func receiveFileDescriptor(from socket: Int32) throws -> Int32 {
    var control = [UInt8](repeating: 0, count: 64)
    var byte: UInt8 = 0

    let received: Int = control.withUnsafeMutableBytes { controlBuffer in
      withUnsafeMutablePointer(to: &byte) { bytePointer in
        var vector = iovec(
          iov_base: UnsafeMutableRawPointer(bytePointer),
          iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
          var message = msghdr()
          message.msg_iov = vectorPointer
          message.msg_iovlen = 1
          message.msg_control = controlBuffer.baseAddress
          message.msg_controllen = socklen_t(controlBuffer.count)
          return recvmsg(socket, &message, 0)
        }
      }
    }

    guard received > 0 else {
      throw RawDiskAccessError.systemCall("recvmsg", errno)
    }

    let header = control.withUnsafeBytes { buffer in
      buffer.load(as: cmsghdr.self)
    }
    guard
      header.cmsg_level == SOL_SOCKET,
      header.cmsg_type == SCM_RIGHTS,
      Int(header.cmsg_len) >= alignedControlHeaderSize + MemoryLayout<Int32>.size
    else {
      throw RawDiskAccessError.invalidDescriptorMessage
    }

    return control.withUnsafeBytes { buffer in
      buffer.load(fromByteOffset: alignedControlHeaderSize, as: Int32.self)
    }
  }

  private var alignedControlHeaderSize: Int {
    let size = MemoryLayout<cmsghdr>.size
    return (size + MemoryLayout<UInt32>.alignment - 1)
      & ~(MemoryLayout<UInt32>.alignment - 1)
  }

  private func readError(pipe: Pipe) -> String {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}

private enum RawDiskAccessError: LocalizedError {
  case systemCall(String, Int32)
  case authorization(String)
  case invalidDescriptorMessage

  var errorDescription: String? {
    switch self {
    case let .systemCall(name, code):
      return "\(name) 失败：\(String(cString: strerror(code)))"
    case let .authorization(message):
      return message
    case .invalidDescriptorMessage:
      return "系统没有返回有效的只读磁盘句柄。"
    }
  }
}
