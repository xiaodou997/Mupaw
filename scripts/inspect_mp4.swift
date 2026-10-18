import AVFoundation
import CoreMedia
import Foundation

@main
enum InspectMP4 {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: inspect_mp4 <path>\n", stderr)
            exit(2)
        }

        do {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let playable = try await asset.load(.isPlayable)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            var width = 0
            var height = 0
            var nominalFrameRate: Float = 0
            var estimatedDataRate: Float = 0
            var codec = "unknown"
            if let videoTrack = videoTracks.first {
                let naturalSize = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let transformed = naturalSize.applying(transform)
                width = max(0, Int(abs(transformed.width).rounded()))
                height = max(0, Int(abs(transformed.height).rounded()))
                nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
                let descriptions = try await videoTrack.load(.formatDescriptions)
                if let description = descriptions.first {
                    codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
                }
            }

            let seconds = CMTimeGetSeconds(duration)
            let payload: [String: Any] = [
                "isPlayable": playable,
                "durationSeconds": seconds.isFinite ? seconds : -1,
                "videoTrackCount": videoTracks.count,
                "audioTrackCount": audioTracks.count,
                "pixelWidth": width,
                "pixelHeight": height,
                "nominalFrameRate": Double(nominalFrameRate),
                "estimatedDataRate": Double(estimatedDataRate),
                "codecFourCC": codec,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("inspect_mp4 failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08x", value)
    }
}
