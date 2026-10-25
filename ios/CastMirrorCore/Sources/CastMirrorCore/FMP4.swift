import Foundation

/// H.264 track settings, from the encoder's output.
public struct VideoTrackConfig: Equatable {
    public var width: Int
    public var height: Int
    /// AVCDecoderConfigurationRecord (SPS and PPS), the body of the avcC box.
    public var avcC: Data
}

/// AAC-LC track settings.
public struct AudioTrackConfig: Equatable {
    public var sampleRate: Int
    public var channels: Int

    /// AudioSpecificConfig: object type 2 (AAC LC, 5 bits), sampling
    /// frequency index (4 bits), channel configuration (4 bits), 3 zero bits.
    public var audioSpecificConfig: Data {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let index = UInt16(rates.firstIndex(of: sampleRate) ?? 3)
        let bits = UInt16(2) << 11 | index << 7 | UInt16(channels) << 3
        return Data([UInt8(bits >> 8), UInt8(bits & 0xff)])
    }
}

public struct MP4Sample {
    public var data: Data
    public var duration: UInt32
    public var isSync: Bool
}

/// Fragmented MP4 as the receiver's Media Source Extensions player takes it:
/// one init segment (ftyp + moov), then moof + mdat fragments. Mirrors the
/// FFmpeg output the PC sender uses (pc-sender/src/mp4.js reads both).
public enum FMP4 {
    public static let videoTrack: UInt32 = 1
    public static let audioTrack: UInt32 = 2
    public static let videoTimescale: UInt32 = 90_000

    public static func initSegment(video: VideoTrackConfig, audio: AudioTrackConfig?) -> Data {
        var w = BoxWriter()
        w.box("ftyp") { w in
            w.fourcc("isom")
            w.u32(0x200)
            for brand in ["isom", "iso6", "avc1", "mp41"] { w.fourcc(brand) }
        }
        w.box("moov") { w in
            w.fullBox("mvhd", version: 0, flags: 0) { w in
                w.u32(0); w.u32(0)              // creation, modification time
                w.u32(1000); w.u32(0)           // timescale, duration
                w.u32(0x0001_0000)              // rate 1.0
                w.u16(0x0100)                   // volume 1.0
                w.zeros(10)
                w.matrix()
                w.zeros(24)                     // pre_defined
                w.u32(audio == nil ? 2 : 3)     // next_track_ID
            }
            videoTrak(&w, video)
            if let audio { audioTrak(&w, audio) }
            w.box("mvex") { w in
                trex(&w, videoTrack)
                if audio != nil { trex(&w, audioTrack) }
            }
        }
        return w.data
    }

    /// One fragment of one track. `baseDecodeTime` is in the track's timescale.
    public static func fragment(sequence: UInt32, track: UInt32, baseDecodeTime: UInt64, samples: [MP4Sample]) -> Data {
        var w = BoxWriter()
        var dataOffsetAt = 0
        w.box("moof") { w in
            w.fullBox("mfhd", version: 0, flags: 0) { w in w.u32(sequence) }
            w.box("traf") { w in
                w.fullBox("tfhd", version: 0, flags: 0x02_0000) { w in w.u32(track) }  // default-base-is-moof
                w.fullBox("tfdt", version: 1, flags: 0) { w in w.u64(baseDecodeTime) }
                // data offset, then per-sample duration, size and flags
                w.fullBox("trun", version: 0, flags: 0x00_0701) { w in
                    w.u32(UInt32(samples.count))
                    dataOffsetAt = w.data.count
                    w.u32(0)
                    for sample in samples {
                        w.u32(sample.duration)
                        w.u32(UInt32(sample.data.count))
                        // sync: depends on no other sample; otherwise depends on others, not a sync sample
                        w.u32(sample.isSync ? 0x0200_0000 : 0x0101_0000)
                    }
                }
            }
        }
        // The sample data starts right after the moof and the mdat header.
        w.patch(UInt32(w.data.count + 8), at: dataOffsetAt)
        w.box("mdat") { w in
            for sample in samples { w.bytes(sample.data) }
        }
        return w.data
    }

    private static func videoTrak(_ w: inout BoxWriter, _ video: VideoTrackConfig) {
        w.box("trak") { w in
            tkhd(&w, track: videoTrack, volume: 0, width: video.width, height: video.height)
            w.box("mdia") { w in
                mdhd(&w, timescale: videoTimescale)
                hdlr(&w, type: "vide", name: "VideoHandler")
                w.box("minf") { w in
                    w.fullBox("vmhd", version: 0, flags: 1) { w in w.zeros(8) }  // graphicsmode, opcolor
                    dinf(&w)
                    w.box("stbl") { w in
                        w.fullBox("stsd", version: 0, flags: 0) { w in
                            w.u32(1)
                            w.box("avc1") { w in
                                w.zeros(6); w.u16(1)                    // reserved, data_reference_index
                                w.zeros(16)                             // pre_defined, reserved
                                w.u16(UInt16(video.width)); w.u16(UInt16(video.height))
                                w.u32(0x0048_0000); w.u32(0x0048_0000)  // 72 dpi
                                w.u32(0)                                // reserved
                                w.u16(1)                                // frame_count
                                w.zeros(32)                             // compressorname
                                w.u16(0x0018)                           // depth
                                w.u16(0xffff)                           // pre_defined = -1
                                w.box("avcC") { w in w.bytes(video.avcC) }
                            }
                        }
                        emptySampleTables(&w)
                    }
                }
            }
        }
    }

