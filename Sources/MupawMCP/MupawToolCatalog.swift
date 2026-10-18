import MCP

internal enum MupawToolCatalog {
    static let tools: [Tool] = [
        Tool(
            name: "mupaw_app_status",
            description:
                "Check whether Mupaw is running and return its version, local bridge version, and permission state.",
            inputSchema: emptyObjectSchema
        ),
        Tool(
            name: "mupaw_capabilities_get",
            description:
                "Return Mupaw's implemented and planned capture capabilities. Planned features are explicitly marked and must not be treated as available.",
            inputSchema: emptyObjectSchema
        ),
        Tool(
            name: "mupaw_sources_list",
            description:
                "Refresh and list active displays and eligible on-screen windows. Use a returned source_id for capture; do not invent identifiers.",
            inputSchema: emptyObjectSchema
        ),
        Tool(
            name: "mupaw_screenshot_capture",
            description:
                "Capture an explicit full_screen, window, or structured region as PNG. full_screen and window require an exact source_id returned by mupaw_sources_list. region requires a rectangle in global_display_points and never simulates UI clicks. The result includes artifact metadata and a bounded preview.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("full_screen"),
                            .string("window"),
                            .string("region"),
                        ]),
                        "description": .string(
                            "Explicit capture mode. For compatibility, omitting it infers window from a window: source_id, region from region, otherwise full_screen."
                        ),
                    ]),
                    "source_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Exact display: or window: identifier returned by mupaw_sources_list. Required for full_screen and window; omit for region."
                        ),
                    ]),
                    "region": .object([
                        "type": .string("object"),
                        "description": .string(
                            "Region in macOS global display points using a top-left origin. It may cross displays."),
                        "properties": .object([
                            "coordinate_space": .object([
                                "type": .string("string"),
                                "enum": .array([.string("global_display_points")]),
                                "default": .string("global_display_points"),
                            ]),
                            "x": .object(["type": .string("number")]),
                            "y": .object(["type": .string("number")]),
                            "width": .object([
                                "type": .string("number"),
                                "exclusiveMinimum": .int(0),
                            ]),
                            "height": .object([
                                "type": .string("number"),
                                "exclusiveMinimum": .int(0),
                            ]),
                        ]),
                        "required": .array([
                            .string("x"),
                            .string("y"),
                            .string("width"),
                            .string("height"),
                        ]),
                        "additionalProperties": .bool(false),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("png")]),
                        "default": .string("png"),
                    ]),
                    "include_cursor": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                    ]),
                    "exclude_mupaw_ui": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string(
                            "Exclude Mupaw windows from full-screen and region captures. It has no effect for independent window capture."
                        ),
                    ]),
                    "file_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional safe base name. Mupaw sanitizes it and controls the destination directory."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]

    private static let emptyObjectSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

}
