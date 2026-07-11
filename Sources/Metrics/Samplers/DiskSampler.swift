import Foundation

/// Enumerates mounted volumes and reports capacity/usage per volume.
final class DiskSampler {

    private let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
        .volumeIsRemovableKey,
        .volumeIsBrowsableKey
    ]

    func sample() -> DiskSnapshot {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return .empty }

        var seenPaths = Set<String>()
        var volumes: [VolumeInfo] = []

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }

            let path = url.path
            guard seenPaths.insert(path).inserted else { continue }

            // "Important usage" accounts for purgeable space; some volume
            // types report it as 0, so fall back to the plain figure.
            var available = values.volumeAvailableCapacityForImportantUsage ?? 0
            if available <= 0 {
                available = Int64(values.volumeAvailableCapacity ?? 0)
            }

            volumes.append(VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                path: path,
                totalBytes: UInt64(total),
                availableBytes: UInt64(max(0, available)),
                isRoot: path == "/",
                isRemovable: values.volumeIsRemovable ?? false
            ))
        }

        volumes.sort { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return DiskSnapshot(volumes: volumes)
    }
}
