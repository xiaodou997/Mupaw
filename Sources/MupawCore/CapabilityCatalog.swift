import Foundation

public enum CapabilityCatalog {
    public static var current: CapabilitySnapshot {
        CapabilitySnapshot(
            appVersion: MupawConstants.appVersion,
            minimumMacOSVersion: "26.0",
            rpcProtocolVersion: MupawConstants.rpcProtocolVersion,
            capabilities: [
                .init(
                    id: "source-enumeration",
                    title: "Display and window source enumeration",
                    availability: .available,
                    detail: "Lists active displays and eligible on-screen windows through ScreenCaptureKit."
                ),
                .init(
                    id: "screenshot",
                    title: "Full-screen, window, and region screenshot",
                    availability: .available,
                    detail:
                        "Captures an explicit display, window, or structured region as PNG and stores it in Mupaw's artifact directory."
                ),
                .init(
                    id: "agent-mcp",
                    title: "Local MCP control",
                    availability: .available,
                    detail:
                        "Exposes status, display/window/microphone/camera discovery, screenshot capture, H.264 MP4 recording with controlled audio and optional baked-in camera picture-in-picture, live audio controls and levels, versioned screenshot projects, structured edits and visual styling, OCR, color sampling, preview, history, and export to a local Agent."
                ),
                .init(
                    id: "region-capture",
                    title: "Interactive and structured region capture",
                    availability: .available,
                    detail:
                        "Provides a native multi-display selection overlay for people and a structured global-display-points rectangle for Agents."
                ),
                .init(
                    id: "screenshot-editing",
                    title: "Non-destructive screenshot editing",
                    availability: .available,
                    detail:
                        "Creates versioned projects with crop, arrow, text, mosaic, persisted undo/redo, shared rendering, preview, and PNG export."
                ),
                .init(
                    id: "ocr",
                    title: "Local screenshot OCR",
                    availability: .available,
                    detail:
                        "Recognizes text locally with Apple Vision, returning engine metadata, confidence, detected language, and original-image pixel coordinates."
                ),
                .init(
                    id: "color-sampling",
                    title: "Point and region color sampling",
                    availability: .available,
                    detail:
                        "Samples original screenshot pixels at a point or summarizes a region with average, center, and dominant sRGB colors."
                ),
                .init(
                    id: "visual-style",
                    title: "Background, canvas, rounded-corner, and shadow styling",
                    availability: .available,
                    detail:
                        "Applies non-destructive presets or custom solid/gradient backgrounds, padding, output aspect ratios, rounded corners, and bounded shadows through the shared preview/export renderer."
                ),
                .init(
                    id: "scrolling-capture",
                    title: "Scrolling long screenshot",
                    availability: .planned,
                    detail: "Planned for M2 with explicit partial-result reporting."
                ),
                .init(
                    id: "recording",
                    title: "H.264 MP4 recording with audio and camera picture-in-picture",
                    availability: .available,
                    detail:
                        "Records an explicit display, independent window, or single-display structured region with the M2c audio modes and an optional selected camera composited into the single H.264 track. Includes camera frame health, runtime visibility/layout/style controls, bounded camera control history, runtime audio controls, device discovery, permission-aware start/status/update/stop/cancel, SHA-256, synchronization validation, and preview. Click/keystroke overlays, GIF, timeline editing, and zoom remain planned."
                ),
                .init(
                    id: "camera-overlay",
                    title: "Camera picture-in-picture overlay",
                    availability: .available,
                    detail:
                        "Discovers permission-aware camera devices and bakes one selected camera into the final H.264 video track. The device locks after start while visibility, corner, size, circle/rounded-rectangle shape, bounded corner radius, and safe margin remain adjustable through the shared recording service."
                ),
                .init(
                    id: "automatic-zoom",
                    title: "Automatic zoom and focus",
                    availability: .planned,
                    detail: "Editable automatic zoom suggestions are planned for M4."
                ),
            ]
        )
    }

}
