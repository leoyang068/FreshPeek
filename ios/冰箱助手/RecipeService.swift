import Foundation
import Supabase
import Functions

struct GeneratedRecipe: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let usedFoods: [String]
    let extraIngredients: [String]
    let steps: [String]
}

protocol RecipeGenerating {
    func generateRecipe(foods: [FoodItem], cuisine: Cuisine) async throws -> GeneratedRecipe
}

struct SupabaseRecipeService: RecipeGenerating {
    func generateRecipe(foods: [FoodItem], cuisine: Cuisine) async throws -> GeneratedRecipe {
        guard !foods.isEmpty else { throw RecipeError.noFoodSelected }
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            throw RecipeError.previewUnavailable
        }
        let request = RecipeFunctionRequest(
            foodIDs: foods.map(\.id),
            cuisine: cuisine.rawValue
        )

        do {
            let response: RecipeFunctionResponse = try await SupabaseConfig.client.functions.invoke(
                "generate-recipe",
                options: FunctionInvokeOptions(
                    headers: ["x-fridge-app-token": AppSecrets.fridgeAppToken],
                    body: request,
                    timeoutInterval: 145
                )
            )
            guard !response.usedFoods.isEmpty else { throw RecipeError.invalidResponse }
            return GeneratedRecipe(
                title: response.title,
                subtitle: response.subtitle,
                usedFoods: response.usedFoods,
                extraIngredients: response.extraIngredients,
                steps: response.steps
            )
        } catch FunctionsError.httpError(let statusCode, let data) {
            let serverError = try? JSONDecoder().decode(RecipeFunctionError.self, from: data)
            if statusCode == 401 {
                throw RecipeError.server("Recipe service configuration is invalid. Reinstall the latest app.")
            }
            throw RecipeError.server(serverError?.error ?? "Recipe service is temporarily unavailable.")
        } catch let error as RecipeError {
            throw error
        } catch {
            throw RecipeError.server("Unable to reach the recipe service. Check your connection and try again.")
        }
    }
}

private struct RecipeFunctionRequest: Encodable {
    let foodIDs: [UUID]
    let cuisine: String

    enum CodingKeys: String, CodingKey {
        case foodIDs = "food_ids"
        case cuisine
    }
}

private struct RecipeFunctionResponse: Decodable {
    let title: String
    let subtitle: String
    let usedFoods: [String]
    let extraIngredients: [String]
    let steps: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case usedFoods = "used_foods"
        case extraIngredients = "extra_ingredients"
        case steps
    }
}

private struct RecipeFunctionError: Decodable {
    let error: String
}

enum RecipeError: LocalizedError {
    case noFoodSelected
    case previewUnavailable
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noFoodSelected:
            return "Select at least one ingredient."
        case .previewUnavailable:
            return "Cloud recipes are disabled in previews. Run the app in Simulator or on a device."
        case .invalidResponse:
            return "The recipe did not use a selected ingredient. Please try again."
        case .server(let message):
            return message
        }
    }
}
