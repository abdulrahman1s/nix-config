import { Icon } from "@vicinae/api";

export type Field = {
  name: string;
  title: string;
  placeholder: string;
  optional?: boolean;
  kind?: "cwd" | "textarea";
  picker?: "file" | "directory";
  options?: { value: string; title: string }[];
};

export type Workflow = {
  id: string;
  section: string;
  title: string;
  subtitle: string;
  guidance: string;
  icon: Icon;
  fields?: Field[];
};

const inputSource: Field = { name: "source", title: "Source", placeholder: "clipboard", options: [{ value: "clipboard", title: "Clipboard" }, { value: "text", title: "Enter text" }] };
const enteredText: Field = { name: "content", title: "Text", placeholder: "Used when Source is Enter text", kind: "textarea", optional: true };
const textFields = [inputSource, enteredText];

export const workflows: Workflow[] = [
  {
    id: "summarize-text", section: "Understand", title: "Summarize", subtitle: "Get the main point and key details",
    guidance: "A concise summary grounded in the source. You can name a topic to focus on.", icon: Icon.Text,
    fields: [...textFields, { name: "instruction", title: "Focus (optional)", placeholder: "Decisions and dates", optional: true }],
  },
  {
    id: "extract-actions", section: "Understand", title: "Extract action items", subtitle: "Find tasks, decisions, and open questions",
    guidance: "Creates a checklist from explicit tasks. Owners and dates appear only when provided.", icon: Icon.List,
    fields: textFields,
  },
  {
    id: "explain-text", section: "Understand", title: "Explain", subtitle: "Make complex text easier to follow",
    guidance: "Explains the source in plain language and points out what remains unclear.", icon: Icon.QuestionMark,
    fields: [...textFields, { name: "instruction", title: "Question (optional)", placeholder: "What does this error mean?", optional: true }],
  },
  {
    id: "translate-text", section: "Write", title: "Translate", subtitle: "Keep meaning, tone, and formatting",
    guidance: "Translate into the language you choose. Names and technical terms stay intact.", icon: Icon.Globe,
    fields: [...textFields, { name: "instruction", title: "Target language", placeholder: "Arabic" }],
  },
  {
    id: "rewrite-text", section: "Write", title: "Rewrite", subtitle: "Improve clarity without changing meaning",
    guidance: "Returns revised text only. Add a style or audience if you have one in mind.", icon: Icon.Pencil,
    fields: [...textFields, { name: "instruction", title: "Style or audience (optional)", placeholder: "Concise and professional", optional: true }],
  },
];
