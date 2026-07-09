import Foundation

enum ObjectLabelNormalizer {
    nonisolated private static let aliases: [(keywords: [String], label: String)] = [
        (["perfume bottle", "cologne bottle"], "perfume bottle"),
        (["medicine bottle", "pill bottle"], "medicine bottle"),
        (["baby bottle"], "baby bottle"),
        (["tissue box"], "tissue box"),
        (["wine glass", "champagne glass"], "wine glass"),
        (["coffee mug", "mug", "cup", "teacup", "goblet"], "cup"),
        (["water bottle", "bottle", "flask"], "bottle"),
        (["book", "notebook", "binder", "comic book"], "book"),
        (["chair", "seat", "stool"], "chair"),
        (["potted plant", "houseplant", "plant", "flowerpot"], "plant"),
        (["backpack", "bag", "handbag", "purse"], "bag"),
        (["toy", "doll", "teddy", "figurine"], "toy"),
        (["table", "desk"], "table"),
        (["laptop", "computer", "notebook computer"], "laptop"),
        (["phone", "mobile phone", "cellular telephone", "smartphone"], "phone"),
        (["pen", "pencil", "marker"], "pen")
    ]

    nonisolated static func normalize(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        for alias in aliases {
            if alias.keywords.contains(where: { lowercased.contains($0) }) {
                return alias.label
            }
        }

        return lowercased
            .split(separator: ",")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .nonEmpty ?? "object"
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