    private static func audioTrak(_ w: inout BoxWriter, _ audio: AudioTrackConfig) {
        w.box("trak") { w in
            tkhd(&w, track: audioTrack, volume: 0x0100, width: 0, height: 0)
            w.box("mdia") { w in
                mdhd(&w, timescale: UInt32(audio.sampleRate))
                hdlr(&w, type: "soun", name: "SoundHandler")
                w.box("minf") { w in
                    w.fullBox("smhd", version: 0, flags: 0) { w in w.zeros(4) }  // balance, reserved
                    dinf(&w)
                    w.box("stbl") { w in
                        w.fullBox("stsd", version: 0, flags: 0) { w in
                            w.u32(1)
                            w.box("mp4a") { w in
                                w.zeros(6); w.u16(1)                    // reserved, data_reference_index
                                w.zeros(8)                              // reserved
                                w.u16(UInt16(audio.channels))
                                w.u16(16)                               // sample size
                                w.zeros(4)                              // pre_defined, reserved
                                w.u32(UInt32(audio.sampleRate) << 16)
                                esds(&w, audio)
                            }
                        }
                        emptySampleTables(&w)
                    }
                }
            }
        }
    }

    /// MPEG-4 elementary stream descriptor for AAC.
    private static func esds(_ w: inout BoxWriter, _ audio: AudioTrackConfig) {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data { Data([tag, UInt8(body.count)]) + body }
        func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        let decoderSpecific = descriptor(0x05, audio.audioSpecificConfig)
        let decoderConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0]) + be32(128_000) + be32(128_000) + decoderSpecific)
        let slConfig = descriptor(0x06, Data([0x02]))
        let elementaryStream = descriptor(0x03, Data([0x00, UInt8(audioTrack), 0x00]) + decoderConfig + slConfig)
        w.fullBox("esds", version: 0, flags: 0) { w in w.bytes(elementaryStream) }
    }

    private static func tkhd(_ w: inout BoxWriter, track: UInt32, volume: UInt16, width: Int, height: Int) {
        w.fullBox("tkhd", version: 0, flags: 3) { w in      // enabled, in movie
            w.u32(0); w.u32(0)                              // creation, modification time
            w.u32(track); w.u32(0)                          // track_ID, reserved
            w.u32(0)                                        // duration
            w.zeros(8)                                      // reserved
            w.u16(0); w.u16(0)                              // layer, alternate_group
            w.u16(volume); w.u16(0)
            w.matrix()
            w.u32(UInt32(width) << 16); w.u32(UInt32(height) << 16)
        }
    }

    private static func mdhd(_ w: inout BoxWriter, timescale: UInt32) {
        w.fullBox("mdhd", version: 0, flags: 0) { w in
            w.u32(0); w.u32(0)                              // creation, modification time
            w.u32(timescale); w.u32(0)                      // timescale, duration
            w.u16(0x55c4)                                   // language "und"
            w.u16(0)
        }
    }

    private static func hdlr(_ w: inout BoxWriter, type: String, name: String) {
        w.fullBox("hdlr", version: 0, flags: 0) { w in
            w.u32(0)
            w.fourcc(type)
            w.zeros(12)
            w.bytes(Data(name.utf8) + Data([0]))
        }
    }

    private static func dinf(_ w: inout BoxWriter) {
        w.box("dinf") { w in
            w.fullBox("dref", version: 0, flags: 0) { w in
                w.u32(1)
                w.fullBox("url ", version: 0, flags: 1) { _ in }  // data is in this file
            }
        }
    }

    private static func emptySampleTables(_ w: inout BoxWriter) {
        w.fullBox("stts", version: 0, flags: 0) { w in w.u32(0) }
        w.fullBox("stsc", version: 0, flags: 0) { w in w.u32(0) }
        w.fullBox("stsz", version: 0, flags: 0) { w in w.u32(0); w.u32(0) }
        w.fullBox("stco", version: 0, flags: 0) { w in w.u32(0) }
    }

    private static func trex(_ w: inout BoxWriter, _ track: UInt32) {
        w.fullBox("trex", version: 0, flags: 0) { w in
            w.u32(track)
            w.u32(1)                                        // sample description index
            w.u32(0); w.u32(0); w.u32(0)                    // default duration, size, flags
        }
    }
}

/// Writes ISO BMFF boxes: a 32-bit size, a four-character type, then the
/// body. Sizes are patched in once the body is written.
struct BoxWriter {
    private(set) var data = Data()

    mutating func u16(_ value: UInt16) { append(value.bigEndian) }
    mutating func u32(_ value: UInt32) { append(value.bigEndian) }
    mutating func u64(_ value: UInt64) { append(value.bigEndian) }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }
    mutating func bytes(_ bytes: Data) { data.append(bytes) }

    mutating func fourcc(_ code: String) {
        precondition(code.utf8.count == 4, "fourcc must be 4 bytes")
        data.append(contentsOf: Array(code.utf8))
    }

    /// The 3x3 identity transform matrix used by mvhd and tkhd.
    mutating func matrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(value) }
    }

    mutating func box(_ type: String, _ body: (inout BoxWriter) -> Void) {
        let start = data.count
        u32(0)
        fourcc(type)
        body(&self)
        patch(UInt32(data.count - start), at: start)
    }

    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout BoxWriter) -> Void) {
        box(type) { w in
            w.u32(UInt32(version) << 24 | flags & 0x00ff_ffff)
            body(&w)
        }
    }

    mutating func patch(_ value: UInt32, at offset: Int) {
        let bytes = [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        data.replaceSubrange(offset..<offset + 4, with: bytes)
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}
