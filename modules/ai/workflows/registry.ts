import * as translateText from "./translate-text";
import * as summarizeText from "./summarize-text";
import * as extractActions from "./extract-actions";
import * as rewriteText from "./rewrite-text";
import * as explainText from "./explain-text";
import type { WorkflowModule } from "./shared";

export const workflows: Record<string, WorkflowModule> = {
  "translate-text": translateText,
  "summarize-text": summarizeText,
  "extract-actions": extractActions,
  "rewrite-text": rewriteText,
  "explain-text": explainText,
};
