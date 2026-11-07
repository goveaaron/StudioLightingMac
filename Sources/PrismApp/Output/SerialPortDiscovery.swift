import Foundation
import IOKit
import IOKit.serial
import PrismCore

/// One serial port as macOS reports it (USB descriptor details included when available).
struct SerialPortInfo: Hashable, Sendable, Identifiable {
    var id: UInt64 { registryID }
    /// IORegistry entry ID of the IOSerialBSDClient (stable while plugged in).
    let registryID: UInt64
    /// "/dev/cu.usbserial-EN406708" (always the cu.* node).
    let path: String
    let ttyName: String?
    /// 0x0403 = FTDI.
    let vendorID: Int?
    let productID: Int?
    /// FTDI iSerial, e.g. "EN406708" (not the ENTTEC label-10 serial).
    let usbSerial: String?
    /// e.g. "DMX USB PRO".
    let productName: String?
    /// e.g. "ENTTEC".
    let vendorName: String?
    let locationID: Int?

    var isUSB: Bool { vendorID != nil }
    var isFTDI: Bool { vendorID == 0x0403 }

    /// Likely a DMX interface: FTDI, or a name that says DMX/ENTTEC/DMXking.
    var looksLikeDMXWidget: Bool {
        let text = [productName, vendorName, usbSerial].compactMap { $0 }.joined(separator: " ").lowercased()
        return isFTDI || text.contains("dmx") || text.contains("enttec") || (usbSerial?.hasPrefix("EN") ?? false)
    }

    /// Stable key for settings: the USB serial number when there is one, else the device path.
    var deviceKey: String {
        if let s = usbSerial?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return "usb:" + s }
        return "path:" + path
    }

    /// Friendly name before identification, e.g. "ENTTEC DMX USB Pro".
    var friendlyName: String {
        let product = (productName ?? "").trimmingCharacters(in: .whitespaces)
        let upper = product.uppercased()
        if upper.contains("DMX USB PRO") { return upper.contains("MK2") ? "ENTTEC DMX USB Pro Mk2" : "ENTTEC DMX USB Pro" }
        if !product.isEmpty { return product }
        return ttyName ?? (path as NSString).lastPathComponent
    }
}

/// Lists serial ports via IOKit (no entitlements needed outside the sandbox).
enum SerialPortScanner {
    /// A fresh matching dictionary for every IOKit call (they consume it).
    static func matchingDictionary() -> CFDictionary {
        let dict: [String: Any] = [
            kIOProviderClassKey: kIOSerialBSDServiceValue,
            kIOSerialBSDTypeKey: kIOSerialBSDAllTypes,
        ]
        return dict as CFDictionary
    }

    static func scan() -> [SerialPortInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary(), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// Reads every object from an iterator — this is also what (re-)arms notification iterators.
    static func drain(_ iterator: io_iterator_t) -> [SerialPortInfo] {
        var result: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = info(for: service) { result.append(info) }
        }
        return result
    }

    static func info(for service: io_object_t) -> SerialPortInfo? {
        guard let path = stringProperty(service, kIOCalloutDeviceKey) else { return nil }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        return SerialPortInfo(
            registryID: entryID,
            path: path,
            ttyName: stringProperty(service, kIOTTYDeviceKey),
            vendorID: searchParents(service, "idVendor") as? Int,
            productID: searchParents(service, "idProduct") as? Int,
            usbSerial: firstString(service, "USB Serial Number", "kUSBSerialNumberString"),
            productName: firstString(service, "USB Product Name", "kUSBProductString"),
            vendorName: firstString(service, "USB Vendor Name", "kUSBVendorString"),
            locationID: searchParents(service, "locationID") as? Int)
    }

    static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Looks for `key` on the entry itself and then on each parent in the IOService plane.
    static func searchParents(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    static func firstString(_ entry: io_registry_entry_t, _ keys: String...) -> String? {
        for key in keys {
            if let s = searchParents(entry, key) as? String { return s }
        }
        return nil
    }
}

/// Reports serial ports as they appear and disappear. Callbacks run on a private serial queue;
/// hop to the main actor yourself. `start()` once, `stop()` when done (balances the retain).
final class SerialPortMonitor: @unchecked Sendable {
    var onAdded: (@Sendable (SerialPortInfo) -> Void)?
    var onRemoved: (@Sendable (SerialPortInfo) -> Void)?

    private let queue = DispatchQueue(label: "Prism.SerialPortMonitor")
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var known: [UInt64: SerialPortInfo] = [:]
    private var retainedSelf: Unmanaged<SerialPortMonitor>?

    func start() {
        queue.sync {
            guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            notifyPort = port
            IONotificationPortSetDispatchQueue(port, queue)

            let ref = Unmanaged.passRetained(self)
            retainedSelf = ref
            let context = ref.toOpaque()

            let addedCallback: IOServiceMatchingCallback = { context, iterator in
                guard let context else { return }
                Unmanaged<SerialPortMonitor>.fromOpaque(context).takeUnretainedValue().handleAdded(iterator)
            }
            let removedCallback: IOServiceMatchingCallback = { context, iterator in
                guard let context else { return }
                Unmanaged<SerialPortMonitor>.fromOpaque(context).takeUnretainedValue().handleRemoved(iterator)
            }

            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                             SerialPortScanner.matchingDictionary(),
                                             addedCallback, context, &addedIterator)
            handleAdded(addedIterator)      // drain once: reports existing ports and arms the notification

            IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                             SerialPortScanner.matchingDictionary(),
                                             removedCallback, context, &removedIterator)
            handleRemoved(removedIterator)  // arm
        }
    }

    func stop() {
        queue.sync {
            if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
            if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
            if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
            known.removeAll()
        }
        retainedSelf?.release()
        retainedSelf = nil
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        for info in SerialPortScanner.drain(iterator) {
            known[info.registryID] = info
            onAdded?(info)
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if let info = known.removeValue(forKey: entryID) { onRemoved?(info) }
        }
    }
}

/// Thread-safe map from device key to the port currently present for it. Device threads
/// call `path(for:)` from their locator closures.
final class PortDirectory: @unchecked Sendable {
    private let ports = Locked<[String: SerialPortInfo]>([:])

    func set(_ info: SerialPortInfo, for key: String) { ports.mutate { $0[key] = info } }

    /// Removes the entry only if it still refers to the same registry object.
    func remove(registryID: UInt64, for key: String) {
        ports.mutate { map in
            if map[key]?.registryID == registryID { map[key] = nil }
        }
    }

    func path(for key: String) -> String? { ports.value[key]?.path }
    func info(for key: String) -> SerialPortInfo? { ports.value[key] }
    var keys: Set<String> { Set(ports.value.keys) }
}
