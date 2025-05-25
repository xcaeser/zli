#!/bin/bash

# Usage: ./release.sh 1.0.0
set -e

VERSION=$1
NOTES_FILE="RELEASE-NOTES.md"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  exit 1
fi

if [ ! -f "$NOTES_FILE" ]; then
  echo "❌ Release notes file '$NOTES_FILE' not found."
  exit 1
fi

# Optional: commit if there are changes
if ! git diff-index --quiet HEAD --; then
  git add .
  git commit -m "Release v$VERSION"
fi

# Tag and push
git tag -a "v$VERSION" -m "Version $VERSION"
git push origin main
git push origin "v$VERSION"

# Create GitHub release with notes from file
gh release create "v$VERSION" \
  --title "v$VERSION" \
  --notes-file "$NOTES_FILE"

echo "✅ GitHub release v$VERSION published."
