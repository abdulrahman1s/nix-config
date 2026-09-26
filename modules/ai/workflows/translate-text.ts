import { runTextTask, type WorkflowHandler } from "./shared";

const recipePrompt = "Translate the text into the requested language. Preserve meaning, tone, formatting, names, and technical terms.";

export const events = ["manual"] as const;
export const run: WorkflowHandler = async ({ values = {} }) => runTextTask(values, recipePrompt);
