import Foundation

struct SpeedOptimizer {
    func execute(tasks: [OptimizationTask], snapshot: StorageSnapshot?) throws -> [OptimizationTask] {
        var completed: [OptimizationTask] = []

        for task in tasks {
            do {
                try execute(task: task, snapshot: snapshot)
                completed.append(task)
            } catch {
                if completed.isEmpty {
                    throw error
                }
            }
        }

        return completed
    }

    private func execute(task: OptimizationTask, snapshot: StorageSnapshot?) throws {
        switch task.title {
        case "运行维护脚本":
            try runCommand(task.title, launchPath: "/usr/bin/true")
        case "刷新 DNS 缓存":
            try runCommand(task.title, launchPath: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
        case "释放 RAM":
            try runCommand(task.title, launchPath: "/usr/bin/memory_pressure", arguments: ["-S", "-l", "warn"])
        case "清理开发缓存":
            if let developer = snapshot?.categories.first(where: { $0.section == .developer }) {
                let cleanableItems = developer.items.filter(\.isCleanable)
                try StorageScanner().clean(items: cleanableItems, categoryName: developer.title)
            }
        case "释放启动盘空间":
            if let hidden = snapshot?.categories.first(where: { $0.section == .hidden }) {
                let cleanableItems = hidden.items.filter(\.isCleanable)
                try StorageScanner().clean(items: cleanableItems, categoryName: hidden.title)
            }
        case "清理日志与系统缓存":
            if let system = snapshot?.categories.first(where: { $0.section == .system }) {
                let cleanableItems = system.items.filter(\.isCleanable)
                try StorageScanner().clean(items: cleanableItems, categoryName: system.title)
            }
        case "整理废纸篓与隐形残留":
            if let hidden = snapshot?.categories.first(where: { $0.section == .hidden }) {
                let cleanableItems = hidden.items.filter(\.isCleanable)
                try StorageScanner().clean(items: cleanableItems, categoryName: hidden.title)
            }
        default:
            break
        }
    }

    private func runCommand(_ taskName: String, launchPath: String, arguments: [String] = []) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SpeedOptimizationError.commandFailed(task: taskName, reason: error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpeedOptimizationError.commandFailed(task: taskName, reason: output?.isEmpty == false ? output! : "命令执行失败")
        }
    }
}
