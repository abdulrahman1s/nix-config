import { runTextTask, type WorkflowHandler } from "./shared";

const recipePrompt = "Extract explicit action items as a checklist. Include an owner or due date only when the source provides one. Put decisions and open questions in separate sections. If there are no action items, say so. Do not invent tasks.";

export const events = ["manual"] as const;
export const run: WorkflowHandler = async ({ values = {} }) => runTextTask(values, recipePrompt);
