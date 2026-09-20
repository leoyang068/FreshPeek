import SwiftUI

struct ChefThinkingOverlay: View {
    @State private var bob = false
    @State private var dotIndex = 0

    private let messages = ["Checking your fridge…", "Pairing ingredients…", "Dinner is almost ready…"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .background(.ultraThinMaterial.opacity(0.4))

            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Text("👩🏻‍🍳")
                        .font(.system(size: 76))
                        .offset(y: bob ? -5 : 4)

                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(FridgeTheme.accent)
                                .frame(width: 7, height: 7)
                                .scaleEffect(dotIndex == index ? 1.45 : 0.75)
                        }
                    }
                    .padding(.trailing, -12)
                }

                Text(messages[dotIndex])
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(FridgeTheme.ink)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .background(FridgeTheme.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(FridgeTheme.ink.opacity(0.1), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.13), radius: 18, y: 8)
        }
        .task {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                bob = true
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeInOut(duration: 0.22)) {
                    dotIndex = (dotIndex + 1) % messages.count
                }
            }
        }
        .transition(.opacity)
    }
}

struct RecipeResultView: View {
    @Environment(\.dismiss) private var dismiss
    let recipe: GeneratedRecipe

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(recipe.title)
                            .font(.system(.title2, design: .rounded, weight: .heavy))
                            .foregroundStyle(FridgeTheme.ink)
                        Text(recipe.subtitle)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(FridgeTheme.mutedInk)
                    }

                    recipeSection("From Your Fridge", icon: "checkmark.seal.fill") {
                        FlowingText(values: recipe.usedFoods)
                    }

                    recipeSection("You'll Also Need", icon: "basket.fill") {
                        FlowingText(values: recipe.extraIngredients)
                    }

                    recipeSection("Directions", icon: "list.number") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(.caption, design: .rounded, weight: .bold))
                                        .frame(width: 25, height: 25)
                                        .background(FridgeTheme.expiring.opacity(0.65), in: Circle())
                                    Text(step)
                                        .font(.system(.body, design: .rounded))
                                        .foregroundStyle(FridgeTheme.ink)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(PaperTexture())
            .navigationTitle("Today's Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func recipeSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(FridgeTheme.ink)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct FlowingText: View {
    let values: [String]

    var body: some View {
        Text(values.joined(separator: " · "))
            .font(.system(.body, design: .rounded))
            .foregroundStyle(FridgeTheme.mutedInk)
    }
}
