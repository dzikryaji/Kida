//
//  ImageRepository.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//

import Foundation

final class ImageRepository {
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
            print("ImageRepository failed to save image: \(error)")
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
        guard let newData else { return oldFilename }
        delete(oldFilename)
        return save(newData)
    }
}
