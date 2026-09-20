import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var inventory: InventoryStore
    @State private var editingItem: FoodItem?
    @State private var showAddFood = false
    @State private var isSelectingRecipeFoods = false
    @State private var selectedFoodIDs: Set<UUID> = []
    @State private var showSettings = false
    @State private var isGeneratingRecipe = false
    @State private var generatedRecipe: GeneratedRecipe?
    @State private var recipeError: String?
    @State private var showUndoToast = false

    private let recipeService: any RecipeGenerating = SupabaseRecipeService()

    var body: some View {
        ZStack {
            PaperTexture()

            VStack(spacing: 0) {
                titleArea
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                fridge
                    .padding(.horizontal, 14)

                recipeBar
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if showUndoToast {
                undoToast
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 86)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
            }

            if isGeneratingRecipe {
                ChefThinkingOverlay()
                    .zIndex(10)
            }
        }
        .tint(FridgeTheme.accent)
        .sheet(item: $editingItem) { item in
            EditFoodSheet(item: item) { inventory.update($0) }
        }
        .sheet(isPresented: $showAddFood) {
            AddFoodSheet()
                .environmentObject(inventory)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(inventory)
        }
        .sheet(item: $generatedRecipe) { recipe in
            RecipeResultView(recipe: recipe)
        }
        .alert("Recipe Generation Failed", isPresented: Binding(
            get: { recipeError != nil },
            set: { if !$0 { recipeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recipeError ?? "Please try again later.")
        }
        .refreshable {
            await inventory.refreshFromCloud()
        }
    }

    private var titleArea: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("My Fridge")
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                        .foregroundStyle(FridgeTheme.ink)
                    Text("❄️")
                        .font(.title3)
                        .rotationEffect(.degrees(-8))
                }

                Text(inventory.syncError == nil ? "Last synced: \(relativeSyncText)" : "Sync failed — showing local data")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(inventory.syncError == nil ? FridgeTheme.mutedInk : FridgeTheme.expiring)
            }

            Spacer()

            Button {
                showAddFood = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(FridgeTheme.accent, in: Circle())
                    .overlay {
                        Circle().stroke(FridgeTheme.ink.opacity(0.08), lineWidth: 1)
                    }
            }
            .accessibilityLabel("Add food")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(FridgeTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(FridgeTheme.paperDeep.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().stroke(FridgeTheme.ink.opacity(0.08), lineWidth: 1)
                    }
            }
            .accessibilityLabel("Settings")
        }
    }

    private var fridge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(FridgeTheme.fridgeBody)
                .shadow(color: FridgeTheme.ink.opacity(0.18), radius: 10, y: 6)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(FridgeTheme.fridgeInside)
                .padding(10)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 82, height: 10)
                        .shadow(color: .white, radius: 9)
                        .padding(.top, 16)
                }

            inventoryList
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(12)
                .padding(.top, 12)
        }
        .overlay(alignment: .leading) {
            fridgeDoorDecoration
                .offset(x: -7)
        }
        .overlay(alignment: .trailing) {
            fridgeDoorDecoration
                .scaleEffect(x: -1, y: 1)
                .offset(x: 7)
        }
    }

    private var inventoryList: some View {
        Group {
            if inventory.sortedItems.isEmpty {
                VStack(spacing: 12) {
                    Text("🧺")
                        .font(.system(size: 54))
                    Text("Your fridge is empty")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(FridgeTheme.ink)
                    Text("Food will appear here automatically when added")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(FridgeTheme.mutedInk)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(inventory.sortedItems) { item in
                            FoodRow(
                                item: item,
                                thresholdDays: inventory.thresholdDays,
                                isSelecting: isSelectingRecipeFoods,
                                isSelected: selectedFoodIDs.contains(item.id),
                                onSelect: { toggleSelection(for: item) },
                                onEdit: { editingItem = item }
                            )
                            .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 9, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !isSelectingRecipeFoods {
                                    Button(role: .destructive) {
                                        delete(item)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(FridgeTheme.expired)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(isSelectingRecipeFoods ? "Choose ingredients" : "Eat what expires first")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(FridgeTheme.mutedInk)
                            Spacer()
                            if isSelectingRecipeFoods {
                                Button("Cancel") { leaveRecipeSelection() }
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                            }
                        }
                        .textCase(nil)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }

    private var fridgeDoorDecoration: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(FridgeTheme.fridgeBody.opacity(0.98))
            .frame(width: 16)
            .overlay {
                Capsule()
                    .fill(FridgeTheme.ink.opacity(0.15))
                    .frame(width: 3, height: 86)
            }
    }

    private var recipeBar: some View {
        Button {
            if isSelectingRecipeFoods {
                generateRecipe()
            } else {
                enterRecipeSelection()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelectingRecipeFoods ? "sparkles" : "fork.knife")
                Text(isSelectingRecipeFoods ? selectionButtonTitle : "Cook with fridge ingredients")
                    .lineLimit(1)
            }
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(FridgeTheme.accent, in: Capsule())
            .shadow(color: FridgeTheme.accent.opacity(0.25), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .opacity(isSelectingRecipeFoods && selectedFoodIDs.isEmpty ? 0.62 : 1)
    }

    private var undoToast: some View {
        HStack(spacing: 18) {
            Text("Food removed")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            Button("Undo") {
                inventory.restoreMostRecentManualDeletion()
                withAnimation { showUndoToast = false }
            }
            .font(.system(.subheadline, design: .rounded, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(FridgeTheme.ink.opacity(0.9), in: Capsule())
    }

    private var relativeSyncText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(inventory.lastSyncDate)))
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) hr ago" }
        return "\(seconds / 86_400) days ago"
    }

    private var selectionButtonTitle: String {
        selectedFoodIDs.isEmpty ? "Select ingredients first" : "Generate Recipe"
    }

    private func enterRecipeSelection() {
        selectedFoodIDs = Set(
            inventory.items
                .filter { $0.expiryState(thresholdDays: inventory.thresholdDays) == .expiringSoon }
                .map(\.id)
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isSelectingRecipeFoods = true
        }
    }

    private func leaveRecipeSelection() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isSelectingRecipeFoods = false
            selectedFoodIDs.removeAll()
        }
    }

    private func toggleSelection(for item: FoodItem) {
        guard item.expiryState(thresholdDays: inventory.thresholdDays) != .expired else { return }
        if selectedFoodIDs.contains(item.id) {
            selectedFoodIDs.remove(item.id)
        } else {
            selectedFoodIDs.insert(item.id)
        }
    }

    private func delete(_ item: FoodItem) {
        inventory.manuallyDelete(item)
        selectedFoodIDs.remove(item.id)
        withAnimation { showUndoToast = true }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { showUndoToast = false }
        }
    }

    private func generateRecipe() {
        let selected = inventory.items.filter { selectedFoodIDs.contains($0.id) }
        guard !selected.isEmpty else {
            recipeError = "Select at least one ingredient first."
            return
        }
        isGeneratingRecipe = true

        Task {
            do {
                let recipe = try await recipeService.generateRecipe(
                    foods: selected,
                    cuisine: inventory.cuisine
                )
                isGeneratingRecipe = false
                generatedRecipe = recipe
                leaveRecipeSelection()
            } catch {
                isGeneratingRecipe = false
                recipeError = error.localizedDescription
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(InventoryStore())
    }
}
