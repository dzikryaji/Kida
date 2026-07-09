//
//  CollectionViewModel.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//
//  VIEWMODEL LAYER
//
//  Thin by design: holds published state for the View and delegates every
//  persistence detail (SwiftData queries, image file I/O) to
//  ScannedItemRepositoryProtocol. No ModelContext, FetchDescriptor, or file
//  system code lives here anymore — this class only orchestrates calls and
//  turns thrown errors into `errorMessage` for the UI.
//

import Foundation
import SwiftUI

@Observable
final class CollectionViewModel {

    // MARK: - Published state consumed by Views
    var items: [ScannedItem] = []
    var errorMessage: String?

    // MARK: - Dependency
    private let repository: ScannedItemRepository

    init(repository: ScannedItemRepository) {
        self.repository = repository
        fetchItems()
    }

    // MARK: - CREATE

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

    // MARK: - READ

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

    /// Resolves the on-disk image Data for an item, for display in Views.
    func imageData(for item: ScannedItem) -> Data? {
        repository.imageData(for: item)
    }

    func segmentedImageData(for item: ScannedItem) -> Data? {
        repository.segmentedImageData(for: item)
    }

    // MARK: - UPDATE

    /// Pass `newImageData` / `newImageSegmentedData` only when the user captured a
    /// *new* photo. Passing nil leaves the existing stored image untouched.
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

    // MARK: - DELETE

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
