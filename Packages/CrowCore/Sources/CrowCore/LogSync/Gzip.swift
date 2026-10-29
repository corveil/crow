import CZlib
import Foundation

/// gzip (RFC 1952) over the system zlib, for session-transcript uploads
/// (CROW-1394). Foundation has no gzip on Linux, so this links libz directly
/// rather than going through Apple's `Compression` framework.
public enum Gzip {
    private static let chunkSize = 64 * 1024

    /// gzip-compress `data`. Nil only if zlib itself fails (out of memory);
    /// empty input yields a valid, empty gzip member.
    public static func compress(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) -> Data? {
        var stream = z_stream()
        // windowBits 15 + 16 selects the gzip wrapper rather than raw zlib.
        guard deflateInit2_(
            &stream, level, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { deflateEnd(&stream) }
        return run(&stream, input: data) { deflate(&$0, Z_FINISH) }
    }

    /// Inflate a gzip (or zlib) body. Nil when `data` is not a complete,
    /// well-formed stream.
    public static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        // windowBits 15 + 32 auto-detects the gzip or zlib header.
        guard inflateInit2_(
            &stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }
        return run(&stream, input: data) { inflate(&$0, Z_NO_FLUSH) }
    }

    /// Drive `step` until it reports `Z_STREAM_END`, collecting output in
    /// fixed-size chunks so a large transcript never needs a second buffer
    /// its own size.
    private static func run(
        _ stream: inout z_stream, input: Data, step: (inout z_stream) -> Int32
    ) -> Data? {
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            // zlib declares `next_in` mutable but never writes through it, so
            // borrowing the input avoids copying a transcript-sized buffer.
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { buf -> (Int32, Int) in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    let status = step(&stream)
                    return (status, buf.count - Int(stream.avail_out))
                }
                output.append(chunk, count: produced)
                switch status {
                case Z_STREAM_END: return output
                case Z_OK: continue
                // Z_BUF_ERROR with input left and output space means no
                // progress is possible: truncated input.
                default: return nil
                }
            }
        }
    }
}
