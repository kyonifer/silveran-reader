#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import Foundation

enum AppleKitResources {
    static func webResourcesDirectory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "WebResources", withExtension: nil) else {
            throw NSError(
                domain: "AppleKitResources",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find bundled WebResources"],
            )
        }
        return url
    }

    static func fontsDirectory() -> URL? {
        Bundle.module.url(forResource: "fonts", withExtension: nil)
    }
}
#endif
