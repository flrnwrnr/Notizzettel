import SwiftUI

struct TaskStatusMarker: View {
    let state: TaskMarkerState
    var displayScale: CGFloat = 1
    var sizeFactor: CGFloat = 1

    private var unit: CGFloat {
        sizeFactor / max(displayScale, 0.1)
    }

    var body: some View {
        ZStack {
            switch state {
            case .proposal:
                Circle()
                    .fill(Color.white)
                Circle()
                    .stroke(
                        Color.secondary,
                        style: StrokeStyle(
                            lineWidth: 1.5 * unit,
                            dash: [3 * unit, 2 * unit]
                        )
                    )
            case .open:
                Circle()
                    .fill(Color.white)
                Circle()
                    .stroke(Color.secondary, lineWidth: 1.5 * unit)
            case .completed:
                Circle()
                    .fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 9 * unit, weight: .bold))
                    .foregroundStyle(.white)
            case .deleted:
                Circle()
                    .fill(Color.red)
                Image(systemName: "xmark")
                    .font(.system(size: 8 * unit, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16 * unit, height: 16 * unit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .proposal:
            return "Noch keine Erinnerung erstellt"
        case .open:
            return "Erinnerung offen"
        case .completed:
            return "Erinnerung erledigt"
        case .deleted:
            return "In Erinnerungen gelöscht"
        }
    }
}
