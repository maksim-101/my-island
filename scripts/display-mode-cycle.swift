#!/usr/bin/env swift
// SC5 / SHELL-09 instrument carried from Phase 6 UAT row 8: re-runnable display probe, positions only.
//
//   swift scripts/display-mode-cycle.swift --list
//   swift scripts/display-mode-cycle.swift --windows
//   swift scripts/display-mode-cycle.swift --cycle <displayID> <pointWidth>
//
// Exit codes: 0 PASS, 1 FAIL, 2 usage or refused.
// Only --cycle changes display state: it refuses the built-in, inactive and mirrored displays,
// applies the mode for the login session only (.forSession), restores the original mode (also on
// SIGINT or SIGTERM), and prints the my-island `reconcile` lines logged meanwhile. --list and
// --windows are read-only; --windows reads only the bounds of my-island-owned windows, never a
// window title or content.

import CoreGraphics
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    print(message)
    exit(code)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
}

func list() -> Never {
    for id in onlineDisplays() {
        let mirror = CGDisplayMirrorsDisplay(id)
        let mirrorText = mirror == kCGNullDirectDisplay ? "none" : String(mirror)
        var line = "display id=\(id) builtin=\(CGDisplayIsBuiltin(id) != 0) main=\(CGDisplayIsMain(id) != 0) active=\(CGDisplayIsActive(id) != 0) mirrorOf=\(mirrorText)"
        if let mode = CGDisplayCopyDisplayMode(id) {
            line += " mode=\(mode.width)x\(mode.height)pt pixels=\(mode.pixelWidth)x\(mode.pixelHeight) refresh=\(mode.refreshRate)"
        }
        print(line)
        if CGDisplayIsActive(id) != 0, CGDisplayIsBuiltin(id) == 0 {
            let widths = Set(allModes(id).filter { $0.isUsableForDesktopGUI() }.map { $0.width }).sorted()
            print("  widths=\(widths.map(String.init).joined(separator: ","))")
        }
    }
    exit(0)
}

func windows() -> Never {
    let active = onlineDisplays().filter { CGDisplayIsActive($0) != 0 }
    guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]] else {
        fail("could not read window list", code: 1)
    }
    var found = 0
    var ghost = false
    for entry in info {
        guard (entry[kCGWindowOwnerName as String] as? String) == "my-island",
              let b = entry[kCGWindowBounds as String] as? [String: AnyObject],
              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
              let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let onDisplay = active.first { CGDisplayBounds($0).intersects(rect) }
        if onDisplay == nil { ghost = true }
        found += 1
        print("window bounds=\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h)) display=\(onDisplay.map(String.init) ?? "none")")
    }
    if found == 0 { fail("no my-island window on screen", code: 1) }
    if ghost { fail("FAIL: a my-island window lies on no active display", code: 1) }
    exit(0)
}

func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

func cycle(id: CGDirectDisplayID, width: Int) -> Never {
    guard onlineDisplays().contains(id) else { fail("refused: display not online", code: 2) }
    if CGDisplayIsBuiltin(id) != 0 { fail("refused: built-in display", code: 2) }
    if CGDisplayIsActive(id) == 0 { fail("refused: display not active", code: 2) }
    if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { fail("refused: display is mirrored", code: 2) }
    guard let original = CGDisplayCopyDisplayMode(id) else { fail("cannot read current mode", code: 1) }

    let ratio = Double(original.pixelWidth) / Double(original.width)
    let candidates = allModes(id).filter { $0.width == width && $0.isUsableForDesktopGUI() }
    let target = candidates.sorted { a, b in
        func score(_ m: CGDisplayMode) -> Double {
            abs(m.refreshRate - original.refreshRate) * 1000 + abs(Double(m.pixelWidth) / Double(m.width) - ratio)
        }
        return score(a) < score(b)
    }.first
    guard let target else { fail("no mode with width \(width)", code: 2) }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let start = formatter.string(from: Date())

    var interrupts: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            _ = apply(original, to: id)
            print("interrupted, restored \(original.width)x\(original.height)pt")
            exit(130)
        }
        source.resume()
        interrupts.append(source)
    }

    let switched = apply(target, to: id)
    print("switched to \(target.width)x\(target.height)pt")
    Thread.sleep(forTimeInterval: 8)
    let restored = apply(original, to: id)
    print("restored \(original.width)x\(original.height)pt")
    Thread.sleep(forTimeInterval: 8)

    let log = Process()
    log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    log.arguments = ["show", "--predicate", "subsystem == \"com.maksim101.myisland\" AND category == \"NotchPanelController\"", "--start", start, "--style", "compact"]
    let pipe = Pipe()
    log.standardOutput = pipe
    do { try log.run() } catch { fail("cannot run /usr/bin/log: \(error)", code: 1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    log.waitUntilExit()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("reconcile") {
        print(line)
    }
    withExtendedLifetime(interrupts) { exit(switched && restored ? 0 : 1) }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--list" where args.count == 1:
    list()
case "--windows" where args.count == 1:
    windows()
case "--cycle" where args.count == 3:
    guard let id = UInt32(args[1]), let width = Int(args[2]) else { fail("usage: --cycle <displayID> <pointWidth>", code: 2) }
    cycle(id: id, width: width)
default:
    fail("usage: display-mode-cycle.swift --list | --windows | --cycle <displayID> <pointWidth>", code: 2)
}
