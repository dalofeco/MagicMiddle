import Cocoa
import IOKit.hid

// MARK: - MultitouchSupport private framework types

// Binary-compatible layout of MultitouchSupport.framework's internal MTFinger C struct.
// Swift's natural alignment inserts 4 bytes of padding between `frame` (Int32) and
// `timestamp` (Double), exactly matching the C compiler's layout.
private struct MTFinger {
    var frame: Int32        // offset  0
                            // +4 bytes padding (Double alignment)
    var timestamp: Double   // offset  8
    var identifier: Int32   // offset 16
    var state: Int32        // offset 20  (1–6 = finger is active, see MTTouchState)
    var unknown1: Int32     // offset 24
    var unknown2: Int32     // offset 28
    var normalizedX: Float  // offset 32  (0.0 = left edge, 1.0 = right edge)
    var normalizedY: Float  // offset 36  (0.0 = bottom, 1.0 = top)
    var size: Float         // offset 40
    var zero1: Int32        // offset 44
    var angle: Float        // offset 48
    var majorAxis: Float    // offset 52
    var minorAxis: Float    // offset 56
    var mmX: Float          // offset 60
    var mmY: Float          // offset 64
    var zero2a: Int32       // offset 68
    var zero2b: Int32       // offset 72
    var density: Float      // offset 76
}                           // total: 80 bytes

// MTTouchState: 0=NotTracking, 1=StartInRange, 2=HoverInRange, 3=MakeTouch,
//               4=Touching, 5=BreakTouch, 6=LingerInRange, 7=OutOfRange

// MARK: - MultitouchSupport type aliases (module-scope for @convention(c) callbacks)

private typealias MTContactCallbackFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
private typealias MTNotifyCallbackFn  = @convention(c) (AnyObject, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias MTAddObserverFn     = @convention(c) (MTNotifyCallbackFn, UnsafeMutableRawPointer?) -> Void

// MARK: - Raw dlsym pointers for MT functions

// Written once at startup on the main thread; safe to read from any thread thereafter.
var mtCreateListFnPtr: UnsafeMutableRawPointer? = nil
var mtRegisterFnPtr:   UnsafeMutableRawPointer? = nil
var mtStartFnPtr:      UnsafeMutableRawPointer? = nil
var mtIsBuiltInFnPtr:  UnsafeMutableRawPointer? = nil

// Opaque pointer IDs of MT devices that have already had mtCallback registered.
// Guards against double-registration when multiple notification paths fire for the same event.
var mtRegisteredDeviceIDs = Set<Int>()

// Pending debounced enumeration work item. Coalesces rapid-fire IOHIDManager callbacks
// (e.g. one per connected HID device at startup) into a single reenumerateMTDevices() call.
var pendingMTEnumeration: DispatchWorkItem? = nil

// MARK: - MT device enumeration

// Calls MTDeviceCreateList and registers mtCallback on any device not yet seen.
// Safe to call multiple times; skips devices already in mtRegisteredDeviceIDs.
// Returns true if at least one non-built-in (peripheral) device was found and registered.
@discardableResult
func reenumerateMTDevices() -> Bool {
    guard let createPtr   = mtCreateListFnPtr,
          let registerPtr = mtRegisterFnPtr,
          let startPtr    = mtStartFnPtr else {
        logger.warning("reenumerateMTDevices: called before MT framework was loaded, skipping")
        return false
    }

    typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    typealias RegisterFn   = @convention(c) (AnyObject, MTContactCallbackFn) -> Void
    typealias StartFn      = @convention(c) (AnyObject, Int32) -> Int32
    typealias IsBuiltInFn  = @convention(c) (AnyObject) -> Bool

    guard let devices = unsafeBitCast(createPtr, to: CreateListFn.self)()?.takeRetainedValue() as? [AnyObject] else {
        logger.error("reenumerateMTDevices: MTDeviceCreateList returned nil")
        return false
    }

    logger.debug("reenumerateMTDevices: \(devices.count) device(s) currently visible")

    var foundPeripheral = false
    for device in devices {
        // Pointer address is stable within a single MTDeviceCreateList call, which is all we need
        // for intra-call deduplication. The set is cleared on disconnect so stale pointers never block re-registration.
        let id = Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        let isBuiltIn = mtIsBuiltInFnPtr.map { unsafeBitCast($0, to: IsBuiltInFn.self)(device) } ?? false

        if !isBuiltIn { foundPeripheral = true }

        if mtRegisteredDeviceIDs.contains(id) {
            logger.debug("reenumerateMTDevices: device \(id) already registered, skipping")
            continue
        }

        logger.info("reenumerateMTDevices: registering device \(id) (builtIn=\(isBuiltIn))")
        mtRegisteredDeviceIDs.insert(id)

        unsafeBitCast(registerPtr, to: RegisterFn.self)(device, mtCallback)
        _ = unsafeBitCast(startPtr, to: StartFn.self)(device, 0)
    }
    return foundPeripheral
}

// MARK: - Multitouch callbacks

// @convention(c) closure — cannot capture context; reads module-level globals directly.
let mtCallback: @convention(c) (
    UnsafeMutableRawPointer?,   // device
    UnsafeRawPointer?,          // finger array
    Int32,                      // finger count
    Double,                     // timestamp
    Int32                       // frame
) -> Void = { devicePtr, fingersRaw, count, _, _ in
    // Ignore events from built-in trackpad devices when trackpad support is disabled.
    if !trackpadEnabled, let ptr = devicePtr {
        typealias IsBuiltInFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
        if let fnPtr = mtIsBuiltInFnPtr, unsafeBitCast(fnPtr, to: IsBuiltInFn.self)(ptr) {
            return
        }
    }

    guard let fingersRaw, count > 0 else {
        centerTouchActive = false
        return
    }

    let fingers = fingersRaw.assumingMemoryBound(to: MTFinger.self)
    var activeCount = 0
    var centerFound = false

    for i in 0..<Int(count) {
        let f = fingers[i]
        guard (1...6).contains(f.state) else { continue }
        activeCount += 1
        if activeCount > 1 { break }
        centerFound = (centerZoneLow...centerZoneHigh).contains(f.normalizedX)
    }

    centerTouchActive = activeCount == 1 && centerFound
}

// Called when a multitouch-capable peripheral is connected after launch.
let mtConnectCallback: @convention(c) (AnyObject, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { device, _, _ in
    let id = Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    logger.info("MT notification: device connected \(id)")
    reenumerateMTDevices()
}

// Called when a multitouch-capable peripheral is disconnected.
// Clears its IDs so reenumerateMTDevices() will re-register it on the next reconnect.
let mtDisconnectCallback: @convention(c) (AnyObject, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { device, _, _ in
    let id = Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    logger.info("MT notification: device disconnected \(id)")
    mtRegisteredDeviceIDs.removeAll()
}
