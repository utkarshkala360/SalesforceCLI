#!/usr/bin/env bash
# Authorizes an org with a browser session ID (sid cookie). For Subscriber
# Access / one-time login URL sessions, where `sf org login web` can't be used
# because the session can't approve OAuth and there are no credentials.
# Prefer scripts/auth/connect.mjs, which reads the cookie from the browser for you;
# this script is the manual fallback.
#
# Get the sid: in the logged-in browser open https://<mydomain>.my.salesforce.com/services/data/,
# then DevTools > Application > Cookies > that my.salesforce.com domain > sid.
# The sid from lightning.force.com / file.force.com is UI-only and is rejected by the API.
#
# Usage: scripts/auth/login-sid.sh <orgId> [sid with only !... part]                       re-auth an org already in `sf org list`
#        scripts/auth/login-sid.sh <orgId> [sid with only !... part] -u <instanceUrl> -a <alias>   first time
# Leave out the sid to be prompted for it (keeps it out of shell history).
# The login lasts only as long as the browser session.

set -euo pipefail

usage() { sed -n '12,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

ORG_ID="" SID="" INSTANCE_URL="" ALIAS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--instance-url) INSTANCE_URL="${2:-}"; shift 2 ;;
        -a|--alias) ALIAS="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) if [[ -z "$ORG_ID" ]]; then ORG_ID="$1"; elif [[ -z "$SID" ]]; then SID="$1"; else usage; fi; shift ;;
    esac
done
[[ -n "$ORG_ID" ]] || usage

ORG15="${ORG_ID:0:15}"
if [[ ! "$ORG15" =~ ^00D[0-9A-Za-z]{12}$ ]]; then
    echo "Org ID must start with 00D and be 15 or 18 characters: $ORG_ID" >&2; exit 1
fi

if [[ -z "$SID" ]]; then
    read -r -s -p "Paste sid: " SID; echo
fi
SID="$(printf '%s' "$SID" | tr -d '[:space:]')"
# The cookie value is "<orgId15>!<token>"; DevTools sometimes shows only the "!..." part.
if [[ "$SID" == '!'* ]]; then
    SID="$ORG15$SID"
elif [[ "${SID:0:15}" != "$ORG15" ]]; then
    echo "The sid belongs to org ${SID:0:15}, not $ORG15." >&2; exit 1
fi

# Fill instance URL / alias from an existing auth for this org.
if [[ -z "$INSTANCE_URL" || -z "$ALIAS" ]]; then
    existing="$(sf org list --json 2>/dev/null \
        | jq -c --arg id "$ORG15" '[.result[][]? | select(.orgId | startswith($id))] | first // empty')"
    if [[ -n "$existing" ]]; then
        [[ -n "$INSTANCE_URL" ]] || INSTANCE_URL="$(jq -r '.instanceUrl // empty' <<<"$existing")"
        [[ -n "$ALIAS" ]] || ALIAS="$(jq -r '.alias // empty' <<<"$existing")"
    fi
fi
if [[ -z "$INSTANCE_URL" || -z "$ALIAS" ]]; then
    echo "Org $ORG15 isn't authorized yet. Pass -u https://<mydomain>.my.salesforce.com and -a \"<Customer> - Production\"." >&2
    exit 1
fi
if [[ "$INSTANCE_URL" == *lightning.force.com* ]]; then
    INSTANCE_URL="${INSTANCE_URL/.lightning.force.com/.my.salesforce.com}"
fi
INSTANCE_URL="${INSTANCE_URL%/}"

echo "Authorizing $ALIAS ($ORG15) at $INSTANCE_URL"
if ! SF_ACCESS_TOKEN="$SID" sf org login access-token \
        --instance-url "$INSTANCE_URL" --alias "$ALIAS" --no-prompt 2>&1 | grep -v "update available"; then
    # Some subscriber sessions are valid for the REST API but /services/oauth2/userinfo
    # redirects them to logout.jsp, and the CLI needs userinfo to find the username.
    # Fallback: get the username over REST and save the auth through the CLI's own
    # @salesforce/core, so the token is encrypted like a normal login.
    echo "CLI login failed; saving the session directly instead."
    rest() { curl -sf -H "Authorization: Bearer $SID" "$INSTANCE_URL/services/data/v62.0/$1"; }
    USERNAME="$(rest chatter/users/me | jq -r '.username // empty')" || true
    ORG18="$(rest 'query?q=SELECT+Id+FROM+Organization' | jq -r '.records[0].Id // empty')" || true
    if [[ -z "$USERNAME" || -z "$ORG18" ]]; then
        echo "The API rejected the sid. Use the sid from the my.salesforce.com cookie, not lightning.force.com." >&2
        exit 1
    fi
    SF_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v sf)")")")"
    CORE="$SF_ROOT/node_modules/@salesforce/core"
    NODE="$SF_ROOT/bin/node"; [[ -x "$NODE" ]] || NODE=node
    [[ -d "$CORE" ]] || { echo "Can't find @salesforce/core under $SF_ROOT." >&2; exit 1; }
    SF_CORE="$CORE" SF_SID="$SID" SF_USER="$USERNAME" SF_URL="$INSTANCE_URL" SF_ORGID="$ORG18" "$NODE" -e '
        const { StateAggregator } = require(process.env.SF_CORE);
        (async () => {
            const e = process.env, sa = await StateAggregator.getInstance();
            sa.orgs.set(e.SF_USER, { username: e.SF_USER, accessToken: e.SF_SID, instanceUrl: e.SF_URL,
                loginUrl: e.SF_URL, orgId: e.SF_ORGID, isDevHub: false });
            await sa.orgs.write(e.SF_USER);
        })().catch((err) => { console.error(err.message); process.exit(1); });'
    sf alias set "$ALIAS=$USERNAME" >/dev/null 2>&1
    echo "Saved session for $USERNAME with org ID $ORG18"
fi

sf data query -o "$ALIAS" -q "SELECT Name FROM Organization" 2>/dev/null \
    | grep -v -i "querying\|total number" || { echo "Authorized, but the test query failed." >&2; exit 1; }
