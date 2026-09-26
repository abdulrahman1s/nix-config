import { spawn } from "node:child_process";
import { Clipboard, showToast, Toast } from "@vicinae/api";
import type { Workflow } from "./catalog";

export type FormValues = Record<string, string | string[]>;
const workflowRunner = "@personalAiWorkflowRunner@";

export function fieldValue(values: FormValues, name: string): string {
  const value = values[name];
  return (Array.isArray(value) ? value[0] : value)?.trim() ?? "";
}

export async function runWorkflow(workflow: Workflow, values: FormValues = {}): Promise<string> {
  const cwdField = workflow.fields?.find((field) => field.kind === "cwd");
  const normalized = Object.fromEntries(Object.keys(values).map((name) => [name, fieldValue(values, name)]));
  if (normalized.source === "clipboard") {
    const clipboardText = await Clipboard.readText().catch(() => undefined);
    if (clipboardText?.trim()) {
      normalized.source = "text";
      normalized.content = clipboardText;
    }
  }
  const toast = await showToast({ style: Toast.Style.Animated, title: `Running ${workflow.title}` });
  return new Promise((resolve, reject) => {
    const child = spawn(workflowRunner, [], { cwd: cwdField ? fieldValue(values, cwdField.name) : undefined });
    let stdout = "";
    let stderr = "";
    let settled = false;
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    // The child may exit before reading stdin; close reports its useful stderr.
    child.stdin.on("error", () => undefined);
    child.once("error", (error) => {
      if (settled) return;
      settled = true;
      toast.style = Toast.Style.Failure;
      toast.title = `${workflow.title} failed`;
      toast.message = error.message;
      reject(error);
    });
    child.once("close", (code) => {
      if (settled) return;
      settled = true;
      if (code === 0) {
        if (!stdout.trim()) {
          const error = new Error("Workflow returned an empty response.");
          toast.style = Toast.Style.Failure;
          toast.title = `${workflow.title} failed`;
          toast.message = error.message;
          reject(error);
          return;
        }
        toast.style = Toast.Style.Success;
        toast.title = `${workflow.title} complete`;
        resolve(stdout.trim());
      } else {
        const message = stderr.trim() || `Workflow exited with status ${code}`;
        toast.style = Toast.Style.Failure;
        toast.title = `${workflow.title} failed`;
        toast.message = message;
        reject(new Error(message));
      }
    });
    child.stdin.end(JSON.stringify({ id: workflow.id, values: normalized, cwd: cwdField ? fieldValue(values, cwdField.name) : undefined }));
  });
}
