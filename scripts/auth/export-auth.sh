#!/usr/bin/env bash
# Exports an authorized org's login details (org display + access token + SFDX
# auth URL) to one JSON file, so a teammate can log in without your passkey:
#   sf org login sfdx-url --sfdx-url-file auth-exports/<name>.json --alias <alias>
# The file holds a refresh token that acts as you until revoked (Setup > Users >
# your user > OAuth Connected Apps). Share it only over a secure channel, then delete it.
#
# Usage: scripts/auth/export-auth.sh            pick the org from a list
#        scripts/auth/export-auth.sh <alias>    skip the list
# Writes auth-exports/<alias_with_underscores>.json (git-ignored, chmod 600).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/auth-exports"

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    # sf org list repeats an org under several groups (sandboxes, nonScratchOrgs, ...), so dedupe by username
    ORGS=()
    while IFS= read -r line; do ORGS+=("$line"); done < <(
        sf org list --json 2>/dev/null | jq -r '
            [.result | to_entries[] | .value | arrays | .[]]
            | unique_by(.username)[]
            | "\(.alias // .username)\t\(.username)"')
    [[ ${#ORGS[@]} -gt 0 ]] || { echo "No authorized orgs found. Run sf org login web first." >&2; exit 1; }

    PS3="Pick an org: "
    select choice in "${ORGS[@]}"; do
        [[ -n "${choice:-}" ]] && break
    done
    TARGET="${choice%%$'\t'*}"
fi

# "Govche - Sandbox" -> govche_sandbox
NAME="$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g')"
OUT="$OUT_DIR/$NAME.json"
mkdir -p "$OUT_DIR"
umask 077

echo "Exporting '$TARGET' -> ${OUT#$ROOT/}"
DISPLAY_JSON="$(sf org display --target-org "$TARGET" --verbose --json 2>/dev/null)" \
    || { echo "sf org display failed for '$TARGET'." >&2; exit 1; }

# --json skips the confirmation prompt on both commands
TOKEN_JSON="$(sf org auth show-access-token --target-org "$TARGET" --json 2>/dev/null || echo '{}')"
URL_JSON="$(sf org auth show-sfdx-auth-url --target-org "$TARGET" --json 2>/dev/null || echo '{}')"

printf '%s' "$DISPLAY_JSON" | jq --argjson t "$TOKEN_JSON" --argjson u "$URL_JSON" \
    '.result += (($t.result // {}) + ($u.result // {}))' > "$OUT"
chmod 600 "$OUT"

jq -e '.result.sfdxAuthUrl // empty | startswith("force://")' "$OUT" >/dev/null \
    || echo "Warning: no sfdxAuthUrl (org was not logged in with sf org login web). Teammates can't log in from this file." >&2
jq -e '.result.accessToken // empty' "$OUT" >/dev/null \
    || echo "Warning: no access token in the export." >&2

echo "Done. Teammate runs:"
echo "  sf org login sfdx-url --sfdx-url-file $NAME.json --alias $NAME"
