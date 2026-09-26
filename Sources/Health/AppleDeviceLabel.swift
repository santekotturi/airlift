import Foundation

extension DeviceLabel {
    /// Every Apple Watch hardware identifier, from the original through
    /// Series 12 and Ultra 4, generated from Xcode 27's watchOS device-traits
    /// database (`WatchOS.platform/usr/standalone/device_traits.db`) —
    /// connectivity and case-size variants collapse to one name. Hardware newer
    /// than this falls back to the Health source name.
    ///
    /// Regenerate when a new Xcode adds models:
    ///   sqlite3 device_traits.db "select distinct ProductType, ProductDescription from Devices"
    private static let appleHardware: [String: String] = [
        "Watch1,1": "Watch (1st generation)",
        "Watch1,2": "Watch (1st generation)",
        "Watch2,3": "Watch Series 2",
        "Watch2,4": "Watch Series 2",
        "Watch2,6": "Watch Series 1",
        "Watch2,7": "Watch Series 1",
        "Watch3,1": "Watch Series 3",
        "Watch3,2": "Watch Series 3",
        "Watch3,3": "Watch Series 3",
        "Watch3,4": "Watch Series 3",
        "Watch4,1": "Watch Series 4",
        "Watch4,2": "Watch Series 4",
        "Watch4,3": "Watch Series 4",
        "Watch4,4": "Watch Series 4",
        "Watch5,1": "Watch Series 5",
        "Watch5,2": "Watch Series 5",
        "Watch5,3": "Watch Series 5",
        "Watch5,4": "Watch Series 5",
        "Watch5,9": "Watch SE",
        "Watch5,10": "Watch SE",
        "Watch5,11": "Watch SE",
        "Watch5,12": "Watch SE",
        "Watch6,1": "Watch Series 6",
        "Watch6,2": "Watch Series 6",
        "Watch6,3": "Watch Series 6",
        "Watch6,4": "Watch Series 6",
        "Watch6,6": "Watch Series 7",
        "Watch6,7": "Watch Series 7",
        "Watch6,8": "Watch Series 7",
        "Watch6,9": "Watch Series 7",
        "Watch6,10": "Watch SE (2nd generation)",
        "Watch6,11": "Watch SE (2nd generation)",
        "Watch6,12": "Watch SE (2nd generation)",
        "Watch6,13": "Watch SE (2nd generation)",
        "Watch6,14": "Watch Series 8",
        "Watch6,15": "Watch Series 8",
        "Watch6,16": "Watch Series 8",
        "Watch6,17": "Watch Series 8",
        "Watch6,18": "Watch Ultra",
        "Watch7,1": "Watch Series 9",
        "Watch7,2": "Watch Series 9",
        "Watch7,3": "Watch Series 9",
        "Watch7,4": "Watch Series 9",
        "Watch7,5": "Watch Ultra 2",
        "Watch7,8": "Watch Series 10",
        "Watch7,9": "Watch Series 10",
        "Watch7,10": "Watch Series 10",
        "Watch7,11": "Watch Series 10",
        "Watch7,12": "Watch Ultra 3",
        "Watch7,13": "Watch SE 3",
        "Watch7,14": "Watch SE 3",
        "Watch7,15": "Watch SE 3",
        "Watch7,16": "Watch SE 3",
        "Watch7,17": "Watch Series 11",
        "Watch7,18": "Watch Series 11",
        "Watch7,19": "Watch Series 11",
        "Watch7,20": "Watch Series 11",
        "Watch8,1": "Watch Ultra 4",
        "Watch8,2": "Watch Series 12",
        "Watch8,3": "Watch Series 12",
        "Watch8,4": "Watch Series 12",
        "Watch8,5": "Watch Series 12",
    ]

    /// Short name for the Apple device a sample came from: "Watch Ultra 2".
    ///
    /// Health source names carry the owner ("Sante’s Apple Watch Ultra 4"),
    /// which is dropped; the Ultra 2's source name is plain "Apple Watch", which
    /// is why the hardware table comes first.
    static func apple(hardware: String?, sourceName: String?) -> String? {
        if let hardware, let name = appleHardware[hardware] { return name }
        guard var name = sourceName, !name.isEmpty else { return nil }
        if let possessive = name.range(of: #"^.+?['’]s\s+"#, options: .regularExpression) {
            name.removeSubrange(possessive)
        }
        name = name.replacingOccurrences(of: "\u{00A0}", with: " ")
        if name.hasPrefix("Apple Watch "), name.count > "Apple Watch ".count {
            name = "Watch " + name.dropFirst("Apple Watch ".count)
        }
        return name
    }
}
