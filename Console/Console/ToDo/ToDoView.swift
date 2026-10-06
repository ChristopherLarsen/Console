import SwiftUI

struct ToDoView: View {
    /// About half a full-screen detail column, so row actions stay near the title
    /// instead of at the far edge of the window.
    private static let contentMaxWidth: CGFloat = 640

    let store: ToDoStore
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("To Do")
                .font(.title2.weight(.semibold))

            HStack {
                TextField("Add an item", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addItem)
                    .accessibilityIdentifier("ToDo.AddField")
                Button(action: addItem) {
                    Image(systemName: "plus")
                }
                .disabled(ToDoStore.singleLine(newTitle) == nil)
                .help("Add item")
                .accessibilityLabel("Add item")
            }
            .disabled(!store.isLoaded)

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if store.items.isEmpty && store.isLoaded {
                Text("No items yet.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in
                        ToDoRow(item: item, store: store)
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: Self.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("ToDo.List")
    }

    private func addItem() {
        if store.add(newTitle) { newTitle = "" }
    }
}

private struct ToDoDragToken: Transferable, Hashable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { token in
            token.id.uuidString
        } importing: { string in
            guard let id = UUID(uuidString: string) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return ToDoDragToken(id: id)
        }
    }
}

private struct ToDoRow: View {
    let item: ToDoItem
    let store: ToDoStore
    @State private var draft: String
    @State private var isHovered = false
    @State private var isDropTargeted = false
    @FocusState private var isEditing: Bool
    @FocusState private var isDeleteFocused: Bool

    init(item: ToDoItem, store: ToDoStore) {
        self.item = item
        self.store = store
        _draft = State(initialValue: item.title)
    }

    private var showsDelete: Bool { isHovered || isDeleteFocused }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 22)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .accessibilityLabel("Reorder \(item.title)")
                .accessibilityAction(named: "Move Up") { move(by: -1) }
                .accessibilityAction(named: "Move Down") { move(by: 1) }
                .draggable(ToDoDragToken(id: item.id)) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }

            Button {
                store.setCompleted(item.id, !item.isCompleted)
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(item.title)")
            .accessibilityValue(item.isCompleted ? "Checked" : "Unchecked")
            .accessibilityAddTraits(.isToggle)
            .accessibilityRemoveTraits(.isButton)

            TextField("Item", text: $draft)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .focused($isEditing)
                .onSubmit(commitEdit)
                .onChange(of: isEditing) { _, focused in
                    if !focused { commitEdit() }
                }
                .onDisappear(perform: commitEdit)
                .accessibilityLabel("Edit item")

            Button {
                store.delete(item.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focused($isDeleteFocused)
            .opacity(showsDelete ? 1 : 0)
            .allowsHitTesting(showsDelete)
            .help("Delete item")
            .accessibilityLabel("Delete \(item.title)")
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .onHover { isHovered = $0 }
        .dropDestination(for: ToDoDragToken.self) { dropped, _ in
            guard let dragged = dropped.first, dragged.id != item.id else { return false }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.move(dragged.id, toSlotOf: item.id)
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func move(by offset: Int) {
        guard let index = store.items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard store.items.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.move(item.id, toSlotOf: store.items[target].id)
        }
    }

    private func commitEdit() {
        if ToDoStore.singleLine(draft) == nil {
            draft = item.title
        } else if store.update(item.id, title: draft) {
            draft = ToDoStore.singleLine(draft) ?? item.title
        }
    }
}
