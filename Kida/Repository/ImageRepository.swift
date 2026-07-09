//
//  ImageRepository.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//
//  REPOSITORY LAYER — image file persistence
//
//  Protocol + concrete implementation for saving/loading/deleting image
//  files on disk. Defined as a protocol (not just static functions) so it
//  can be injected into ScannedItemRepository and swapped for a mock/fake
//  in tests or SwiftUI previews.
//

import Foundation

final class ImageRepository {

    /// Directory where all scanned images live: .../Documents/ScannedImages/
    private var imagesDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("ScannedImages", isDirectory: true)

        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func save(_ data: Data) -> String? {
        let filename = "\(UUID().uuidString).jpg"
        let url = imagesDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            print("FileSystemImageRepository: failed to save image — \(error)")
            return nil
        }
    }

    func load(_ filename: String?) -> Data? {
        guard let filename else { return nil }
        let url = imagesDirectory.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    func delete(_ filename: String?) {
        guard let filename else { return }
        let url = imagesDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    func replace(oldFilename: String?, with newData: Data?) -> String? {
        guard let newData else { return oldFilename } // nothing new captured, keep existing
        delete(oldFilename)
        return save(newData)
    }
}
