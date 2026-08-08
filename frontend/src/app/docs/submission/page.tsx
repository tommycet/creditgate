import { DocsLayout } from "../DocsLayout";
import { MarkdownRenderer } from "../MarkdownRenderer";
import { SUBMISSION_MD } from "../content/submission";

export default function SubmissionPage() {
  return (
    <DocsLayout title="Submission">
      <MarkdownRenderer content={SUBMISSION_MD} />
    </DocsLayout>
  );
}
