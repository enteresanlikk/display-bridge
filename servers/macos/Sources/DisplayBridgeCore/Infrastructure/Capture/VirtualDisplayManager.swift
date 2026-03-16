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

    deinit {
        if virtualDisplayObject != nil {
            print("[VirtualDisplayManager] deinit — destroying orphaned virtual display (ID: \(virtualDisplayID ?? 0))")
            virtualDisplayObject = nil
            virtualDisplayID = nil
        }
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

    /// Helper: [[cls alloc] init] with correct ObjC ownership semantics.
    /// alloc returns +1, init consumes it and returns +1. We use raw pointers
    /// to avoid ARC over-retaining the +1 return, then bridge via
    /// Unmanaged.takeRetainedValue() so ARC takes correct ownership.
    private static func objcAllocInit(_ cls: AnyClass, msgSendPtr: UnsafeMutableRawPointer) -> AnyObject {
        typealias AllocFn = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer
        typealias InitFn  = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer

        let alloc = unsafeBitCast(msgSendPtr, to: AllocFn.self)
        let initFn = unsafeBitCast(msgSendPtr, to: InitFn.self)

        let raw = alloc(cls as AnyObject, NSSelectorFromString("alloc"))
        let obj = initFn(raw, NSSelectorFromString("init"))
        return Unmanaged<AnyObject>.fromOpaque(obj).takeRetainedValue()
    }

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

        // Raw-pointer alloc/init variants — avoids ARC over-retaining +1 returns
        typealias AllocFn     = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer
        typealias InitObjFn   = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?
        typealias InitModeFn  = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
        // ARC-safe types for property access / queries (no ownership transfer)
        typealias BoolObjFn   = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        typealias UInt32Fn    = @convention(c) (AnyObject, Selector) -> UInt32

        let fnAlloc     = unsafeBitCast(msgSendPtr, to: AllocFn.self)
        let fnInitObj   = unsafeBitCast(msgSendPtr, to: InitObjFn.self)
        let fnInitMode  = unsafeBitCast(msgSendPtr, to: InitModeFn.self)
        let fnBoolObj   = unsafeBitCast(msgSendPtr, to: BoolObjFn.self)
        let fnUInt32    = unsafeBitCast(msgSendPtr, to: UInt32Fn.self)

        // 1. Create descriptor: [[CGVirtualDisplayDescriptor alloc] init]
        let descriptor = Self.objcAllocInit(descriptorClass, msgSendPtr: msgSendPtr)

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
        let dispRaw = fnAlloc(displayClass as AnyObject, NSSelectorFromString("alloc"))
        guard let dispPtr = fnInitObj(dispRaw, NSSelectorFromString("initWithDescriptor:"), descriptor) else {
            throw VirtualDisplayError.creationFailed("initWithDescriptor: returned nil")
        }
        let display = Unmanaged<AnyObject>.fromOpaque(dispPtr).takeRetainedValue()

        // 3. Create mode: [[CGVirtualDisplayMode alloc] initWithWidth:height:refreshRate:]
        let modeRaw = fnAlloc(modeClass as AnyObject, NSSelectorFromString("alloc"))
        guard let modePtr = fnInitMode(
            modeRaw,
            NSSelectorFromString("initWithWidth:height:refreshRate:"),
            UInt32(config.width),
            UInt32(config.height),
            Double(config.refreshRate)
        ) else {
            throw VirtualDisplayError.creationFailed("initWithWidth:height:refreshRate: returned nil")
        }
        let mode = Unmanaged<AnyObject>.fromOpaque(modePtr).takeRetainedValue()

        // 4. Create settings, set modes, apply
        let settings = Self.objcAllocInit(settingsClass, msgSendPtr: msgSendPtr)
        (settings as! NSObject).setValue([mode], forKey: "modes")

        let applied = fnBoolObj(display, NSSelectorFromString("applySettings:"), settings)
        if !applied {
            print("[VirtualDisplayManager] Warning: applySettings: returned false")
        }

        // 5. Read displayID via objc_msgSend (UInt32 return, NOT KVC)
        let cgDisplayID = fnUInt32(display, NSSelectorFromString("displayID"))

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
