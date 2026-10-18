import CoreGraphics
import Foundation
import ImageIO
import MupawCore
import MupawEditing

private struct OCRHelperInvocation: Codable, Sendable {
    let inputFileURL: URL
    let outputFileURL: URL
    let level: OCRRecognitionLevel
    let languages: [String]
    let usesLanguageCorrection: Bool
}

private enum IsolatedVisionError: Error, LocalizedError {
    case executableUnavailable
    case timedOut
    case helperFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return L10n.string("analysis.detail.ocr_helper_executable_unavailable")
        case .timedOut:
            return L10n.string("analysis.detail.ocr_helper_timed_out")
        case .helperFailed(let message):
            return L10n.format("analysis.detail.ocr_helper_failed.format", message)
        case .invalidResponse:
            return L10n.string("analysis.detail.ocr_helper_invalid_response")
        }
    }
}

private final class OCRProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

struct IsolatedVisionScreenshotTextRecognizer: ScreenshotTextRecognizing {
    func recognizeText(
        in image: CGImage,
        level: OCRRecognitionLevel,
        languages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> RawOCRRecognitionResult {
        let executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("mupaw-ocr-helper", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IsolatedVisionError.executableUnavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mupaw-OCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.png")
        let requestURL = directory.appendingPathComponent("request.json")
        let outputURL = directory.appendingPathComponent("response.json")
        try writePNG(image, to: inputURL)

        let invocation = OCRHelperInvocation(
            inputFileURL: inputURL,
            outputFileURL: outputURL,
            level: level,
            languages: languages,
            usesLanguageCorrection: usesLanguageCorrection
        )
        let requestData = try JSONEncoder.mupaw.encode(invocation)
        try requestData.write(to: requestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: requestURL.path
        )

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [requestURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let box = OCRProcessBox(process)

        do {
            try await run(box)
        } catch {
            box.terminate()
            throw error
        }

        guard process.terminationStatus == 0 else {
            let data = try? errorPipe.fileHandleForReading.readToEnd()
            let message = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw IsolatedVisionError.helperFailed(
                message?.isEmpty == false ? message! : "exit \(process.terminationStatus)"
            )
        }
        guard let responseData = try? Data(contentsOf: outputURL),
            let result = try? JSONDecoder.mupaw.decode(
                RawOCRRecognitionResult.self,
                from: responseData
            )
        else {
            throw IsolatedVisionError.invalidResponse
        }
        return result
    }

    private func run(_ box: OCRProcessBox) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        box.process.terminationHandler = { _ in
                            continuation.resume()
                        }
                        do {
                            try box.process.run()
                        } catch {
                            box.process.terminationHandler = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(
                        for: .seconds(MupawConstants.ocrHelperTimeoutSeconds)
                    )
                    throw IsolatedVisionError.timedOut
                }

                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    box.terminate()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            throw IsolatedVisionError.invalidResponse
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IsolatedVisionError.invalidResponse
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
