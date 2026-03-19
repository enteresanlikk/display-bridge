import CUSBKit
import CoreFoundation
import Foundation
import IOKit
import IOKit.usb

/// Monitors USB bus for Android devices, performs AOA negotiation, and creates `AOATransport` instances.
///
/// State machine: idle → monitoring → [device detected] → negotiating → [re-enumerate] → connected
///                                  ↑                                                          │
///                                  └──────────── device removed ──────────────────────────────┘
public final class AOAManager: @unchecked Sendable {

    // AOA protocol constants
    private static let aoaVendorID: UInt16 = 0x18D1  // Google
    private static let aoaProductIDs: Set<UInt16> = [0x2D00, 0x2D01]  // AOA / AOA+ADB

    // AOA control transfer request codes
    private static let aoaGetProtocol: UInt8  = 51  // 0x33
    private static let aoaSendString: UInt8   = 52  // 0x34
    private static let aoaStart: UInt8        = 53  // 0x35

    // Accessory identification (must match accessory_filter.xml on Android)
    private static let manufacturer = "DisplayBridge"
    private static let model        = "DisplayBridge"
    private static let description  = "DisplayBridge Virtual Display"
    private static let version      = "1.0"
    private static let uri          = "https://github.com/nicepayment/display-bridge"
    private static let serial       = "1"

    // MARK: - Properties

    private let lock = NSLock()
    private var monitorThread: Thread?
    private var monitorRunLoop: CFRunLoop?
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    /// Location IDs of devices currently being negotiated (prevents double-negotiation after re-enumerate).
    private var negotiatingLocations = Set<UInt64>()
    /// Maps location ID to client ID for connected AOA devices.
    private var connectedDevices: [UInt64: UUID] = [:]
    private var isMonitoring = false

    // MARK: - Callbacks

    /// Called when an AOA accessory is ready — provides a connected `AOATransport` and client ID.
    public var onAccessoryConnected: ((_ transport: AOATransport, _ clientID: UUID) -> Void)?
    /// Called when an AOA accessory is physically disconnected.
    public var onAccessoryDisconnected: ((_ clientID: UUID) -> Void)?

    public init() {}

    // MARK: - Lifecycle

    /// Starts IOKit USB monitoring on a dedicated thread.
    public func start() {
        let alreadyRunning = lock.withLock {
            guard !isMonitoring else { return true }
            isMonitoring = true
            return false
        }
        guard !alreadyRunning else { return }

        let thread = Thread { [weak self] in
            self?.monitorLoop()
        }
        thread.name = "com.displaybridge.aoa-monitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        lock.withLock { monitorThread = thread }

        print("[AOAManager] USB monitoring started")
    }

    /// Stops monitoring and cleans up IOKit resources.
    public func stop() {
        let rl: CFRunLoop? = lock.withLock {
            isMonitoring = false
            return monitorRunLoop
        }

        if let rl {
            CFRunLoopStop(rl)
        }

        // Release IOKit notification resources
        lock.lock()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        monitorRunLoop = nil
        monitorThread = nil
        lock.unlock()

        print("[AOAManager] USB monitoring stopped")
    }

    // MARK: - IOKit Monitor Loop

    private func monitorLoop() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else {
            print("[AOAManager] Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        let rl = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(rl, runLoopSource, .defaultMode)

        lock.withLock {
            self.notifyPort = port
            self.monitorRunLoop = rl
        }

        // Match all USB devices
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            print("[AOAManager] Failed to create matching dictionary")
            return
        }

        // We need two copies — one for added, one for removed
        let matchingDictRemoved = matchingDict as NSDictionary as! CFMutableDictionary

        // Register for device addition
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var addIter: io_iterator_t = 0
        let krAdd = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchingDict,  // consumed by this call
            AOAManager.deviceAddedCallback,
            selfPtr,
            &addIter
        )

        if krAdd == kIOReturnSuccess {
            lock.withLock { addedIterator = addIter }
            // Drain existing devices
            AOAManager.deviceAddedCallback(selfPtr, addIter)
        }

