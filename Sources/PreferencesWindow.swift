import Cocoa

// MARK: - Preferences window

enum DefaultsKey {
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
