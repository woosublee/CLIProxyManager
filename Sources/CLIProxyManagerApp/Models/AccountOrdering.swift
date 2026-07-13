enum AccountOrdering {
    static func orderedRows(
        _ rows: [ProviderRowState],
        storedIDs: [String]
    ) -> [ProviderRowState] {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.rawValue, $0) })
        var seen: Set<String> = []
        var ordered: [ProviderRowState] = []

        for id in storedIDs where seen.insert(id).inserted {
            if let row = rowsByID[id] {
                ordered.append(row)
            }
        }

        ordered.append(contentsOf: rows.filter { seen.insert($0.id.rawValue).inserted })
        return ordered
    }

    static func moving(
        _ rows: [ProviderRowState],
        id: ProviderRowState.ID,
        before targetID: ProviderRowState.ID?
    ) -> [ProviderRowState] {
        guard targetID != id,
              let sourceIndex = rows.firstIndex(where: { $0.id == id }) else {
            return rows
        }

        var movedRows = rows
        let source = movedRows.remove(at: sourceIndex)

        if let targetID {
            guard let targetIndex = movedRows.firstIndex(where: { $0.id == targetID }) else {
                return rows
            }
            movedRows.insert(source, at: targetIndex)
        } else {
            movedRows.append(source)
        }

        return movedRows
    }
}
