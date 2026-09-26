import { workflows } from "./registry";
import type { WorkflowRequest } from "./shared";

try {
  const input = await Bun.stdin.text();
  const request = JSON.parse(input) as WorkflowRequest;
  if (!request.id || typeof request.id !== "string") throw new Error("Workflow request is missing an id.");
  if (!Object.hasOwn(workflows, request.id)) throw new Error(`Unknown workflow: ${request.id}`);
  const workflow = workflows[request.id];
  process.stdout.write(`${await workflow.run(request)}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
