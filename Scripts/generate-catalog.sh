#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GENERATOR_DIR="$ROOT_DIR/CatalogGenerator"
CATALOG_OUTPUT="$ROOT_DIR/Console/Console/Resources/ActionCatalog.json"

echo "=== Console Catalog Generator ==="

# Build the generator tool
echo ""
echo "Building CatalogGenerator..."
cd "$GENERATOR_DIR"
swift build -c release
TOOL="$GENERATOR_DIR/.build/release/CatalogGenerator"

# Run based on argument (default: full pipeline)
COMMAND="${1:-all}"

case "$COMMAND" in
    build)
        echo "Build complete."
        ;;
    discover)
        echo ""
        echo "Discovering installed apps..."
        "$TOOL" discover --output "$GENERATOR_DIR/discovered-apps.json" "${@:2}"
        ;;
    generate)
        echo ""
        echo "Generating catalog entries..."
        "$TOOL" generate --input "$GENERATOR_DIR/discovered-apps.json" --output "$CATALOG_OUTPUT" "${@:2}"
        ;;
    validate)
        echo ""
        echo "Validating catalog..."
        "$TOOL" validate "$CATALOG_OUTPUT" "${@:2}"
        ;;
    review)
        echo ""
        echo "Reviewing catalog..."
        "$TOOL" review "$CATALOG_OUTPUT" "${@:2}"
        ;;
    all)
        echo ""
        echo "Running full pipeline: discover → generate → validate"
        "$TOOL" discover --output "$GENERATOR_DIR/discovered-apps.json"
        "$TOOL" generate --input "$GENERATOR_DIR/discovered-apps.json" --output "$CATALOG_OUTPUT"
        "$TOOL" validate "$CATALOG_OUTPUT"
        echo ""
        echo "Catalog written to: $CATALOG_OUTPUT"
        ;;
    *)
        echo "Usage: $0 {build|discover|generate|validate|review|all}"
        exit 1
        ;;
esac

echo ""
echo "Done."
