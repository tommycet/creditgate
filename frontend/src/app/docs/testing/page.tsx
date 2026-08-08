import { DocsLayout } from "../DocsLayout";
import { MarkdownRenderer } from "../MarkdownRenderer";
import { TEST_SUMMARY_MD } from "../content/testSummary";

export default function TestingPage() {
  return (
    <DocsLayout title="Testing">
      <MarkdownRenderer content={TEST_SUMMARY_MD} />
    </DocsLayout>
  );
}
