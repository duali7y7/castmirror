import Foundation

/// CastMessage from cast_channel.proto, encoded by hand (fields 1–7), with the
/// 4-byte big-endian length prefix the Cast channel uses. Same encoding as
/// pc-sender/src/castv2.js.
///   1 protocol_version  varint, 0 = CASTV2_1_0
///   2 source_id         string
///   3 destination_id    string
///   4 namespace         string
///   5 payload_type      varint, 0 = STRING
///   6 payload_utf8      string
///   7 payload_binary    bytes (ignored)
public struct CastMessage: Equatable {
    public var source: String
    public var destination: String
    public var namespace: String
    public var payload: String

    public init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    /// The message with its length prefix, ready to write to the socket.
    public func framed() -> Data {
        var body = Data()
        func varint(_ value: Int) {
            var n = UInt64(value)
            while n > 0x7f {
                body.append(UInt8(n & 0x7f) | 0x80)
                n >>= 7
            }
            body.append(UInt8(n))
        }
        func key(_ field: Int, _ wireType: Int) { varint(field << 3 | wireType) }
        func string(_ field: Int, _ value: String) {
            let bytes = Data(value.utf8)
            key(field, 2)
            varint(bytes.count)
            body.append(bytes)
        }

        key(1, 0); varint(0)
        string(2, source)
        string(3, destination)
        string(4, namespace)
        key(5, 0); varint(0)
        string(6, payload)

        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Decodes one message body (without the length prefix).
    public static func decode(_ data: Data) throws -> CastMessage {
        let bytes = [UInt8](data)
        var pos = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard pos < bytes.count, shift < 64 else { throw CastError.malformed }
                let byte = bytes[pos]
                pos += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        var message = CastMessage(source: "", destination: "", namespace: "", payload: "")
        while pos < bytes.count {
            let key = try varint()
            switch key & 7 {
            case 0:
                _ = try varint()
            case 2:
                let length = Int(try varint())
                guard length <= bytes.count - pos else { throw CastError.malformed }
                let value = String(decoding: bytes[pos..<pos + length], as: UTF8.self)
                pos += length
                switch key >> 3 {
                case 2: message.source = value
                case 3: message.destination = value
                case 4: message.namespace = value
                case 6: message.payload = value
                default: break
                }
            default:
                throw CastError.malformed
            }
        }
        return message
    }

    /// Takes every complete message off the front of `buffer`, leaving any
    /// partial one for the next read.
    public static func takeMessages(from buffer: inout Data) throws -> [CastMessage] {
        var messages: [CastMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex
            messages.append(try decode(buffer.subdata(in: start + 4 ..< start + 4 + length)))
            buffer = buffer.subdata(in: start + 4 + length ..< buffer.endIndex)
        }
        return messages
    }
}
