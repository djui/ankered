import Foundation

enum DeviceCatalog {
    static let usbSentinels: Set<UInt16> = [
        0x0000, 0xFFFA, 0xFFFB, 0xFFFC, 0xFFFD, 0xFFFE, 0xFFFF
    ]

    static let brandNames: [UInt32: String] = [
        0x01: "Apple", 0x02: "Samsung", 0x03: "Xiaomi", 0x04: "Huawei",
        0x05: "Google", 0x06: "LG", 0x07: "IDT", 0x08: "TI",
        0x09: "YBZ", 0x0A: "Anker", 0x0B: "Honor", 0x0C: "HP",
        0x0D: "Dell", 0x0E: "Lenovo", 0x0F: "Microsoft", 0x10: "ASUS",
        0x11: "ASUS", 0x12: "MSI", 0x13: "Razer"
    ]

    static let usbVendorNames: [UInt16: String] = [
        0x05AC: "Apple",
        0x04E8: "Samsung",
        0x2717: "Xiaomi",
        0x12D1: "Huawei",
        0x18D1: "Google",
        0x1004: "LG",
        0x0451: "TI",
        0x291A: "Anker",
        0x03F0: "HP",
        0x413C: "Dell",
        0x17EF: "Lenovo",
        0x045E: "Microsoft",
        0x0B05: "ASUS",
        0x0DB0: "MSI",
        0x1532: "Razer"
    ]

    /// USB VID/PID labels observed against the official app. Unknown PIDs stay
    /// at the brand-level fallback rather than inventing a model name.
    static let usbModelNames: [UInt32: String] = [
        pack(vid: 0x05AC, pid: 0x7519): "iPhone 17",
        pack(vid: 0x05AC, pid: 0x7319): "MacBook Pro",
        pack(vid: 0x05AC, pid: 0x7117): "iPad Pro",
        pack(vid: 0x291A, pid: 0x110A): "Prime Power Bank 26K",
        pack(vid: 0x291A, pid: 0x110B): "Prime Power Bank 20K"
    ]

    static func brandName(_ code: UInt32) -> String? {
        brandNames[code]
    }

    static func deviceLabel(brand: String, model: UInt32) -> String {
        _ = model
        return "\(brand) Device"
    }

    static func usbDeviceLabel(vid: UInt16, pid: UInt16) -> String? {
        guard !usbSentinels.contains(vid) else { return nil }
        if let named = usbModelNames[pack(vid: vid, pid: pid)] {
            return named
        }
        guard let vendor = usbVendorNames[vid] else { return nil }
        return "\(vendor) Device"
    }

    static func ankerProtocolLabel(vid: UInt16, pid: UInt16, isAIMode: Bool) -> String? {
        guard isAIMode, vid == 0x291A, pid == 0x110A || pid == 0x110B else { return nil }
        return "Anker Protocol"
    }

    private static func pack(vid: UInt16, pid: UInt16) -> UInt32 {
        UInt32(vid) | (UInt32(pid) << 16)
    }
}
