import Darwin
import Foundation

/// Unix filesystem permissions and same-user peers are the local trust boundary.
/// They do not isolate arbitrary processes already running as this user.
public enum VoxPrivateIPC {
    public static func prepareDirectory(_ url: URL) throws {
        // Walk using directory descriptors: no symlink traversal, including ancestors.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else { throw POSIXError(.EACCES) }
        for (index, part) in parts.enumerated() {
            if mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw POSIXError(.EACCES) }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.ELOOP) }
            close(fd); fd = next
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == geteuid(),
                  info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { throw POSIXError(.EACCES) }
            if index == parts.count - 1 {
                guard info.st_uid == geteuid(),
                      fchmod(fd, 0o700) == 0 else { throw POSIXError(.EACCES) }
            }
        }
    }

    public static func removeStaleSocket(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }; throw POSIXError(.EACCES)
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EACCES) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw POSIXError(.EIO) }
        defer { close(probe) }
        guard fcntl(probe, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard url.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { dest in url.path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result != 0, errno == ECONNREFUSED else { throw POSIXError(.EADDRINUSE) }
        guard unlink(url.path) == 0 else { throw POSIXError(.EACCES) }
    }

    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == geteuid(), existing.st_nlink == 1 else { throw POSIXError(.EACCES) }
        } else if errno != ENOENT { throw POSIXError(.EACCES) }
        let temporary = url.path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd); unlink(temporary) }
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count,
              fsync(fd) == 0, rename(temporary, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    public static func sameUserPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
}
