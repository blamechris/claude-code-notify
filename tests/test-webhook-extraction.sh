#!/bin/bash
# test-webhook-extraction.sh -- Tests for webhook ID/token extraction robustness
#
# Verifies that:
#   - Standard Discord webhook URLs are parsed correctly
#   - URLs with query parameters are handled
#   - URLs with trailing slashes are handled
#   - URLs with fragments are handled
#   - Invalid or malformed URLs are rejected
#   - Extracted tokens match expected format

set -uo pipefail

[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

# -- Tests --

# 1. Standard Discord webhook URL
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/123456789/abcdefghijk")
assert_eq "Standard webhook URL" "123456789/abcdefghijk" "$result"

# 2. Webhook URL with ?wait=true parameter
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/123456789/abcdefghijk?wait=true")
assert_eq "Webhook URL with query parameter" "123456789/abcdefghijk" "$result"

# 3. Webhook URL with trailing slash
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/123456789/abcdefghijk/")
assert_eq "Webhook URL with trailing slash" "123456789/abcdefghijk" "$result"

# 4. Webhook URL with trailing slash and query parameter
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/123456789/abcdefghijk/?wait=true")
assert_eq "Webhook URL with trailing slash and query parameter" "123456789/abcdefghijk" "$result"

# 5. Webhook URL with dashes and underscores in token
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/987654321/xyz-789_123")
assert_eq "Webhook URL with dashes and underscores" "987654321/xyz-789_123" "$result"

# 6. Webhook URL with fragment
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/123456789/abcdefg123456#fragment")
assert_eq "Webhook URL with fragment" "123456789/abcdefg123456" "$result"

# 7. Multiple query parameters
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/123456789/abcdefghijk?wait=true&thread_id=456")
assert_eq "Webhook URL with multiple query parameters" "123456789/abcdefghijk" "$result"

# 8. Invalid URL - missing token (should fail)
assert_false "Invalid URL (missing token) correctly rejected" extract_webhook_id_token "https://discord.com/api/webhooks/123456789/"

# 9. Invalid URL - non-numeric ID (should fail)
assert_false "Invalid URL (non-numeric ID) correctly rejected" extract_webhook_id_token "https://discord.com/api/webhooks/abc/defghijk"

# 10. Invalid URL - empty token (should fail)
assert_false "Invalid URL (empty token) correctly rejected" extract_webhook_id_token "https://discord.com/api/webhooks/123456789/\?"

# 11. Very long IDs and tokens (should still work)
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/999888777666555444/abcdefghijklmnopqrstuvwxyz0123456789abcd")
assert_eq "Webhook URL with very long ID and token" "999888777666555444/abcdefghijklmnopqrstuvwxyz0123456789abcd" "$result"

# 12. Short IDs and tokens (should still work)
result=$(extract_webhook_id_token "https://discord.com/api/webhooks/1/a")
assert_eq "Webhook URL with short ID and token" "1/a" "$result"

# -- Webhook URL format validation tests --

# Helper to check if URL triggers a warning
validate_webhook_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https://discord\.com/api/webhooks/[0-9]+/ ]] && \
       [[ ! "$url" =~ ^https://discordapp\.com/api/webhooks/[0-9]+/ ]]; then
        return 1
    fi
    return 0
}

# 13. Valid discord.com webhook URL passes validation
assert_true "Valid discord.com URL passes" validate_webhook_url "https://discord.com/api/webhooks/123456789/abctoken"

# 14. Valid discordapp.com webhook URL passes validation
assert_true "Valid discordapp.com URL passes" validate_webhook_url "https://discordapp.com/api/webhooks/123456789/abctoken"

# 15. Random URL fails validation
assert_false "Random URL fails validation" validate_webhook_url "https://example.com/webhook"

# 16. Empty URL fails validation
assert_false "Empty URL fails validation" validate_webhook_url ""

# 17. HTTP (non-HTTPS) URL fails validation
assert_false "HTTP URL fails validation" validate_webhook_url "http://discord.com/api/webhooks/123/abc"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
