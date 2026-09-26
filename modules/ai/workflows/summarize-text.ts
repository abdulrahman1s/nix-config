import { runTextTask, type WorkflowHandler } from "./shared";

const recipePrompt = "Summarize the source in concise bullets. Lead with the main point, then preserve important names, dates, numbers, and decisions. Do not add facts that are not in the source.";

export const events = ["manual"] as const;
export const run: WorkflowHandler = async ({ values = {} }) => runTextTask(values, recipePrompt);
