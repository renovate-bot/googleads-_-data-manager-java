#!/bin/bash
set -euo pipefail
set -x

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# Ensure Java 17 is used on Kokoro Ubuntu 22.04 workers (which default to OpenJDK 11)
if [[ ! -d "/usr/lib/jvm/java-17-openjdk-amd64" ]]; then
  echo "ERROR: Kokoro worker missing expected OpenJDK 17 at /usr/lib/jvm/java-17-openjdk-amd64" >&2
  exit 1
fi
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
export PATH="${JAVA_HOME}/bin:${PATH}"

# 1. Clean, Test, Sign, and Publish to Artifact Registry
# Keyring / ADC handles authentication via the Kokoro BYOSA service account
# Keystore fetches the PGP signing key from Keystore config 74347
KEYSTORE_GPG_FILE="${KOKORO_KEYSTORE_DIR:-}/74347_google_ads_java_gpg_secring"
if [[ -n "${KOKORO_KEYSTORE_DIR:-}" && -f "${KEYSTORE_GPG_FILE}" ]]; then
  export SIGNING_KEY="$(cat "${KEYSTORE_GPG_FILE}")"
fi

if [[ -z "${SIGNING_KEY:-}" ]]; then
  echo "ERROR: SIGNING_KEY is not set and Keystore GPG file is missing (${KEYSTORE_GPG_FILE})." >&2
  exit 1
fi

./gradlew clean check publish --no-daemon

# 2. DRY_RUN Check
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo "=== DRY_RUN is enabled. Artifacts staged in Artifact Registry. ==="
  echo "Skipping GCS manifest upload to Exit Gate."
  exit 0
fi

# 3. Create Exit Gate Release Manifest
# Maven Central manifests require 'namespace' (groupId) and package 'name' (artifactId)
cat <<EOF > manifest.json
{
  "publish_all": false,
  "publishing_groups": [
    {
      "namespace": "com.google.api-ads",
      "packages": [
        {
          "name": "data-manager-util"
        }
      ]
    }
  ]
}
EOF

# 4. Trigger Exit Gate Release via GCS Manifest
EXIT_GATE_BUCKET="gs://oss-exit-gate-prod-projects-bucket/measurement-devrel/mavencentral/manifests"
MANIFEST_NAME="manifest-$(date +%Y%m%d%H%M%S).json"

echo "=== Uploading manifest to ${EXIT_GATE_BUCKET}/${MANIFEST_NAME} ==="
gcloud storage cp manifest.json "${EXIT_GATE_BUCKET}/${MANIFEST_NAME}"

echo "=== Release successfully triggered to OSS Exit Gate! ==="
