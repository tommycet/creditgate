import { DocsLayout } from "../DocsLayout";
import { MarkdownRenderer } from "../MarkdownRenderer";
import { ARCHITECTURE_MD } from "../content/architecture";

export default function ArchitecturePage() {
  return (
    <DocsLayout title="Architecture">
      <MarkdownRenderer content={ARCHITECTURE_MD} />
    </DocsLayout>
  );
}
