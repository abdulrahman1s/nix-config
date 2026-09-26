import { Action, ActionPanel, List } from "@vicinae/api";
import { workflows } from "./catalog";
import { WorkflowForm } from "./workflow-view";

const sections = ["Understand", "Write"];

export default function PersonalAiWorkflows() {
  return (
    <List searchBarPlaceholder="Search AI workflows…" navigationTitle="Personal AI">
      {sections.map((section) => (
        <List.Section key={section} title={section}>
          {workflows.filter((workflow) => workflow.section === section).map((workflow) => (
            <List.Item key={workflow.id} title={workflow.title} subtitle={workflow.subtitle} icon={workflow.icon} actions={
              <ActionPanel>
                <Action.Push title={workflow.title} icon={workflow.icon} target={<WorkflowForm workflow={workflow} />} />
              </ActionPanel>
            } />
          ))}
        </List.Section>
      ))}
    </List>
  );
}
