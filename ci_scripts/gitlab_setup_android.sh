#!/usr/bin/env bash

set -euo pipefail

SWIFT_VERSION="6.3.1"
SWIFT_ANDROID_CHECKSUM="8193a4e96538635131a154736c8896fba0e5a1c30e065524f00ed78719bac35a"
SWIFT_ANDROID_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/android-sdk/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_android.artifactbundle.tar.gz"
SWIFT_TOOLCHAIN_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
SWIFT_TOOLCHAIN_PATH="/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain"
DOWNLOAD_CACHE="${CI_PROJECT_DIR}/.ci-cache/downloads"
SWIFT_ANDROID_ARCHIVE="${DOWNLOAD_CACHE}/swift-${SWIFT_VERSION}-RELEASE_android.artifactbundle.tar.gz"
SWIFT_TOOLCHAIN_PACKAGE="${DOWNLOAD_CACHE}/swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
export ANDROID_HOME="${CI_PROJECT_DIR}/.ci-cache/android-sdk"
export ANDROID_NDK_HOME="${ANDROID_HOME}/ndk/27.1.12297006"
export SILVERAN_SWIFT_ANDROID_SDK_BUNDLE="${HOME}/Library/org.swift.swiftpm/swift-sdks/swift-${SWIFT_VERSION}-RELEASE_android.artifactbundle"
export SILVERAN_SWIFT_TOOLCHAIN=""

brew install bc imagemagick openjdk@17
brew install --cask android-commandlinetools

export PATH="${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${PATH}"
mkdir -p "${ANDROID_HOME}"

set +o pipefail
yes | sdkmanager --sdk_root="${ANDROID_HOME}" --licenses >/dev/null
set -o pipefail
sdkmanager --sdk_root="${ANDROID_HOME}" \
    "build-tools;36.0.0" \
    "ndk;27.1.12297006" \
    "platforms;android-36"

mkdir -p "${DOWNLOAD_CACHE}"
if [[ ! -f "${SWIFT_TOOLCHAIN_PACKAGE}" ]]; then
    curl -fL "${SWIFT_TOOLCHAIN_URL}" -o "${SWIFT_TOOLCHAIN_PACKAGE}"
fi
sudo installer -pkg "${SWIFT_TOOLCHAIN_PACKAGE}" -target /
export PATH="${SWIFT_TOOLCHAIN_PATH}/usr/bin:${PATH}"

if [[ ! -f "${SWIFT_ANDROID_ARCHIVE}" ]]; then
    curl -fL "${SWIFT_ANDROID_URL}" -o "${SWIFT_ANDROID_ARCHIVE}"
fi
swift sdk install "${SWIFT_ANDROID_ARCHIVE}" --checksum "${SWIFT_ANDROID_CHECKSUM}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
    "${SILVERAN_SWIFT_ANDROID_SDK_BUNDLE}/swift-android/scripts/setup-android-sdk.sh"

swift --version
swift sdk list
java -version
sdkmanager --version
