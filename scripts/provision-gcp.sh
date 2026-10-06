#!/bin/bash
# One-time GCP provisioning for the nightly bench. Idempotent — safe to re-run,
# and re-running is how you verify the live project still matches this file.
#
# What the nightly needs on GCP, and nothing more:
#   - a Workload Identity pool + OIDC provider pinned to THIS repo, so the
#     workflow authenticates with no stored key;
#   - sbg-bench-ci, the identity the workflow federates into: it may create and
#     delete instances and touch the bench bucket;
#   - sbg-bench-vm, attached to the bench box itself: bucket objects only, no
#     compute rights, so a compromised bench box cannot launch anything;
#   - the bucket holding corpus.json, results and the done-signal.
#
# The repo pin matters: search-benchmark-game is PUBLIC. The attribute
# condition is what stops any other repo's OIDC token from minting these
# credentials, and the two-account split is what keeps the box's own identity
# narrower than the workflow's.
set -euo pipefail

PROJECT="infino-dev-ci"
PROJECT_NUMBER="309265046192"
REGION="us-central1"
BUCKET="sbg-bench-corpus"
REPO="infino-ai/search-benchmark-game"
POOL="github-pool"
PROVIDER="search-benchmark-game"
CI_SA="sbg-bench-ci@${PROJECT}.iam.gserviceaccount.com"
VM_SA="sbg-bench-vm@${PROJECT}.iam.gserviceaccount.com"
PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

say() { echo "==> $*"; }

say "APIs"
gcloud services enable \
  iamcredentials.googleapis.com sts.googleapis.com \
  compute.googleapis.com storage.googleapis.com --project "$PROJECT"

say "service accounts"
gcloud iam service-accounts describe "$CI_SA" --project "$PROJECT" >/dev/null 2>&1 || \
  gcloud iam service-accounts create sbg-bench-ci --project "$PROJECT" \
    --display-name "SBG nightly bench CI (GitHub OIDC)"
gcloud iam service-accounts describe "$VM_SA" --project "$PROJECT" >/dev/null 2>&1 || \
  gcloud iam service-accounts create sbg-bench-vm --project "$PROJECT" \
    --display-name "SBG nightly bench VM"

say "workload identity pool + repo-pinned provider"
gcloud iam workload-identity-pools describe "$POOL" \
  --project "$PROJECT" --location global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$POOL" \
    --project "$PROJECT" --location global \
    --display-name "GitHub Actions" \
    --description "OIDC federation for infino-ai GitHub Actions"

gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project "$PROJECT" --location global --workload-identity-pool "$POOL" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --project "$PROJECT" --location global --workload-identity-pool "$POOL" \
    --display-name "$PROVIDER" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition "assertion.repository=='${REPO}'"

say "bucket"
gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" >/dev/null 2>&1 || \
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" \
    --location "$REGION" --uniform-bucket-level-access --public-access-prevention

say "IAM"
# only this repo's OIDC tokens may become sbg-bench-ci
gcloud iam service-accounts add-iam-policy-binding "$CI_SA" --project "$PROJECT" \
  --role roles/iam.workloadIdentityUser --member "$PRINCIPAL" >/dev/null
# ...which may attach the (narrower) VM identity to an instance it creates
gcloud iam service-accounts add-iam-policy-binding "$VM_SA" --project "$PROJECT" \
  --role roles/iam.serviceAccountUser --member "serviceAccount:$CI_SA" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT" \
  --role roles/compute.instanceAdmin.v1 --member "serviceAccount:$CI_SA" --condition=None >/dev/null
# bucket objects, on this one bucket, for both
for SA in "$CI_SA" "$VM_SA"; do
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --project "$PROJECT" \
    --role roles/storage.objectAdmin --member "serviceAccount:$SA" >/dev/null
done

say "done. The workflow references:"
echo "  workload_identity_provider: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
echo "  service_account:            ${CI_SA}"
echo
echo "The bucket still needs corpus.json — see RUNNING.md."
