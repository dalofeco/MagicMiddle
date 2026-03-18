import Cocoa
import IOKit.hid
import os

let logger = Logger(subsystem: "com.magicmiddle", category: "devices")

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem:  NSStatusItem!
    private var prefsWindow: PreferencesWindowController?
    private var hidManager:  IOHIDManager?   // retained to keep device-match callbacks alive

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("MagicMiddle starting up (version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", privacy: .public))")
        loadPreferences()
        setupStatusBar()
        requestAccessibility()
        setupEventTap()
        setupMultitouchMonitor()
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.halfWidth) != nil {
            let hw = defaults.float(forKey: DefaultsKey.halfWidth)
            centerZoneLow  = 0.5 - hw
            centerZoneHigh = 0.5 + hw
        }
        trackpadEnabled = defaults.bool(forKey: DefaultsKey.trackpadEnabled)
    }

    private func makeMenuBarIcon() -> NSImage {
        if let image = Bundle.main.image(forResource: "mmstatus") {
            image.isTemplate = true
            return image
        }
        // Fallback: draw "MM" glyphs programmatically
        let size = NSSize(width: 24, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let strokeWidth: CGFloat = 1.5
            let pad    = strokeWidth / 2 + 2.5
            let top    = rect.maxY - pad
            let bottom = rect.minY + pad
            let glyphW: CGFloat = 8.5
            let gap:    CGFloat = 2.5

            NSColor.black.setStroke()

            func drawM(originX x: CGFloat) {
                let left  = x
                let right = x + glyphW
                let mid   = x + glyphW / 2
                let peak  = bottom + (top - bottom) * 0.38

                let path = NSBezierPath()
                path.lineWidth     = strokeWidth
                path.lineCapStyle  = .round
                path.lineJoinStyle = .miter

                path.move(to: NSPoint(x: left,  y: bottom))
                path.line(to: NSPoint(x: left,  y: top))
                path.line(to: NSPoint(x: mid,   y: peak))
                path.line(to: NSPoint(x: right, y: top))
                path.line(to: NSPoint(x: right, y: bottom))
                path.stroke()
            }

            drawM(originX: pad)
            drawM(originX: pad + glyphW + gap)

            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeMenuBarIcon()
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MagicMiddle", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func requestAccessibility() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts)
    }

    private func setupEventTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.leftMouseUp.rawValue)
                              | (1 << CGEventType.leftMouseDragged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: nil
        ) else { exit(1) }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func setupMultitouchMonitor() {
        let fwPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle    = dlopen(fwPath, RTLD_NOW),
              let pCreate   = dlsym(handle, "MTDeviceCreateList"),
              let pRegister = dlsym(handle, "MTRegisterContactFrameCallback"),
              let pStart    = dlsym(handle, "MTDeviceStart") else {
            logger.error("setupMultitouchMonitor: failed to load MultitouchSupport framework or required symbols")
            return
        }

        // Store raw pointers so reenumerateMTDevices() and @convention(c) callbacks can use them.
        mtCreateListFnPtr = pCreate
        mtRegisterFnPtr   = pRegister
        mtStartFnPtr      = pStart
        mtIsBuiltInFnPtr  = dlsym(handle, "MTDeviceIsBuiltIn")
        logger.info("setupMultitouchMonitor: framework loaded, MTDeviceIsBuiltIn=\(mtIsBuiltInFnPtr != nil)")

        // Also try the private MT notification API — fires instantly on connect/disconnect
        // but is not available on all macOS versions or device configurations.
        let mtNotifyConnect    = dlsym(handle, "MTDeviceNotificationAddConnectObserver")
        let mtNotifyDisconnect = dlsym(handle, "MTDeviceNotificationAddRemoveObserver")
        logger.info("setupMultitouchMonitor: MT notification API — connect=\(mtNotifyConnect != nil), disconnect=\(mtNotifyDisconnect != nil)")
        if let pAddConnect = mtNotifyConnect, let pAddDisconnect = mtNotifyDisconnect {
            typealias MTAddObserverFn = @convention(c) (
                @convention(c) (AnyObject, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
                UnsafeMutableRawPointer?
            ) -> Void
            let addConnect    = unsafeBitCast(pAddConnect,    to: MTAddObserverFn.self)
            let addDisconnect = unsafeBitCast(pAddDisconnect, to: MTAddObserverFn.self)
            addConnect(mtConnectCallback, nil)
            addDisconnect(mtDisconnectCallback, nil)
            logger.info("setupMultitouchMonitor: MT notification observers registered")
        }

        // Use IOHIDManager as a reliable complement: fires on every HID device connection,
        // triggering re-enumeration so newly reconnected touch devices are never missed.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, _ in
            // Debounce: cancel any pending work and reschedule. This coalesces the burst of
            // per-device callbacks that IOHIDManager fires for every connected HID device at
            // startup (and on reconnect) into a single reenumerateMTDevices() call.
            pendingMTEnumeration?.cancel()
            let work = DispatchWorkItem {
                logger.info("IOHIDManager: triggering re-enumeration")
                guard !reenumerateMTDevices() else { return }
                // No peripheral found yet — Bluetooth devices (e.g. Magic Mouse) appear in the
                // MT framework later than the HID layer. Retry at increasing intervals.
                func retryIfNeeded(_ delays: [Double]) {
                    guard let next = delays.first else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + next) {
                        guard !reenumerateMTDevices() else { return }
                        retryIfNeeded(Array(delays.dropFirst()))
                    }
                }
                retryIfNeeded([0.5, 1.5, 3.0, 6.0])
            }
            pendingMTEnumeration = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, _ in
            logger.info("IOHIDManager: device removed, clearing all MT device registrations")
            // All pointer-based IDs are stale after any reconnect cycle; clear the set so
            // reenumerateMTDevices() re-registers every device with fresh pointers.
            mtRegisteredDeviceIDs.removeAll()
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        logger.info("setupMultitouchMonitor: IOHIDManager open result=\(openResult)")
        hidManager = manager
    }

    @objc private func openPreferences() {
        if prefsWindow == nil { prefsWindow = PreferencesWindowController() }
        prefsWindow?.show()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }
}
