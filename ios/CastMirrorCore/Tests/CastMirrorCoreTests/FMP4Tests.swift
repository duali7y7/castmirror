@testable import CastMirrorCore
import XCTest

/// A box read back from MP4 bytes.
struct Box {
    let type: String
    let body: Data

    static func read(_ data: Data) -> [Box] {
        var boxes: [Box] = []
        var pos = data.startIndex
        while data.endIndex - pos >= 8 {
            let size = Int(data[pos..<pos + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard size >= 8, data.endIndex - pos >= size else { break }
            boxes.append(Box(type: String(decoding: data[pos + 4..<pos + 8], as: UTF8.self),
                             body: data.subdata(in: pos + 8..<pos + size)))
            pos += size
        }
        return boxes
    }

    var children: [Box] { Box.read(body) }

    func child(_ type: String) -> Box? { children.first { $0.type == type } }

    func u32(at offset: Int) -> UInt32 {
        body[body.startIndex + offset..<body.startIndex + offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

final class FMP4Tests: XCTestCase {
    let avcC = Data([0x01, 0x64, 0x00, 0x29, 0xff, 0xe1, 0x00, 0x04, 0x67, 0x64, 0x00, 0x29, 0x01, 0x00, 0x02, 0x68, 0xee])

    func testInitSegmentLayout() throws {
        let segment = FMP4.initSegment(video: VideoTrackConfig(width: 1920, height: 886, avcC: avcC),
                                       audio: AudioTrackConfig(sampleRate: 48000, channels: 2))
        let top = Box.read(segment)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(top.reduce(0) { $0 + $1.body.count + 8 }, segment.count)
        let moov = try XCTUnwrap(top.last)
        XCTAssertEqual(moov.children.map(\.type), ["mvhd", "trak", "trak", "mvex"])
        XCTAssertEqual(moov.child("mvex")?.children.map(\.type), ["trex", "trex"])

        // The receiver builds its codec string from the bytes after "avcC".
        let at = try XCTUnwrap(segment.range(of: Data("avcC".utf8))).upperBound
        XCTAssertEqual(segment.subdata(in: at..<at + avcC.count), avcC)
        XCTAssertNotNil(segment.range(of: Data("mp4a".utf8)))
        // AAC LC, 48 kHz, stereo
        XCTAssertNotNil(segment.range(of: Data([0x05, 0x02, 0x11, 0x90])))

        let tracks = moov.children.filter { $0.type == "trak" }
        let handlers = tracks.compactMap { $0.child("mdia")?.child("hdlr") }
        XCTAssertEqual(handlers.map { String(decoding: $0.body[$0.body.startIndex + 8..<$0.body.startIndex + 12], as: UTF8.self) }, ["vide", "soun"])
        let tkhd = try XCTUnwrap(tracks.first?.child("tkhd"))
        XCTAssertEqual(tkhd.u32(at: 76) >> 16, 1920)
        XCTAssertEqual(tkhd.u32(at: 80) >> 16, 886)
    }

    func testFragmentPointsAtItsSamples() throws {
        let samples = [MP4Sample(data: Data(repeating: 0xaa, count: 300), duration: 3000, isSync: true),
                       MP4Sample(data: Data(repeating: 0xbb, count: 20), duration: 3000, isSync: false)]
        let fragment = FMP4.fragment(sequence: 7, track: FMP4.videoTrack, baseDecodeTime: 123_456, samples: samples)
        let top = Box.read(fragment)
        XCTAssertEqual(top.map(\.type), ["moof", "mdat"])
        let moof = top[0]
        XCTAssertEqual(moof.child("mfhd")?.u32(at: 4), 7)
        let traf = try XCTUnwrap(moof.child("traf"))
        XCTAssertEqual(traf.children.map(\.type), ["tfhd", "tfdt", "trun"])
        XCTAssertEqual(traf.child("tfhd")?.u32(at: 4), FMP4.videoTrack)
        let tfdt = try XCTUnwrap(traf.child("tfdt"))
        XCTAssertEqual(UInt64(tfdt.u32(at: 4)) << 32 | UInt64(tfdt.u32(at: 8)), 123_456)

        let trun = try XCTUnwrap(traf.child("trun"))
        XCTAssertEqual(trun.u32(at: 0) & 0xffffff, 0x701)
        XCTAssertEqual(trun.u32(at: 4), 2)
        let dataOffset = Int(trun.u32(at: 8))
        XCTAssertEqual(dataOffset, moof.body.count + 8 + 8)
        XCTAssertEqual(fragment.subdata(in: dataOffset..<dataOffset + 320), samples[0].data + samples[1].data)
        // flags: first a sync sample, then a non-sync one
        XCTAssertEqual(trun.u32(at: 20), 0x0200_0000)
        XCTAssertEqual(trun.u32(at: 32), 0x0101_0000)
        XCTAssertEqual(top[1].body, samples[0].data + samples[1].data)
    }
}
