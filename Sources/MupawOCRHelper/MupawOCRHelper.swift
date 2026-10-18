import Darwin
import Foundation
import ImageIO
import MupawCore
import MupawEditing

private struct OCRHelperInvocation: Codable {
    let inputFileURL: URL
    let outputFileURL: URL
    let level: OCRRecognitionLevel
    let languages: [String]
    let usesLanguageCorrection: Bool
}

private enum OCRHelperError: Error, LocalizedError {
    case invalidArguments
    case invalidRequest
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Expected one owner-only OCR request file path."
        case .invalidRequest:
            return "The OCR helper request is invalid."
        case .imageUnavailable:
            return "The OCR helper could not open the input image."
        }
    }
}

@main
private enum MupawOCRHelper {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw OCRHelperError.invalidArguments
            }

            let requestURL = URL(fileURLWithPath: CommandLine.arguments[1])
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let requestDirectory = requestURL.deletingLastPathComponent()
            let requestData = try Data(contentsOf: requestURL, options: [.mappedIfSafe])
            let invocation = try JSONDecoder.mupaw.decode(
                OCRHelperInvocation.self,
                from: requestData
            )
            let inputURL = invocation.inputFileURL.standardizedFileURL.resolvingSymlinksInPath()
            let outputURL = invocation.outputFileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard inputURL.isFileURL,
                outputURL.isFileURL,
                inputURL.deletingLastPathComponent() == requestDirectory,
                outputURL.deletingLastPathComponent() == requestDirectory
            else {
                throw OCRHelperError.invalidRequest
            }
            guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw OCRHelperError.imageUnavailable
            }

            let result = try await VisionScreenshotTextRecognizer().recognizeText(
                in: image,
                level: invocation.level,
                languages: invocation.languages,
                usesLanguageCorrection: invocation.usesLanguageCorrection
            )
            let responseData = try JSONEncoder.mupaw.encode(result)
            try responseData.write(to: outputURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
}
