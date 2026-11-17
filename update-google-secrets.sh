#!/usr/bin/env bash
# ------------------------------------------------------------
# update-google-secrets.sh
#   - Generates a Google OAuth refresh token (device flow)
#   - Updates Bitwarden secrets (preserving UUIDs)
#   - Optionally pushes the same values to Cloudflare Workers secrets
#   - Optionally pushes the same values to the OneCLI gateway vault
# ------------------------------------------------------------

set -euo pipefail

# ---- CONFIG ------------------------------------------------
# Required environment variables (export them before running)
#   GOOGLE_CLIENT_ID            – OAuth desktop client ID
#   GOOGLE_CLIENT_SECRET        – OAuth client secret
#   BW_UUID_CLIENT_ID           – Bitwarden secret UUID for client ID
#   BW_UUID_CLIENT_SECRET       – Bitwarden secret UUID for client secret
#   BW_UUID_REFRESH_TOKEN       – Bitwarden secret UUID for refresh token
#   BITWARDEN_SESSION           – "bw" session key (login + unlock first)
# Optional Cloudflare variables (set to enable CF sync)
#   CF_ACCOUNT_ID, CF_SCRIPT_NAME, CF_API_TOKEN
# Optional OneCLI variables (set ONECLI_API_KEY to enable OneCLI sync)
#   ONECLI_API_KEY              – OneCLI API key (oc_…); unset = skip stage
#   ONECLI_API_HOST             – OneCLI API base URL (default: https://onecli.assistedly.ai)
#   ONECLI_PROJECT              – OneCLI project slug (optional; CLI default used if unset)
#   ONECLI_SECRET_CLIENT_ID     – secret name for client ID (default: GOOGLE_OAUTH_CLIENT_ID)
#   ONECLI_SECRET_CLIENT_SECRET – secret name for client secret (default: GOOGLE_OAUTH_CLIENT_SECRET)
#   ONECLI_SECRET_REFRESH_TOKEN – secret name for refresh token (default: GOOGLE_OAUTH_REFRESH_TOKEN)
# ------------------------------------------------------------

# Verify required vars
required_vars=(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET BW_UUID_CLIENT_ID BW_UUID_CLIENT_SECRET BW_UUID_REFRESH_TOKEN BITWARDEN_SESSION)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "❌ Missing required env var: $v"
    exit 1
  fi
done

