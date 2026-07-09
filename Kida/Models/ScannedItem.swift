//
//  ScannedItem.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 08/07/26.
//

import Foundation
import SwiftData

@Model
final class ScannedItem {
    @Attribute(.unique) var id: UUID

    // Store image filenames only so app-container path changes do not break rows.
    var imagePath: String?
    var imageSegmentedPath: String?

    var itemDescription: String
    var objectName: String
    var date: Date

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
