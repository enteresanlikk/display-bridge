import CoreGraphics
import Foundation
import ObjectiveC

public enum VirtualDisplayError: Error, Sendable {
    case creationFailed(String)
    case apiNotAvailable
}

/// Manages a virtual display for screen capture.
///
/// CGVirtualDisplay is available on macOS 14+ but is not exposed through the
/// public Swift module for CoreGraphics when building with SPM. This
/// implementation uses `objc_msgSend` to dynamically instantiate
/// CGVirtualDisplay at runtime with correct argument types.
///
/// If the runtime classes are not available (macOS 13 or SPM builds without
/// the private framework), the manager falls back to using the main display ID.
public final class VirtualDisplayManager: @unchecked Sendable {
    private static var nextSerial: UInt32 = 1
    private static let serialLock = NSLock()

    private static func allocSerial() -> UInt32 {
        serialLock.lock()
        defer { serialLock.unlock() }
        let s = nextSerial
        nextSerial += 1
        return s
    }

    private var virtualDisplayID: CGDirectDisplayID?
    private var virtualDisplayObject: AnyObject?
    private let lock = NSLock()
    private let serial: UInt32

    public init() {
        self.serial = Self.allocSerial()
    }

    /// Creates a virtual display with the given configuration.
    /// Returns the display ID for the new virtual display.
    public func create(config: DeviceConfig, deviceName: String? = nil) throws -> CGDirectDisplayID {
        lock.lock()
        defer { lock.unlock() }

        if #available(macOS 14.0, *) {
            do {
                return try createVirtualDisplay(config: config, deviceName: deviceName)
            } catch {
                print("[VirtualDisplayManager] Virtual display creation failed: \(error). Using fallback.")
                return createFallbackDisplay(config: config)
            }
        } else {
            return createFallbackDisplay(config: config)
        }
    }

    /// Destroys and recreates the virtual display with a device name suffix.
    /// Returns the new display ID.
    public func recreate(config: DeviceConfig, deviceName: String? = nil) throws -> CGDirectDisplayID {
        lock.lock()

        if virtualDisplayObject != nil {
            print("[VirtualDisplayManager] Recreating virtual display: \(config.width)x\(config.height) deviceName=\(deviceName ?? "nil")")
            virtualDisplayObject = nil
            virtualDisplayID = nil
        }

        // Release lock and wait for macOS to fully tear down the old display
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.3)
        lock.lock()
        defer { lock.unlock() }

        if #available(macOS 14.0, *) {
            do {
                return try createVirtualDisplay(config: config, deviceName: deviceName)
            } catch {
                print("[VirtualDisplayManager] Recreate failed: \(error). Using fallback.")
                return createFallbackDisplay(config: config)
            }
        } else {
            return createFallbackDisplay(config: config)
        }
    }

    /// Destroys the virtual display if one exists.
    public func destroy() {
        lock.lock()
        defer { lock.unlock() }

        if virtualDisplayObject != nil {
            print("[VirtualDisplayManager] Destroying virtual display (ID: \(virtualDisplayID ?? 0))")
        }
        virtualDisplayObject = nil
        virtualDisplayID = nil
    }

    /// Returns the current virtual display ID, if any.
    public var displayID: CGDirectDisplayID? {
        lock.lock()
        defer { lock.unlock() }
        return virtualDisplayID
    }

    // MARK: - macOS 14+ CGVirtualDisplay via objc_msgSend

    @available(macOS 14.0, *)
    private func createVirtualDisplay(config: DeviceConfig, deviceName: String? = nil) throws -> CGDirectDisplayID {
        guard let descriptorClass: AnyClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let displayClass: AnyClass = NSClassFromString("CGVirtualDisplay"),
              let settingsClass: AnyClass = NSClassFromString("CGVirtualDisplaySettings"),
              let modeClass: AnyClass = NSClassFromString("CGVirtualDisplayMode") else {
            throw VirtualDisplayError.apiNotAvailable
        }

        // Load objc_msgSend via dlsym (Swift marks it unavailable directly)
        guard let msgSendPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            throw VirtualDisplayError.creationFailed("dlsym(objc_msgSend) failed")
        }

        typealias MsgSendVoid = @convention(c) (AnyObject, Selector) -> AnyObject
        typealias MsgSendObj1 = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        typealias MsgSendBool1 = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        typealias MsgSendUInt32 = @convention(c) (AnyObject, Selector) -> UInt32
        typealias MsgSendInitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?

        let msgSend = unsafeBitCast(msgSendPtr, to: MsgSendVoid.self)
        let msgSendObj1 = unsafeBitCast(msgSendPtr, to: MsgSendObj1.self)
        let msgSendBool1 = unsafeBitCast(msgSendPtr, to: MsgSendBool1.self)
        let msgSendUInt32 = unsafeBitCast(msgSendPtr, to: MsgSendUInt32.self)
        let msgSendInitMode = unsafeBitCast(msgSendPtr, to: MsgSendInitMode.self)

        // 1. Create descriptor: [[CGVirtualDisplayDescriptor alloc] init]
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("init")
        let descriptorRaw = msgSend(descriptorClass as AnyObject, allocSel)
        let descriptor = msgSend(descriptorRaw, initSel)

        // Set descriptor properties via KVC
        let queue = DispatchQueue(label: "com.displaybridge.virtualdisplay")
        (descriptor as! NSObject).setValue(queue, forKey: "queue")

        var displayName = "DisplayBridge"
        if let deviceName = deviceName, !deviceName.isEmpty {
            displayName = deviceName
        }
        (descriptor as! NSObject).setValue(displayName, forKey: "name")

        if (descriptor as! NSObject).responds(to: NSSelectorFromString("setMaxPixelsWide:")) {
            (descriptor as! NSObject).setValue(config.width, forKey: "maxPixelsWide")
            (descriptor as! NSObject).setValue(config.height, forKey: "maxPixelsHigh")
        }

        // Size in millimeters (approximate, based on ~110 PPI)
        let mmWidth = Double(config.width) / 110.0 * 25.4
        let mmHeight = Double(config.height) / 110.0 * 25.4
        if (descriptor as! NSObject).responds(to: NSSelectorFromString("setSizeInMillimeters:")) {
            (descriptor as! NSObject).setValue(CGSize(width: mmWidth, height: mmHeight), forKey: "sizeInMillimeters")
        }

        if (descriptor as! NSObject).responds(to: NSSelectorFromString("setProductID:")) {
            (descriptor as! NSObject).setValue(0xDB01, forKey: "productID")
            (descriptor as! NSObject).setValue(0xDB00, forKey: "vendorID")
            (descriptor as! NSObject).setValue(self.serial, forKey: "serialNum")
        }

        // 2. Create display: [[CGVirtualDisplay alloc] initWithDescriptor:descriptor]
        let displayRaw = msgSend(displayClass as AnyObject, allocSel)
        let initWithDescSel = NSSelectorFromString("initWithDescriptor:")
        guard let display = msgSendObj1(displayRaw, initWithDescSel, descriptor) else {
            throw VirtualDisplayError.creationFailed("initWithDescriptor: returned nil")
        }

        // 3. Create mode: [[CGVirtualDisplayMode alloc] initWithWidth:height:refreshRate:]
        let modeRaw = msgSend(modeClass as AnyObject, allocSel)
        let initModeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let mode = msgSendInitMode(
            modeRaw,
            initModeSel,
            UInt32(config.width),
            UInt32(config.height),
            Double(config.refreshRate)
        ) else {
            throw VirtualDisplayError.creationFailed("initWithWidth:height:refreshRate: returned nil")
        }

        // 4. Create settings, set modes, apply
        let settingsRaw = msgSend(settingsClass as AnyObject, allocSel)
        let settings = msgSend(settingsRaw, initSel)
        (settings as! NSObject).setValue([mode], forKey: "modes")

        let applySel = NSSelectorFromString("applySettings:")
        let applied = msgSendBool1(display, applySel, settings)
        if !applied {
            print("[VirtualDisplayManager] Warning: applySettings: returned false")
        }

        // 5. Read displayID via objc_msgSend (UInt32 return, NOT KVC)
        let displayIDSel = NSSelectorFromString("displayID")
        let cgDisplayID = msgSendUInt32(display, displayIDSel)

        if cgDisplayID != 0 {
            self.virtualDisplayObject = display
            self.virtualDisplayID = cgDisplayID
            print("[VirtualDisplayManager] Virtual display created successfully (ID: \(cgDisplayID), \(config.width)x\(config.height)@\(config.refreshRate)Hz)")
            return cgDisplayID
        }

        throw VirtualDisplayError.creationFailed("displayID returned 0")
    }

    // MARK: - Fallback

    private func createFallbackDisplay(config: DeviceConfig) -> CGDirectDisplayID {
        let mainDisplay = CGMainDisplayID()
        self.virtualDisplayID = mainDisplay
        print("[VirtualDisplayManager] Using main display \(mainDisplay) as fallback (\(config.width)x\(config.height)@\(config.refreshRate)Hz).")
        return mainDisplay
    }
}
