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
                "Capture one source previously returned by mupaw_sources_list. M0 outputs a PNG artifact and a bounded preview.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source_id": .object([
                        "type": .string("string"),
                        "description": .string("Exact source identifier returned by mupaw_sources_list."),
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
                    "file_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional safe base name. Mupaw sanitizes it and controls the destination directory."),
                    ]),
                ]),
                "required": .array([.string("source_id")]),
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
