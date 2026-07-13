import CoreGraphics

enum AccountOrdering {
    static func orderedRows(
        _ rows: [ProviderRowState],
        storedIDs: [String]
    ) -> [ProviderRowState] {
        let rowsByID = Dictionary(
            rows.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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

    static func moving(
        _ ids: [ProviderRowState.ID],
        id: ProviderRowState.ID,
        before targetID: ProviderRowState.ID?
    ) -> [ProviderRowState.ID] {
        guard targetID != id,
              let sourceIndex = ids.firstIndex(of: id) else {
            return ids
        }

        var movedIDs = ids
        let source = movedIDs.remove(at: sourceIndex)

        if let targetID {
            guard let targetIndex = movedIDs.firstIndex(of: targetID) else {
                return ids
            }
            movedIDs.insert(source, at: targetIndex)
        } else {
            movedIDs.append(source)
        }

        return movedIDs
    }

    static func insertionIndex(
        for pointerY: CGFloat,
        orderedIDs: [ProviderRowState.ID],
        dragging draggedID: ProviderRowState.ID,
        frames: [ProviderRowState.ID: CGRect]
    ) -> Int? {
        let remainingIDs = orderedIDs.filter { $0 != draggedID }
        let positionedIDs = remainingIDs.compactMap { id -> (ProviderRowState.ID, CGRect)? in
            guard let frame = frames[id] else { return nil }
            return (id, frame)
        }
        .sorted { $0.1.midY < $1.1.midY }

        guard positionedIDs.count == remainingIDs.count else { return nil }
        return positionedIDs.firstIndex { pointerY < $0.1.midY } ?? positionedIDs.count
    }
}
