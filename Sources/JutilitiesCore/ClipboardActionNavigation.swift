/// The action menu keeps a selection independently of clipboard history and skips
/// actions that cannot run for the current entry.
public enum ClipboardActionID: CaseIterable, Hashable, Sendable {
    case paste, copy, copyText, airDrop, pin, delete, toggleCapture, backup, clear
}

public struct ClipboardActionNavigation: Equatable, Sendable {
    public private(set) var selectedAction: ClipboardActionID?

    public init() {}

    public mutating func selectFirst(in enabledActions: [ClipboardActionID]) {
        selectedAction = enabledActions.first
    }

    public mutating func selectLast(in enabledActions: [ClipboardActionID]) {
        selectedAction = enabledActions.last
    }

    public mutating func select(_ action: ClipboardActionID, in enabledActions: [ClipboardActionID]) {
        guard enabledActions.contains(action) else { return }
        selectedAction = action
    }

    public mutating func reconcile(with enabledActions: [ClipboardActionID]) {
        if let selectedAction, enabledActions.contains(selectedAction) { return }
        selectFirst(in: enabledActions)
    }

    public mutating func move(_ direction: Int, in enabledActions: [ClipboardActionID]) {
        guard !enabledActions.isEmpty else {
            selectedAction = nil
            return
        }
        guard let selectedAction, let current = enabledActions.firstIndex(of: selectedAction) else {
            self.selectedAction = direction < 0 ? enabledActions.last : enabledActions.first
            return
        }
        let step = direction < 0 ? -1 : 1
        let next = (current + step + enabledActions.count) % enabledActions.count
        self.selectedAction = enabledActions[next]
    }
}
