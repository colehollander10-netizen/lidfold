import Foundation
import IOKit
import IOKit.hid

/// Reads the hinge angle from the MacBook lid sensor.
///
/// The sensor is an `AppleSPUHIDDevice` on HID usage page 0x20 (Sensor),
/// usage 0x8A (Orientation). Two feature reports carry the angle:
///  - report 7: `[0x07, b0, b1, b2, b3]`, little-endian hundredths of a degree
///  - report 1: `[0x01, lo, hi]`, whole degrees
/// 0 is closed; a MacBook opens to roughly 130. Values refresh about every
/// 100 ms and need no permission.
final class LidAngleSensor {
    enum Resolution { case hundredths, wholeDegrees
        var reportID: CFIndex { self == .hundredths ? 7 : 1 }
        var label: String { self == .hundredths ? "report 7 (0.01°)" : "report 1 (1°)" }
    }

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 64)
    private(set) var resolution: Resolution?
    private(set) var lastStatus: IOReturn = kIOReturnSuccess

    var isAvailable: Bool { device != nil && resolution != nil }

    init() { open() }

    deinit {
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    /// Current lid angle in degrees, or nil if the read failed.
    func angle() -> Double? {
        guard let resolution, let bytes = read(reportID: resolution.reportID) else { return nil }
        let degrees: Double
        switch resolution {
        case .hundredths:
            guard bytes.count >= 5 else { return nil }
            let raw = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard bytes.count >= 3 else { return nil }
            degrees = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        }
        guard degrees >= 0, degrees <= 360 else { return nil }
        return degrees
    }

    private func open() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8A]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        self.manager = manager
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            device = candidate
            if let b = read(reportID: 7), b.count >= 5 { resolution = .hundredths; return }
            if let b = read(reportID: 1), b.count >= 3 { resolution = .wholeDegrees; return }
        }
        device = nil
    }

    private func read(reportID: CFIndex) -> [UInt8]? {
        guard let device else { lastStatus = kIOReturnNoDevice; return nil }
        var length = CFIndex(buffer.count)
        let status = buffer.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, reportID, base, &length)
        }
        lastStatus = status
        guard status == kIOReturnSuccess, length > 0 else { return nil }
        return Array(buffer[0..<Int(length)])
    }
}
