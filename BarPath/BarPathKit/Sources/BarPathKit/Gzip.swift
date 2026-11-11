import Foundation

/// The pure parts of a gzip file (RFC 1952): CRC-32 and the container around a raw DEFLATE
/// stream (RFC 1951). The deflate bytes themselves come from the system
/// (`NSData.compressed(using: .zlib)`); this only adds header and trailer so that any tool
/// (gzip, Python's gzip module) can open the result.
public enum Gzip {
    /// An empty input as a raw DEFLATE stream: one final, fixed-Huffman block holding only the end marker.
    public static let emptyDeflate: Data = Data([0x03, 0x00])

    private static let crcTable: [UInt32] = {
        var table: [UInt32] = []
        table.reserveCapacity(256)
        for n in 0..<256 {
            var c: UInt32 = UInt32(n)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table.append(c)
        }
        return table
    }()

    /// CRC-32 (IEEE 802.3, as used by gzip and zip). `crc32("123456789") == 0xCBF43926`.
    public static func crc32(_ data: Data) -> UInt32 {
        let table: [UInt32] = crcTable
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                let index: Int = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = table[index] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Header (10 bytes: magic 1f 8b, method 8 = deflate, no flags, no timestamp, no extra
    /// flags, OS 255 = unknown), the raw DEFLATE stream, then CRC-32 and input size modulo 2^32,
    /// both little-endian.
    public static func container(deflated: Data, crc32: UInt32, inputSize: UInt32) -> Data {
        var out = Data()
        out.reserveCapacity(deflated.count + 18)
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        out.append(deflated)
        out.append(littleEndian: crc32)
        out.append(littleEndian: inputSize)
        return out
    }

    /// The gzip file for `original`, given its raw DEFLATE stream.
    public static func wrap(deflated: Data, of original: Data) -> Data {
        return container(deflated: deflated,
                         crc32: crc32(original),
                         inputSize: UInt32(truncatingIfNeeded: original.count))
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
