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

    /// Anker USB VID/PID labels from the official app's whitelist. Unknown PIDs
    /// stay at the brand-level fallback rather than inventing a model name.
    static let usbModelNames: [UInt32: String] = [
        pack(vid: 0x291A, pid: 0x110A): "Prime Power Bank 26K",
        pack(vid: 0x291A, pid: 0x110B): "Prime Power Bank 20K",
        pack(vid: 0x291A, pid: 0x1665): "Power Bank 5K",
        pack(vid: 0x291A, pid: 0x1669): "Power Bank 10K",
        pack(vid: 0x291A, pid: 0x1340): "Power Bank 27K",
        pack(vid: 0x291A, pid: 0x25F7): "Wireless Charger 35W"
    ]

    /// Brand and model codes the charger reports in B5, as the official
    /// Anker app 3.25.1 names them. Model 0xFFFF means any device of the brand.
    static let brandModelNames: [UInt32: [UInt32: String]] = [
        0x01: [
            0x0001: "iPhone 12",
            0x0002: "iPhone 12 mini",
            0x0003: "iPhone 12",
            0x0004: "iPhone 12 Pro",
            0x0005: "iPhone 12 Pro Max",
            0x0006: "iPhone SE 3",
            0x0007: "iPhone 13",
            0x0008: "iPhone 13 mini",
            0x0009: "iPhone 13",
            0x000A: "iPhone 13 Pro",
            0x000B: "iPhone 13 Pro Max",
            0x000C: "iPhone 14",
            0x000D: "iPhone 14",
            0x000E: "iPhone 14 Pro",
            0x000F: "iPhone 14 Plus",
            0x0010: "iPhone 14 Pro Max",
            0x0011: "iPhone 15",
            0x0012: "iPhone 15 Plus",
            0x0013: "iPhone 15 Pro",
            0x0014: "iPhone 15 Pro Max",
            0x0015: "iPhone 16",
            0x0016: "iPhone 16",
            0x0017: "iPhone 16 Plus",
            0x0018: "iPhone 16e",
            0x0019: "iPhone 16 Pro",
            0x001A: "iPhone 16 Pro",
            0x001B: "iPhone 16 Pro Max",
            0x001C: "iPhone 17",
            0x001D: "iPhone 17",
            0x001E: "iPhone Air",
            0x001F: "iPhone 17 Pro",
            0x0020: "iPhone 17 Pro",
            0x0021: "iPhone 17 Pro Max",
            0x0022: "iPad 9 (2021)",
            0x0023: "iPad 10 (2022)",
            0x0024: "iPad 11 (2025)",
            0x0025: "iPad Air 4 (2020)",
            0x0026: "iPad Air 5 (2022)",
            0x0027: "iPad Air 11\" (2024)",
            0x0028: "iPad Air 13\" (2024)",
            0x0029: "iPad Air 11\" (2025)",
            0x002A: "iPad Air 13\" (2025)",
            0x002B: "iPad mini 6 (2021)",
            0x002C: "iPad mini 7 (2024)",
            0x002D: "iPad Pro 2020",
            0x002E: "iPad Pro 11\" (2020)",
            0x002F: "iPad Pro 12.9\" (2020)",
            0x0030: "iPad Pro M1",
            0x0031: "iPad Pro 11\" M1 (2021)",
            0x0032: "iPad Pro 12.9\" M1 (2021)",
            0x0033: "iPad Pro M2",
            0x0034: "iPad Pro 11\" M2 (2022)",
            0x0035: "iPad Pro 12.9\" M2 (2022)",
            0x0036: "iPad Pro M4",
            0x0037: "iPad Pro 11\" M4 (2024)",
            0x0038: "iPad Pro 13\" M4 (2024)",
            0x0039: "iPad Pro M5",
            0x003A: "iPad Pro 11\" M5 (2025)",
            0x003B: "iPad Pro 13\" M5 (2025)",
            0x003C: "MacBook Air 13\" (2020)",
            0x003D: "MacBook Air 13\" M1 (2020)",
            0x003E: "MacBook Pro 13.4\" (2020)",
            0x003F: "MacBook Pro 13.4\" M1 (2020)",
            0x0040: "MacBook Air 13\" M2 (2022)",
            0x0041: "MacBook Air 13\" M3 (2024)",
            0x0042: "MacBook Air 13\" M4 (2025)",
            0x0043: "MacBook Air 15\" (2023)",
            0x0044: "MacBook Air 15\" M3 (2024)",
            0x0045: "MacBook Air 15\" M4 (2025)",
            0x0046: "MacBook Pro 13\" M2 (2022)",
            0x0047: "MacBook Pro 14\" M1 Pro (2021)",
            0x0048: "MacBook Pro 14\" M2 Pro (2023)",
            0x0049: "MacBook Pro 14\" M3 (2023)",
            0x004A: "MacBook Pro 14\" M4",
            0x004B: "MacBook Pro 14\" M4 Pro (2024)",
            0x004C: "MacBook Pro 14\" M4 Max (2024)",
            0x004D: "MacBook Pro 14\" M5 (2025)",
            0x004E: "MacBook Pro 16\" M1 Max (2021)",
            0x004F: "MacBook Pro 16\" M2 Pro (2023)",
            0x0050: "MacBook Pro 16\" M3 Pro (2023)",
            0x0051: "MacBook Pro 16\" M4",
            0x0052: "MacBook Pro 16\" M4 Pro (2024)",
            0x0053: "MacBook Pro 16\" M4 Max (2024)",
            0x0054: "HomePod Mini",
            0x0055: "iPhone 17e",
            0x0056: "iPad Air 11\" (2026)",
            0x0057: "iPad Air 13\" (2026)",
            0x0058: "MacBook Air 13\" M5 (2026)",
            0x0059: "MacBook Air 15\" M5 (2026)",
            0x005A: "MacBook Pro 16\" M5 Pro (2026)",
            0x005B: "MacBook Neo A18 Pro (2026)",
            0x005C: "MacBook Pro 14\" M5 (2026)",
            0x005D: "iPad Air 2026",
            0x005E: "MacBook Pro 14\" M3 Max (2023)",
            0x005F: "iPhone 18 Pro",
            0x0060: "iPhone 18 Pro",
            0x0061: "iPhone 18 Pro Max",
            0xFFFF: "Apple Device",
        ],
        0x02: [0xFFFF: "Samsung Device"],
        0x03: [0xFFFF: "Xiaomi Device"],
        0x04: [0xFFFF: "Huawei Device"],
        0x05: [0xFFFF: "Google Device"],
        0x06: [0xFFFF: "LG Device"],
        0x07: [0xFFFF: "IDT Device"],
        0x08: [0xFFFF: "TI Device"],
        0x09: [0xFFFF: "YBZ Device"],
        0x0A: [
            0x0001: "Power Bank 26K",
            0x0002: "Power Bank 20K",
            0x0004: "Power Bank 5K",
            0x0005: "Power Bank 10K",
            0x0006: "Charging Base 150W",
            0x0008: "Power Bank 27K",
            0x0009: "Wireless Charger 35W",
            0x000A: "Charger 160W",
            0x000B: "Charger 250W",
            0x000C: "Charging Station 240W",
            0x000D: "Power Bank 20K",
        ],
        0x0B: [0xFFFF: "Honor Device"],
        0x0C: [0xFFFF: "HP Device"],
        0x0D: [0xFFFF: "Dell Device"],
        0x0E: [
            0x0001: "ThinkBook 16 (2025)",
            0x0002: "ThinkPad X1 Carbon (2025)",
            0x0003: "YOGA Air 14c",
            0x0004: "YOGA Pro 14s",
            0x0005: "YOGA Air 15s (2025)",
            0xFFFF: "Lenovo Device",
        ],
        0x0F: [0xFFFF: "Microsoft Device"],
        0x10: [0xFFFF: "ASUS Device"],
        0x11: [0xFFFF: "ASUS Device"],
        0x12: [0xFFFF: "MSI Device"],
        0x13: [0xFFFF: "Razer Device"],
    ]

    /// Apple USB-PD product IDs by device family, from the official app's
    /// whitelist. The app shows the family name without "Series".
    static let appleFamilyNames: [UInt16: String] = [
        0x751B: "iPhone 17", 0x7519: "iPhone 17", 0x751A: "iPhone 17",
        0x7518: "iPhone Air",
        0x751C: "iPhone 16", 0x7515: "iPhone 16", 0x7517: "iPhone 16",
        0x7510: "iPhone 15", 0x7511: "iPhone 15", 0x7512: "iPhone 15", 0x7513: "iPhone 15",
        0x750E: "iPhone 14", 0x750D: "iPhone 14", 0x750F: "iPhone 14",
        0x7507: "iPhone 13", 0x7509: "iPhone 13", 0x750A: "iPhone 13",
        0x7504: "iPhone 12", 0x7506: "iPhone 12",
        0x750B: "iPhone SE 3",
        0x7111: "iPad", 0x7112: "iPad", 0x711B: "iPad",
        0x710D: "iPad Air", 0x7108: "iPad Air", 0x7114: "iPad Air", 0x711C: "iPad Air", 0x7115: "iPad Air", 0x711D: "iPad Air",
        0x710C: "iPad mini", 0x7116: "iPad mini",
        0x7102: "iPad Pro", 0x7109: "iPad Pro", 0x710E: "iPad Pro", 0x7117: "iPad Pro", 0x711E: "iPad Pro",
        0x7302: "MacBook Air", 0x7307: "MacBook Air", 0x730B: "MacBook Air", 0x7318: "MacBook Air", 0x7310: "MacBook Air", 0x7314: "MacBook Air", 0x731C: "MacBook Air", 0x731B: "MacBook Air",
        0x7304: "MacBook Pro", 0x7306: "MacBook Pro", 0x730E: "MacBook Pro", 0x7308: "MacBook Pro", 0x730C: "MacBook Pro", 0x7313: "MacBook Pro", 0x7319: "MacBook Pro", 0x731A: "MacBook Pro", 0x7309: "MacBook Pro", 0x730D: "MacBook Pro", 0x7312: "MacBook Pro", 0x7315: "MacBook Pro",
    ]

    static func brandName(_ code: UInt32) -> String? {
        brandNames[code]
    }

    /// The official app's name for a B5 brand/model pair: the exact model when
    /// known, otherwise "<Brand> Device". Nil for an unknown brand.
    static func deviceLabel(brandCode: UInt32, model: UInt32) -> String? {
        guard let brand = brandNames[brandCode] else { return nil }
        if let named = brandModelNames[brandCode]?[model] {
            return named
        }
        return brandModelNames[brandCode]?[0xFFFF] ?? "\(brand) Device"
    }

    static func usbDeviceLabel(vid: UInt16, pid: UInt16) -> String? {
        guard !usbSentinels.contains(vid) else { return nil }
        if let named = usbModelNames[pack(vid: vid, pid: pid)] {
            return named
        }
        if vid == 0x05AC, let family = appleFamilyNames[pid] {
            return family
        }
        guard let vendor = usbVendorNames[vid] else { return nil }
        return "\(vendor) Device"
    }

    /// Key for naming a device model; nil when the charger reports no identity.
    static func deviceKey(vid: UInt16, pid: UInt16) -> String? {
        guard !usbSentinels.contains(vid) else { return nil }
        return String(format: "usb:%04X:%04X", vid, pid)
    }

    static func deviceKey(brand: UInt32, model: UInt32) -> String {
        String(format: "brand:%02X:%08X", brand, model)
    }

    static func ankerProtocolLabel(vid: UInt16, pid: UInt16, isAIMode: Bool) -> String? {
        guard isAIMode, vid == 0x291A, pid == 0x110A || pid == 0x110B else { return nil }
        return "Anker Protocol"
    }

    private static func pack(vid: UInt16, pid: UInt16) -> UInt32 {
        UInt32(vid) | (UInt32(pid) << 16)
    }
}
