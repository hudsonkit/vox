import Darwin
import Foundation

/// Owner-only capability files. Same-user code is inside this trust boundary.
public enum VoxPrivateFiles {
    private static func parent(_ url: URL, create: Bool) throws -> (Int32, String) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              let name = parts.last, !parts.contains("."), !parts.contains("..") else { throw POSIXError(.EACCES) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        do {
            for (index, part) in parts.dropLast().enumerated() {
                if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw POSIXError(.EACCES) }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
                close(fd); fd = next
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == 0 || info.st_uid == geteuid(),
                      info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { throw POSIXError(.EACCES) }
                if index == parts.count - 2 {
                    guard info.st_uid == geteuid() else { throw POSIXError(.EACCES) }
                    if create {
                        guard fchmod(fd, 0o700) == 0 else { throw POSIXError(.EACCES) }
                    } else { guard info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) } }
                }
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
            return (fd, name)
        } catch { close(fd); throw error }
    }

    public static func prepareDirectory(_ url: URL) throws {
        let (fd, _) = try parent(url.appendingPathComponent(".permission-probe"), create: true)
        close(fd)
    }

    /// Atomic replacement; never follows a leaf or ancestor symlink, or overwrites a hard link.
    public static func write(_ data: Data, to url: URL) throws {
        let (directory, name) = try parent(url, create: true)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else { throw POSIXError(.EACCES) }
        } else if errno != ENOENT { throw POSIXError(.EACCES) }
        let temporary = "." + name + "." + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EACCES) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }; offset += n
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0 else { throw POSIXError(.EIO) }
    }

    public static func read(_ url: URL, maxBytes: Int = 65536) throws -> Data {
        guard maxBytes > 0, maxBytes <= 16 * 1024 * 1024 else { throw POSIXError(.EINVAL) }
        let (directory, name) = try parent(url, create: false)
        defer { close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maxBytes else { throw POSIXError(.EACCES) }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw POSIXError(.EIO) }
            if n == 0 { return data }
            guard data.count + n <= maxBytes else { throw POSIXError(.EFBIG) }
            data.append(contentsOf: bytes.prefix(n))
        }
    }

    /// The caller holds the registration lease while removing its own capability.
    static func remove(_ url: URL) throws {
        let (directory, name) = try parent(url, create: false)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw POSIXError(.EACCES) }
        guard unlinkat(directory, name, 0) == 0 else { throw POSIXError(.EACCES) }
    }

    static func lock(_ url: URL) throws -> Int32 {
        let (directory, name) = try parent(url, create: true)
        defer { close(directory) }
        let fd = openat(directory, name + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o777 == 0o600, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw POSIXError(.EADDRINUSE)
        }
        return fd
    }
}
