import SwiftUI

struct FoodRow: View {
    let item: FoodItem
    let thresholdDays: Int
    let isSelecting: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    private var state: ExpiryState {
        item.expiryState(thresholdDays: thresholdDays)
    }

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(
                            state == .expired
                                ? FridgeTheme.mutedInk.opacity(0.35)
                                : FridgeTheme.accent
                        )
                }
                .buttonStyle(.plain)
                .disabled(state == .expired)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(FridgeTheme.ink)
                    .lineLimit(1)

                Text("Shelf life \(item.shelfLifeDays) days · \(item.statusText())")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(FridgeTheme.mutedInk)
            }

            Spacer(minLength: 6)

            if !isSelecting {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FridgeTheme.mutedInk)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(FridgeTheme.color(for: state).opacity(0.46))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(FridgeTheme.ink.opacity(0.09), lineWidth: 1.2)
                }
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: 7, height: 7)
                .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { onSelect() } else { onEdit() }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isSelecting)
    }
}

struct EditFoodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FoodItem
    private let originalName: String
    let onSave: (FoodItem) -> Void

    init(item: FoodItem, onSave: @escaping (FoodItem) -> Void) {
        _draft = State(initialValue: item)
        originalName = item.name
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("Food name", text: $draft.name)
                }

                Section("Shelf Life") {
                    DatePicker("Added Date", selection: $draft.addedDate, displayedComponents: .date)
                    Stepper("Shelf life: \(draft.shelfLifeDays) days", value: $draft.shelfLifeDays, in: 1...365)
                    LabeledContent("Estimated Expiry") {
                        Text(draft.expiryDate, format: .dateTime.year().month().day())
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FridgeTheme.paper)
            .navigationTitle("Edit Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        let trimmedName = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.name = trimmedName
                        if trimmedName != originalName.trimmingCharacters(in: .whitespacesAndNewlines) {
                            saved.canonicalName = trimmedName
                        }
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AddFoodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inventory: InventoryStore
    @State private var name = ""
    @State private var addedDate = Date()
    @State private var shelfLifeDays = 7

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("e.g. spinach", text: $name)
                        .textInputAutocapitalization(.never)
                }

                Section("Shelf Life") {
                    DatePicker("Added Date", selection: $addedDate, displayedComponents: .date)
                    Stepper("Shelf life: \(shelfLifeDays) days", value: $shelfLifeDays, in: 1...365)
                    LabeledContent("Estimated Expiry") {
                        Text(expiryDate, format: .dateTime.year().month().day())
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FridgeTheme.paper)
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        inventory.mergeIncoming(
                            FoodItem(
                                name: trimmedName,
                                canonicalName: trimmedName,
                                addedDate: addedDate,
                                shelfLifeDays: shelfLifeDays
                            )
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: name) { _, newName in
                if let suggestion = inventory.suggestedShelfLife(for: newName) {
                    shelfLifeDays = suggestion
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var expiryDate: Date {
        Calendar.current.date(
            byAdding: .day,
            value: shelfLifeDays,
            to: Calendar.current.startOfDay(for: addedDate)
        ) ?? addedDate
    }
}
