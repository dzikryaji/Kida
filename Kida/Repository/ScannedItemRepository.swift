//
//  ScannedItemRepository.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//
//  REPOSITORY LAYER — owns all persistence details for ScannedItem:
//  SwiftData queries/predicates/saves AND coordinating image file writes
//  via ImageRepositoryProtocol. The ViewModel talks only to this protocol —
//  it never touches ModelContext or FetchDescriptor directly.
//
//  The segmented image can arrive either as raw Data (e.g. captured/loaded
//  bytes) or as a CVPixelBuffer (e.g. straight out of a Vision/CoreML
//  segmentation request). Both are supported so callers don't have to
//  convert a pixel buffer to Data themselves before calling in.
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

    // MARK: - READ

    func fetchAll(sortByDateDescending: Bool = true) throws -> [ScannedItem] {
        let sortDescriptor = SortDescriptor(\ScannedItem.date, order: sortByDateDescending ? .reverse : .forward)
        let descriptor = FetchDescriptor<ScannedItem>(sortBy: [sortDescriptor])
        return try modelContext.fetch(descriptor)
    }

    func fetch(matching query: String) throws -> [ScannedItem] {
        guard !query.isEmpty else {
            return try fetchAll()
        }

        let predicate = #Predicate<ScannedItem> { item in
            item.objectName.localizedStandardContains(query)
        }
        let descriptor = FetchDescriptor<ScannedItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func imageData(for item: ScannedItem) -> Data? {
        imageRepository.load(item.imagePath)
    }

    func segmentedImageData(for item: ScannedItem) -> Data? {
        imageRepository.load(item.imageSegmentedPath)
    }

    // MARK: - CREATE

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

    // MARK: - UPDATE

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
            item.imageSegmentedPath = imageRepository.replace(oldFilename: item.imageSegmentedPath, with: newImageSegmentedData)
        }
        if let itemDescription { item.itemDescription = itemDescription }
        if let objectName { item.objectName = objectName }
        if let date { item.date = date }

        try modelContext.save()
    }

    // MARK: - DELETE

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
