#!/bin/bash
# ==============================================================================
# deploy-tee.sh — CreditGate FCC TEE Python handler
#
# Build → push → deploy the CreditGate credit handler to GCP Confidential Space
# running on Intel TDX. Adapted from the official flare-ai-kit deploy-tee.sh
# (https://github.com/flare-foundation/flare-ai-kit/blob/main/deploy-tee.sh).
#
# Three phases:
#   1. Build the Docker image with the Dockerfile next to this script
#   2. Push the image to Artifact Registry (requires gcloud + docker auth)
#   3. Provision a Confidential Space instance from the image, passing the
#      CreditGate env vars through Confidential Space `tee-env-*` metadata keys
#      so they land inside the enclave at boot.
#
# Prerequisites (see .env.example):
#   - gcloud CLI authenticated against the project below
#   - .env filled in (sourced at the start of this script)
#   - Artifact Registry repo exists (one-time: gcloud artifacts repositories create ...)
# ==============================================================================
set -e

# --- 1. Helpers ----------------------------------------------------------------
log_info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_succ()  { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
log_err()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

usage() {
    echo "Usage: $0 [options]"
    echo
    echo "Builds, pushes, and deploys the CreditGate FCC TEE Python handler to"
    echo "GCP Confidential Space (Intel TDX)."
    echo
    echo "Options:"
    echo "  --image-tag <tag>   Override the image tag (default: latest)"
    echo "  --skip-build        Skip Docker build/push, only deploy infrastructure"
    echo "  --skip-deploy        Skip infra deploy, only build Docker"
    echo "  --force-yes          Skip confirmation prompts"
    echo "  --help               Show this message"
    exit 1
}

# --- 2. Argument parsing -------------------------------------------------------
IMAGE_TAG="latest"
DO_BUILD=true
DO_DEPLOY=true
FORCE_YES=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --image-tag)   IMAGE_TAG="$2"; shift ;;
        --skip-build)  DO_BUILD=false ;;
        --skip-deploy) DO_DEPLOY=false ;;
        --force-yes)   FORCE_YES=true ;;
        --help)        usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# --- 3. Source .env ------------------------------------------------------------
# This is the contract: the operator fills .env from .env.example and runs
# ./deploy-tee.sh. Environment drives every gcloud flag below.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    log_info "Sourcing .env from $SCRIPT_DIR/.env ..."
    set -a; source .env; set +a
else
    log_err ".env file not found at $SCRIPT_DIR/.env — copy .env.example and fill it in."
    exit 1
fi

# Mandatory GCP variables.
: "${GCP__TEE_IMAGE_REFERENCE:?Please set GCP__TEE_IMAGE_REFERENCE in .env (e.g. us-central1-docker.pkg.dev/<proj>/creditgate/fcc-tee)}"
: "${GCP__PROJECT:?Please set GCP__PROJECT in .env}"
: "${GCP__ZONE:?Please set GCP__ZONE in .env}"
: "${GCP__MACHINE_TYPE:?Please set GCP__MACHINE_TYPE in .env}"
: "${GCP__SERVICE_ACCOUNT:?Please set GCP__SERVICE_ACCOUNT in .env}"
: "${GCP__CONFIDENTIAL_IMAGE:?Please set GCP__CONFIDENTIAL_IMAGE in .env}"
: "${GCP__CONFIDENTIAL_COMPUTE_TYPE:?Please set GCP__CONFIDENTIAL_COMPUTE_TYPE in .env (TDX or SEV)}"

# CreditGate-specific mandatory variables.
: "${FLARE__RPC_URL:?Please set FLARE__RPC_URL in .env (Coston2 or mainnet)}"
: "${VAULT__ADDRESS:?Please set VAULT__ADDRESS in .env}"

TARGET_IMAGE="${GCP__TEE_IMAGE_REFERENCE}:${IMAGE_TAG}"
log_info "Configuration:"
echo "  Target image:              $TARGET_IMAGE"
echo "  GCP project:               $GCP__PROJECT"
echo "  Zone:                      $GCP__ZONE"
echo "  Machine type:              $GCP__MACHINE_TYPE"
echo "  Confidential compute type: $GCP__CONFIDENTIAL_COMPUTE_TYPE"
echo "  Vault address:             $VAULT__ADDRESS"
echo "  Flare RPC:                 $FLARE__RPC_URL"

# ==============================================================================
# PHASE 1: DOCKER BUILD & PUSH
# ==============================================================================
if [ "$DO_BUILD" = true ]; then
    log_info "Phase 1/3: Building Docker image..."
    # --platform linux/amd64 pins TDX-compatible x86_64 images.
    docker build \
        --platform linux/amd64 \
        -t "$TARGET_IMAGE" \
        -f Dockerfile \
        "$SCRIPT_DIR"

    log_info "Authenticating Docker to Artifact Registry..."
    # Operate-region-aware setup. NOOP if already authed.
    REGION_PREFIX=$(echo "$GCP__TEE_IMAGE_REFERENCE" | sed -E 's|^(.*)-docker.pkg.dev.*$|\1|')
    gcloud auth print-access-token | docker login -u oauth2accesstoken \
        --password-stdin "https://${REGION_PREFIX}-docker.pkg.dev" || true

    log_info "Pushing $TARGET_IMAGE to Artifact Registry..."
    docker push "$TARGET_IMAGE"
    log_succ "Phase 1 complete: image pushed to $TARGET_IMAGE"
