# Security

Please report security issues privately by opening a GitHub Security Advisory for this repository.

PadKey stores optional API keys in the macOS Keychain and keeps dictation history local by default. Do not include personal transcripts, API keys, recordings, or local diagnostic files in public issues.

Before sharing a bug report, remove:

- `~/Library/Application Support/PadKey` data
- screenshots that show real transcripts, contacts, emails, paths, or API key state
- generated app bundles from `dist/`
- downloaded local speech models from `Support/`
