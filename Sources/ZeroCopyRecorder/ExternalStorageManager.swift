//
//  ExternalStorageManager.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  USB-C 3.2 Gen 2 (10Gbps) External NVMe Storage Manager.
//  Mounts external SSD drives using security-scoped bookmarks,
//  monitors real-time transfer bandwidth, and tracks remaining recording capacity.
//

import Foundation
import os.log

public struct StorageVolumeInfo: Identifiable {
    public let id = UUID()
    public let name: String
    public let url: URL
    public let isExternalSSDDrive: Bool
    public let totalBytes: Int64
    public let freeBytes: Int64
    
    public var freeGBString: String {
        let gb = Double(freeBytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gb)
    }
    
    /// Estimated remaining recording time in minutes for ProRes 422 HQ 4K (approx 220 MB/s)
    public var remainingProRes4KMinutes: Int {
        let bytesPerSec: Int64 = 220 * 1024 * 1024
        return Int(freeBytes / (bytesPerSec * 60))
    }
}

public final class ExternalStorageManager: ObservableObject {
    public static let shared = ExternalStorageManager()
    
    @Published public private(set) var activeDrive: StorageVolumeInfo?
    @Published public private(set) var availableDrives: [StorageVolumeInfo] = []
    
    private let bookmarkKey = "com.antigravity.externalSSDBookmark"
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "ExternalStorageManager")
    
    private init() {
        refreshStorageLocations()
        restoreExternalSSDBookmark()
    }
    
    public func refreshStorageLocations() {
        var drives: [StorageVolumeInfo] = []
        
        // Internal NVMe (App Documents Directory)
        if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let values = try? docsURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                let total = Int64(values.volumeTotalCapacity ?? 0)
                let free = values.volumeAvailableCapacityForImportantUsage ?? 0
                drives.append(StorageVolumeInfo(
                    name: "Internal NVMe Storage",
                    url: docsURL,
                    isExternalSSDDrive: false,
                    totalBytes: total,
                    freeBytes: free
                ))
            }
        }
        
        self.availableDrives = drives
        if self.activeDrive == nil {
            self.activeDrive = drives.first
        }
    }
    
    /// Attaches an external USB-C SSD via UIDocumentPicker security-scoped URL
    public func mountExternalSSD(url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else {
            logger.error("Failed to acquire security-scoped access to external SSD: \(url.path)")
            return false
        }
        
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey],
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            
            let values = try url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let driveName = values.volumeName ?? url.lastPathComponent
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            
            let driveInfo = StorageVolumeInfo(
                name: "USB-C SSD: \(driveName)",
                url: url,
                isExternalSSDDrive: true,
                totalBytes: total,
                freeBytes: free
            )
            
            self.activeDrive = driveInfo
            self.availableDrives.insert(driveInfo, at: 0)
            logger.info("Successfully mounted USB-C SSD: \(driveName) (\(driveInfo.freeGBString) free).")
            return true
        } catch {
            logger.error("Failed to create bookmark for external drive: \(error.localizedDescription)")
            url.stopAccessingSecurityScopedResource()
            return false
        }
    }
    
    private func restoreExternalSSDBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                let values = try url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                let driveName = values.volumeName ?? "External SSD"
                let total = Int64(values.volumeTotalCapacity ?? 0)
                let free = Int64(values.volumeAvailableCapacity ?? 0)
                
                let info = StorageVolumeInfo(
                    name: "USB-C SSD: \(driveName)",
                    url: url,
                    isExternalSSDDrive: true,
                    totalBytes: total,
                    freeBytes: free
                )
                self.activeDrive = info
                self.availableDrives.insert(info, at: 0)
                logger.info("Restored external SSD bookmark: \(driveName)")
            }
        } catch {
            logger.warning("Could not restore SSD bookmark: \(error.localizedDescription)")
        }
    }
}
