import AVFoundation
import AudioToolbox
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
            var videoDurationSeconds: Double = 0
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
                let range = try await videoTrack.load(.timeRange)
                let value = CMTimeGetSeconds(range.duration)
                videoDurationSeconds = value.isFinite ? value : 0
            }

            var audioCodec = "none"
            var audioSampleRate = 0
            var audioChannelCount = 0
            var audioDurationSeconds: Double = 0
            var audioEstimatedDataRate: Float = 0
            var audioRMS: Double = 0
            var audioPeak: Double = 0
            var decodedAudioSampleCount = 0
            if let audioTrack = audioTracks.first {
                let descriptions = try await audioTrack.load(.formatDescriptions)
                if let description = descriptions.first {
                    audioCodec = fourCC(CMFormatDescriptionGetMediaSubType(description))
                    if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        audioSampleRate = Int(basic.mSampleRate.rounded())
                        audioChannelCount = Int(basic.mChannelsPerFrame)
                    }
                }
                let range = try await audioTrack.load(.timeRange)
                let value = CMTimeGetSeconds(range.duration)
                audioDurationSeconds = value.isFinite ? value : 0
                audioEstimatedDataRate = try await audioTrack.load(.estimatedDataRate)
                let levels = try audioLevels(asset: asset, track: audioTrack)
                audioRMS = levels.rms
                audioPeak = levels.peak
                decodedAudioSampleCount = levels.sampleCount
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
                "videoDurationSeconds": videoDurationSeconds,
                "audioCodecFourCC": audioCodec,
                "audioSampleRate": audioSampleRate,
                "audioChannelCount": audioChannelCount,
                "audioDurationSeconds": audioDurationSeconds,
                "audioEstimatedDataRate": Double(audioEstimatedDataRate),
                "audioRMS": audioRMS,
                "audioPeak": audioPeak,
                "decodedAudioSampleCount": decodedAudioSampleCount,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("inspect_mp4 failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func audioLevels(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (rms: Double, peak: Double, sampleCount: Int) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return (0, 0, 0) }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "MupawInspectMP4", code: 1)
        }

        let maximumSamples = 1_000_000
        var sumSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0
        while sampleCount < maximumSamples, let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var totalLength = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &pointer
            )
            guard status == kCMBlockBufferNoErr, let pointer, totalLength >= 2 else { continue }
            let available = min(totalLength / MemoryLayout<Int16>.size, maximumSamples - sampleCount)
            pointer.withMemoryRebound(to: Int16.self, capacity: available) { samples in
                for index in 0..<available {
                    let normalized = Double(samples[index]) / Double(Int16.max)
                    sumSquares += normalized * normalized
                    peak = max(peak, abs(normalized))
                }
            }
            sampleCount += available
        }
        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        return (rms, peak, sampleCount)
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
