import Foundation
import SwiftSoup
import ZIPFoundation

public enum EPUBContentLoaderError: Error {
    case failedToOpenArchive(String)
    case fileNotFoundInArchive(String)
    case invalidEncoding
    case parseError(String)
}

public enum EPUBContentLoader {

    /// Load full XHTML content for a section
    public static func loadSection(
        from epubURL: URL,
        href: String
    ) throws -> String {
        let archive = try Archive(url: epubURL, accessMode: .read)
        let data = try extractFile(from: archive, path: href)
        guard let content = String(data: data, encoding: .utf8) else {
            throw EPUBContentLoaderError.invalidEncoding
        }
        return content
    }

    /// Extract element content by ID from HTML
    /// Returns the inner HTML of the element with the given ID
    public static func extractElement(
        from html: String,
        elementId: String
    ) -> String? {
        do {
            let doc = try SwiftSoup.parse(html)
            guard let element = try doc.getElementById(elementId) else {
                return nil
            }
            return try element.html()
        } catch {
            return nil
        }
    }

    /// Strip HTML tags from string, returning plain text
    public static func stripHTML(_ html: String) -> String {
        do {
            let doc = try SwiftSoup.parse(html)
            return try doc.text()
        } catch {
            return html
        }
    }

    public static func extractElementsText(
        from html: String,
        elementIds: [String]
    ) -> [String: String] {
        do {
            let doc = try SwiftSoup.parse(html)
            var results: [String: String] = [:]
            for elementId in Set(elementIds) {
                guard let element = try doc.getElementById(elementId) else { continue }
                let text = try element.text()
                if !text.isEmpty {
                    results[elementId] = text
                }
            }
            return results
        } catch {
            return [:]
        }
    }

    /// Get plain text for a specific element
    public static func getElementText(
        from epubURL: URL,
        href: String,
        elementId: String
    ) throws -> String? {
        let html = try loadSection(from: epubURL, href: href)
        guard let elementHTML = extractElement(from: html, elementId: elementId) else {
            return nil
        }
        return stripHTML(elementHTML)
    }

    // MARK: - Private

    private static func extractFile(from archive: Archive, path: String) throws -> Data {
        let pathsToTry = [
            path,
            "OPS/\(path)",
            "OEBPS/\(path)",
            "epub/\(path)",
        ]

        for tryPath in pathsToTry {
            if let entry = archive[tryPath] {
                var data = Data()
                _ = try archive.extract(entry, skipCRC32: true) { chunk in
                    data.append(chunk)
                }
                return data
            }
        }

        throw EPUBContentLoaderError.fileNotFoundInArchive(path)
    }
}
