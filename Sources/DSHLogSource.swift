import Foundation

/// 从 DSH 的本地会话日志里读用量。
///
/// 为什么需要这条通路：平台用量接口认的是**网页登录态**（`userToken`），
/// 属于「账户」作用域。当 API Key 是别人给的、而你登录的不是同一个账户时，
/// 那个接口给出的数字与这把 Key 无关，两者混在一起显示会误导。
/// 本地日志记的则是「这台机器、这个 DSH、用当前 Key 实际发出的请求」，
/// 口径正好对得上，而且不需要任何账户级凭据。
///
/// 日志格式（2026-10 实测）：
///   `~/.dsh/sessions/<project>/<session>/session.v4.jsonl.zstd`
/// 每行一条 JSON，带 `data.usage` 的记录形如：
///   inputTokens / cacheReadTokens / outputTokens / cacheWriteTokens / totalTokens
///
/// 字段语义用恒等式验证过（456 条真实记录全部成立，0 条例外）：
///   totalTokens == inputTokens + cacheReadTokens + outputTokens
/// 因此可以确定：`inputTokens` 是**未命中**、`cacheReadTokens` 是**命中**、
/// `outputTokens` 是输出；`cacheWriteTokens` 恒为 0（DeepSeek 无显式缓存写入）。
///
/// 局限（必须在 UI 上说清楚）：
///   · 只覆盖 DSH 的流量，同一把 Key 在别处的调用不在这里
///   · 日志没有金额字段，所以这个来源只能给 token 与命中率
actor DSHLogSource {
    static let shared = DSHLogSource()

    struct Record {
        let time: Date
        /// 已经是可展示的标签：有 model 就用 model，
        /// 没有的（实测只有 3 条 compaction/summary）用中文兜底名
        let model: String
        let hit: Int64
        let miss: Int64
        let output: Int64
    }

    private struct CachedFile {
        let size: Int64
        let modified: Date
        let records: [Record]
    }

    /// 按路径缓存解析结果，只重解析有变化的文件。
    /// 不缓存的话每次刷新都要解压 20 MB 日志，纯浪费。
    private var fileCache: [String: CachedFile] = [:]

    private static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions", isDirectory: true)
    }

    /// zstd 可执行文件。系统不带，SDK 也没有 `libzstd` 头文件，
    /// 所以只能调 homebrew 装的命令行版本。
    /// GUI 从 Finder 启动时 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，
    /// 因此必须用绝对路径候选，不能指望 `which zstd`。
    private static let zstdCandidates = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
        "/usr/bin/zstd"
    ]

    private func zstdExecutable() -> String? {
        Self.zstdCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - 对外

    /// 汇总指定时间范围内的用量。没有金额，`hasCost` 恒为 false。
    func snapshot(for range: UsageRange, now: Date = Date()) async throws -> UsageSnapshot {
        let all = try await loadRecords()
        let window = range.window(now: now)
        let start = Double(window.start)
        let end = Double(window.end)

        let records = all.filter { record in
            let t = record.time.timeIntervalSince1970
            return t >= start && t <= end
        }

        var snapshot = UsageSnapshot()
        snapshot.hasCost = false
        snapshot.scopeNote = "本机 DSH · \(range.title)"
        snapshot.fetchedAt = now

        guard !records.isEmpty else { return snapshot }

        var totals = TokenBreakdown()
        var byModel: [String: TokenBreakdown] = [:]
        let hourly = (range == .today || range == .last24h)

        // 先按日历铺满所有桶（含 0 值），保证步长均匀
        var byBuckets: [Double: TokenBreakdown] = [:]
        for key in Self.bucketKeys(from: Date(timeIntervalSince1970: start),
                                   to: Date(timeIntervalSince1970: end),
                                   hourly: hourly) {
            byBuckets[key] = TokenBreakdown()
        }

        for record in records {
            let piece = TokenBreakdown(
                cacheHit: record.hit,
                cacheMiss: record.miss,
                output: record.output,
                requests: 1
            )
            totals += piece
            byModel[record.model, default: TokenBreakdown()] += piece
            byBuckets[Self.bucketKey(for: record.time, hourly: hourly),
                      default: TokenBreakdown()] += piece
        }

        snapshot.totals = totals
        snapshot.models = byModel
            .map { ModelUsage(model: $0.key, breakdown: $0.value, cost: 0) }
            .sorted { $0.breakdown.totalTokens > $1.breakdown.totalTokens }
        snapshot.buckets = byBuckets
            .map { UsageBucket(time: $0.key, breakdown: $0.value) }
            .sorted { $0.time < $1.time }
        return snapshot
    }

    /// 时间桶的起点（Unix 秒）。小时级取整点，天级取本地零点。
    static func bucketKey(for date: Date, hourly: Bool, calendar: Calendar = .current) -> Double {
        if hourly {
            let seconds = date.timeIntervalSince1970
            return (seconds / 3600).rounded(.down) * 3600
        }
        return calendar.startOfDay(for: date).timeIntervalSince1970
    }

    // MARK: - 读日志

    private func loadRecords() throws -> [Record] {
        guard let zstd = zstdExecutable() else {
            throw LogSourceError.zstdMissing
        }

        let files = try sessionFiles()
        guard !files.isEmpty else { throw LogSourceError.noSessions }

        var seen = Set<String>()
        var records: [Record] = []
        var firstError: Error?

        for file in files {
            let path = file.path
            seen.insert(path)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast

            if let cached = fileCache[path], cached.size == size, cached.modified == modified {
                records.append(contentsOf: cached.records)
                continue
            }

            do {
                let parsed = try parse(file: file, zstd: zstd)
                fileCache[path] = CachedFile(size: size, modified: modified, records: parsed)
                records.append(contentsOf: parsed)
            } catch {
                // 单个文件坏掉不该让整个来源不可用：可能正好在写入、或者是更高的日志版本。
                // 记下第一个错误，其余文件照常处理。
                if firstError == nil { firstError = error }
            }
        }

        // 清掉已经消失的会话，避免缓存无限增长
        fileCache = fileCache.filter { seen.contains($0.key) }

        if records.isEmpty, let firstError { throw firstError }
        return records
    }

    private func sessionFiles() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.sessionsRoot.path) else {
            throw LogSourceError.noSessions
        }
        guard let walker = fm.enumerator(
            at: Self.sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LogSourceError.noSessions
        }

        var files: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("session"), name.hasSuffix(".jsonl.zstd") else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func parse(file: URL, zstd: String) throws -> [Record] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", file.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw LogSourceError.decompressFailed("\(file.lastPathComponent)：\(error.localizedDescription)")
        }
        // readDataToEndOfFile 会一边读一边排空管道，不会把子进程堵死
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LogSourceError.decompressFailed("\(file.lastPathComponent)：zstd 退出码 \(process.terminationStatus)")
        }
        return Self.parse(jsonl: data)
    }

    /// 从解压后的 JSONL 中抽取带 `data.usage` 的记录。
    /// 单独抽成静态函数，方便用合成夹具做断言（不碰真实日志）。
    static func parse(jsonl data: Data) -> [Record] {
        var records: [Record] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.contains(UInt8(ascii: "u")),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["data"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any],
                  let timeMilliseconds = number(object["time"])
            else { continue }

            let hit = Int64(number(usage["cacheReadTokens"]) ?? 0)
            let miss = Int64(number(usage["inputTokens"]) ?? 0)
            let output = Int64(number(usage["outputTokens"]) ?? 0)
            let date = Date(timeIntervalSince1970: timeMilliseconds / 1000)

            var model: String?
            if let message = payload["message"] as? [String: Any],
               let source = message["source"] as? [String: Any],
               let name = source["model"] as? String, !name.isEmpty {
                model = name
            }
            // 压缩摘要这类记录带 usage 但没有模型归属。它们确实花了 token，
            // 不能丢；但叫「未知模型」等于没说，所以按记录类型给个明确名字。
            let label = model ?? Self.fallbackLabel(for: object["type"] as? String)

            records.append(Record(time: date, model: label, hit: hit, miss: miss, output: output))
        }
        return records
    }

    /// 没有 model 字段时按记录类型给标签
    static func fallbackLabel(for recordType: String?) -> String {
        switch recordType {
        case "compaction/summary": return "压缩摘要"
        case nil: return "其他"
        default: return "其他（\(recordType!)）"
        }
    }

    /// 生成区间内**每个**桶的起点，用日历逐格推进（跨夏令时也不会漂）。
    /// 不补齐空桶的话，稀疏数据会让「相邻桶平均步长」远超真实粒度，
    /// 热力图据此判断小时/天档位就会误判。
    static func bucketKeys(from start: Date, to end: Date, hourly: Bool,
                           calendar: Calendar = .current) -> [Double] {
        var cursor: Date
        if hourly {
            // 与 bucketKey 的取整方式保持一致
            let seconds = start.timeIntervalSince1970
            cursor = Date(timeIntervalSince1970: (seconds / 3600).rounded(.down) * 3600)
        } else {
            cursor = calendar.startOfDay(for: start)
        }

        var keys: [Double] = []
        var guardCount = 0
        while cursor <= end, guardCount < 4000 {
            let key = cursor.timeIntervalSince1970
            if keys.last != key { keys.append(key) }
            guard let next = calendar.date(byAdding: hourly ? .hour : .day, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return keys
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }
}

enum LogSourceError: LocalizedError {
    case zstdMissing
    case noSessions
    case decompressFailed(String)

    var errorDescription: String? {
        switch self {
        case .zstdMissing:
            return "未找到 zstd（需要 brew install zstd）"
        case .noSessions:
            return "没有找到 DSH 会话日志（~/.dsh/sessions）"
        case .decompressFailed(let detail):
            return "日志解压失败：\(detail)"
        }
    }
}
