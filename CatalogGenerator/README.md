# CatalogGenerator

Dev-only CLI tool for generating the Console action catalog. This code **never ships** with the main app.

## Purpose

Discovers installed macOS app capabilities (AppleScript dictionaries, App Intents, bundle metadata) and uses LLM-assisted generation to produce structured catalog entries that the main app uses at runtime for command execution.

## Workflow

```
discover → generate → validate → review → commit JSON → ship app
```

1. **Discover** — Scan `/Applications` for automation capabilities
2. **Generate** — Produce catalog entries from discovered data via LLM
3. **Validate** — Check entries for correctness, safety, and timing accuracy
4. **Review** — Interactive review before approval
5. **Commit** — The generated `ActionCatalog.json` is committed to the repo and bundled with the shipping app

## Usage

### Via convenience script (recommended)

```bash
# Full pipeline
./Scripts/generate-catalog.sh all

# Individual steps
./Scripts/generate-catalog.sh build
./Scripts/generate-catalog.sh discover
./Scripts/generate-catalog.sh generate
./Scripts/generate-catalog.sh validate
./Scripts/generate-catalog.sh review
```

### Direct CLI

```bash
cd CatalogGenerator
swift build -c release
.build/release/CatalogGenerator --help
.build/release/CatalogGenerator discover --output discovered-apps.json
.build/release/CatalogGenerator generate --input discovered-apps.json --output ../Console/Console/Resources/ActionCatalog.json
.build/release/CatalogGenerator validate ../Console/Console/Resources/ActionCatalog.json
```

## What Ships vs. What Stays

| Artifact | Ships with app? |
|----------|----------------|
| `CatalogGenerator/` (this tool) | No |
| `discovered-apps.json` | No (gitignored) |
| `ActionCatalog.json` | Yes (bundled resource) |
