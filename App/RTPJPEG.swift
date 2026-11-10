import Foundation

/// Reassembles RTP/JPEG (RFC 2435) packets into complete JPEG files.
///
/// The drone sends payload type 26, JPEG type 65 (4:2:2 with restart markers),
/// Q 255 (quantisation tables carried in-band in the first fragment of each frame),
/// 240x320. Each frame arrives as several fragments identified by a byte offset;
/// the RTP marker bit flags the last fragment. The entropy-coded scan is sent
/// without any JPEG headers, so this class rebuilds SOI, DQT, DRI, SOF0, DHT and
/// SOS around it, exactly as RFC 2435 Appendix B describes.
final class RTPJPEGAssembler {
    struct FrameHeader {
        var type: UInt8
        var q: UInt8
        var width: Int
        var height: Int
        var dri: UInt16
    }

    private(set) var dropped = 0
    private var scan = Data()
    private var currentTimestamp: UInt32?
    private var header: FrameHeader?
    private var qtables: Data?
    private var qtableCache: [UInt8: Data] = [:]
    private var bad = false

    /// Feed one RTP packet. Returns a complete JPEG when the frame finishes.
    func push(_ packet: Data) -> Data? {
        let b = [UInt8](packet)
        guard b.count >= 12 else { return nil }
        let version = b[0] >> 6
        guard version == 2 else { return nil }
        let payloadType = b[1] & 0x7f
        guard payloadType == 26 else { return nil }
        let marker = (b[1] & 0x80) != 0
        let csrcCount = Int(b[0] & 0x0f)
        let hasExtension = (b[0] & 0x10) != 0
        let hasPadding = (b[0] & 0x20) != 0
        let timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])

        var p = 12 + csrcCount * 4
        if hasExtension {
            guard b.count >= p + 4 else { return nil }
            let words = Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4 + words * 4
        }
        var end = b.count
        if hasPadding, let pad = b.last, Int(pad) < end { end -= Int(pad) }

        // RFC 2435 main header: type-specific(1) offset(3) type(1) q(1) width/8(1) height/8(1)
        guard end >= p + 8 else { return nil }
        let offset = Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        let type = b[p + 4]
        let q = b[p + 5]
        let width = Int(b[p + 6]) * 8
        let height = Int(b[p + 7]) * 8
        p += 8

        var dri: UInt16 = 0
        if type >= 64 {
            guard end >= p + 4 else { return nil }
            dri = UInt16(b[p]) << 8 | UInt16(b[p + 1])
            p += 4
        }

        if offset == 0 {
            var tables: Data?
            if q >= 128 {
                guard end >= p + 4 else { return nil }
                let length = Int(b[p + 2]) << 8 | Int(b[p + 3])
                p += 4
                if length > 0 {
                    guard end >= p + length else { return nil }
                    tables = Data(b[p..<(p + length)])
                    qtableCache[q] = tables
                    p += length
                } else {
                    tables = qtableCache[q]
                }
            } else {
                tables = Self.makeTables(q: Int(q))
            }
            if currentTimestamp != nil { dropped += 1 }   // previous frame never completed
            scan.removeAll(keepingCapacity: true)
            currentTimestamp = timestamp
            header = FrameHeader(type: type, q: q, width: width, height: height, dri: dri)
            qtables = tables
            bad = false
        } else {
            guard currentTimestamp == timestamp, !bad else { return nil }
            guard offset == scan.count else {      // lost fragment: give up on this frame
                bad = true
                dropped += 1
                currentTimestamp = nil
                return nil
            }
        }

        guard end >= p else { return nil }
        scan.append(contentsOf: b[p..<end])

        guard marker else { return nil }
        defer {
            currentTimestamp = nil
            scan.removeAll(keepingCapacity: true)
        }
        guard let hdr = header, let qt = qtables, qt.count >= 64, hdr.width > 0, hdr.height > 0 else {
            dropped += 1
            return nil
        }
        return Self.makeJPEG(header: hdr, qtables: qt, scan: scan)
    }

    // MARK: - JPEG construction

    static func makeJPEG(header h: FrameHeader, qtables: Data, scan: Data) -> Data {
        var out = Data(capacity: scan.count + 700)
        out.append(contentsOf: [0xFF, 0xD8])                                // SOI

        let luma = qtables.prefix(64)
        let chroma = qtables.count >= 128 ? qtables.subdata(in: 64..<128) : Data(luma)
        appendDQT(&out, id: 0, table: Data(luma))
        appendDQT(&out, id: 1, table: chroma)

        if h.dri > 0 {
            out.append(contentsOf: [0xFF, 0xDD, 0x00, 0x04, UInt8(h.dri >> 8), UInt8(h.dri & 0xFF)])
        }

        // SOF0, baseline, 3 components. Type bit 0 selects 4:2:2 (1) or 4:2:0 (0).
        let ySampling: UInt8 = (h.type & 1) == 1 ? 0x21 : 0x22
        out.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08,
                                UInt8(h.height >> 8), UInt8(h.height & 0xFF),
                                UInt8(h.width >> 8), UInt8(h.width & 0xFF),
                                0x03,
                                0x01, ySampling, 0x00,
                                0x02, 0x11, 0x01,
                                0x03, 0x11, 0x01])

        appendDHT(&out, tableClass: 0, id: 0, codeLengths: lumDCCodeLens, symbols: lumDCSymbols)
        appendDHT(&out, tableClass: 1, id: 0, codeLengths: lumACCodeLens, symbols: lumACSymbols)
        appendDHT(&out, tableClass: 0, id: 1, codeLengths: chmDCCodeLens, symbols: chmDCSymbols)
        appendDHT(&out, tableClass: 1, id: 1, codeLengths: chmACCodeLens, symbols: chmACSymbols)

        // SOS
        out.append(contentsOf: [0xFF, 0xDA, 0x00, 0x0C, 0x03,
                                0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
                                0x00, 0x3F, 0x00])
        out.append(scan)
        if scan.count < 2 || scan[scan.index(scan.endIndex, offsetBy: -2)] != 0xFF || scan[scan.index(before: scan.endIndex)] != 0xD9 {
            out.append(contentsOf: [0xFF, 0xD9])                            // EOI
        }
        return out
    }

    private static func appendDQT(_ out: inout Data, id: UInt8, table: Data) {
        out.append(contentsOf: [0xFF, 0xDB, 0x00, 0x43, id])
        out.append(table.prefix(64))
    }

    private static func appendDHT(_ out: inout Data, tableClass: UInt8, id: UInt8, codeLengths: [UInt8], symbols: [UInt8]) {
        let length = 3 + codeLengths.count + symbols.count
        out.append(contentsOf: [0xFF, 0xC4, UInt8(length >> 8), UInt8(length & 0xFF), (tableClass << 4) | id])
        out.append(contentsOf: codeLengths)
        out.append(contentsOf: symbols)
    }

    // MARK: - Quantisation tables for Q < 128 (RFC 2435 Appendix A)

    private static let lumaQuantizer: [Int] = [
        16, 11, 12, 14, 12, 10, 16, 14, 13, 14, 18, 17, 16, 19, 24, 40,
        26, 24, 22, 22, 24, 49, 35, 37, 29, 40, 58, 51, 61, 60, 57, 51,
        56, 55, 64, 72, 92, 78, 64, 68, 87, 69, 55, 56, 80, 109, 81, 87,
        95, 98, 103, 104, 103, 62, 77, 113, 121, 112, 100, 120, 92, 101, 103, 99
    ]
    private static let chromaQuantizer: [Int] = [
        17, 18, 18, 24, 21, 24, 47, 26, 26, 47, 99, 66, 56, 66, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99
    ]

    static func makeTables(q: Int) -> Data {
        let clamped = max(1, min(99, q))
        let factor = clamped < 50 ? 5000 / clamped : 200 - clamped * 2
        var out = Data(capacity: 128)
        for base in lumaQuantizer { out.append(UInt8(max(1, min(255, (base * factor + 50) / 100)))) }
        for base in chromaQuantizer { out.append(UInt8(max(1, min(255, (base * factor + 50) / 100)))) }
        return out
    }

    // MARK: - Standard Huffman tables (JPEG Annex K.3, as listed in RFC 2435 Appendix B)

    private static let lumDCCodeLens: [UInt8] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    private static let lumDCSymbols: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    private static let lumACCodeLens: [UInt8] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
    private static let lumACSymbols: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa
    ]
    private static let chmDCCodeLens: [UInt8] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    private static let chmDCSymbols: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    private static let chmACCodeLens: [UInt8] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    private static let chmACSymbols: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa
    ]
}
