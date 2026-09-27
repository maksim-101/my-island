#!/usr/bin/env swift
// D-06 gap closure (07-15, gap-15 Task 1): re-runnable, positions-only measurement of the
// MacBook collapsed pill against the live menu bar and the "Show Hidden Menu Bar Items" chevron.
// Run with: swift scripts/notch-clearance-probe.swift
//
// House style follows scripts/clickthrough-probe.sh (exit-code convention: 0 PASS / 1 FAIL / 2
// SKIP) and .planning/quick/260925-osd-symmetric-narrow-notch-wings/evidence/measure-bar.swift
// (the CGWindowListCopyWindowInfo idiom, and its lesson: derive expectations from live values,
// not session literals). Positions only: never captures pixels, never reads window titles, and
// prints nothing about status items other than the one chevron button.

import CoreGraphics
import AppKit
import ApplicationServices

func boundsOf(_ entry: [String: AnyObject]) -> CGRect? {
    guard let b = entry[kCGWindowBounds as String] as? [String: AnyObject],
          let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
          let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
}

func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = axAttribute(element, attribute) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = axAttribute(element, attribute) else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axAttribute(element, attribute) as? String
}

func axChildren(_ element: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
    (axAttribute(element, attribute) as? [AXUIElement]) ?? []
}

// Depth <= 6, first match wins — the chevron is a shallow descendant of the per-display
// MenuBarAgent window in practice, but this walks the whole subtree defensively.
func findChevron(in element: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth <= 6 else { return nil }
    if axString(element, kAXRoleAttribute) == (kAXButtonRole as String),
       axString(element, kAXDescriptionAttribute) == "Show Hidden Menu Bar Items" {
        return element
    }
    for child in axChildren(element) {
        if let found = findChevron(in: child, depth: depth + 1) {
            return found
        }
    }
    return nil
}

func myIslandWindows(on bounds: CGRect) -> [CGRect] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: AnyObject]] else { return [] }
    var results: [CGRect] = []
    for entry in list {
        guard let owner = entry[kCGWindowOwnerName as String] as? String, owner == "my-island" else { continue }
        guard let rect = boundsOf(entry) else { continue }
        // Top edge at the display's own top, x inside its bounds (with margin for the overlay,
        // which is wider than the interactive panel and can start left of the notch anchor).
        guard abs(rect.origin.y - bounds.origin.y) < 1.0 else { continue }
        guard rect.origin.x >= bounds.origin.x - 80, rect.maxX <= bounds.maxX + 80 else { continue }
        results.append(rect)
    }
    return results
}

func menuBarRect(on bounds: CGRect, level: CGWindowLevel) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: AnyObject]] else { return nil }
    for entry in list {
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == Int(level) else { continue }
        guard let rect = boundsOf(entry) else { continue }
        if abs(rect.origin.x - bounds.origin.x) < 0.5, abs(rect.origin.y - bounds.origin.y) < 0.5,
           abs(rect.width - bounds.width) < 0.5 {
            return rect
        }
    }
    return nil
}

// (1) Built-in display.
var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displays, &displayCount)

guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
    print("SKIP no built-in display active")
    exit(2)
}
let builtinBounds = CGDisplayBounds(builtinID)
let builtinScreen = NSScreen.screens.first { screen in
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
    return CGDirectDisplayID(number.uint32Value) == builtinID
}
let safeAreaTop = builtinScreen?.safeAreaInsets.top ?? 0
print("builtin display=\(builtinID) bounds=\(builtinBounds) safeAreaTop=\(safeAreaTop)")

// (2) Menu-bar height.
let menuBarLevel = CGWindowLevelForKey(.mainMenuWindow)
guard let mbRect = menuBarRect(on: builtinBounds, level: menuBarLevel) else {
    print("SKIP menu bar not on screen")
    exit(2)
}
let menuBarHeight = mbRect.height
print("menuBar height=\(menuBarHeight) rect=\(mbRect)")

