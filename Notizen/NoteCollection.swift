import Foundation

enum NoteCollection: Hashable {
    case all
    case unassigned
    case customer(UUID)
}