        // Register for device removal
        var removeIter: io_iterator_t = 0
        let krRemove = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDictRemoved,  // consumed by this call
            AOAManager.deviceRemovedCallback,
            selfPtr,
            &removeIter
        )

        if krRemove == kIOReturnSuccess {
            lock.withLock { removedIterator = removeIter }
            // Drain existing
            AOAManager.deviceRemovedCallback(selfPtr, removeIter)
        }

        // Run until stopped
        CFRunLoopRun()
    }

    // MARK: - IOKit Callbacks (C-bridged)

    private static let deviceAddedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let manager = Unmanaged<AOAManager>.fromOpaque(refcon).takeUnretainedValue()
        manager.handleDevicesAdded(iterator: iterator)
    }

    private static let deviceRemovedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let manager = Unmanaged<AOAManager>.fromOpaque(refcon).takeUnretainedValue()
        manager.handleDevicesRemoved(iterator: iterator)
    }

    // MARK: - Device Added

    private func handleDevicesAdded(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            let locationID = getLocationID(service)

            // Skip if already negotiating or connected
            let skip = lock.withLock {
                negotiatingLocations.contains(locationID) || connectedDevices[locationID] != nil
            }
            if skip { continue }

            // Check if this is already an AOA device
            var device: CUSBDeviceRef?
            guard CUSBCreateDeviceInterface(service, &device) == kIOReturnSuccess, let dev = device else {
                continue
            }

            var vendorID: UInt16 = 0
            var productID: UInt16 = 0
            CUSBGetDeviceVendor(dev, &vendorID)
            CUSBGetDeviceProduct(dev, &productID)

            if vendorID == AOAManager.aoaVendorID && AOAManager.aoaProductIDs.contains(productID) {
                // Already in AOA mode — release the check handle (never opened) and open properly
                CUSBDeviceRelease(dev)
                print("[AOAManager] AOA device detected (PID=0x\(String(productID, radix: 16)))")
                openAOADevice(service: service, locationID: locationID)
            } else {
                // Try AOA negotiation — control requests work without USBDeviceOpen
                // (USBDeviceOpen would fail if ADB holds the device)
                attemptAOANegotiation(device: dev, locationID: locationID)
            }
        }
    }

    // MARK: - Device Removed

    private func handleDevicesRemoved(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            let locationID = getLocationID(service)

            let clientID: UUID? = lock.withLock {
                negotiatingLocations.remove(locationID)
                return connectedDevices.removeValue(forKey: locationID)
            }

            if let clientID {
                print("[AOAManager] AOA device removed (client \(clientID.uuidString.prefix(8)))")
                onAccessoryDisconnected?(clientID)
            }
        }
    }

    // MARK: - AOA Negotiation

    private func attemptAOANegotiation(device: CUSBDeviceRef, locationID: UInt64) {
        lock.lock()
        negotiatingLocations.insert(locationID)
        lock.unlock()

        // Step 1: Check AOA protocol version
        var versionData: UInt16 = 0
        var transferred: UInt32 = 0
        let ret = CUSBDeviceControlRequest(
            device,
            0xC0,   // Device-to-host, vendor, device
            AOAManager.aoaGetProtocol,
            0, 0,
            &versionData, 2,
            &transferred
        )

        guard ret == kIOReturnSuccess && transferred >= 2 else {
            // Not an Android device or doesn't support AOA — silently skip
            CUSBDeviceRelease(device)
            lock.lock()
            negotiatingLocations.remove(locationID)
            lock.unlock()
            return
        }

        let version = versionData.littleEndian
        guard version >= 1 else {
            print("[AOAManager] Device does not support AOA (version=\(version))")
            CUSBDeviceRelease(device)
            lock.lock()
            negotiatingLocations.remove(locationID)
            lock.unlock()
            return
        }

        print("[AOAManager] AOA version \(version) supported")

        // Step 2: Send accessory identification strings
        let strings: [(UInt16, String)] = [
            (0, AOAManager.manufacturer),
            (1, AOAManager.model),
            (2, AOAManager.description),
            (3, AOAManager.version),
            (4, AOAManager.uri),
            (5, AOAManager.serial),
        ]

        for (index, string) in strings {
            var cString = Array(string.utf8) + [0]  // null-terminated
            let sendRet = CUSBDeviceControlRequest(
                device,
                0x40,   // Host-to-device, vendor, device
                AOAManager.aoaSendString,
                0, index,
                &cString, UInt16(cString.count),
                nil
            )
            if sendRet != kIOReturnSuccess {
                print("[AOAManager] Failed to send accessory string index=\(index): \(sendRet)")
                CUSBDeviceRelease(device)
                lock.lock()
                negotiatingLocations.remove(locationID)
                lock.unlock()
                return
            }
        }

        // Step 3: Start accessory mode (device will re-enumerate with AOA PID)
        let startRet = CUSBDeviceControlRequest(
            device,
            0x40,
            AOAManager.aoaStart,
            0, 0,
            nil, 0,
            nil
        )

        // Device will re-enumerate — just release the handle (never opened with USBDeviceOpen)
        CUSBDeviceRelease(device)

        if startRet == kIOReturnSuccess {
            print("[AOAManager] AOA negotiation complete, waiting for re-enumeration...")
        } else {
            print("[AOAManager] Failed to start accessory mode: \(startRet)")
            lock.lock()
            negotiatingLocations.remove(locationID)
            lock.unlock()
        }
    }

    // MARK: - Open AOA Device

    private func openAOADevice(service: io_service_t, locationID: UInt64) {
        // Retain the service for interface creation
        IOObjectRetain(service)
        defer { IOObjectRelease(service) }

        // Create interface handle (also returns the opened device handle — must stay alive for I/O)
        var interface: CUSBInterfaceRef?
        var deviceRef: CUSBDeviceRef?
        let ret = CUSBCreateInterfaceInterface(service, &interface, &deviceRef)
        guard ret == kIOReturnSuccess, let iface = interface, let dev = deviceRef else {
            print("[AOAManager] Failed to create interface: \(ret)")
            lock.lock()
            negotiatingLocations.remove(locationID)
            lock.unlock()
            return
        }

        let openRet = CUSBInterfaceOpen(iface)
        guard openRet == kIOReturnSuccess else {
            print("[AOAManager] Failed to open interface: \(openRet)")
            CUSBDeviceClose(dev)
            lock.lock()
            negotiatingLocations.remove(locationID)
            lock.unlock()
            return
        }

        // Discover bulk IN and OUT endpoints
        var numEndpoints: UInt8 = 0
        CUSBGetNumEndpoints(iface, &numEndpoints)

        var bulkIn: UInt8 = 0
        var bulkOut: UInt8 = 0

        for i in 1...numEndpoints {
            var direction: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            CUSBGetEndpointInfo(iface, i, &direction, &transferType, &maxPacketSize)

            let dirStr = direction == kUSBIn ? "IN" : "OUT"
            let typeStr = transferType == 2 ? "Bulk" : "Other(\(transferType))"
            print("[AOAManager] Pipe \(i): \(dirStr) \(typeStr) maxPacketSize=\(maxPacketSize)")

            // kUSBBulk = 2
            guard transferType == 2 else { continue }

            if direction == kUSBIn {
                bulkIn = i
            } else if direction == kUSBOut {
                bulkOut = i
            }
        }

        guard bulkIn != 0 && bulkOut != 0 else {
            print("[AOAManager] Could not find bulk IN/OUT endpoints (in=\(bulkIn) out=\(bulkOut))")
            CUSBInterfaceClose(iface)
            CUSBDeviceClose(dev)
            lock.lock()
            negotiatingLocations.remove(locationID)
            lock.unlock()
            return
        }

        print("[AOAManager] AOA accessory opened: bulkIn=\(bulkIn) bulkOut=\(bulkOut) numEndpoints=\(numEndpoints)")

        // Clear stall on both endpoints after SetConfiguration + InterfaceOpen.
        // Resets data toggle on both host and device sides.
        CUSBClearPipeStallBothEnds(iface, bulkIn)
        CUSBClearPipeStallBothEnds(iface, bulkOut)

        // Let the USB stack settle after opening the interface — prevents
        // immediate kIOReturnNotReady errors on the first I/O operation.
        usleep(50_000) // 50ms

        let clientID = UUID()
        lock.withLock {
            negotiatingLocations.remove(locationID)
            connectedDevices[locationID] = clientID
        }

        let transport = AOATransport(
            interface: iface,
            device: dev,
            bulkInPipe: bulkIn,
            bulkOutPipe: bulkOut,
            clientID: clientID
        )

        onAccessoryConnected?(transport, clientID)
    }

    // MARK: - Helpers

    private func getLocationID(_ service: io_service_t) -> UInt64 {
        var locationID: UInt64 = 0
        if let prop = IORegistryEntryCreateCFProperty(service, "locationID" as CFString, kCFAllocatorDefault, 0) {
            if let number = prop.takeRetainedValue() as? NSNumber {
                locationID = number.uint64Value
            }
        }
        return locationID
    }

    deinit {
        stop()
    }
}
