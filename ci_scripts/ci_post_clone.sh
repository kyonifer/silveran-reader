#!/bin/bash
set -e

echo "Installing dependencies..."
brew install xcodegen imagemagick

echo "Generating icons..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
./scripts/genicons

echo "Generating Xcode project..."
./scripts/genxproj

echo "Copying Package.resolved to Xcode project..."
mkdir -p Silveran.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp SilveranKit/Package.resolved Silveran.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

echo "Xcode project generated successfully"
