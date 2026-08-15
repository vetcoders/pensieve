#!/usr/bin/env bash
# Landing-page (docs/index.html) download-panel checksum handling.
#
# The public download page advertises a SHA-256 for the DMG that
# releases/latest/download/Pensieve.dmg resolves to. That checksum is only
# worth printing if it belongs to the artifact this run actually produced, so
# the release script STAMPS it from the freshly notarized DMG instead of
# trusting a human to paste it. A marker-only check cannot do that job: after a
# failed run an operator can paste the checksum of the artifact that failed,
# and the next successful run produces a DIFFERENT DMG (PensieveBuildDate is
# baked into the app, and DMG creation is not byte-reproducible anyway), so the
# page would advertise a checksum that matches nothing downloadable.
#
# This file is meant to be SOURCED. It defines functions only: no `set` calls,
# no global state, no `exit`/`die`. Failures return non-zero and explain
# themselves on stderr, so the caller decides what fatal means. Every read is
# fail-closed: an unreadable or unparsable page is a failure, never a pass.
#
# Usage:
#   source "$SCRIPT_DIR/lib/landing-page.sh"
#   landing_page_assert_publishable "$PAGE" "$APP_VERSION" || …   # preflight
#   landing_page_stamp_checksum "$PAGE" "$DMG_SHA256" || …        # publish
#   landing_page_assert_checksum "$PAGE" "$DMG_SHA256" || …       # gate

# The one line that carries the advertised checksum, e.g.
#   <div class="sha"><b>SHA-256</b><br />…</div>
LANDING_PAGE_CHECKSUM_SLOT_PATTERN='class="sha"'
# A placeholder that must never reach a published page.
LANDING_PAGE_UNFILLED_MARKER='DO-NOT-SHIP'

# landing_page_readable <page> — 0 when the page exists and is readable.
# Split out so callers report "missing" and "unreadable" as distinct failures
# rather than folding both into a silent "no match".
landing_page_readable() {
    local page="${1:-}"

    if [[ -z "$page" ]]; then
        printf 'landing-page: usage: landing_page_readable <page>\n' >&2
        return 2
    fi
    if [[ ! -f "$page" ]]; then
        printf 'landing-page: no landing page at %s\n' "$page" >&2
        return 1
    fi
    if [[ ! -r "$page" ]]; then
        printf 'landing-page: %s exists but is not readable\n' "$page" >&2
        return 1
    fi
}

# landing_page_checksum_values <page> — prints one line per checksum slot with
# the advertised value (whitespace stripped), or `!unparsable` for a slot whose
# shape this lib no longer understands. No output means no slot at all.
landing_page_checksum_values() {
    local page="${1:-}"

    landing_page_readable "$page" || return $?
    /usr/bin/awk -v slot="$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" '
        index($0, slot) > 0 {
            line = $0
            if (match(line, /<br[^>]*>[^<]*<\/div>/)) {
                payload = substr(line, RSTART, RLENGTH)
                sub(/^<br[^>]*>/, "", payload)
                sub(/<\/div>$/, "", payload)
                gsub(/[ \t\r]/, "", payload)
                print payload
            } else {
                print "!unparsable"
            }
        }
    ' "$page" || {
        printf 'landing-page: could not parse %s\n' "$page" >&2
        return 1
    }
}

# landing_page_declared_version <page> — prints the version the download panel
# advertises (the <dd> next to <dt>Version</dt>). No output means the panel no
# longer declares one in the shape this lib understands.
landing_page_declared_version() {
    local page="${1:-}"

    landing_page_readable "$page" || return $?
    /usr/bin/awk '
        /<dt>Version<\/dt>/ {
            if (match($0, /<dd>[^<]*<\/dd>/)) {
                value = substr($0, RSTART + 4, RLENGTH - 9)
                gsub(/^[ \t\r]+|[ \t\r]+$/, "", value)
                print value
            }
        }
    ' "$page" || {
        printf 'landing-page: could not parse %s\n' "$page" >&2
        return 1
    }
}

# landing_page_assert_publishable <page> <expected_version>
#
#   0 — the page can be stamped at the end of this run
#   1 — missing/unreadable/unwritable page, no single stampable checksum slot,
#       or the panel advertises a different version than this release
#   2 — called wrong
#
# Runs BEFORE anything is built or published, so a page that cannot carry this
# release's checksum costs a preflight failure instead of a notarization round
# trip followed by an artifact already copied onto the team shelf.
landing_page_assert_publishable() {
    local page="${1:-}"
    local expected_version="${2:-}"
    local values version_values slot_count version_count

    if [[ -z "$page" || -z "$expected_version" ]]; then
        printf 'landing-page: usage: landing_page_assert_publishable <page> <expected_version>\n' >&2
        return 2
    fi

    landing_page_readable "$page" || return $?
    if [[ ! -w "$page" ]]; then
        printf 'landing-page: %s is not writable — the release cannot stamp this build'"'"'s checksum into it\n' "$page" >&2
        return 1
    fi

    values="$(landing_page_checksum_values "$page")" || return 1
    slot_count=0
    [[ -z "$values" ]] || slot_count="$(printf '%s\n' "$values" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    if (( slot_count != 1 )); then
        printf 'landing-page: %s must carry exactly one %s checksum slot, found %s\n' \
            "$page" "$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" "$slot_count" >&2
        return 1
    fi
    if [[ "$values" == "!unparsable" ]]; then
        printf 'landing-page: %s: the checksum slot is no longer <b>SHA-256</b><br />VALUE</div> — teach scripts/lib/landing-page.sh the new shape before releasing\n' \
            "$page" >&2
        return 1
    fi

    version_values="$(landing_page_declared_version "$page")" || return 1
    version_count=0
    [[ -z "$version_values" ]] || version_count="$(printf '%s\n' "$version_values" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    if (( version_count != 1 )); then
        printf 'landing-page: %s must declare exactly one download version (<dt>Version</dt><dd>…</dd>), found %s\n' \
            "$page" "$version_count" >&2
        return 1
    fi
    if [[ "$version_values" != "$expected_version" ]]; then
        printf 'landing-page: %s advertises version %s but this release is %s — update the download panel before publishing\n' \
            "$page" "$version_values" "$expected_version" >&2
        return 1
    fi
}

