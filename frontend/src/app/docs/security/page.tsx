import { DocsLayout } from "../DocsLayout";
import { MarkdownRenderer } from "../MarkdownRenderer";
import { SECURITY_FIXES_MD } from "../content/securityFixes";

export default function SecurityPage() {
  return (
    <DocsLayout title="Security">
      <MarkdownRenderer content={SECURITY_FIXES_MD} />
    </DocsLayout>
  );
}
