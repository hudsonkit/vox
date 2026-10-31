import Foundation
import Testing
@testable import HudsonSpeechEngine

struct StdioTransportTests {
    @Test("cancelling a pending call returns CancellationError without stopping other calls")
    func cancellingPendingCall() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = temp.appendingPathComponent("cancel-provider.js")
        try """
        require('readline').createInterface({input:process.stdin}).on('line', line => {
          const r = JSON.parse(line);
          if (r.id === undefined) return;
          setTimeout(() => process.stdout.write(JSON.stringify({id:r.id,result:{ok:true}})+'\\n'), r.method === 'slow' ? 500 : 0);
        });
        """.write(to: script, atomically: true, encoding: .utf8)
        let transport = StdioTransport(command: ["/usr/bin/env", "bun", script.path])
        try transport.start(); defer { transport.stop() }
        let task = Task { () -> Bool in
            do { _ = try await transport.call(method: "slow"); return false }
            catch { return error is CancellationError }
        }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        #expect(await task.value)
        let other = try await transport.call(method: "ping")
        #expect(other["ok"] as? Bool == true && transport.processIsRunning)
    }

    @Test("opt-in cancellation and timeout send only the matching JSON-RPC notification")
    func requestScopedProtocolCancellation() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = temp.appendingPathComponent("scoped-cancel.js")
        try """
        const cancelled = [];
        require('readline').createInterface({input:process.stdin}).on('line', line => {
          const r = JSON.parse(line);
          if (r.method === '$/cancelRequest') {
            cancelled.push(r.params.id);
            // An intentionally late response must not resume a cancelled continuation twice.
            process.stdout.write(JSON.stringify({id:r.params.id,result:{late:true}})+'\\n');
            return;
          }
          if (r.method === 'slow') return;
          process.stdout.write(JSON.stringify({id:r.id,result:{cancelled}})+'\\n');
        });
        """.write(to: script, atomically: true, encoding: .utf8)
        let transport = StdioTransport(command: ["/usr/bin/env", "bun", script.path],
            callTimeoutSeconds: 0.4, supportsRequestCancellation: true)
        try transport.start(); defer { transport.stop() }
        let task = Task { () -> Bool in
            do { _ = try await transport.call(method: "slow"); return false }
            catch { return error is CancellationError }
        }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        #expect(await task.value)
        do {
            _ = try await transport.call(method: "oversized", params: ["input": String(repeating: "x", count: 1024 * 1024)])
            Issue.record("Expected rejection before writing a frame that could disrupt other clients")
        } catch let error as StdioTransportError {
            if case .requestTooLarge = error {} else { Issue.record("Expected requestTooLarge") }
        }
        let state = try await transport.call(method: "state")
        #expect(state["cancelled"] as? [Int] == [1])
        do { _ = try await transport.call(method: "slow"); Issue.record("Expected timeout") }
        catch let error as StdioTransportError {
            if case .timeout = error {} else { Issue.record("Expected timeout") }
        }
        let afterTimeout = try await transport.call(method: "state")
        #expect(afterTimeout["cancelled"] as? [Int] == [1, 4])
        #expect(transport.processIsRunning)
    }

    @Test("an already cancelled call is never submitted to the provider")
    func alreadyCancelledCall() async throws {
        let transport = StdioTransport(command: ["/usr/bin/false"])
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await transport.call(method: "never"); return false }
            catch { return error is CancellationError }
        }
        #expect(await task.value)
    }

    @Test("fast provider responses are matched to pending calls")
    func fastProviderResponseDoesNotRacePendingRegistration() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("fast-provider.js")
        try """
        process.stdin.setEncoding("utf8");
        let buffer = "";
        process.stdin.on("data", (chunk) => {
          buffer += chunk;
          const lines = buffer.split("\\n");
          buffer = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.trim()) continue;
            const req = JSON.parse(line);
            process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: req.id, result: { ok: true } }) + "\\n");
          }
        });
        """
        .write(to: scriptURL, atomically: true, encoding: .utf8)

        let transport = StdioTransport(
            command: ["/usr/bin/env", "bun", "run", scriptURL.path],
            callTimeoutSeconds: 1
        )

        try transport.start()
        defer { transport.stop() }

        let result = try await transport.call(method: "ping")
        #expect(result["ok"] as? Bool == true)
    }

    @Test("call timeout resumes with timeout error instead of trapping the queue")
    func callTimeoutThrowsTimeoutError() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("hanging-provider.js")
        try """
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", () => {
          // Intentionally ignore requests so the transport timeout path runs.
        });
        setInterval(() => {}, 1000);
        """
        .write(to: scriptURL, atomically: true, encoding: .utf8)

        let transport = StdioTransport(
            command: ["/usr/bin/env", "bun", "run", scriptURL.path],
            callTimeoutSeconds: 0.1
        )

        try transport.start()
        defer { transport.stop() }

        do {
            _ = try await transport.call(method: "hang")
            Issue.record("Expected call(method:) to time out")
        } catch let error as StdioTransportError {
            switch error {
            case .timeout(let method):
                #expect(method == "hang")
            default:
                Issue.record("Expected timeout error, got \(error.localizedDescription)")
            }
        }
    }
}
