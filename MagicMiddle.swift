import Cocoa

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

// MARK: - State

// Module-level globals are required because the multitouch callback is @convention(c)
// and cannot capture any Swift context.

var isMiddleClicking  = false
var centerTouchActive = false  // true when exactly one finger rests in the center zone

// Trigger zone, symmetric around 0.5. Default half-width 0.1 → zone 0.40–0.60.
var centerZoneLow:  Float = 0.4
var centerZoneHigh: Float = 0.6

// Opaque pointer IDs of built-in trackpad devices, used to filter them in the MT callback.
// Written once on the main thread at startup; read from the MT callback thread.
var trackpadDeviceIDs = Set<Int>()
var trackpadEnabled   = false

// MARK: - Multitouch callback

// @convention(c) closure — cannot capture context; reads module-level globals directly.
private let mtCallback: @convention(c) (
    UnsafeMutableRawPointer?,   // device
    UnsafeRawPointer?,          // finger array
    Int32,                      // finger count
    Double,                     // timestamp
    Int32                       // frame
) -> Void = { devicePtr, fingersRaw, count, _, _ in
    // Ignore events from built-in trackpad devices when trackpad support is disabled.
    if let ptr = devicePtr, trackpadDeviceIDs.contains(Int(bitPattern: ptr)), !trackpadEnabled {
        return
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

// MARK: - CGEventTap callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if isMiddleClicking {
        switch type {
        case .leftMouseDragged:
            return middleEvent(type: .otherMouseDragged, from: event)
        case .leftMouseUp:
            isMiddleClicking = false
            return middleEvent(type: .otherMouseUp, from: event)
        default:
            return nil
        }
    }

    if type == .leftMouseDown, event.flags.contains(.maskSecondaryFn) || centerTouchActive {
        isMiddleClicking  = true
        centerTouchActive = false
        return middleEvent(type: .otherMouseDown, from: event)
    }

    return Unmanaged.passUnretained(event)
}

private func middleEvent(type: CGEventType, from source: CGEvent) -> Unmanaged<CGEvent>? {
    guard let e = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: source.location,
        mouseButton: .center
    ) else { return nil }
    e.timestamp = source.timestamp
    return Unmanaged.passRetained(e)
}

// MARK: - Preferences window

private enum DefaultsKey {
    static let halfWidth       = "centerZoneHalfWidth"
    static let trackpadEnabled = "trackpadEnabled"
}

class PreferencesWindowController: NSWindowController {
    private var slider:           NSSlider!
    private var rangeLabel:       NSTextField!
    private var trackpadCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 165),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "MagicMiddle Preferences"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
        syncUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Trigger Zone Width")
        heading.font  = .boldSystemFont(ofSize: 13)
        heading.frame = NSRect(x: 20, y: 123, width: 300, height: 18)
        cv.addSubview(heading)

        for (text, x) in [("Narrow", 20), ("Wide", 292)] {
            let label = NSTextField(labelWithString: text)
            label.font      = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame     = NSRect(x: x, y: 77, width: 48, height: 15)
            cv.addSubview(label)
        }

        // Slider: half-width range 0.05 (10% zone) … 0.45 (90% zone)
        slider = NSSlider(value: 0.1, minValue: 0.05, maxValue: 0.45,
                          target: self, action: #selector(sliderChanged))
        slider.frame = NSRect(x: 20, y: 93, width: 300, height: 22)
        cv.addSubview(slider)

        rangeLabel = NSTextField(labelWithString: "")
        rangeLabel.font      = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.alignment = .center
        rangeLabel.frame     = NSRect(x: 20, y: 55, width: 300, height: 18)
        cv.addSubview(rangeLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.frame   = NSRect(x: 20, y: 44, width: 300, height: 1)
        cv.addSubview(divider)

        trackpadCheckbox = NSButton(checkboxWithTitle: "Also enable on trackpad",
                                    target: self, action: #selector(trackpadToggled))
        trackpadCheckbox.frame = NSRect(x: 18, y: 16, width: 280, height: 20)
        cv.addSubview(trackpadCheckbox)
    }

    private func syncUI() {
        let hw = (centerZoneHigh - centerZoneLow) / 2.0
        slider.floatValue      = hw
        trackpadCheckbox.state = trackpadEnabled ? .on : .off
        updateRangeLabel(halfWidth: hw)
    }

    @objc private func sliderChanged() {
        let hw = slider.floatValue
        centerZoneLow  = 0.5 - hw
        centerZoneHigh = 0.5 + hw
        updateRangeLabel(halfWidth: hw)
        UserDefaults.standard.set(hw, forKey: DefaultsKey.halfWidth)
    }

    @objc private func trackpadToggled() {
        trackpadEnabled = trackpadCheckbox.state == .on
        UserDefaults.standard.set(trackpadEnabled, forKey: DefaultsKey.trackpadEnabled)
    }

    private func updateRangeLabel(halfWidth: Float) {
        rangeLabel.stringValue = String(
            format: "Active zone: %.2f – %.2f  (%.0f%% of surface)",
            0.5 - halfWidth, 0.5 + halfWidth, halfWidth * 200
        )
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem:  NSStatusItem!
    private var prefsWindow: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
              let pStart    = dlsym(handle, "MTDeviceStart") else { return }

        typealias MTDeviceRef  = AnyObject
        typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
        typealias CallbackFn   = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
        typealias RegisterFn   = @convention(c) (AnyObject, CallbackFn) -> Void
        typealias StartFn      = @convention(c) (AnyObject, Int32) -> Int32
        typealias IsBuiltInFn  = @convention(c) (AnyObject) -> Bool

        let createList = unsafeBitCast(pCreate,   to: CreateListFn.self)
        let register_  = unsafeBitCast(pRegister, to: RegisterFn.self)
        let start      = unsafeBitCast(pStart,    to: StartFn.self)
        let isBuiltIn  = dlsym(handle, "MTDeviceIsBuiltIn")
                            .map { unsafeBitCast($0, to: IsBuiltInFn.self) }

        guard let devices = createList()?.takeRetainedValue() as? [MTDeviceRef] else { return }

        for device in devices {
            // Tag built-in trackpad devices so the MT callback can filter them.
            if isBuiltIn?(device) == true {
                let ptr = Unmanaged.passUnretained(device).toOpaque()
                trackpadDeviceIDs.insert(Int(bitPattern: ptr))
            }
            register_(device, mtCallback)
            _ = start(device, 0)
        }
    }

    @objc private func openPreferences() {
        if prefsWindow == nil { prefsWindow = PreferencesWindowController() }
        prefsWindow?.show()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - Entry point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
