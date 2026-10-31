import Darwin
import Foundation
import VoxCore

/// Unix filesystem permissions and same-user peers are the local trust boundary.
/// They do not isolate arbitrary processes already running as this user.
public enum VoxPrivateIPC {
    public static func prepareDirectory(_ url: URL) throws {
        try VoxPrivateFiles.prepareDirectory(url)
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
        try VoxPrivateFiles.write(data, to: url)
    }

    public static func sameUserPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
}
