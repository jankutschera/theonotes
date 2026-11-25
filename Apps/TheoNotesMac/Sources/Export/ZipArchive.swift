// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import zlib

/// A minimal zip container with stored (uncompressed) entries, enough for an Office Open XML
/// package (A8, MAC11-R15). Names must be ASCII; sizes stay below 4 GiB (no zip64).
enum ZipArchive {
    /// 1980-01-01 00:00, so the same parts always give the same bytes.
    private static let dosDate: UInt16 = 0x0021

    static func data(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = entry.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(entry.data.count))) }
            let offset = UInt32(out.count)
            let size = UInt32(entry.data.count)
            // version 20, flags 0, method 0 (stored), time 0, date, crc, sizes, name length, extra length
            var header = Data()
            header.le(UInt32(0x0403_4B50)); header.le(UInt16(20)); header.le(UInt16(0)); header.le(UInt16(0))
            header.le(UInt16(0)); header.le(dosDate); header.le(crc); header.le(size); header.le(size)
            header.le(UInt16(name.count)); header.le(UInt16(0))
            out += header + name + entry.data

            central.le(UInt32(0x0201_4B50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(dosDate); central.le(crc)
            central.le(size); central.le(size); central.le(UInt16(name.count))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(UInt32(0)); central.le(offset)
            central += name
        }
        let centralOffset = UInt32(out.count)
        out += central
        out.le(UInt32(0x0605_4B50)); out.le(UInt16(0)); out.le(UInt16(0))
        out.le(UInt16(entries.count)); out.le(UInt16(entries.count))
        out.le(UInt32(central.count)); out.le(centralOffset); out.le(UInt16(0))
        return out
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
