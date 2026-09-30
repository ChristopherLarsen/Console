import SwiftUI

struct ToDoView: View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("ToDo.List")
    }

    private func addItem() {
        if store.add(newTitle) { newTitle = "" }
    }
}

private struct ToDoRow: View {
    let item: ToDoItem
    let store: ToDoStore
    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(item: ToDoItem, store: ToDoStore) {
        self.item = item
        self.store = store
        _draft = State(initialValue: item.title)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Complete \(item.title)", isOn: Binding(
                get: { item.isCompleted },
                set: { store.setCompleted(item.id, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

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
            .help("Delete item")
            .accessibilityLabel("Delete \(item.title)")
        }
        .padding(.vertical, 10)
    }

    private func commitEdit() {
        if ToDoStore.singleLine(draft) == nil {
            draft = item.title
        } else if store.update(item.id, title: draft) {
            draft = ToDoStore.singleLine(draft) ?? item.title
        }
    }
}
