import { DocsLayout } from "../DocsLayout";
import { MarkdownRenderer } from "../MarkdownRenderer";
import { FDC_REAL_VERIFY_MD } from "../content/fdcRealVerify";

export default function FdcVerifyPage() {
  return (
    <DocsLayout title="FDC Real Verify">
      <MarkdownRenderer content={FDC_REAL_VERIFY_MD} />
    </DocsLayout>
  );
}
