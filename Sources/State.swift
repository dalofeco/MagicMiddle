import Foundation

// Module-level globals are required because the multitouch callback is @convention(c)
// and cannot capture any Swift context.

var isMiddleClicking  = false
var centerTouchActive = false  // true when exactly one finger rests in the center zone

// Trigger zone, symmetric around 0.5. Default half-width 0.1 → zone 0.40–0.60.
var centerZoneLow:  Float = 0.4
var centerZoneHigh: Float = 0.6

var trackpadEnabled = false
