# Mupaw localization

Mupaw supports localization from the first application version.

## Initial languages

- English: `en`
- Simplified Chinese: `zh-Hans`

The application follows the macOS system language and the per-application language override available in System Settings. A language change takes effect after restarting Mupaw.

## Resource layout

```text
Resources/MupawApp/
├── en.lproj/
│   ├── Localizable.strings
│   └── InfoPlist.strings
└── zh-Hans.lproj/
    ├── Localizable.strings
    └── InfoPlist.strings
```

`Localizable.strings` contains user-facing application text. `InfoPlist.strings` contains privacy usage descriptions shown by macOS for the camera and microphone.

MCP tool names, RPC method names, error codes, JSON field names, and serialized enum values are protocol identifiers. They remain stable and are not translated. Human-readable messages returned by the running app may follow its current locale, while callers must rely on stable error codes.

## Validation

Run:

```bash
make localization-check
```

The validator uses `plutil` to parse every table, checks English and Simplified Chinese key parity, rejects empty values, and confirms required UI and privacy keys exist. `make lint` includes this validation.

## Adding a language

1. Add `<language>.lproj/Localizable.strings` and `<language>.lproj/InfoPlist.strings`.
2. Copy the complete key set from English and translate values only.
3. Add the language code to `LANGUAGES` in `scripts/validate_localizations.py`.
4. Run `make localization-check`, `make build`, and `make test`.
5. Launch the stable development app and validate the macOS per-application language override.

## Stable development app

Use:

```bash
make install-dev
```

This installs the signed development bundle at:

```text
~/Applications/Mupaw.app
```

Use this stable bundle when manually adding Mupaw to Screen & System Audio Recording permissions. Rebuilding inside DerivedData alone can leave macOS pointing at a temporary development path.
