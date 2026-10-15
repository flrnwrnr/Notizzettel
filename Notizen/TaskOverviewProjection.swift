import Foundation

enum TaskOverviewCategory: Equatable {
    case proposal
    case attention
    case open
    case completed
    case ignored
    case hidden
}

enum TaskOverviewProjection {
    static func category(for task: RecognizedTask) -> TaskOverviewCategory {
        if task.isIgnored { return .ignored }
        if task.reminderIdentifier == nil {
            return task.isPresent ? .proposal : .hidden
        }
        if task.reminderSyncError != nil || task.reminderRemovalPending
            || (task.isPresent && task.reminderStatus == .deleted)
            || (!task.isPresent && !task.wasRemovedFromDrawing) {
            return .attention
        }
        guard task.isPresent else { return .hidden }
        return task.markerState == .completed ? .completed : .open
    }

    static func mayCreateInBulk(_ task: RecognizedTask, isProvisional: Bool) -> Bool {
        category(for: task) == .proposal && !isProvisional
            && !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func needsAction(_ task: RecognizedTask) -> Bool {
        let category = category(for: task)
        return category == .proposal || category == .attention
    }
}
