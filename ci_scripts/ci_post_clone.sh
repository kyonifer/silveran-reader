#!/bin/bash
set -e

echo "Installing dependencies..."
brew install xcodegen imagemagick

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Removing unused Foliate PDF support..."
rm -f SilveranKit/Sources/AppleKit/Resources/WebResources/foliate-js/pdf.js
rm -rf SilveranKit/Sources/AppleKit/Resources/WebResources/foliate-js/vendor/pdfjs

echo "Generating icons..."
./scripts/genicons

echo "Generating Xcode project..."
./scripts/genxproj

echo "Copying Package.resolved to Xcode project..."
mkdir -p Silveran.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Silveran.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

echo "Xcode project generated successfully"
