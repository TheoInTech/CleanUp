import Foundation
import Testing
@testable import CleanUpCore

@Suite struct FolderSizeTests {
    private func makeDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("foldersize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolved = base.path.withCString { p -> String in
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(p, &buf) != nil ? String(cString: buf) : base.path
        }
        return URL(fileURLWithPath: resolved)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test func sumsAllocatedBytes() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir.appendingPathComponent("a"), bytes: 100_000)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write(dir.appendingPathComponent("sub/b"), bytes: 100_000)
        let m = FolderSize.measure(dir)
        #expect(m.bytes >= 200_000)
        #expect(m.complete)
    }

    @Test func symlinkTargetsAreNotCounted() throws {
        let dir = try makeDir()
        let outside = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        try write(outside.appendingPathComponent("big"), bytes: 5_000_000)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("big"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("dirlink"), withDestinationURL: outside)
        #expect(FolderSize.measure(dir).bytes < 1_000_000)
    }

    @Test func newestModification() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old"), recent = dir.appendingPathComponent("recent")
        try write(old, bytes: 10); try write(recent, bytes: 10)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: old.path)
        let twoMin = now.addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: twoMin], ofItemAtPath: recent.path)
        let newest = try #require(FolderSize.measure(dir).newest)
        #expect(abs(newest.timeIntervalSince(twoMin)) < 2)
    }

    @Test func unreadableFolderMarksIncomplete() throws {
        let dir = try makeDir()
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(dir.appendingPathComponent("a"), bytes: 100_000)
        try write(locked.appendingPathComponent("x"), bytes: 100_000)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let m = FolderSize.measure(dir)
        #expect(!m.complete)
        #expect(m.bytes >= 100_000)
    }

    @Test func cacheReusesUntilFolderChanges() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try write(dir.appendingPathComponent("a"), bytes: 100_000)
        try fm.setAttributes([.modificationDate: pinned], ofItemAtPath: dir.path)
        let cache = SizeCache()
        let t0 = Date()
        let first = await cache.measure(dir, now: t0)
        // Top-level change moves the folder mtime: re-measures.
        try write(dir.appendingPathComponent("b"), bytes: 100_000)
        try fm.setAttributes([.modificationDate: pinned.addingTimeInterval(5)], ofItemAtPath: dir.path)
        let second = await cache.measure(dir, now: t0.addingTimeInterval(20))
        #expect(second.bytes >= first.bytes + 100_000)
        // .git file mtime moving also re-measures.
        let git = dir.appendingPathComponent(".git")
        try write(git, bytes: 10)
        try fm.setAttributes([.modificationDate: pinned], ofItemAtPath: git.path)
        try fm.setAttributes([.modificationDate: pinned.addingTimeInterval(5)], ofItemAtPath: dir.path)
        let third = await cache.measure(dir, now: t0.addingTimeInterval(30))
        try write(dir.appendingPathComponent("c"), bytes: 100_000)
        try fm.setAttributes([.modificationDate: pinned.addingTimeInterval(5)], ofItemAtPath: dir.path)
        #expect(await cache.measure(dir, now: t0.addingTimeInterval(31)) == third)
        try fm.setAttributes([.modificationDate: pinned.addingTimeInterval(9)], ofItemAtPath: git.path)
        #expect(await cache.measure(dir, now: t0.addingTimeInterval(32)).bytes > third.bytes)
    }

    @Test func nestedChangeIsStaleUntilFresh() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write(dir.appendingPathComponent("sub/a"), bytes: 100_000)
        try fm.setAttributes([.modificationDate: pinned], ofItemAtPath: dir.path)
        let cache = SizeCache()
        let t0 = Date()
        let first = await cache.measure(dir, now: t0)
        let deep = dir.appendingPathComponent("sub/deep")
        try write(deep, bytes: 100_000)
        try fm.setAttributes([.modificationDate: pinned], ofItemAtPath: dir.path)
        let deepMTime = try #require(try fm.attributesOfItem(atPath: deep.path)[.modificationDate] as? Date)
        // Cached call may serve the old value (display only).
        #expect(await cache.measure(dir, now: t0.addingTimeInterval(10)) == first)
        let fresh = await cache.measure(dir, now: t0.addingTimeInterval(11), fresh: true)
        #expect(try #require(fresh.newest) >= deepMTime)
        #expect(fresh.bytes > first.bytes)
        #expect(await cache.measure(dir, now: t0.addingTimeInterval(12)) == fresh)
    }

    @Test func cacheExpiresAfterMaxAge() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write(dir.appendingPathComponent("sub/a"), bytes: 100_000)
        try fm.setAttributes([.modificationDate: pinned], ofItemAtPath: dir.path)
        let cache = SizeCache()
        let t0 = Date()
        let first = await cache.measure(dir, now: t0)
        try write(dir.appendingPathComponent("sub/big"), bytes: 1_000_000)
        try fm.setAttributes([.modificationDate: pinned], ofItemAtPath: dir.path)
        #expect(await cache.measure(dir, now: t0.addingTimeInterval(3600)) == first)
        let expired = await cache.measure(dir, now: t0.addingTimeInterval(7 * 3600))
        #expect(expired.bytes > first.bytes)
    }

    @Test func incompleteMeasureIsNotCached() async throws {
        let dir = try makeDir()
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(locked.appendingPathComponent("x"), bytes: 100_000)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let cache = SizeCache()
        let now = Date()
        #expect(await cache.measure(dir, now: now).complete == false)
        chmod(locked.path, 0o755)
        #expect(await cache.measure(dir, now: now).complete == true)
    }
}
