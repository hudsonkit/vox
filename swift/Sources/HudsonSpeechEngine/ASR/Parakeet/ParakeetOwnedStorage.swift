import Darwin
import Foundation

/// Paths below the trusted Vox home are walked without following symlinks.
/// Receipts prevent a catalog alias from claiming/deleting another model's leaf.
struct ParakeetOwnedStorage: Sendable {
    let anchor: URL
    let parents: [String]
    let manifest: ParakeetModelManifest
    private static let receiptName = "vox-parakeet.json"
    private struct Receipt: Codable, Equatable {
        let schemaVersion: Int
        let modelId: String
        let repository: String
        let revision: String
    }
    private var expectedReceipt: Receipt {
        Receipt(schemaVersion: 1, modelId: manifest.modelId,
                repository: manifest.repositoryFolderName, revision: manifest.revision)
    }
    func directory() throws -> URL {
        let name = manifest.cacheDirectoryName
        guard anchor.isFileURL, anchor.path.hasPrefix("/"), !anchor.path.utf8.contains(0),
              !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0) else { throw ParakeetLifecycleError.unsafeStore }
        return (parents + [name]).reduce(anchor) { $0.appendingPathComponent($1, isDirectory: true) }
    }
    private func root(create: Bool) throws -> Int32? {
        _ = try directory()
        if create { try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true) }
        guard let resolved = realpath(anchor.path, nil) else {
            if errno == ENOENT && !create { return nil }; throw ParakeetLifecycleError.unsafeStore
        }
        defer { free(resolved) }
        var fd = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ParakeetLifecycleError.unsafeStore }
        do {
            try owner(fd)
            for name in parents {
                if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw ParakeetLifecycleError.unsafeStore }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && !create { close(fd); return nil }
                guard next >= 0 else { throw ParakeetLifecycleError.unsafeStore }
                close(fd); fd = next; try owner(fd)
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func owner(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else { throw ParakeetLifecycleError.unsafeStore }
    }
    private func model(_ root: Int32, create: Bool) throws -> Int32? {
        let name = manifest.cacheDirectoryName
        if create, mkdirat(root, name, 0o700) != 0, errno != EEXIST { throw ParakeetLifecycleError.unsafeStore }
        let fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT && !create { return nil }
        guard fd >= 0 else { throw ParakeetLifecycleError.unsafeStore }
        do { try owner(fd); return fd } catch { close(fd); throw error }
    }
    private var legacyLayout: Bool {
        ParakeetModelManifest.builtin.contains { $0.modelId == manifest.modelId
            && $0.cacheDirectoryName == manifest.cacheDirectoryName
            && $0.repositoryFolderName == manifest.repositoryFolderName && $0.revision == manifest.revision }
    }
    private func receipt(_ fd: Int32) throws -> Receipt? {
        let file = openat(fd, Self.receiptName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw ParakeetLifecycleError.unsafeStore }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else { throw ParakeetLifecycleError.unsafeStore }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(file, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= 4096 else { throw ParakeetLifecycleError.unsafeStore }
            if count == 0 { break }; data.append(contentsOf: bytes.prefix(count))
        }
        guard let value = try? JSONDecoder().decode(Receipt.self, from: data) else { throw ParakeetLifecycleError.unsafeStore }
        return value
    }
    private func validate(_ fd: Int32, allowEmpty: Bool = false) throws {
        if let value = try receipt(fd) {
            guard value == expectedReceipt else { throw ParakeetLifecycleError.unsafeStore }
        } else if !legacyLayout {
            guard allowEmpty else { throw ParakeetLifecycleError.unsafeStore }
            guard try names(fd).isEmpty else { throw ParakeetLifecycleError.unsafeStore }
        }
    }
    func prepare() throws {
        guard let root = try root(create: true) else { throw ParakeetLifecycleError.unsafeStore }
        defer { close(root) }
        guard let fd = try model(root, create: true) else { throw ParakeetLifecycleError.unsafeStore }
        defer { close(fd) }
        try validate(fd, allowEmpty: true)
        if try receipt(fd) != nil { return }
        let data = try JSONEncoder().encode(expectedReceipt)
        guard data.count <= 4096 else { throw ParakeetLifecycleError.unsafeStore }
        let temporary = ".vox-receipt-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0, fchmod(file, 0o600) == 0 else { if file >= 0 { close(file) }; throw ParakeetLifecycleError.unsafeStore }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ParakeetLifecycleError.unsafeStore }; offset += n
            }
        }
        guard fsync(file) == 0 else { throw ParakeetLifecycleError.unsafeStore }
        if renameatx_np(fd, temporary, fd, Self.receiptName, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw ParakeetLifecycleError.unsafeStore }
            try validate(fd) // Another installer must have claimed this exact model/revision.
        }
    }
    func remove() throws {
        guard let root = try root(create: false) else { return }
        defer { close(root) }
        guard let fd = try model(root, create: false) else { return }
        defer { close(fd) }
        try validate(fd)
        var original = stat(); guard fstat(fd, &original) == 0 else { throw ParakeetLifecycleError.unsafeStore }
        try removeContents(fd, preservingReceipt: true)
        var current = stat()
        guard fstatat(root, manifest.cacheDirectoryName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino else { throw ParakeetLifecycleError.unsafeStore }
        guard unlinkat(fd, Self.receiptName, 0) == 0 || errno == ENOENT else { throw ParakeetLifecycleError.unsafeStore }
        guard unlinkat(root, manifest.cacheDirectoryName, AT_REMOVEDIR) == 0 else { throw ParakeetLifecycleError.unsafeStore }
    }
    private func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw ParakeetLifecycleError.unsafeStore }
        guard let directory = fdopendir(copy) else { close(copy); throw ParakeetLifecycleError.unsafeStore }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ParakeetLifecycleError.unsafeStore }; break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
    private func removeContents(_ fd: Int32, preservingReceipt: Bool = false) throws {
        for name in try names(fd) {
            if preservingReceipt && name == Self.receiptName { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ParakeetLifecycleError.unsafeStore }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ParakeetLifecycleError.unsafeStore }
                do { try removeContents(child); close(child) } catch { close(child); throw error }
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw ParakeetLifecycleError.unsafeStore }
            } else {
                // Unlink a symlink itself, never its target (including hard-linked files).
                guard unlinkat(fd, name, 0) == 0 else { throw ParakeetLifecycleError.unsafeStore }
            }
        }
    }
}
