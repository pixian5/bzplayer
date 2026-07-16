import XCTest
@testable import BZPlayerCore

final class MediaAnalyzerTests: XCTestCase {
    func testFFprobeStreamSummaryIncludesVideoMetadata() {
        let result = ffprobeStreamSummary(from: [
            "codec_type": "video",
            "codec_name": "h264",
            "codec_long_name": "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10",
            "codec_tag_string": "avc1",
            "profile": "High",
            "width": 1920,
            "height": 1080,
            "r_frame_rate": "30000/1001",
            "bit_rate": "8000000"
        ])

        XCTAssertEqual(result?.codecName, "h264")
        XCTAssertEqual(result?.codecTag, "avc1")
        XCTAssertEqual(result?.profile, "High")
        let fps = parseFPS(fromFFprobeSummary: result?.summary ?? "")
        XCTAssertNotNil(fps)
        XCTAssertEqual(fps ?? 0, 30000.0 / 1001.0, accuracy: 0.0001)
    }

    func testFFprobeStreamSummaryIncludesAudioMetadata() {
        let result = ffprobeStreamSummary(from: [
            "codec_type": "audio",
            "codec_name": "AAC",
            "sample_rate": "48000",
            "channels": 2,
            "channel_layout": "stereo",
            "bit_rate": "192000",
            "tags": ["language": "zh"]
        ])

        XCTAssertEqual(result?.codecName, "aac")
        XCTAssertTrue(result?.summary.contains("48000 Hz") == true)
        XCTAssertTrue(result?.summary.contains("语言 zh") == true)
    }
}
