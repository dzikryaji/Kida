//
//  CollectionViewModel.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//

import Foundation
import Observation

@Observable
final class CollectionViewModel {
    var items: [ScannedItem] = []
    var errorMessage: String?

    private let repository: ScannedItemRepository

    init(repository: ScannedItemRepository) {
        self.repository = repository
        fetchItems()
    }

    func addItem(
        imageData: Data?,
        imageSegmentedData: Data? = nil,
        itemDescription: String,
        objectName: String,
        date: Date = .now
    ) {
        do {
            try repository.add(
                imageData: imageData,
                imageSegmentedData: imageSegmentedData,
                itemDescription: itemDescription,
                objectName: objectName,
                date: date
            )
            fetchItems()
        } catch {
            errorMessage = "Failed to add item: \(error.localizedDescription)"
        }
    }

    func fetchItems(sortByDateDescending: Bool = true) {
        do {
            items = try repository.fetchAll(sortByDateDescending: sortByDateDescending)
        } catch {
            errorMessage = "Failed to fetch items: \(error.localizedDescription)"
            items = []
        }
    }

    func fetchItems(matching query: String) {
        do {
            items = try repository.fetch(matching: query)
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    func imageData(for item: ScannedItem) -> Data? {
        repository.imageData(for: item)
    }

    func segmentedImageData(for item: ScannedItem) -> Data? {
        repository.segmentedImageData(for: item)
    }

    func updateItem(
        _ item: ScannedItem,
        newImageData: Data? = nil,
        newImageSegmentedData: Data? = nil,
        itemDescription: String? = nil,
        objectName: String? = nil,
        date: Date? = nil
    ) {
        do {
            try repository.update(
                item,
                newImageData: newImageData,
                newImageSegmentedData: newImageSegmentedData,
                itemDescription: itemDescription,
                objectName: objectName,
                date: date
            )
            fetchItems()
        } catch {
            errorMessage = "Failed to save changes: \(error.localizedDescription)"
        }
    }

    func deleteItem(_ item: ScannedItem) {
        do {
            try repository.delete(item)
            fetchItems()
        } catch {
            errorMessage = "Failed to delete item: \(error.localizedDescription)"
        }
    }

    func deleteItems(at offsets: IndexSet) {
        let itemsToDelete = offsets.map { items[$0] }
        do {
            try repository.delete(itemsToDelete)
            fetchItems()
        } catch {
            errorMessage = "Failed to delete items: \(error.localizedDescription)"
        }
    }

    func deleteAll() {
        do {
            try repository.delete(items)
            fetchItems()
        } catch {
            errorMessage = "Failed to delete all items: \(error.localizedDescription)"
        }
    }
}
