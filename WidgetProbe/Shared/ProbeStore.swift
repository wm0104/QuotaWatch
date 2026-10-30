import Foundation

struct ProbeStore {
    // Injected directory is for pure Foundation tests; production calls appGroup() only.
    let directoryURL: URL

    static func appGroup() throws -> ProbeStore {
        #if os(iOS)
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ProbeIdentity.group) else {
            throw ProbeError.groupUnavailable
        }
        return ProbeStore(directoryURL: url)
        #else
        throw ProbeError.groupUnavailable
        #endif
    }

    private func read(_ filename: String) throws -> Data? {
        do {
            return try Data(contentsOf: directoryURL.appendingPathComponent(filename))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func write(_ data: Data, filename: String) throws {
        let url = directoryURL.appendingPathComponent(filename)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    func readSnapshot() throws -> ProbeSnapshot? {
        guard let data = try read(ProbeIdentity.snapshotFile) else { return nil }
        return try ProbeCodec.decode(ProbeSnapshot.self, from: data).validated()
    }

    func writeSnapshot(_ snapshot: ProbeSnapshot) throws {
        try write(ProbeCodec.encode(snapshot.validated()), filename: ProbeIdentity.snapshotFile)
    }

    func removeSnapshot() throws {
        do {
            try FileManager.default.removeItem(at: directoryURL.appendingPathComponent(ProbeIdentity.snapshotFile))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already missing is a successful removal; no other file is touched.
        }
    }

    func readDiagnostic() throws -> ProbeReadDiagnostic? {
        guard let data = try read(ProbeIdentity.diagnosticFile) else { return nil }
        return try ProbeCodec.decode(ProbeReadDiagnostic.self, from: data).validated()
    }

    func writeDiagnostic(_ diagnostic: ProbeReadDiagnostic) throws {
        try write(ProbeCodec.encode(diagnostic.validated()), filename: ProbeIdentity.diagnosticFile)
    }
}
