import Cocoa

// MARK: - CGEventTap callback

func eventTapCallback(
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