else
    log_info "Skipping Phase 1 (build/push) per --skip-build"
fi

# ==============================================================================
# PHASE 2: BUILD TEE METADATA KEYS
# ==============================================================================
# Confidential Space passes env vars to the enclave via VM metadata keys
# prefixed `tee-env-<NAME>=<VAL>`. The runtime translates those to env vars
# inside the container. We pick every env var matching the CreditGate prefixes
# and add them to the gcloud --metadata flag. This mirrors flare-ai-kit's
# PREFIX_PATTERN approach but adapted to our own env-var namespaces.

PREFIX_PATTERN="^(FLARE__|VAULT__|TEE__|GCP__|CREDITGATE__|LOG_LEVEL|PORT)"
VAR_NAMES=$(printenv | grep -E "$PREFIX_PATTERN" | cut -d'=' -f1 | sort -u)

METADATA_VARS=""
if [ -n "$VAR_NAMES" ]; then
    for VAR_NAME in $VAR_NAMES; do
        VAR_VALUE="${!VAR_NAME}"
        if [ -n "$VAR_VALUE" ]; then
            # Pass both the legacy `tee-env-` and the newer `stee-env-` keys
            # so both Confidential Space runtime generations receive them.
            METADATA_VARS="${METADATA_VARS},tee-env-${VAR_NAME}=${VAR_VALUE},stee-env-${VAR_NAME}=${VAR_VALUE}"
        fi
    done
fi

# ==============================================================================
# PHASE 3: PROVISION CONFIDENTIAL SPACE INSTANCE
# ==============================================================================
if [ "$DO_DEPLOY" = true ]; then
    log_info "Phase 3/3: Provisioning Confidential Space instance..."

    INAME="${GCP__INSTANCE_NAME:-creditgate-fcc-tee}"
    if gcloud compute instances describe "$INAME" \
            --project="$GCP__PROJECT" --zone="$GCP__ZONE" \
            --format="json" >/dev/null 2>&1; then
        log_warn "Instance '$INAME' already exists."
        if [ "$FORCE_YES" = true ]; then
            REPLY="y"
        else
            read -p "Delete and redeploy? (y/N) " -n 1 -r; echo
        fi
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deleting existing instance '$INAME'..."
            gcloud compute instances delete "$INAME" \
                --project="$GCP__PROJECT" --zone="$GCP__ZONE" --quiet
        else
            log_err "Deployment cancelled."
            exit 1
        fi
    fi

    SCOPES="${GCP__SCOPES:-https://www.googleapis.com/auth/cloud-platform}"
    TAGS="${GCP__TAGS:-creditgate,http-server}"
    LOG_REDIRECT="${GCP__TEE_CONTAINER_LOG_REDIRECT:-true}"

    # Construct the gcloud create call. We pass the image via the
    # tee-image-reference / stee-image-reference metadata keys (Confidential
    # Space launches the image automatically inside the enclave).
    COMMAND=(
        gcloud compute instances create "$INAME"
        --project="$GCP__PROJECT"
        --zone="$GCP__ZONE"
        --machine-type="$GCP__MACHINE_TYPE"
        --network-interface="network-tier=PREMIUM,nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=default"
        --metadata="tee-image-reference=$TARGET_IMAGE,stee-image-reference=$TARGET_IMAGE,tee-container-log-redirect=$LOG_REDIRECT,stee-container-log-redirect=$LOG_REDIRECT${METADATA_VARS}"
        --maintenance-policy=TERMINATE
        --provisioning-model=STANDARD
        --service-account="$GCP__SERVICE_ACCOUNT"
        --scopes="$SCOPES"
        --tags="$TAGS"
        --create-disk="auto-delete=yes,boot=yes,device-name=$INAME,image=projects/confidential-space-images/global/images/$GCP__CONFIDENTIAL_IMAGE,mode=rw,size=20,type=pd-balanced"
        --shielded-secure-boot
        --shielded-vtpm
        --shielded-integrity-monitoring
        --reservation-affinity=any
        --confidential-compute-type="$GCP__CONFIDENTIAL_COMPUTE_TYPE"
    )

    log_info "Launching instance '$INAME' from image $TARGET_IMAGE ..."
    if [ "$FORCE_YES" != true ]; then
        read -p "Ready to deploy? Continue? (y/N) " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_err "Cancelled."
            exit 1
        fi
    fi

    "${COMMAND[@]}"
    log_succ "Instance '$INAME' deployed."
    echo
    log_info "Next steps:"
    echo "  1. Wait ~2-5 min for Confidential Space boot + attestation"
    echo "  2. Find the instance's serial-port-1 log in the GCP Console to see"
    echo "     'creditgate-fcc-tee listening on :8080 authority=0x...'"
    echo "  3. Copy the 'authority=' address — that's the TEE_AUTHORITY the vault"
    echo "     needs registered via setTeeAuthority() (admin function)."
    echo "  4. Reach the proxy through the Confidential Space VPC. The TEE itself"
    echo "     is sealed: only the proxy can call /action."
    echo
    echo "  Inspect serial logs:"
    echo "    gcloud compute connect-to-serial-port --project=\$GCP__PROJECT \\"
    echo "      --zone=\$GCP__ZONE $INAME --port=1"
else
    log_info "Skipping Phase 3 (deploy) per --skip-deploy"
fi
