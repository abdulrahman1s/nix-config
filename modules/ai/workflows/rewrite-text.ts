import { runTextTask, type WorkflowHandler } from "./shared";

const recipePrompt = "Rewrite the source for clarity and flow. Preserve its meaning, facts, names, and useful formatting. Follow the requested style or audience when given. Return only the rewritten text; do not add new claims.";

export const events = ["manual"] as const;
export const run: WorkflowHandler = async ({ values = {} }) => runTextTask(values, recipePrompt);
