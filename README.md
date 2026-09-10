# automate-auths

A tiny utility that:

1. Generates a **Google OAuth refresh token** (device‑code flow) for the `https://www.googleapis.com/auth/adwords` scope.
2. Updates the **same Bitwarden secret objects** (preserving their UUIDs) with:
   - `CLIENT_ID`
   - `CLIENT_SECRET`
   - `REFRESH_TOKEN`
3. (Optional) Mirrors those values to **Cloudflare Workers secrets** via `wrangler`.

---

## Prerequisites

| Tool | Install |
|------|---------|
| **Bitwarden CLI** (`bw`) + **bws** wrapper | `brew install bitwarden-cli && npm i -g bws` |
| **jq** (JSON parser) | `brew install jq` |
| **curl** (standard) | pre‑installed |
| **wrangler** (optional, for Cloudflare) | `npm i -g @cloudflare/wrangler` |
| **Google OAuth desktop client** – create one in Google Cloud Console and note the `client_id` & `client_secret`. |

---

## Environment variables

```bash
export GOOGLE_CLIENT_ID="YOUR_CLIENT_ID.apps.googleusercontent.com"
export GOOGLE_CLIENT_SECRET="YOUR_CLIENT_SECRET"

# Bitwarden secret UUIDs (keep the same UUIDs)
export BW_UUID_CLIENT_ID="b19dbe68-6aec-4a4c-8396-b4bd0119fed9"
export BW_UUID_CLIENT_SECRET="a4e931aa-0be5-4fd7-bd2f-b4bd011a4104"
export BW_UUID_REFRESH_TOKEN="d986f0d6-41e3-4fb3-84ae-b4bd011d0eb3"

# Bitwarden session key (run `bw login` then `bw unlock` and export $BW_SESSION)
export BITWARDEN_SESSION="YOUR_BW_SESSION"

# Optional Cloudflare vars (set if you want to sync to Workers)
export CF_ACCOUNT_ID="your-account-id"
export CF_SCRIPT_NAME="my-worker"
export CF_API_TOKEN="your-cloudflare-token"
```

---

## Usage

```bash
# 1️⃣ Log in to Bitwarden once (stores session key)
bw login
bw unlock   # copies $BW_SESSION to your shell

# 2️⃣ Run the script
./update-google-secrets.sh
```

The script will:
1. Prompt you to open a URL and enter a code (Google device‑code flow).
2. Poll until you approve, then capture the refresh token.
3. Update the three Bitwarden secrets **in‑place** (same UUIDs).
4. If Cloudflare vars are set, push the same values as Workers secrets.

---

## Automated refresh (GitHub Actions)

A workflow (`.github/workflows/refresh.yml`) is provided to run the script automatically on a schedule (default: daily at 03:00 UTC). It requires the same environment variables to be stored as **GitHub repository secrets**.

---

## Contributing

Feel free to open PRs to add support for other Google scopes, improve error handling, or extend the Cloudflare sync.
