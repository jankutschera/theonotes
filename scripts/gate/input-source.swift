// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Gate item 2: list or select keyboard input sources (TISSelectInputSource).
// Usage: swift scripts/gate/input-source.swift list
//        swift scripts/gate/input-source.swift current
//        swift scripts/gate/input-source.swift select <input-source-id>
//   e.g. com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese
//        com.apple.inputmethod.SCIM.ITABC   (Simplified Chinese Pinyin)
//        com.apple.keylayout.ABC            (back to Latin)
import Carbon
import Foundation

func id(_ source: TISInputSource) -> String {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func sources(includeAll: Bool) -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
    return (TISCreateInputSourceList(filter, includeAll)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "list":
    sources(includeAll: false).forEach { print(id($0)) }
case "current":
    print(id(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
case "select":
    guard let wanted = args.dropFirst().first else { print("missing input source id"); exit(2) }
    guard let source = sources(includeAll: true).first(where: { id($0) == wanted }) else {
        print("input source \(wanted) not found; enable it in System Settings > Keyboard > Input Sources")
        exit(1)
    }
    _ = TISEnableInputSource(source) // no-op if already enabled
    let status = TISSelectInputSource(source)
    print(status == noErr ? "selected \(wanted)" : "TISSelectInputSource failed: \(status)")
    exit(status == noErr ? 0 : 1)
default:
    print("usage: input-source.swift list | current | select <id>")
    exit(2)
}
