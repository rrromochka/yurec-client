import Foundation

@main
private enum ProductIsolationTests {
    static func main() throws {
        testIdentityPaths()
        try testReadOnlyProfileImport()
        try testInvalidInputIsRejectedBeforeCopy()
        print("Product isolation tests passed")
    }

    private static func testIdentityPaths() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        expect(
            ProductIdentity.bundleIdentifier == "ru.rom-gorodnichev.cambodgia.yurecclient",
            "downstream bundle identifier must remain distinct"
        )
        expect(
            ProductIdentity.profilesDirectory(homeDirectory: home).path
                == "/Users/example/Library/Application Support/Cambodgia YurecClient/Profiles",
            "profiles must live in downstream Application Support"
        )
        expect(
            ProductIdentity.logsDirectory(homeDirectory: home).path
                == "/Users/example/Library/Logs/Cambodgia YurecClient",
            "logs must live in a downstream-specific directory"
        )
        expect(
            ProductIdentity.upstreamProfilesDirectory(homeDirectory: home).path
                == "/Users/example/.singbox/profiles",
            "legacy upstream path must only be an explicit import source"
        )
    }

    private static func testReadOnlyProfileImport() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("upstream", isDirectory: true)
        let destination = root.appendingPathComponent("downstream", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let sourceProfile = source.appendingPathComponent("main.json")
        let original = Data("{\"outbounds\":[]}".utf8)
        try original.write(to: sourceProfile)
        let linkedProfile = source.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(
            at: linkedProfile,
            withDestinationURL: sourceProfile
        )

        let first = try ProfileImporter.importProfiles(from: source, to: destination)
        expect(first == ProfileImportSummary(imported: 1, skippedExisting: 0), "first import must copy")
        let sourceAfterImport = try Data(contentsOf: sourceProfile)
        expect(sourceAfterImport == original, "source profile must remain unchanged")

        let copiedProfile = destination.appendingPathComponent("main.json")
        let copiedData = try Data(contentsOf: copiedProfile)
        expect(copiedData == original, "destination must be an exact snapshot")
        expect(permissions(of: destination) == 0o700, "profile directory permissions must be 0700")
        expect(permissions(of: copiedProfile) == 0o600, "profile file permissions must be 0600")

        let second = try ProfileImporter.importProfiles(from: source, to: destination)
        expect(second == ProfileImportSummary(imported: 0, skippedExisting: 1), "duplicates must be skipped")
        expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("linked.json").path
            ),
            "import must not follow symbolic links"
        )
    }

    private static func testInvalidInputIsRejectedBeforeCopy() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("upstream", isDirectory: true)
        let destination = root.appendingPathComponent("downstream", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{\"valid\":true}".utf8).write(to: source.appendingPathComponent("a-valid.json"))
        try Data("not-json".utf8).write(to: source.appendingPathComponent("b-invalid.json"))

        do {
            _ = try ProfileImporter.importProfiles(from: source, to: destination)
            fatalError("invalid input must fail")
        } catch is ProfileImporter.ImportError {
            expect(
                !FileManager.default.fileExists(atPath: destination.path),
                "validation must complete before destination creation"
            )
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cambodgia-product-isolation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        guard try condition() else {
            fatalError("\(message) (\(file):\(line))")
        }
    }
}
