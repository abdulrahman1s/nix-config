import { useState } from "react";
import { Action, ActionPanel, Detail, Form, Icon, showToast, Toast, useNavigation } from "@vicinae/api";
import type { Workflow } from "./catalog";
import { fieldValue, runWorkflow, type FormValues } from "./runner";

function Result({ workflow, result, error, onRetry }: { workflow: Workflow; result?: string; error?: string; onRetry: () => void }) {
  const { pop } = useNavigation();
  const markdown = error ? `# ${workflow.title} failed\n\n\`\`\`text\n${error}\n\`\`\`` : result ?? "Done.";
  return <Detail navigationTitle={workflow.title} markdown={markdown} actions={
    <ActionPanel>
      {!error && <Action.Paste title="Paste Result" content={result ?? ""} />}
      {!error && <Action.CopyToClipboard title="Copy Result" content={result ?? ""} />}
      <ActionPanel.Section title="Workflow">
        <Action title="Edit inputs" icon={Icon.Repeat} onAction={onRetry} shortcut={{ modifiers: ["ctrl"], key: "r" }} />
        <Action title="Back to Workflows" icon={Icon.ArrowLeft} onAction={pop} />
      </ActionPanel.Section>
    </ActionPanel>
  } />;
}

export function WorkflowForm({ workflow }: { workflow: Workflow }) {
  const fields = workflow.fields ?? [];
  const [isLoading, setIsLoading] = useState(false);
  const [result, setResult] = useState<string>();
  const [error, setError] = useState<string>();
  const [submittedValues, setSubmittedValues] = useState<FormValues>({});
  const [source, setSource] = useState("clipboard");
  const [draftText, setDraftText] = useState("");
  if (result !== undefined || error !== undefined) return <Result workflow={workflow} result={result} error={error} onRetry={() => { setResult(undefined); setError(undefined); }} />;
  return (
    <Form isLoading={isLoading} navigationTitle={workflow.title} actions={
      <ActionPanel><Action.SubmitForm title="Run Workflow" icon={Icon.Play} onSubmit={async (values: FormValues) => {
        const selectedSource = fieldValue(values, "source") || source;
        if (selectedSource === "text" && !fieldValue(values, "content")) {
          showToast({ style: Toast.Style.Failure, title: "Text is required", message: "Enter text or choose Clipboard." });
          return;
        }
        const missing = fields.find((field) => !field.optional && field.name !== "source" && !fieldValue(values, field.name));
        if (missing) {
          showToast({ style: Toast.Style.Failure, title: `${missing.title} is required` });
          return;
        }
        setIsLoading(true);
        setError(undefined);
        setSubmittedValues({ ...values, source: selectedSource });
        setSource(selectedSource);
        setDraftText(fieldValue(values, "content"));
        try { setResult(await runWorkflow(workflow, { ...values, source: selectedSource })); }
        catch (reason) {
          const message = reason instanceof Error ? reason.message : String(reason);
          setError(message);
        } finally { setIsLoading(false); }
      }} /></ActionPanel>
    }>
      <Form.Description title="Local workflow" text={workflow.guidance} />
      {fields.map((field) => field.name === "content" && source !== "text" ? null : field.options ? (
        <Form.Dropdown key={field.name} id={field.name} title={field.title} defaultValue={fieldValue(submittedValues, field.name) || field.options[0].value} onChange={field.name === "source" ? setSource : undefined}>
          {field.options.map((option) => <Form.Dropdown.Item key={option.value} value={option.value} title={option.title} />)}
        </Form.Dropdown>
      ) : field.picker ? (
        <Form.FilePicker key={field.name} id={field.name} title={field.title} allowMultipleSelection={false} canChooseFiles={field.picker === "file"} canChooseDirectories={field.picker === "directory"} />
      ) : field.kind === "textarea" ? (
        <Form.TextArea key={field.name} id={field.name} title={field.title} placeholder={field.placeholder} defaultValue={field.name === "content" ? draftText : fieldValue(submittedValues, field.name)} onChange={field.name === "content" ? setDraftText : undefined} />
      ) : (
        <Form.TextField key={field.name} id={field.name} title={field.title} placeholder={field.placeholder} defaultValue={fieldValue(submittedValues, field.name)} />
      ))}
    </Form>
  );
}
