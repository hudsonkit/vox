import Darwin
import Foundation
import VoxCore

/// An annotation-owned leaf beneath the OS-provided temporary-directory grant.
/// Not a general capability-path writer: never walk/create/chmod ancestors from /.
/// Same-UID code is inside the trust boundary; other users cannot enter the leaf.
final class AnnotationStagingFile: @unchecked Sendable {
    let directory: URL
    let url: URL
    private let lock = NSLock()
    private var parentFD: Int32
    private var directoryFD: Int32
    private let name: String
    private let device: dev_t
    private let inode: ino_t

    private init(root: URL, name: String, parentFD: Int32, directoryFD: Int32, info: stat) {
        self.directory = root.appendingPathComponent(name, isDirectory: true)
        self.url = directory.appendingPathComponent("upload.bin")
        self.name = name
        self.parentFD = parentFD
        self.directoryFD = directoryFD
        self.device = info.st_dev
        self.inode = info.st_ino
    }

    /// The parameter is an internal test seam. Production always uses the OS grant,
    /// never a caller-supplied directory or environment-specific cache path.
    static func create(in root: URL = FileManager.default.temporaryDirectory) throws -> AnnotationStagingFile {
        guard root.isFileURL, !root.path.utf8.contains(0) else { throw failure("root-url", EINVAL) }
        var path = root.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let parentFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw failure("root-open", errno) }
        do {
            var rootInfo = stat()
            guard fstat(parentFD, &rootInfo) == 0 else { throw failure("root-stat", errno) }
            guard rootInfo.st_mode & S_IFMT == S_IFDIR,
                  rootInfo.st_uid == geteuid() || (rootInfo.st_uid == 0 && rootInfo.st_mode & S_ISVTX != 0)
            else { throw failure("root-owner", EACCES) }
            // Mobile app-container grants, not ancestor POSIX modes, are the boundary.
            // On desktop also refuse a writable, non-sticky shared temp root.
            #if os(macOS)
            guard rootInfo.st_mode & 0o022 == 0 || rootInfo.st_mode & S_ISVTX != 0 else {
                throw failure("root-mode", EACCES)
            }
            #endif
            let name = "vox-annotation-" + UUID().uuidString
            guard mkdirat(parentFD, name, 0o700) == 0 else { throw failure("leaf-create", errno) }
            let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else {
                let error = failure("leaf-open", errno)
                if unlinkat(parentFD, name, AT_REMOVEDIR) != 0, errno != ENOENT {
                    _ = Self.failure("cleanup-leaf", errno)
                }
                throw error
            }
            do {
                var info = stat()
                guard fstat(directoryFD, &info) == 0 else { throw failure("leaf-stat", errno) }
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
                else { throw failure("leaf-mode", EACCES) }
                guard fchmod(directoryFD, 0o700) == 0 else { throw failure("leaf-chmod", errno) }
                return AnnotationStagingFile(root: root, name: name, parentFD: parentFD, directoryFD: directoryFD, info: info)
            } catch {
                close(directoryFD); _ = unlinkat(parentFD, name, AT_REMOVEDIR)
                throw error
            }
        } catch { close(parentFD); throw error }
    }

    func openOutput() throws -> Int32 {
        try lock.withLock {
            guard directoryFD >= 0 else { throw Self.failure("closed", EBADF) }
            let fd = openat(directoryFD, "upload.bin", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Self.failure("file-create", errno) }
            do {
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw Self.failure("file-stat", errno) }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1
                else { throw Self.failure("file-mode", EACCES) }
                guard fchmod(fd, 0o600) == 0 else { throw Self.failure("file-chmod", errno) }
                return fd
            } catch { close(fd); throw error }
        }
    }

    /// Idempotent descriptor-relative cleanup, never recursive path deletion.
    func remove() {
        lock.withLock {
            guard directoryFD >= 0 else { return }
            if unlinkat(directoryFD, "upload.bin", 0) != 0, errno != ENOENT {
                _ = Self.failure("cleanup-file", errno)
            }
            var info = stat()
            if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
               info.st_dev == device, info.st_ino == inode {
                if unlinkat(parentFD, name, AT_REMOVEDIR) != 0, errno != ENOENT {
                    _ = Self.failure("cleanup-leaf", errno)
                }
            }
            close(directoryFD); close(parentFD)
            directoryFD = -1; parentFD = -1
        }
    }
    deinit { remove() }

    private static func failure(_ phase: String, _ code: Int32) -> POSIXError {
        // Only fixed library phase identifiers and numeric errno. No private paths,
        // requests, transcript, credentials or upstream error descriptions.
        VoxLog.engine.warning("Annotation staging failed phase=\(phase) errno=\(code)")
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
