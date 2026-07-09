//
//  ScannedItemRepository.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//

import Foundation
import SwiftData

final class ScannedItemRepository {
    private let modelContext: ModelContext
    private let imageRepository: ImageRepository

    init(modelContext: ModelContext, imageRepository: ImageRepository = ImageRepository()) {
        self.modelContext = modelContext
        self.imageRepository = imageRepository
    }

    func fetchAll(sortByDateDescending: Bool = true) throws -> [ScannedItem] {
        let sortDescriptor = SortDescriptor(
            \ScannedItem.date,
            order: sortByDateDescending ? .reverse : .forward
        )
        let descriptor = FetchDescriptor<ScannedItem>(sortBy: [sortDescriptor])
        return try modelContext.fetch(descriptor)
    }

    func fetch(matching query: String) throws -> [ScannedItem] {
        let items = try fetchAll()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }

        return items.filter {
            $0.objectName.localizedStandardContains(trimmed)
                || $0.itemDescription.localizedStandardContains(trimmed)
        }
    }

    func imageData(for item: ScannedItem) -> Data? {
        imageRepository.load(item.imagePath)
    }

    func segmentedImageData(for item: ScannedItem) -> Data? {
        imageRepository.load(item.imageSegmentedPath)
    }

    @discardableResult
    func add(
        imageData: Data?,
        imageSegmentedData: Data?,
        itemDescription: String,
        objectName: String,
        date: Date = .now
    ) throws -> ScannedItem {
        let savedImagePath = imageData.flatMap { imageRepository.save($0) }
        let savedSegmentedPath = imageSegmentedData.flatMap { imageRepository.save($0) }
        let newItem = ScannedItem(
            imagePath: savedImagePath,
            imageSegmentedPath: savedSegmentedPath,
            itemDescription: itemDescription,
            objectName: objectName,
            date: date
        )

        modelContext.insert(newItem)
        try modelContext.save()
        return newItem
    }

    func update(
        _ item: ScannedItem,
        newImageData: Data? = nil,
        newImageSegmentedData: Data? = nil,
        itemDescription: String? = nil,
        objectName: String? = nil,
        date: Date? = nil
    ) throws {
        if let newImageData {
            item.imagePath = imageRepository.replace(oldFilename: item.imagePath, with: newImageData)
        }

        if let newImageSegmentedData {
            item.imageSegmentedPath = imageRepository.replace(
                oldFilename: item.imageSegmentedPath,
                with: newImageSegmentedData
            )
        }

        if let itemDescription { item.itemDescription = itemDescription }
        if let objectName { item.objectName = objectName }
        if let date { item.date = date }

        try modelContext.save()
    }

    func delete(_ item: ScannedItem) throws {
        imageRepository.delete(item.imagePath)
        imageRepository.delete(item.imageSegmentedPath)
        modelContext.delete(item)
        try modelContext.save()
    }

    func delete(_ items: [ScannedItem]) throws {
        for item in items {
            imageRepository.delete(item.imagePath)
            imageRepository.delete(item.imageSegmentedPath)
            modelContext.delete(item)
        }

        try modelContext.save()
    }
}
