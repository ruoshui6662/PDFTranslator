import Foundation
import CoreGraphics
import CoreText

/// Extracts standalone TrueType (.ttf) font data from macOS system fonts (.ttf or .ttc)
/// and performs true `glyf`/`loca` glyph subsetting so only used characters are embedded into output PDFs.
public enum FontSubsetter {
    private static let essentialTables: Set<String> = [
        "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "prep"
    ]

    private static let baseRequiredCharacters =
        " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~" +
        "，。、；：？！“”‘’（）《》【】「」『』—…·【译】第页图表摘要引言方法实验结果结论参考文献"

    /// Loads and subsets a TrueType font buffer suitable for `FPDFText_LoadFont(..., FPDF_FONT_TRUETYPE, 1)`.
    public static func loadTrueTypeFontData(
        style: CJKFontStyle,
        usedText: String
    ) -> Data? {
        let candidates: [String]
        switch style {
        case .sansSerif, .sourceHanSans, .pingFang, .hiraginoSans:
            candidates = [
                "/System/Library/Fonts/STHeiti Medium.ttc",
                "/System/Library/Fonts/STHeiti Light.ttc",
                "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
            ]
        case .serif, .autoMatch, .sourceHanSerif:
            candidates = [
                "/System/Library/Fonts/Supplemental/Songti.ttc",
                "/System/Library/Fonts/STHeiti Light.ttc",
                "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
            ]
        case .kaiti:
            candidates = [
                "/Users/ruoshui/Library/Fonts/MacKTGB2312.ttf",
                "/System/Library/Fonts/Supplemental/Kaiti.ttc",
                "/System/Library/Fonts/Supplemental/Songti.ttc",
                "/System/Library/Fonts/STHeiti Light.ttc"
            ]
        case .fangsong:
            candidates = [
                "/Users/ruoshui/Library/Fonts/MacFSGB2312.ttf",
                "/System/Library/Fonts/Supplemental/Songti.ttc",
                "/System/Library/Fonts/STHeiti Light.ttc"
            ]
        }

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path),
                  let rawData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  rawData.count > 32 else {
                continue
            }
            if let extracted = extractAndSubsetTrueType(from: rawData, fontIndex: 0, usedText: usedText) {
                return extracted
            }
        }
        return nil
    }

    /// Unpacks a `.ttc` (TrueType Collection) or `.ttf` into a standalone `.ttf` and subsets its `glyf`/`loca` tables
    /// to only the glyphs needed by `usedText`.
    public static func extractAndSubsetTrueType(
        from data: Data,
        fontIndex: Int = 0,
        usedText: String = ""
    ) -> Data? {
        guard data.count >= 12 else { return nil }
        let magic = readUInt32BE(data, at: 0)
        let tableDirOffset: Int

        if magic == 0x74746366 { // "ttcf"
            let numFonts = Int(readUInt32BE(data, at: 8))
            guard numFonts > 0 else { return nil }
            let idx = min(max(0, fontIndex), numFonts - 1)
            let offsetPos = 12 + idx * 4
            guard offsetPos + 4 <= data.count else { return nil }
            tableDirOffset = Int(readUInt32BE(data, at: offsetPos))
        } else if magic == 0x00010000 || magic == 0x74727565 {
            tableDirOffset = 0
        } else {
            return nil
        }

        guard tableDirOffset + 12 <= data.count else { return nil }
        let sfntVersion = readUInt32BE(data, at: tableDirOffset)
        let numTables = Int(readUInt16BE(data, at: tableDirOffset + 4))
        guard numTables > 0, tableDirOffset + 12 + numTables * 16 <= data.count else { return nil }

        struct RawTableEntry {
            let tag: String
            let tagBytes: UInt32
            let checkSum: UInt32
            let offset: Int
            let length: Int
        }

        var rawEntries: [RawTableEntry] = []
        for i in 0..<numTables {
            let entryOffset = tableDirOffset + 12 + i * 16
            let tagBytes = readUInt32BE(data, at: entryOffset)
            let tagStr = String(bytes: [
                UInt8((tagBytes >> 24) & 0xFF),
                UInt8((tagBytes >> 16) & 0xFF),
                UInt8((tagBytes >> 8) & 0xFF),
                UInt8(tagBytes & 0xFF)
            ], encoding: .ascii) ?? ""
            let checkSum = readUInt32BE(data, at: entryOffset + 4)
            let offset = Int(readUInt32BE(data, at: entryOffset + 8))
            let length = Int(readUInt32BE(data, at: entryOffset + 12))

            guard offset >= 0, length >= 0, offset + length <= data.count else { continue }
            if essentialTables.contains(tagStr) {
                rawEntries.append(RawTableEntry(tag: tagStr, tagBytes: tagBytes, checkSum: checkSum, offset: offset, length: length))
            }
        }

        var tableDataMap: [String: (tagBytes: UInt32, data: Data)] = [:]
        for entry in rawEntries {
            let slice = data.subdata(in: entry.offset..<(entry.offset + entry.length))
            tableDataMap[entry.tag] = (entry.tagBytes, slice)
        }

        guard tableDataMap["cmap"] != nil,
              let glyfTuple = tableDataMap["glyf"],
              let locaTuple = tableDataMap["loca"],
              let headTuple = tableDataMap["head"],
              let maxpTuple = tableDataMap["maxp"] else {
            return nil
        }

        // First assemble the full un-subsetted standalone TTF so CoreText can resolve Unicode -> CGGlyph IDs
        let fullTTF = packSFNT(sfntVersion: sfntVersion, tables: tableDataMap)

        // Perform glyph subsetting on `glyf` + `loca` + `head`
        if let subsetted = subsetGlyfAndLoca(
            fullTTF: fullTTF,
            headData: headTuple.data,
            maxpData: maxpTuple.data,
            locaData: locaTuple.data,
            glyfData: glyfTuple.data,
            usedText: usedText + baseRequiredCharacters
        ) {
            tableDataMap["head"] = (headTuple.tagBytes, subsetted.head)
            tableDataMap["loca"] = (locaTuple.tagBytes, subsetted.loca)
            tableDataMap["glyf"] = (glyfTuple.tagBytes, subsetted.glyf)
            return packSFNT(sfntVersion: sfntVersion, tables: tableDataMap)
        }

        return fullTTF
    }

    private static func subsetGlyfAndLoca(
        fullTTF: Data,
        headData: Data,
        maxpData: Data,
        locaData: Data,
        glyfData: Data,
        usedText: String
    ) -> (head: Data, loca: Data, glyf: Data)? {
        guard headData.count >= 54, maxpData.count >= 6 else { return nil }
        let indexToLocFormat = Int16(bitPattern: readUInt16BE(headData, at: 50))
        let numGlyphs = Int(readUInt16BE(maxpData, at: 4))
        guard numGlyphs > 0 else { return nil }

        // Read original loca offsets
        var origOffsets: [Int] = []
        origOffsets.reserveCapacity(numGlyphs + 1)
        if indexToLocFormat == 0 {
            guard locaData.count >= (numGlyphs + 1) * 2 else { return nil }
            for i in 0...numGlyphs {
                origOffsets.append(Int(readUInt16BE(locaData, at: i * 2)) * 2)
            }
        } else {
            guard locaData.count >= (numGlyphs + 1) * 4 else { return nil }
            for i in 0...numGlyphs {
                origOffsets.append(Int(readUInt32BE(locaData, at: i * 4)))
            }
        }

        // Resolve CGGlyph IDs for all characters in `usedText` via CoreText
        guard let desc = CTFontManagerCreateFontDescriptorFromData(fullTTF as CFData) else {
            return nil
        }
        let ctFont = CTFontCreateWithFontDescriptor(desc, 12.0, nil)
        let utf16Chars = Array(Set(usedText)).flatMap { String($0).utf16 }
        var glyphs = [CGGlyph](repeating: 0, count: utf16Chars.count)
        CTFontGetGlyphsForCharacters(ctFont, utf16Chars, &glyphs, utf16Chars.count)

        var keptGIDs: Set<Int> = [0, 1] // Always keep .notdef (0) and .null (1)
        for g in glyphs where Int(g) < numGlyphs {
            keptGIDs.insert(Int(g))
        }

        // Transitively include component glyphs of composite glyphs
        var queue = Array(keptGIDs)
        while let gid = queue.popLast() {
            guard gid >= 0, gid < numGlyphs else { continue }
            let start = origOffsets[gid]
            let end = origOffsets[gid + 1]
            guard end > start + 10, end <= glyfData.count else { continue }
            let numContours = Int16(bitPattern: readUInt16BE(glyfData, at: start))
            if numContours < 0 {
                var pos = start + 10
                while pos + 4 <= end {
                    let flags = readUInt16BE(glyfData, at: pos)
                    let compGID = Int(readUInt16BE(glyfData, at: pos + 2))
                    if compGID < numGlyphs && !keptGIDs.contains(compGID) {
                        keptGIDs.insert(compGID)
                        queue.append(compGID)
                    }
                    pos += 4
                    // Advance past arguments
                    if (flags & 0x0001) != 0 { pos += 4 } else { pos += 2 }
                    // Advance past transform
                    if (flags & 0x0008) != 0 {
                        pos += 2
                    } else if (flags & 0x0040) != 0 {
                        pos += 4
                    } else if (flags & 0x0080) != 0 {
                        pos += 8
                    }
                    if (flags & 0x0020) == 0 { break } // MORE_COMPONENTS not set
                }
            }
        }

        // Build subsetted `glyf` and long-format `loca`
        var newGlyf = Data()
        newGlyf.reserveCapacity(keptGIDs.count * 128)
        var newLoca = Data(capacity: (numGlyphs + 1) * 4)

        for gid in 0..<numGlyphs {
            appendUInt32BE(&newLoca, UInt32(newGlyf.count))
            if keptGIDs.contains(gid) {
                let start = origOffsets[gid]
                let end = origOffsets[gid + 1]
                if end > start && end <= glyfData.count {
                    newGlyf.append(glyfData.subdata(in: start..<end))
                    let pad = ((newGlyf.count + 3) & ~3) - newGlyf.count
                    if pad > 0 {
                        newGlyf.append(contentsOf: repeatElement(UInt8(0), count: pad))
                    }
                }
            }
        }
        appendUInt32BE(&newLoca, UInt32(newGlyf.count))
        if newGlyf.isEmpty {
            newGlyf.append(contentsOf: [0, 0, 0, 0])
        }

        // Update `head` table to set indexToLocFormat = 1 (32-bit loca offsets)
        var newHead = headData
        newHead[50] = 0
        newHead[51] = 1
        return (newHead, newLoca, newGlyf)
    }

    private static func packSFNT(
        sfntVersion: UInt32,
        tables: [String: (tagBytes: UInt32, data: Data)]
    ) -> Data {
        let sorted = tables.values.sorted { $0.tagBytes < $1.tagBytes }
        let outNumTables = sorted.count
        var maxPow2 = 1
        var entrySelector = 0
        while (maxPow2 << 1) <= outNumTables {
            maxPow2 <<= 1
            entrySelector += 1
        }
        let searchRange = maxPow2 * 16
        let rangeShift = outNumTables * 16 - searchRange

        let headerSize = 12 + outNumTables * 16
        let totalEstimated = headerSize + sorted.reduce(0) { $0 + (($1.data.count + 3) & ~3) }
        var out = Data(capacity: totalEstimated)

        appendUInt32BE(&out, sfntVersion)
        appendUInt16BE(&out, UInt16(outNumTables))
        appendUInt16BE(&out, UInt16(searchRange))
        appendUInt16BE(&out, UInt16(entrySelector))
        appendUInt16BE(&out, UInt16(rangeShift))

        var currentDataOffset = headerSize
        for item in sorted {
            appendUInt32BE(&out, item.tagBytes)
            appendUInt32BE(&out, 0) // checkSum
            appendUInt32BE(&out, UInt32(currentDataOffset))
            appendUInt32BE(&out, UInt32(item.data.count))
            currentDataOffset += (item.data.count + 3) & ~3
        }

        for item in sorted {
            out.append(item.data)
            let pad = ((item.data.count + 3) & ~3) - item.data.count
            if pad > 0 {
                out.append(contentsOf: repeatElement(UInt8(0), count: pad))
            }
        }
        return out
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return (b0 << 8) | b1
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func appendUInt16BE(_ data: inout Data, _ val: UInt16) {
        data.append(UInt8((val >> 8) & 0xFF))
        data.append(UInt8(val & 0xFF))
    }

    private static func appendUInt32BE(_ data: inout Data, _ val: UInt32) {
        data.append(UInt8((val >> 24) & 0xFF))
        data.append(UInt8((val >> 16) & 0xFF))
        data.append(UInt8((val >> 8) & 0xFF))
        data.append(UInt8(val & 0xFF))
    }
}
