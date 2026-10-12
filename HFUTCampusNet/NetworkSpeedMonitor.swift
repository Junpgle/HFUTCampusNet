import Foundation
import Darwin

public protocol NetworkSpeedMonitorDelegate: AnyObject {
    func speedMonitorDidUpdate(download: String, upload: String, compact: String)
}

public class NetworkSpeedMonitor {
    public static let shared = NetworkSpeedMonitor()

    public weak var delegate: NetworkSpeedMonitorDelegate?

    public private(set) var currentDownloadBytes: Double = 0.0
    public private(set) var currentUploadBytes: Double = 0.0

    public var formattedDownloadSpeed: String {
        formatBytesPerSecond(currentDownloadBytes)
    }

    public var formattedUploadSpeed: String {
        formatBytesPerSecond(currentUploadBytes)
    }

    public var compactSpeedString: String {
        let down = formatCompact(currentDownloadBytes)
        let up = formatCompact(currentUploadBytes)
        return "↓ \(down)  ↑ \(up)"
    }

    private var timer: Timer?
    private var lastIBytes: UInt64 = 0
    private var lastOBytes: UInt64 = 0
    private var lastTimestamp: Date = Date()
    private var isStarted = false

    private var lastInterfaceBytes: [String: (ibytes: UInt32, obytes: UInt32)] = [:]

    private init() {}

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        lastInterfaceBytes = getInterfaceNetworkBytes()
        lastTimestamp = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isStarted = false
    }

    private func tick() {
        let now = Date()
        let deltaSec = now.timeIntervalSince(lastTimestamp)
        guard deltaSec > 0.3 else { return }

        let currentMap = getInterfaceNetworkBytes()
        var diffI: UInt64 = 0
        var diffO: UInt64 = 0

        // यदि从睡眠唤醒间隔过长 (> 10s)，仅重置基准不计算瞬时速率，避免唤醒瞬间虚高
        if deltaSec <= 10.0 {
            for (name, curr) in currentMap {
                if let prev = lastInterfaceBytes[name] {
                    // ifi_ibytes / ifi_obytes 为 32 位无符号整型 (4GB 溢出回绕)，使用 &+ / &- 安全处理回绕
                    let dI = curr.ibytes >= prev.ibytes ? (curr.ibytes - prev.ibytes) : (curr.ibytes &- prev.ibytes)
                    let dO = curr.obytes >= prev.obytes ? (curr.obytes - prev.obytes) : (curr.obytes &- prev.obytes)
                    // 过滤网卡重置导致的异常跳变 (> 1 GB/s)
                    if dI < 1_073_741_824 { diffI += UInt64(dI) }
                    if dO < 1_073_741_824 { diffO += UInt64(dO) }
                }
            }
        }

        currentDownloadBytes = Double(diffI) / deltaSec
        currentUploadBytes = Double(diffO) / deltaSec

        lastInterfaceBytes = currentMap
        lastTimestamp = now

        let currentSpeedMBs = max(currentDownloadBytes, currentUploadBytes) / (1024.0 * 1024.0)
        if currentSpeedMBs > 0.01 {
            CampusHistoryManager.shared.updatePeakSpeed(speedMBs: currentSpeedMBs)
        }

        delegate?.speedMonitorDidUpdate(
            download: formattedDownloadSpeed,
            upload: formattedUploadSpeed,
            compact: compactSpeedString
        )
    }

    private func getInterfaceNetworkBytes() -> [String: (ibytes: UInt32, obytes: UInt32)] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [:] }
        defer { freeifaddrs(ifap) }

        var result: [String: (ibytes: UInt32, obytes: UInt32)] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            if let cName = current.pointee.ifa_name,
               let addr = current.pointee.ifa_addr,
               let data = current.pointee.ifa_data,
               Int32(addr.pointee.sa_family) == AF_LINK {
                let name = String(cString: cName)
                // 仅统计物理外网接口（en* 为 Wi-Fi/以太网，pdp_ip* 为蜂窝热点），排除 lo0、VPN/代理虚拟网卡 (utun*/ipsec*/ppp*) 及隔空投送 (awdl0/llw0) 避免流量翻倍
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    let networkData = data.assumingMemoryBound(to: if_data.self)
                    let prev = result[name] ?? (0, 0)
                    result[name] = (
                        ibytes: prev.ibytes &+ networkData.pointee.ifi_ibytes,
                        obytes: prev.obytes &+ networkData.pointee.ifi_obytes
                    )
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }

    private func formatBytesPerSecond(_ bytes: Double) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB/s", bytes / (1024 * 1024 * 1024))
        } else if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytes / (1024 * 1024))
        } else if bytes >= 1024 {
            return String(format: "%.0f KB/s", bytes / 1024)
        } else {
            return String(format: "%.0f B/s", bytes)
        }
    }

    private func formatCompact(_ bytes: Double) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1fM/s", bytes / (1024 * 1024))
        } else if bytes >= 1024 {
            return String(format: "%.0fK/s", bytes / 1024)
        } else {
            return String(format: "%.0fB/s", bytes)
        }
    }
}
