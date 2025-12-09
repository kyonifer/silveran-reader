import Foundation
import ZIPFoundation

public enum SMILParserError: Error {
    case failedToOpenArchive(String)
    case containerNotFound
    case opfPathNotFound
    case invalidXML
    case fileNotFoundInArchive(String)
    case parseError(String)
}

public enum SMILParser {

    /// Parse EPUB to extract SMIL structure for audio playback
    public static func parseEPUB(at url: URL) throws -> [SectionInfo] {
        let archive = try Archive(url: url, accessMode: .read)

        let opfPath = try findOPFPath(in: archive)
        let opfData = try extractFile(from: archive, path: opfPath)

        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let (manifest, spine) = try parseOPF(opfData)
        let tocLabels = try parseTOCLabels(from: archive, manifest: manifest, opfDir: opfDir)

        var sections: [SectionInfo] = []
        var cumulativeTime: Double = 0

        for (index, spineItem) in spine.enumerated() {
            guard let manifestItem = manifest[spineItem.idref] else { continue }

            let sectionId = manifestItem.href
            let label = tocLabels[sectionId] ?? tocLabels[spineItem.idref]

            var mediaOverlay: [SMILEntry] = []

            if let mediaOverlayId = spineItem.mediaOverlay ?? manifestItem.mediaOverlay,
               let smilItem = manifest[mediaOverlayId] {
                let smilPath = resolvePath(smilItem.href, relativeTo: opfDir)
                if let smilData = try? extractFile(from: archive, path: smilPath) {
                    let smilDir = (smilPath as NSString).deletingLastPathComponent
                    let entries = try parseSMIL(smilData, smilDir: smilDir, opfDir: opfDir)
                    for entry in entries {
                        let duration = entry.end - entry.begin
                        cumulativeTime += duration
                        mediaOverlay.append(SMILEntry(
                            textId: entry.textId,
                            textHref: entry.textHref,
                            audioFile: entry.audioFile,
                            begin: entry.begin,
                            end: entry.end,
                            cumSumAtEnd: cumulativeTime
                        ))
                    }
                }
            }

            sections.append(SectionInfo(
                index: index,
                id: sectionId,
                label: label,
                level: nil,
                mediaOverlay: mediaOverlay
            ))
        }

        return sections
    }

    // MARK: - Time Parsing

    /// Parse SMIL time formats: "h:mm:ss.fff", "m:ss", "5.5s", "100ms"
    static func parseSMILTime(_ str: String?) -> Double? {
        guard let str = str, !str.isEmpty else { return nil }

        let parts = str.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }

        let trimmed = str.trimmingCharacters(in: .whitespaces)

        if trimmed.hasSuffix("h") {
            let numberStr = String(trimmed.dropLast())
            if let number = Double(numberStr) { return number * 3600 }
        } else if trimmed.hasSuffix("min") {
            let numberStr = String(trimmed.dropLast(3))
            if let number = Double(numberStr) { return number * 60 }
        } else if trimmed.hasSuffix("ms") {
            let numberStr = String(trimmed.dropLast(2))
            if let number = Double(numberStr) { return number * 0.001 }
        } else if trimmed.hasSuffix("s") {
            let numberStr = String(trimmed.dropLast())
            if let number = Double(numberStr) { return number }
        }

        return Double(trimmed)
    }

    // MARK: - Container Parsing

    private static func findOPFPath(in archive: Archive) throws -> String {
        let containerPath = "META-INF/container.xml"
        let containerData = try extractFile(from: archive, path: containerPath)

        let delegate = ContainerXMLDelegate()
        let parser = XMLParser(data: containerData)
        parser.delegate = delegate
        guard parser.parse(), let opfPath = delegate.opfPath else {
            throw SMILParserError.opfPathNotFound
        }

        return opfPath
    }

    private static func extractFile(from archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw SMILParserError.fileNotFoundInArchive(path)
        }

        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            data.append(chunk)
        }
        return data
    }

    // MARK: - OPF Parsing

    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String?
        let mediaOverlay: String?
    }

    struct SpineItem {
        let idref: String
        let mediaOverlay: String?
    }

    private static func parseOPF(_ data: Data) throws -> (manifest: [String: ManifestItem], spine: [SpineItem]) {
        let delegate = OPFXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SMILParserError.parseError("Failed to parse OPF")
        }
        return (delegate.manifest, delegate.spine)
    }

    private static func parseTOCLabels(
        from archive: Archive,
        manifest: [String: ManifestItem],
        opfDir: String
    ) throws -> [String: String] {
        let ncxItem = manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }

        if let ncxItem = ncxItem {
            let ncxPath = resolvePath(ncxItem.href, relativeTo: opfDir)
            if let ncxData = try? extractFile(from: archive, path: ncxPath) {
                return parseNCXLabels(ncxData)
            }
        }

        return [:]
    }

    private static func parseNCXLabels(_ data: Data) -> [String: String] {
        let delegate = NCXXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.labels
    }

    // MARK: - SMIL Parsing

    struct RawSMILEntry {
        let textId: String
        let textHref: String
        let audioFile: String
        let begin: Double
        let end: Double
    }

    private static func parseSMIL(_ data: Data, smilDir: String, opfDir: String) throws -> [RawSMILEntry] {
        let delegate = SMILXMLDelegate(smilDir: smilDir)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SMILParserError.parseError("Failed to parse SMIL")
        }

        return delegate.entries.map { entry in
            let resolvedTextHref = resolvePath(entry.textHref, relativeTo: smilDir)
            let relativeTextHref = makePathRelative(resolvedTextHref, to: opfDir)
            return RawSMILEntry(
                textId: entry.textId,
                textHref: relativeTextHref,
                audioFile: entry.audioFile,
                begin: entry.begin,
                end: entry.end
            )
        }
    }

    private static func makePathRelative(_ path: String, to basePath: String) -> String {
        if basePath.isEmpty {
            return path
        }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private static func resolvePath(_ path: String, relativeTo base: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("http") {
            return path
        }
        if base.isEmpty {
            return path
        }
        let combined = (base as NSString).appendingPathComponent(path)
        return normalizePath(combined)
    }

    private static func normalizePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.components(separatedBy: "/") {
            if component == ".." {
                if !components.isEmpty && components.last != ".." {
                    components.removeLast()
                }
            } else if component != "." && !component.isEmpty {
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }
}

// MARK: - XMLParser Delegates

private class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        if elementName == "rootfile" || qName?.hasSuffix(":rootfile") == true {
            opfPath = attributes["full-path"]
        }
    }
}

