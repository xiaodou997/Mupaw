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
                        "Exposes status, capture, versioned screenshot projects, structured edits, preview, history, and PNG export to a local Agent."
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
                    id: "ocr-color-style",
                    title: "OCR, color sampling, and visual styling",
                    availability: .planned,
                    detail:
                        "OCR, color sampling, background, rounded-corner, and shadow styling remain planned for later M1–M2 batches."
                ),
                .init(
                    id: "scrolling-capture",
                    title: "Scrolling long screenshot",
                    availability: .planned,
                    detail: "Planned for M2 with explicit partial-result reporting."
                ),
                .init(
                    id: "recording",
                    title: "MP4 and GIF recording",
                    availability: .planned,
                    detail:
                        "Screen, system audio, microphone, camera, click, keystroke, and export pipelines are planned for M1–M3."
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
