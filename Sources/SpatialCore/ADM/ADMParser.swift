import Foundation

// MARK: - ADM document model (ITU-R BS.2076 subset)

public struct ADMBlock: Sendable {
    public var start: Double
    public var duration: Double?
    public var position: SpatialPoint
    public var gainDB: Double?
    public var width: Double?
}

public struct ADMChannelFormat: Sendable {
    public var id: String
    public var name: String
    public var typeLabel: String?
    public var blocks: [ADMBlock]
}

public struct ADMPackFormat: Sendable {
    public var id: String
    public var name: String
    public var typeLabel: String?
    public var channelFormatIDs: [String]
}

public struct ADMObject: Sendable {
    public var id: String
    public var name: String
    public var typeLabel: String?
    public var channelFormatIDs: [String]
    public var packFormatIDs: [String]
    public var dialogueID: Int?
    public var trackUIDRefs: [String] = []
}

public struct ADMTrackUID: Sendable {
    public var uid: String
    public var channelIndex: Int
    public var sampleRate: Double?
}

public struct ADMDocument: Sendable {
    public var programmeName: String?
    public var programmeStart: Double?
    public var programmeEnd: Double?
    public var channels: [String: ADMChannelFormat] = [:]
    public var packs: [String: ADMPackFormat] = [:]
    public var objects: [ADMObject] = []
    public var trackUIDs: [ADMTrackUID] = []
    public var sampleRate: Double?
    public var referencesDolby: Bool = false

    public var isEmpty: Bool { objects.isEmpty && channels.isEmpty }
}

/// One decoded audio channel plus its spatial source description.
public struct ADMTrack: Sendable {
    public var channelIndex: Int
    public var objectName: String
    public var isBed: Bool
    public var speaker: Speaker?
    public var keyframes: [ObjectKeyframe]
    public var dialogue: Int?
    public var group: String
}

// MARK: - Minimal XML tree

final class XMLNode {
    var name: String
    var attributes: [String: String]
    var text: String = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func children(named target: String) -> [XMLNode] {
        children.filter { $0.name == target }
    }

    func first(_ target: String) -> XMLNode? {
        children.first { $0.name == target }
    }

    /// Depth-first search for all nodes with a local name.
    func descendants(named target: String) -> [XMLNode] {
        var found: [XMLNode] = []
        if name == target { found.append(self) }
        for child in children { found.append(contentsOf: child.descendants(named: target)) }
        return found
    }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root = XMLNode(name: "#document", attributes: [:])
    private var stack: [XMLNode] = []

    func parse(_ data: Data) throws -> XMLNode {
        root = XMLNode(name: "#document", attributes: [:])
        stack = [root]
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "ADM.XML", code: 1)
        }
        return root
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: local(elementName), attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
}

// MARK: - ADM interpretation

public enum ADMParser {
    public static func parse(data: Data) throws -> ADMDocument {
        let tree = try XMLTreeBuilder().parse(data)
        return interpret(tree)
    }

    public static func parse(string: String) throws -> ADMDocument {
        try parse(data: Data(string.utf8))
    }