private class OPFXMLDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: SMILParser.ManifestItem] = [:]
    var spine: [SMILParser.SpineItem] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        if localName == "item" {
            guard let id = attributes["id"], let href = attributes["href"] else { return }
            let decodedHref = href.removingPercentEncoding ?? href
            manifest[id] = SMILParser.ManifestItem(
                id: id,
                href: decodedHref,
                mediaType: attributes["media-type"],
                mediaOverlay: attributes["media-overlay"]
            )
        } else if localName == "itemref" {
            guard let idref = attributes["idref"] else { return }
            spine.append(SMILParser.SpineItem(
                idref: idref,
                mediaOverlay: attributes["media-overlay"]
            ))
        }
    }
}

private class NCXXMLDelegate: NSObject, XMLParserDelegate {
    var labels: [String: String] = [:]

    private var currentNavPointSrc: String?
    private var currentText: String = ""
    private var inNavLabel = false
    private var inText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "navPoint":
            currentNavPointSrc = nil
            currentText = ""
        case "navLabel":
            inNavLabel = true
        case "text":
            if inNavLabel {
                inText = true
                currentText = ""
            }
        case "content":
            if let src = attributes["src"] {
                let baseSrc = src.components(separatedBy: "#").first ?? ""
                currentNavPointSrc = baseSrc.removingPercentEncoding ?? baseSrc
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "navLabel":
            inNavLabel = false
        case "text":
            inText = false
        case "navPoint":
            if let src = currentNavPointSrc, !currentText.isEmpty {
                let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                labels[src] = trimmedText
            }
        default:
            break
        }
    }
}

private class SMILXMLDelegate: NSObject, XMLParserDelegate {
    let smilDir: String
    var entries: [SMILParser.RawSMILEntry] = []

    private var inPar = false
    private var currentTextSrc: String?
    private var currentAudioSrc: String?
    private var currentClipBegin: Double = 0
    private var currentClipEnd: Double = 0

    init(smilDir: String) {
        self.smilDir = smilDir
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "par":
            inPar = true
            currentTextSrc = nil
            currentAudioSrc = nil
            currentClipBegin = 0
            currentClipEnd = 0
        case "text":
            if inPar, let src = attributes["src"] {
                currentTextSrc = src
            }
        case "audio":
            if inPar {
                currentAudioSrc = attributes["src"]
                currentClipBegin = SMILParser.parseSMILTime(attributes["clipBegin"]) ?? 0
                currentClipEnd = SMILParser.parseSMILTime(attributes["clipEnd"]) ?? 0
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        if localName == "par" {
            if let textSrc = currentTextSrc, let audioSrc = currentAudioSrc {
                let (textHref, textId) = parseTextSrc(textSrc)
                let resolvedAudioPath = resolvePath(audioSrc, relativeTo: smilDir)

                entries.append(SMILParser.RawSMILEntry(
                    textId: textId,
                    textHref: textHref,
                    audioFile: resolvedAudioPath,
                    begin: currentClipBegin,
                    end: currentClipEnd
                ))
            }
            inPar = false
        }
    }

    private func parseTextSrc(_ src: String) -> (href: String, id: String) {
        let components = src.components(separatedBy: "#")
        let href = components.first ?? src
        let id = components.count > 1 ? components[1] : ""
        let decodedHref = href.removingPercentEncoding ?? href
        return (decodedHref, id)
    }

    private func resolvePath(_ path: String, relativeTo base: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("http") {
            return path
        }
        if base.isEmpty {
            return path
        }
        let combined = (base as NSString).appendingPathComponent(path)
        return normalizePath(combined)
    }

    private func normalizePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.components(separatedBy: "/") {
            if component == ".." {
                if !components.isEmpty && components.last != ".." {
                    components.removeLast()
                }
            } else if component != "." && !component.isEmpty {
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }
}
