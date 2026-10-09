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

    private init() {}

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let initial = getSystemNetworkBytes()
        lastIBytes = initial.ibytes
        lastOBytes = initial.obytes
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

        let current = getSystemNetworkBytes()
        let diffI = (current.ibytes >= lastIBytes) ? Double(current.ibytes - lastIBytes) : 0.0
        let diffO = (current.obytes >= lastOBytes) ? Double(current.obytes - lastOBytes) : 0.0

        currentDownloadBytes = diffI / deltaSec
        currentUploadBytes = diffO / deltaSec

        lastIBytes = current.ibytes
        lastOBytes = current.obytes
        lastTimestamp = now

        delegate?.speedMonitorDidUpdate(
            download: formattedDownloadSpeed,
            upload: formattedUploadSpeed,
            compact: compactSpeedString
        )
    }

    private func getSystemNetworkBytes() -> (ibytes: UInt64, obytes: UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var totalI: UInt64 = 0
        var totalO: UInt64 = 0

        var ptr = Optional(first)
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            // 排除本地回环 lo0
            if !name.hasPrefix("lo"),
               let data = current.pointee.ifa_data,
               Int32(current.pointee.ifa_addr.pointee.sa_family) == AF_LINK {
                let networkData = data.assumingMemoryBound(to: if_data.self)
                totalI += UInt64(networkData.pointee.ifi_ibytes)
                totalO += UInt64(networkData.pointee.ifi_obytes)
            }
            ptr = current.pointee.ifa_next
        }
        return (totalI, totalO)
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
