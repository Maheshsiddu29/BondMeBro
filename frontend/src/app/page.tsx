import { Dashboard } from "@/components/dashboard";
import { DeploymentRequired } from "@/components/deployment-required";
import { Providers } from "@/components/providers";
import { deploymentStatus } from "@/lib/deployment";

/**
 * The deployment gate is the outermost decision in the app.
 *
 * Wallet providers, chain-bound reads and every contract hook only exist inside a verified
 * deployment, so there is no code path in which a hook could be called against an
 * unconfigured or inconsistent chain.
 */
export default function Home() {
  if (deploymentStatus.status !== "ready") {
    return <DeploymentRequired problems={deploymentStatus.problems} />;
  }

  return (
    <Providers deployment={deploymentStatus.deployment}>
      <Dashboard deployment={deploymentStatus.deployment} />
    </Providers>
  );
}
