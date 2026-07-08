//
//  ScannedItem.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//
import Foundation
import SwiftData

@Model
final class ScannedItem { // named ScannedItem to avoid clashing with collection protocol

    // MARK: - Properties
    @Attribute(.unique) var id: UUID

    // Only filenames are stored here. The actual image bytes live on disk
    // (see ImageFileManager) under the app's Documents/ScannedImages folder.
    // Storing just the filename (not a full path) keeps things valid even if
    // the app's container path changes between launches or after a restore.
    var imagePath: String?
    var imageSegmentedPath: String?

    var itemDescription: String   // named to avoid clashing with NSObject's `description`
    var objectName: String
    var date: Date

    // MARK: - Init
    init(
        id: UUID = UUID(),
        imagePath: String? = nil,
        imageSegmentedPath: String? = nil,
        itemDescription: String = "",
        objectName: String = "",
        date: Date = .now
    ) {
        self.id = id
        self.imagePath = imagePath
        self.imageSegmentedPath = imageSegmentedPath
        self.itemDescription = itemDescription
        self.objectName = objectName
        self.date = date
    }
}
