import Foundation

final class PersonaLibraryStore {
    private let key = "savedObjectPersonas"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() -> [ObjectPersona] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let personas = try? decoder.decode([ObjectPersona].self, from: data) else {
            return []
        }

        return personas
    }

    func save(_ persona: ObjectPersona) {
        var personas = load()
        personas.removeAll { $0.name == persona.name && $0.objectLabel == persona.objectLabel }
        personas.insert(persona, at: 0)

        guard let data = try? encoder.encode(personas) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }
}