// (3) my-island windows on the built-in — poll up to 10s for both the interactive panel and the
// click-through overlay to be on screen.
var found: [CGRect] = []
for _ in 0..<20 {
    found = myIslandWindows(on: builtinBounds)
    if found.count >= 2 { break }
    usleep(500_000)
}
guard !found.isEmpty else {
    print("SKIP my-island not running")
    exit(2)
}
found.sort { $0.width < $1.width }
let pillWindow = found[0]
let pillWidthInt = Int(pillWindow.width.rounded())
guard pillWidthInt == 257 || pillWidthInt == 258 else {
    print("SKIP panel not collapsed (move the pointer off the notch) width=\(pillWindow.width)")
    exit(2)
}
let cx = pillWindow.origin.x + pillWindow.width / 2
print("pill window=\(pillWindow) cx=\(cx)")

// (4) Vertical gate — from collapsedSurfaceFrame's own formula: window height = depth + sag + 6.
let windowHeight = pillWindow.height
let shoulderFloor = windowHeight - 9
let drawnFloor = windowHeight - 6
let overhang = drawnFloor - menuBarHeight
let verticalPass = shoulderFloor <= menuBarHeight
print("vertical windowHeight=\(windowHeight) menuBar=\(menuBarHeight) shoulderFloor=\(shoulderFloor) drawnFloor=\(drawnFloor) overhang=\(overhang) \(verticalPass ? "PASS" : "FAIL")")

var housingPass = true
if safeAreaTop == 0 {
    print("INFO housing gate skipped (safeAreaTop reads 0)")
} else {
    housingPass = shoulderFloor >= safeAreaTop
    print("housing shoulderFloor=\(shoulderFloor) safeAreaTop=\(safeAreaTop) \(housingPass ? "PASS" : "FAIL")")
}

// (5) Chevron — INFO only, never gates PASS/FAIL. Non-prompting trust check only.
if !AXIsProcessTrusted() {
    print("INFO chevron unavailable (accessibility not trusted)")
} else if let menuBarAgent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first {
    let appElement = AXUIElementCreateApplication(menuBarAgent.processIdentifier)
    var chevron: AXUIElement?
    for window in axChildren(appElement, kAXWindowsAttribute) {
        guard let pos = axPoint(window, kAXPositionAttribute), let size = axSize(window, kAXSizeAttribute) else { continue }
        let winRect = CGRect(origin: pos, size: size)
        guard abs(winRect.origin.x - mbRect.origin.x) < 0.5, abs(winRect.origin.y - mbRect.origin.y) < 0.5,
              abs(winRect.width - mbRect.width) < 0.5, abs(winRect.height - mbRect.height) < 0.5 else { continue }
        if let match = findChevron(in: window, depth: 0) {
            chevron = match
            break
        }
    }
    if let chevron, let pos = axPoint(chevron, kAXPositionAttribute), let size = axSize(chevron, kAXSizeAttribute) {
        let globalFrame = CGRect(origin: pos, size: size)
        let relMinX = globalFrame.origin.x - cx
        let relMaxX = relMinX + globalFrame.width
        let entersFrameBy = 128.5 - relMinX
        print("chevron global=\(globalFrame) relMinX=\(relMinX) relMaxX=\(relMaxX) entersFrameBy=\(entersFrameBy)")
    } else {
        print("INFO chevron absent")
    }
} else {
    print("INFO chevron absent (com.apple.MenuBarAgent not running)")
}

// (6) Controlled comparison — every non-built-in display, INFO only.
for displayID in displays where displayID != builtinID {
    let bounds = CGDisplayBounds(displayID)
    guard let otherMenuBar = menuBarRect(on: bounds, level: menuBarLevel) else {
        print("INFO display=\(displayID) menu bar not found")
        continue
    }
    let otherWindows = myIslandWindows(on: bounds)
    guard let otherPill = otherWindows.min(by: { $0.width < $1.width }) else {
        print("INFO display=\(displayID) no my-island window found")
        continue
    }
    let otherDrawnFloor = otherPill.height - 6
    let otherOverhang = otherDrawnFloor - otherMenuBar.height
    print("compare display=\(displayID) menuBar=\(otherMenuBar.height) drawnFloor=\(otherDrawnFloor) overhang=\(otherOverhang)")
}

// (7) Verdict.
let overallPass = verticalPass && housingPass
print(overallPass ? "RESULT PASS" : "RESULT FAIL")
exit(overallPass ? 0 : 1)
