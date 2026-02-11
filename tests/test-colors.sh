#!/bin/bash
# test-colors.sh -- Tests for project color lookup
#
# Verifies that:
#   - Default color returns Discord blurple (5793266)
#   - Custom color from colors.conf is returned
#   - Invalid/non-numeric color in config is ignored (falls back to default)
#   - Missing colors.conf uses default

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

# -- Tests --

# 1. Default color for unknown project (no colors.conf)
rm -f "$NOTIFY_DIR/colors.conf"
result=$(get_project_color "random-project")
assert_eq "Default color is Discord blurple (5793266)" "5793266" "$result"

# 2. Default color for another unknown project (no colors.conf)
result=$(get_project_color "another-project")
assert_eq "Another project also gets default blurple" "5793266" "$result"

# 3. Custom color from colors.conf
cat > "$NOTIFY_DIR/colors.conf" << 'EOF'
my-cool-project=1752220
work-project=10181046
EOF
result=$(get_project_color "my-cool-project")
assert_eq "Custom color for my-cool-project" "1752220" "$result"

result=$(get_project_color "work-project")
assert_eq "Custom color for work-project" "10181046" "$result"

# 4. Project not in colors.conf falls back to default
result=$(get_project_color "unlisted-project")
assert_eq "Unlisted project falls back to default" "5793266" "$result"

# 5. Invalid (non-numeric) color is ignored, falls back to default
cat > "$NOTIFY_DIR/colors.conf" << 'EOF'
bad-project=not-a-number
hex-project=#FF5733
empty-project=
good-project=3066993
EOF

result=$(get_project_color "bad-project")
assert_eq "Non-numeric color ignored, falls back to default" "5793266" "$result"

result=$(get_project_color "hex-project")
assert_eq "Hex color string ignored, falls back to default" "5793266" "$result"

result=$(get_project_color "empty-project")
assert_eq "Empty color value ignored, falls back to default" "5793266" "$result"

# 6. Valid color in same file still works
result=$(get_project_color "good-project")
assert_eq "Valid color in mixed config file still works" "3066993" "$result"

# 7. Missing colors.conf entirely
rm -f "$NOTIFY_DIR/colors.conf"
result=$(get_project_color "any-project")
assert_eq "Missing colors.conf uses default" "5793266" "$result"

# 8. Colors.conf with comments and blank lines
cat > "$NOTIFY_DIR/colors.conf" << 'EOF'
# This is a comment

fancy-project=15105570

# Another comment
plain-project=9807270
EOF

result=$(get_project_color "fancy-project")
assert_eq "Color read correctly with comments in file" "15105570" "$result"

result=$(get_project_color "plain-project")
assert_eq "Second color read correctly with comments in file" "9807270" "$result"

# 9. First match wins when duplicate project names
cat > "$NOTIFY_DIR/colors.conf" << 'EOF'
dupe-project=1111111
dupe-project=2222222
EOF

result=$(get_project_color "dupe-project")
assert_eq "First match wins for duplicate project names" "1111111" "$result"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