    private static func double(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        if let value = Double(raw) { return value }
        let parts = raw.split(separator: ":")
        if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        }
        return nil
    }

    public static func time(_ raw: String?) -> Double? { double(raw) }

    private static func blockPosition(_ node: XMLNode) -> SpatialPoint {
        var x = 0.0, y = 0.0, z = 0.0
        var azimuth: Double?, elevation: Double?
        var found = false
        for position in node.descendants(named: "position") {
            guard let value = double(position.trimmedText) else { continue }
            let coordinate = (position.attributes["coordinate"] ?? "").lowercased()
            switch coordinate {
            case "x": x = value; found = true
            case "y": y = value; found = true
            case "z": z = value; found = true
            case "azimuth": azimuth = value; found = true
            case "elevation": elevation = value; found = true
            case "distance": found = true
            default: break
            }
        }
        // BS.2076: azimuth positive = left, Cartesian Y = +1 front. Internal: positive
        // azimuth = right, y = −1 front.
        if let azimuth {
            return SpatialPoint.fromSpherical(azimuth: -azimuth, elevation: elevation ?? 0, radius: 1)
        }
        return found ? SpatialPoint(x: x, y: -y, z: z).clamped : .center
    }

    private static func interpret(_ root: XMLNode) -> ADMDocument {
        var doc = ADMDocument()
        doc.referencesDolby = root.descendants(named: "coreMetadata").first?.text.contains("Dolby") ?? false

        for programme in root.descendants(named: "audioProgramme") {
            doc.programmeName = programme.attributes["audioProgrammeName"]
            doc.programmeStart = double(programme.attributes["start"])
            doc.programmeEnd = double(programme.attributes["end"])
            break
        }

        for channel in root.descendants(named: "audioChannelFormat") {
            guard let id = channel.attributes["audioChannelFormatID"] else { continue }
            var blocks: [ADMBlock] = []
            for (index, block) in channel.descendants(named: "audioBlockFormat").enumerated() {
                let start = double(block.attributes["rtime"]) ?? Double(index) * 0.0
                let width = double(block.first("width")?.trimmedText)
                let gain = double(block.first("gain")?.trimmedText)
                blocks.append(ADMBlock(
                    start: start,
                    duration: double(block.attributes["duration"]),
                    position: blockPosition(block),
                    gainDB: gain.map { 20 * log10(max($0, 1e-6)) },
                    width: width
                ))
            }
            if blocks.isEmpty {
                blocks = [ADMBlock(start: 0, duration: nil, position: .center, gainDB: nil, width: nil)]
            }
            doc.channels[id] = ADMChannelFormat(
                id: id,
                name: channel.attributes["audioChannelFormatName"] ?? "",
                typeLabel: channel.attributes["typeLabel"],
                blocks: blocks
            )
        }

        for pack in root.descendants(named: "audioPackFormat") {
            guard let id = pack.attributes["audioPackFormatID"] else { continue }
            let refs = pack.descendants(named: "audioChannelFormatIDRef")
                .compactMap { $0.attributes["audioChannelFormatIDRef"] ?? $0.trimmedText.nonEmpty }
            doc.packs[id] = ADMPackFormat(
                id: id,
                name: pack.attributes["audioPackFormatName"] ?? "",
                typeLabel: pack.attributes["typeLabel"],
                channelFormatIDs: refs
            )
        }

        for object in root.descendants(named: "audioObject") {
            guard let id = object.attributes["audioObjectID"] else { continue }
            let channelRefs = object.children(named: "audioChannelFormatIDRef")
                .compactMap { $0.attributes["audioChannelFormatIDRef"] ?? $0.trimmedText.nonEmpty }
            let packRefs = object.children(named: "audioPackFormatIDRef")
                .compactMap { $0.attributes["audioPackFormatIDRef"] ?? $0.trimmedText.nonEmpty }
            doc.objects.append(ADMObject(
                id: id,
                name: object.attributes["audioObjectName"] ?? "",
                typeLabel: object.attributes["typeLabel"],
                channelFormatIDs: channelRefs,
                packFormatIDs: packRefs,
                dialogueID: object.attributes["dialogueId"].flatMap(Int.init),
                trackUIDRefs: object.children(named: "audioTrackUIDRef").compactMap { $0.trimmedText.nonEmpty }
            ))
        }

        for uid in root.descendants(named: "audioTrackUID") {
            let index = Int(uid.trimmedText) ?? (doc.trackUIDs.count + 1)
            doc.trackUIDs.append(ADMTrackUID(
                uid: uid.attributes["UID"] ?? "",
                channelIndex: max(0, index - 1),
                sampleRate: double(uid.attributes["sampleRate"])
            ))
        }

        doc.sampleRate = double(root.descendants(named: "audioFormatExtended").first?.attributes["sampleRate"])
        return doc
    }

    // MARK: Track resolution

    /// Resolves objects to tracks. When the file's `chna` table is supplied (UID → 1-based
    /// track index) channels are bound through each object's audioTrackUIDRef; otherwise
    /// tracks are assumed to follow object order.
    public static func tracks(in doc: ADMDocument, chna: [String: Int] = [:]) -> [ADMTrack] {
        var tracks: [ADMTrack] = []
        for object in doc.objects {
            let pack = object.packFormatIDs.compactMap { doc.packs[$0] }.first
            let channelIDs = object.channelFormatIDs.isEmpty ? (pack?.channelFormatIDs ?? []) : object.channelFormatIDs
            guard !channelIDs.isEmpty else { continue }

            let packIsBed = isBedPack(pack)
            for (sub, channelID) in channelIDs.enumerated() {
                guard let channel = doc.channels[channelID] else { continue }
                let speaker = Speaker.allCases.first { $0.label.caseInsensitiveCompare(channel.name) == .orderedSame }
                let isBed = packIsBed || speaker != nil
                let keyframes = channel.blocks.map { block in
                    ObjectKeyframe(
                        time: block.start,
                        position: block.position,
                        size: block.width ?? 0
                    )
                }
                var channelIndex = tracks.count
                if sub < object.trackUIDRefs.count, let track = chna[object.trackUIDRefs[sub]] {
                    channelIndex = track - 1
                }
                tracks.append(ADMTrack(
                    channelIndex: channelIndex,
                    objectName: isBed ? (speaker?.label ?? channel.name.nonEmpty ?? object.name) :
                        (channelIDs.count > 1 ? "\(object.name) \(sub + 1)" : object.name.nonEmpty ?? "Object"),
                    isBed: isBed,
                    speaker: isBed ? speaker : nil,
                    keyframes: keyframes.isEmpty ? [ObjectKeyframe(time: 0, position: .center, size: 0)] : keyframes,
                    dialogue: object.dialogueID,
                    group: isBed ? "Bed" : "Objects"
                ))
            }
        }
        if tracks.isEmpty, !doc.trackUIDs.isEmpty {
            for uid in doc.trackUIDs.sorted(by: { $0.channelIndex < $1.channelIndex }) {
                tracks.append(ADMTrack(
                    channelIndex: tracks.count,
                    objectName: "Track \(uid.channelIndex + 1)",
                    isBed: false,
                    speaker: nil,
                    keyframes: [ObjectKeyframe(time: 0, position: .center, size: 0)],
                    dialogue: nil,
                    group: "Objects"
                ))
            }
        }
        return tracks
    }

    private static func isBedPack(_ pack: ADMPackFormat?) -> Bool {
        guard let pack else { return false }
        let label = pack.typeLabel ?? ""
        let name = pack.name.lowercased()
        if ["0001", "0002"].contains(label) { return true }
        if name.contains("bed") || name.contains("roomcentric") { return true }
        return false
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Array {
    public subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
