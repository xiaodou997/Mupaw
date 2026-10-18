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
        Tool(
            name: "mupaw_project_create",
            description:
                "Create a non-destructive screenshot editing project from a Mupaw capture artifact. The source file must be inside Mupaw's Captures directory and its SHA-256 must match.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source_file_url": .object([
                        "type": .string("string"),
                        "description": .string("Exact file URL returned by mupaw_screenshot_capture."),
                    ]),
                    "source_sha256": .object([
                        "type": .string("string"),
                        "description": .string("Exact SHA-256 returned by mupaw_screenshot_capture."),
                    ]),
                    "source_artifact_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional capture artifact identifier."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Optional project title."),
                    ]),
                ]),
                "required": .array([.string("source_file_url"), .string("source_sha256")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mupaw_project_get",
            description:
                "Read the current revision, crop, edit objects, original image metadata, and undo/redo availability for a screenshot project.",
            inputSchema: projectIDSchema
        ),
        Tool(
            name: "mupaw_project_apply_edits",
            description:
                "Atomically apply one or more crop, arrow, text, mosaic, update, delete, or reset commands to a screenshot project. Coordinates use original-image pixels with a top-left origin. expected_revision is required for optimistic concurrency.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": projectIDProperty,
                    "expected_revision": revisionProperty,
                    "commands": .object([
                        "type": .string("array"),
                        "minItems": .int(1),
                        "maxItems": .int(1_000),
                        "items": editCommandSchema,
                    ]),
                ]),
                "required": .array([
                    .string("project_id"),
                    .string("expected_revision"),
                    .string("commands"),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mupaw_project_history",
            description:
                "Undo or redo one persisted project history step. Every successful history action creates a new monotonic revision.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": projectIDProperty,
                    "expected_revision": revisionProperty,
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("undo"), .string("redo")]),
                    ]),
                ]),
                "required": .array([
                    .string("project_id"),
                    .string("expected_revision"),
                    .string("action"),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mupaw_project_preview",
            description:
                "Render the current project revision through the same pipeline used for export and return dimensions plus a bounded JPEG preview.",
            inputSchema: projectRevisionSchema
        ),
        Tool(
            name: "mupaw_project_ocr",
            description:
                "Recognize text locally from the immutable project original using Apple Vision. Returns effective recognition settings, detected-language metadata, and bounded observations with text, confidence, language, and original-image pixel rectangles using a top-left origin. The current crop is the default region; annotations are not analyzed.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": projectIDProperty,
                    "expected_revision": revisionProperty,
                    "region": rectSchema,
                    "recognition_level": .object([
                        "type": .string("string"),
                        "enum": .array([.string("fast"), .string("accurate")]),
                        "default": .string("accurate"),
                    ]),
                    "recognition_languages": .object([
                        "type": .string("array"),
                        "maxItems": .int(8),
                        "items": .object([
                            "type": .string("string"),
                            "maxLength": .int(64),
                        ]),
                        "description": .string(
                            "Optional BCP-47 language hints such as en-US or zh-Hans. Omit or use an empty array for automatic language detection."
                        ),
                    ]),
                    "uses_language_correction": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                    ]),
                    "minimum_confidence": .object([
                        "type": .string("number"),
                        "minimum": .int(0),
                        "maximum": .int(1),
                        "default": .int(0),
                    ]),
                ]),
                "required": .array([.string("project_id")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mupaw_project_color_sample",
            description:
                "Sample sRGB color from the immutable project original. point mode returns one pixel. region mode returns average, center, and deterministic dominant colors plus the bounded sampled-pixel count. Coordinates use original-image pixels with a top-left origin.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": projectIDProperty,
                    "expected_revision": revisionProperty,
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("point"), .string("region")]),
                    ]),
                    "point": pointSchema,
                    "region": rectSchema,
                ]),
                "required": .array([.string("project_id"), .string("mode")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mupaw_project_export",
            description:
                "Render and export the current screenshot project as PNG while preserving the original capture and editable project. Returns file metadata, SHA-256, and preview.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": projectIDProperty,
                    "expected_revision": revisionProperty,
                    "file_name": .object([
                        "type": .string("string"),
                        "description": .string("Optional safe base name for the exported PNG."),
                    ]),
                ]),
                "required": .array([.string("project_id")]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]

    private static let projectIDProperty: Value = .object([
        "type": .string("string"),
        "description": .string("Screenshot project UUID returned by mupaw_project_create."),
    ])

    private static let revisionProperty: Value = .object([
        "type": .string("integer"),
        "minimum": .int(1),
        "description": .string("Expected current project revision."),
    ])

    private static let projectIDSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["project_id": projectIDProperty]),
        "required": .array([.string("project_id")]),
        "additionalProperties": .bool(false),
    ])

    private static let projectRevisionSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "project_id": projectIDProperty,
            "expected_revision": revisionProperty,
        ]),
        "required": .array([.string("project_id")]),
        "additionalProperties": .bool(false),
    ])

    private static let pointSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "x": .object(["type": .string("number")]),
            "y": .object(["type": .string("number")]),
        ]),
        "required": .array([.string("x"), .string("y")]),
        "additionalProperties": .bool(false),
    ])

    private static let rectSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "x": .object(["type": .string("number")]),
            "y": .object(["type": .string("number")]),
            "width": .object(["type": .string("number"), "exclusiveMinimum": .int(0)]),
            "height": .object(["type": .string("number"), "exclusiveMinimum": .int(0)]),
        ]),
        "required": .array([
            .string("x"), .string("y"), .string("width"), .string("height"),
        ]),
        "additionalProperties": .bool(false),
    ])

    private static let colorSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "red": normalizedColorProperty,
            "green": normalizedColorProperty,
            "blue": normalizedColorProperty,
            "alpha": normalizedColorProperty,
        ]),
        "required": .array([
            .string("red"), .string("green"), .string("blue"), .string("alpha"),
        ]),
        "additionalProperties": .bool(false),
    ])

    private static let normalizedColorProperty: Value = .object([
        "type": .string("number"),
        "minimum": .int(0),
        "maximum": .int(1),
    ])

    private static let editObjectSchema: Value = .object([
        "type": .string("object"),
        "description": .string(
            "Tagged edit object. kind must match exactly one payload field: arrow, text, or mosaic."
        ),
        "properties": .object([
            "kind": .object([
                "type": .string("string"),
                "enum": .array([.string("arrow"), .string("text"), .string("mosaic")]),
            ]),
            "arrow": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "start": pointSchema,
                    "end": pointSchema,
                    "color": colorSchema,
                    "lineWidth": .object([
                        "type": .string("number"),
                        "minimum": .int(1),
                        "maximum": .int(128),
                    ]),
                ]),
                "required": .array([
                    .string("id"), .string("start"), .string("end"),
                    .string("color"), .string("lineWidth"),
                ]),
                "additionalProperties": .bool(false),
            ]),
            "text": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "frame": rectSchema,
                    "text": .object(["type": .string("string")]),
                    "color": colorSchema,
                    "fontSize": .object([
                        "type": .string("number"),
                        "minimum": .int(6),
                        "maximum": .int(512),
                    ]),
                ]),
                "required": .array([
                    .string("id"), .string("frame"), .string("text"),
                    .string("color"), .string("fontSize"),
                ]),
                "additionalProperties": .bool(false),
            ]),
            "mosaic": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "frame": rectSchema,
                    "blockSize": .object([
                        "type": .string("number"),
                        "minimum": .int(2),
                        "maximum": .int(256),
                    ]),
                ]),
                "required": .array([
                    .string("id"), .string("frame"), .string("blockSize"),
                ]),
                "additionalProperties": .bool(false),
            ]),
        ]),
        "required": .array([.string("kind")]),
        "additionalProperties": .bool(false),
    ])

    private static let editCommandSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("set_crop"),
                    .string("add_object"),
                    .string("update_object"),
                    .string("delete_object"),
                    .string("reset"),
                ]),
            ]),
            "rect": .object([
                "anyOf": .array([
                    rectSchema,
                    .object(["type": .string("null")]),
                ])
            ]),
            "object": editObjectSchema,
            "object_id": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("type")]),
        "additionalProperties": .bool(false),
    ])

    private static let emptyObjectSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

}