# ---- 1️⃣ Device flow to obtain refresh token ----
DEVICE_RESP=$(curl -s -X POST \
  -d "client_id=${GOOGLE_CLIENT_ID}&scope=https://www.googleapis.com/auth/adwords" \
  https://oauth2.googleapis.com/device/code)

DEVICE_CODE=$(jq -r .device_code <<<"$DEVICE_RESP")
USER_CODE=$(jq -r .user_code <<<"$DEVICE_RESP")
VERIF_URL=$(jq -r .verification_url <<<"$DEVICE_RESP")
INTERVAL=$(jq -r .interval <<<"$DEVICE_RESP")
EXPIRES_IN=$(jq -r .expires_in <<<"$DEVICE_RESP")

echo "\n🔐 Open the following URL and enter the code to authorise:";
printf "   %s\n   Code: %s\n\n" "$VERIF_URL" "$USER_CODE"

END_TIME=$(( $(date +%s) + EXPIRES_IN ))
while (( $(date +%s) < END_TIME )); do
  sleep "$INTERVAL"
  TOKEN_RESP=$(curl -s -X POST \
    -d "client_id=${GOOGLE_CLIENT_ID}&client_secret=${GOOGLE_CLIENT_SECRET}&device_code=${DEVICE_CODE}&grant_type=urn:ietf:params:oauth:grant-type:device_code" \
    https://oauth2.googleapis.com/token)
  ERROR=$(jq -r .error <<<"$TOKEN_RESP")
  if [[ "$ERROR" == "authorization_pending" ]]; then
    continue
  elif [[ "$ERROR" != "null" && -n "$ERROR" ]]; then
    echo "❌ OAuth error: $ERROR"
    exit 1
  else
    REFRESH_TOKEN=$(jq -r .refresh_token <<<"$TOKEN_RESP")
    break
  fi
done

if [[ -z "${REFRESH_TOKEN:-}" ]]; then
  echo "❌ Failed to obtain refresh token"
  exit 1
fi

echo "✅ Refresh token obtained"

# ---- 2️⃣ Update Bitwarden secrets (using bws wrapper) ----
# bws secret edit <uuid> --value "<value>"

bws secret edit "$BW_UUID_CLIENT_ID" --value "$GOOGLE_CLIENT_ID"
bws secret edit "$BW_UUID_CLIENT_SECRET" --value "$GOOGLE_CLIENT_SECRET"
bws secret edit "$BW_UUID_REFRESH_TOKEN" --value "$REFRESH_TOKEN"

echo "✅ Bitwarden secrets updated"

# ---- 3️⃣ Optional Cloudflare secret sync ----
if [[ -n "${CF_ACCOUNT_ID:-}" && -n "${CF_SCRIPT_NAME:-}" && -n "${CF_API_TOKEN:-}" ]]; then
  echo "🔄 Syncing to Cloudflare Workers secrets..."
  printf "%s" "$GOOGLE_CLIENT_ID" | wrangler secret put GOOGLE_OAUTH_CLIENT_ID --account-id "$CF_ACCOUNT_ID" --script "$CF_SCRIPT_NAME" --env production
  printf "%s" "$GOOGLE_CLIENT_SECRET" | wrangler secret put GOOGLE_OAUTH_CLIENT_SECRET --account-id "$CF_ACCOUNT_ID" --script "$CF_SCRIPT_NAME" --env production
  printf "%s" "$REFRESH_TOKEN" | wrangler secret put GOOGLE_OAUTH_REFRESH_TOKEN --account-id "$CF_ACCOUNT_ID" --script "$CF_SCRIPT_NAME" --env production
  echo "✅ Cloudflare secrets updated"
else
  echo "⚠️ Cloudflare vars not set – skipping CF sync"
fi

# ---- 4️⃣ Optional OneCLI gateway sync ----
if [[ -n "${ONECLI_API_KEY:-}" ]]; then
  echo "🔄 Syncing to OneCLI gateway..."
  command -v onecli >/dev/null 2>&1 || {
    echo "❌ onecli CLI not found – install with: curl -fsSL onecli.sh/cli/install | sh"
    exit 1
  }
  # The onecli CLI reads ONECLI_API_KEY / ONECLI_API_HOST / ONECLI_PROJECT from env.
  export ONECLI_API_HOST="${ONECLI_API_HOST:-https://onecli.assistedly.ai}"

  # Idempotent upsert: update the secret if it exists, otherwise create it.
  onecli_secret_upsert() {
    local name="$1" value="$2" host="$3"
    local existing_id
    existing_id=$(onecli secrets list --fields id,name --max 200 \
      | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -n1)
    if [[ -n "$existing_id" ]]; then
      onecli secrets update --id "$existing_id" --value "$value" >/dev/null
      echo "   ✅ updated OneCLI secret: $name"
    else
      onecli secrets create --name "$name" --type generic \
        --value "$value" --host-pattern "$host" >/dev/null
      echo "   ✅ created OneCLI secret: $name"
    fi
  }

  onecli_secret_upsert "${ONECLI_SECRET_CLIENT_ID:-GOOGLE_OAUTH_CLIENT_ID}" \
    "$GOOGLE_CLIENT_ID" "*.googleapis.com"
  onecli_secret_upsert "${ONECLI_SECRET_CLIENT_SECRET:-GOOGLE_OAUTH_CLIENT_SECRET}" \
    "$GOOGLE_CLIENT_SECRET" "*.googleapis.com"
  onecli_secret_upsert "${ONECLI_SECRET_REFRESH_TOKEN:-GOOGLE_OAUTH_REFRESH_TOKEN}" \
    "$REFRESH_TOKEN" "*.googleapis.com"
  echo "✅ OneCLI secrets updated"
else
  echo "⚠️ ONECLI_API_KEY not set – skipping OneCLI sync"
fi

echo "\n🎉 All done! 🎉"
