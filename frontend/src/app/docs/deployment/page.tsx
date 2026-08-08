import { DocsLayout } from "../DocsLayout";
import { MarkdownRenderer } from "../MarkdownRenderer";
import { LIVE_DEPLOYMENT_MD } from "../content/liveDeployment";
import { FDC_ATTESTATION_MD } from "../content/fdcAttestation";

export default function DeploymentPage() {
  return (
    <DocsLayout title="Deployment">
      <MarkdownRenderer content={LIVE_DEPLOYMENT_MD} />
      <div className="border-t border-slate-800 my-8" />
      <MarkdownRenderer content={FDC_ATTESTATION_MD} />
    </DocsLayout>
  );
}
