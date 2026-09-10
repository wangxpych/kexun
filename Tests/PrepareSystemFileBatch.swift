import Foundation

// Host-side fixture for testSystemFileBatchReportsOversizeWithoutLosingSuccess.
// Pass the dedicated simulator's local Files provider directory, not an app DB.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Tests/PrepareSystemFileBatch.swift '<simulator local provider>/File Provider Storage'")
}
let provider = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let metadataURL = provider.deletingLastPathComponent()
    .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: metadataURL), format: nil) as? [String: Any]
guard provider.path.contains("/CoreSimulator/Devices/"),
      provider.lastPathComponent == "File Provider Storage",
      metadata?["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage" else {
    fatalError("Refusing non-simulator or non-local-provider directory")
}
let fm = FileManager.default
let root = provider.appendingPathComponent("KexunImport112")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let good = root.appendingPathComponent("Import112-good.txt")
let large = root.appendingPathComponent("Import112-oversize.bin")
let bytes = Data("KEXUN_IMPORT_112 独立成功文件\n".utf8)
let oversizedBytes = 100 * 1024 * 1024 + 1
// Reuse only exact expected fixtures; never overwrite or truncate an old file.
if fm.fileExists(atPath: good.path) {
    guard try Data(contentsOf: good) == bytes else { fatalError("Existing good fixture differs") }
} else {
    try bytes.write(to: good, options: .withoutOverwriting)
}
if fm.fileExists(atPath: large.path) {
    guard try large.resourceValues(forKeys: [.fileSizeKey]).fileSize == oversizedBytes else {
        fatalError("Existing oversize fixture differs")
    }
} else {
    try Data().write(to: large, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(oversizedBytes))
    try handle.close()
}
for url in [good, large] {
    print(url.path, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
}
// A second small, valid source for the separate import-stop test. Unlike the
// oversize fixture, this would save successfully if the user did not cancel.
let second = root.appendingPathComponent("Import117-second.txt")
let secondBytes = Data("KEXUN_IMPORT_117 second valid file\n".utf8)
if fm.fileExists(atPath: second.path) {
    guard try Data(contentsOf: second) == secondBytes else { fatalError("Existing second fixture differs") }
} else {
    try secondBytes.write(to: second, options: .withoutOverwriting)
}
print(second.path, secondBytes.count)