# landing_page_stamp_checksum <page> <sha256>
#
#   0 — the single checksum slot now carries <sha256>
#   1 — page unreadable, or not exactly one slot could be rewritten
#   2 — called wrong (missing args, or a value that is not a SHA-256)
#
# The file is rewritten in place (same inode, same permissions): everything
# outside the checksum slot stays byte-identical.
landing_page_stamp_checksum() {
    local page="${1:-}"
    local sha="${2:-}"
    local tmp status=0

    if [[ -z "$page" || -z "$sha" ]]; then
        printf 'landing-page: usage: landing_page_stamp_checksum <page> <sha256>\n' >&2
        return 2
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'landing-page: refusing to stamp a value that is not a lowercase SHA-256: %s\n' "$sha" >&2
        return 2
    fi
    landing_page_readable "$page" || return $?
    if [[ ! -w "$page" ]]; then
        printf 'landing-page: %s is not writable\n' "$page" >&2
        return 1
    fi

    tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/pensieve-landing-page.XXXXXX")" || return 1
    /usr/bin/awk -v slot="$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" -v sha="$sha" '
        BEGIN { stamped = 0 }
        {
            if (index($0, slot) > 0) {
                line = $0
                if (sub(/<br[^>]*>[^<]*<\/div>/, "<br />" sha "</div>", line)) {
                    stamped++
                    print line
                    next
                }
            }
            print
        }
        END { if (stamped != 1) exit 3 }
    ' "$page" >"$tmp" || status=$?
    if (( status != 0 )); then
        /bin/rm -f "$tmp"
        printf 'landing-page: %s: could not rewrite exactly one checksum slot (awk status %s)\n' \
            "$page" "$status" >&2
        return 1
    fi
    if ! /bin/cat "$tmp" >"$page"; then
        /bin/rm -f "$tmp"
        printf 'landing-page: could not write %s\n' "$page" >&2
        return 1
    fi
    /bin/rm -f "$tmp"
}

# landing_page_assert_checksum <page> <sha256>
#
#   0 — the page advertises exactly this checksum and carries no placeholder
#   1 — page unreadable, wrong/absent/duplicated checksum, or a leftover
#       DO-NOT-SHIP marker anywhere in the file
#   2 — called wrong
landing_page_assert_checksum() {
    local page="${1:-}"
    local sha="${2:-}"
    local values slot_count marker_status

    if [[ -z "$page" || -z "$sha" ]]; then
        printf 'landing-page: usage: landing_page_assert_checksum <page> <sha256>\n' >&2
        return 2
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'landing-page: expected checksum is not a lowercase SHA-256: %s\n' "$sha" >&2
        return 2
    fi
    landing_page_readable "$page" || return $?

    # grep exits 0 (match), 1 (no match) and 2 (read error) — collapsing 2 into
    # "no match" is exactly how a gate silently opens on an unreadable page.
    marker_status=0
    /usr/bin/grep -q -- "$LANDING_PAGE_UNFILLED_MARKER" "$page" || marker_status=$?
    case "$marker_status" in
        0)
            printf 'landing-page: %s still carries the %s placeholder — it must not be published\n' \
                "$page" "$LANDING_PAGE_UNFILLED_MARKER" >&2
            return 1
            ;;
        1) ;;
        *)
            printf 'landing-page: could not scan %s for the %s placeholder (grep status %s)\n' \
                "$page" "$LANDING_PAGE_UNFILLED_MARKER" "$marker_status" >&2
            return 1
            ;;
    esac

    values="$(landing_page_checksum_values "$page")" || return 1
    slot_count=0
    [[ -z "$values" ]] || slot_count="$(printf '%s\n' "$values" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    if (( slot_count != 1 )); then
        printf 'landing-page: %s must carry exactly one %s checksum slot, found %s\n' \
            "$page" "$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" "$slot_count" >&2
        return 1
    fi
    if [[ "$values" != "$sha" ]]; then
        printf 'landing-page: %s advertises checksum %s but this build'"'"'s DMG is %s\n' \
            "$page" "$values" "$sha" >&2
        return 1
    fi
}
