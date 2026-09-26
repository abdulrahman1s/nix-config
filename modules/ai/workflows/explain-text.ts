import { runTextTask, type WorkflowHandler } from "./shared";

const recipePrompt = "Explain the source in plain language. Define unfamiliar terms and show how the important parts fit together. Separate what the source establishes from what remains unclear. Do not invent missing context.";

export const events = ["manual"] as const;
export const run: WorkflowHandler = async ({ values = {} }) => runTextTask(values, recipePrompt);
