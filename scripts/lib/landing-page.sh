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
#   landing_page_assert_publishable "$PAGE" "$VERSION" "$URL" || …  # preflight
#   landing_page_stamp_checksum "$PAGE" "$DMG_SHA256" || …          # publish
#   landing_page_assert_published "$PAGE" "$SHA" "$VERSION" "$URL" || …  # gate
#
# The gate takes the WHOLE published contract — checksum, declared version and
# artifact URL — in one call on purpose. A gate that asserts only the checksum
# passes a page whose <dt>Version</dt> or download href moved underneath the
# run, and the pipeline then reports success for a page advertising this
# build's checksum next to another release's version or somebody else's bytes.

# The one line that carries the advertised checksum, e.g.
#   <div class="sha"><b>SHA-256</b><br />…</div>
LANDING_PAGE_CHECKSUM_SLOT_PATTERN='class="sha"'
# The algorithm the slot promises the reader, and the only one this lib will
# stamp into or vouch for. It is asserted rather than assumed: what the release
# computes is a SHA-256, so a slot relabelled <b>MD5</b> while keeping the same
# shape would sail through the parser, the stamper and the final gate, and the
# published page would present this build's SHA-256 as a checksum of another
# algorithm — a reader verifying it would compute an MD5 and conclude the DMG
# was tampered with.
LANDING_PAGE_ALGORITHM_LABEL='<b>SHA-256</b>'
# A placeholder that must never reach a published page.
LANDING_PAGE_UNFILLED_MARKER='DO-NOT-SHIP'

# Every parser below prints one NON-EMPTY record per declaration it finds, using
# `!empty` / `!unparsable` / `!wronglabel` sentinels for a declaration it cannot
# vouch for. That is a hard rule, not a style: listings are read through `$(…)`,
# which strips trailing newlines, so a record that printed as an empty line would
# vanish from the end of a listing and turn "two declarations, one of them
# broken" into "one clean declaration". Whoever adds a parser here keeps the
# rule.

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
# the advertised value (whitespace stripped), `!empty` for a slot that carries
# no value, `!wronglabel` for a slot that does not promise the reader a SHA-256,
# or `!unparsable` for a slot whose shape this lib no longer understands. No
# output means no slot at all.
#
# The label is read from BEFORE the value, because that is where the page prints
# it: a `<b>SHA-256</b>` sitting after the `<br />` is not the label the reader
# sees next to the number.
landing_page_checksum_values() {
    local page="${1:-}"

    landing_page_readable "$page" || return $?
    /usr/bin/awk -v slot="$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" \
        -v label="$LANDING_PAGE_ALGORITHM_LABEL" '
        index($0, slot) > 0 {
            line = $0
            if (match(line, /<br[^>]*>[^<]*<\/div>/)) {
                if (index(substr(line, 1, RSTART - 1), label) == 0) {
                    print "!wronglabel"
                    next
                }
                payload = substr(line, RSTART, RLENGTH)
                sub(/^<br[^>]*>/, "", payload)
                sub(/<\/div>$/, "", payload)
                gsub(/[ \t\r]/, "", payload)
                print (payload == "" ? "!empty" : payload)
            } else {
                print "!unparsable"
            }
        }
    ' "$page" || {
        printf 'landing-page: could not parse %s\n' "$page" >&2
        return 1
    }
}

# landing_page_assert_checksum_slot_shape <page> <values> — 0 unless <values> is
# a sentinel record this lib refuses to vouch for. Shared by preflight and the
# final gate so the two cannot disagree about what an untrustworthy slot is.
landing_page_assert_checksum_slot_shape() {
    local page="${1:-}"
    local values="${2:-}"

    case "$values" in
        '!unparsable')
            printf 'landing-page: %s: the checksum slot is no longer %s<br />VALUE</div> — teach scripts/lib/landing-page.sh the new shape before releasing\n' \
                "$page" "$LANDING_PAGE_ALGORITHM_LABEL" >&2
            return 1
            ;;
        '!wronglabel')
            printf 'landing-page: %s: the checksum slot is not labelled %s — the page would present this build'"'"'s SHA-256 as another algorithm\n' \
                "$page" "$LANDING_PAGE_ALGORITHM_LABEL" >&2
            return 1
            ;;
    esac
}

# landing_page_count_records <records> — how many lines a values listing holds.
# Empty input means zero; every other listing counts its lines. Split out so
# the call sites cannot drift apart.
landing_page_count_records() {
    local records="${1:-}"

    if [[ -z "$records" ]]; then
        printf '0\n'
        return 0
    fi
    printf '%s\n' "$records" | /usr/bin/wc -l | /usr/bin/tr -d ' '
}

# landing_page_artifact_urls <page> — prints every absolute URL on the page
# that points at a `.dmg`, one per line, in document order.
#
# That is the whole artifact surface of this page: the hero button, the
# download-panel button and the JSON-LD `downloadUrl`. A checksum is only
# meaningful next to the link the reader will actually click, so the release
# asserts that all of them are the one artifact it publishes. Out of scope by
# construction: a button repointed at a URL that does not end in `.dmg` (an
# installer page, a redirector) — that is a page redesign, not a swap the
# checksum could be read as covering.
#
# No sentinel record here: a match is a matched URL, so every record this prints
# is non-empty by construction and none can be swallowed off the end of a
# listing.
landing_page_artifact_urls() {
    local page="${1:-}"

    landing_page_readable "$page" || return $?
    /usr/bin/awk '
        {
            line = $0
            while (match(line, /https?:\/\/[^"'"'"'<> ]+\.dmg/)) {
                print substr(line, RSTART, RLENGTH)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$page" || {
        printf 'landing-page: could not parse %s\n' "$page" >&2
        return 1
    }
}

# landing_page_declared_version <page> — prints one line per <dt>Version</dt>
# declaration with the version the panel advertises, `!empty` for a declaration
# with no value, or `!unparsable` for one whose shape this lib no longer
# understands. No output means the panel declares no version at all.
#
# Both sentinels exist for the counting rule above: a page carrying the real
# version plus a trailing `<dt>Version</dt><dd></dd>` used to print "0.4.3" and
# an empty line, and `$(…)` dropped the empty one — so two declarations, one of
# which nobody could have stamped or trusted, were read as one clean version.
landing_page_declared_version() {
    local page="${1:-}"

    landing_page_readable "$page" || return $?
    /usr/bin/awk '
        /<dt>Version<\/dt>/ {
            if (match($0, /<dd>[^<]*<\/dd>/)) {
                value = substr($0, RSTART + 4, RLENGTH - 9)
                gsub(/^[ \t\r]+|[ \t\r]+$/, "", value)
                print (value == "" ? "!empty" : value)
            } else {
                print "!unparsable"
            }
        }
    ' "$page" || {
        printf 'landing-page: could not parse %s\n' "$page" >&2
        return 1
    }
}

# landing_page_assert_download_panel <page> <expected_version> <expected_url> [reported_path]
#
#   0 — the panel declares exactly this release's version and every artifact
#       link on the page points at exactly <expected_url>
#   1 — unreadable page, no single declared version, a different version, no
#       artifact link at all, or a link pointing somewhere else
#   2 — called wrong
#
# Asserted at BOTH ends of the run (preflight and the final gate), because the
# checksum is only worth printing next to the version and the download link it
# describes.
#
# <reported_path> is the path the diagnostics name, defaulting to the file being
# read. The final gate reads a private snapshot of the page, and an operator
# sent to a temporary copy that no longer exists cannot fix anything.
landing_page_assert_download_panel() {
    local page="${1:-}"
    local expected_version="${2:-}"
    local expected_url="${3:-}"
    local reported="${4:-${1:-}}"
    local version_values version_count urls url_count url

    if [[ -z "$page" || -z "$expected_version" || -z "$expected_url" ]]; then
        printf 'landing-page: usage: landing_page_assert_download_panel <page> <expected_version> <expected_url>\n' >&2
        return 2
    fi
    if [[ ! "$expected_url" =~ ^https://[^[:space:]\"]+\.dmg$ ]]; then
        printf 'landing-page: expected artifact URL is not an https .dmg URL: %s\n' "$expected_url" >&2
        return 2
    fi
    landing_page_readable "$page" || return $?

    version_values="$(landing_page_declared_version "$page")" || return 1
    version_count="$(landing_page_count_records "$version_values")"
    if (( version_count != 1 )); then
        printf 'landing-page: %s must declare exactly one download version (<dt>Version</dt><dd>…</dd>), found %s\n' \
            "$reported" "$version_count" >&2
        return 1
    fi
    case "$version_values" in
        '!empty')
            printf 'landing-page: %s declares an empty download version (<dt>Version</dt><dd></dd>) — fill it in before publishing\n' \
                "$reported" >&2
            return 1
            ;;
        '!unparsable')
            printf 'landing-page: %s: the version record is no longer <dt>Version</dt><dd>VALUE</dd> — teach scripts/lib/landing-page.sh the new shape before releasing\n' \
                "$reported" >&2
            return 1
            ;;
    esac
    if [[ "$version_values" != "$expected_version" ]]; then
        printf 'landing-page: %s advertises version %s but this release is %s — update the download panel before publishing\n' \
            "$reported" "$version_values" "$expected_version" >&2
        return 1
    fi

    urls="$(landing_page_artifact_urls "$page")" || return 1
    url_count="$(landing_page_count_records "$urls")"
    if (( url_count < 1 )); then
        printf 'landing-page: %s advertises no downloadable artifact — a checksum with no link beside it is not publishable\n' \
            "$reported" >&2
        return 1
    fi
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        if [[ "$url" != "$expected_url" ]]; then
            printf 'landing-page: %s links the artifact %s but this release publishes %s — the advertised checksum would sit next to bytes it does not describe\n' \
                "$reported" "$url" "$expected_url" >&2
            return 1
        fi
    done <<<"$urls"
}

# landing_page_assert_publishable <page> <expected_version> <expected_url>
#
#   0 — the page can be stamped at the end of this run
#   1 — a page or page DIRECTORY the stamp could not write, a symlinked page, no
#       single stampable checksum slot, or a download panel that does not
#       describe this release
#   2 — called wrong
#
# Runs BEFORE anything is built or published, so a page that cannot carry this
# release's checksum costs a preflight failure instead of a notarization round
# trip followed by an artifact already copied onto the team shelf. That is only
# true while preflight rejects everything the stamp would reject: the checks
# below deliberately mirror landing_page_stamp_checksum's own refusals — the
# symlink, and the directory the stamped page is renamed from, not just the
# page's own write bit.
landing_page_assert_publishable() {
    local page="${1:-}"
    local expected_version="${2:-}"
    local expected_url="${3:-}"
    local values slot_count page_dir

    if [[ -z "$page" || -z "$expected_version" || -z "$expected_url" ]]; then
        printf 'landing-page: usage: landing_page_assert_publishable <page> <expected_version> <expected_url>\n' >&2
        return 2
    fi

    landing_page_readable "$page" || return $?
    if [[ -L "$page" ]]; then
        printf 'landing-page: %s is a symlink — the stamp refuses to replace a link with a regular file, so point the release at the file it resolves to\n' \
            "$page" >&2
        return 1
    fi
    if [[ ! -w "$page" ]]; then
        printf 'landing-page: %s is not writable — the release cannot stamp this build'"'"'s checksum into it\n' "$page" >&2
        return 1
    fi
    # The stamped page is a temp file renamed into place from the page's OWN
    # directory, so a writable page inside a sealed directory is not stampable.
    # Without this the run failed at mktemp — after the build and the
    # notarization round trip.
    page_dir="$(/usr/bin/dirname "$page")"
    if [[ ! -w "$page_dir" || ! -x "$page_dir" ]]; then
        printf 'landing-page: %s is not a writable directory — the stamped page is written by renaming a temporary file created next to %s\n' \
            "$page_dir" "$page" >&2
        return 1
    fi

    values="$(landing_page_checksum_values "$page")" || return 1
    slot_count="$(landing_page_count_records "$values")"
    if (( slot_count != 1 )); then
        printf 'landing-page: %s must carry exactly one %s checksum slot, found %s\n' \
            "$page" "$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" "$slot_count" >&2
        return 1
    fi
    landing_page_assert_checksum_slot_shape "$page" "$values" || return 1

    landing_page_assert_download_panel "$page" "$expected_version" "$expected_url"
}

# landing_page_digest <page> — SHA-256 of the page's current bytes.
# Used to bracket the read→transform→write window with a same-content check.
landing_page_digest() {
    local page="${1:-}"
    local digest

    landing_page_readable "$page" || return $?
    digest="$(/usr/bin/shasum -a 256 "$page" | /usr/bin/awk '{print $1}')" || {
        printf 'landing-page: could not digest %s\n' "$page" >&2
        return 1
    }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        printf 'landing-page: could not digest %s\n' "$page" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

# landing_page_stamp_checksum <page> <sha256>
#
#   0 — the single checksum slot now carries <sha256>
#   1 — page unreadable, not exactly one slot could be rewritten, or the page
#       changed underneath the rewrite
#   2 — called wrong (missing args, or a value that is not a SHA-256)
#
# Everything outside the checksum slot stays byte-identical, and the write is a
# same-directory rename: a reader never sees a half-written page.
#
# This repo is worked in SHARED worktrees, so the rewrite is bracketed by a
# digest of the page: read it, transform it, and refuse to publish the
# transformed snapshot if the page moved in between. Without that, a concurrent
# edit landing between the read and the write was simply erased — and erased
# INVISIBLY, because the snapshot still carried the checksum the final gate
# looks for, so the gate had nothing to notice. The rename closes the tail of
# the window; what remains is the rename itself, which cannot lose a write it
# does not overlap.
landing_page_stamp_checksum() {
    local page="${1:-}"
    local sha="${2:-}"
    local tmp before after mode status=0

    if [[ -z "$page" || -z "$sha" ]]; then
        printf 'landing-page: usage: landing_page_stamp_checksum <page> <sha256>\n' >&2
        return 2
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'landing-page: refusing to stamp a value that is not a lowercase SHA-256: %s\n' "$sha" >&2
        return 2
    fi
    landing_page_readable "$page" || return $?
    if [[ -L "$page" ]]; then
        # A rename would replace the link with a regular file and leave the
        # real page unstamped, so this is a refusal rather than a silent swap.
        printf 'landing-page: %s is a symlink — stamp the file it points at\n' "$page" >&2
        return 1
    fi
    if [[ ! -w "$page" ]]; then
        printf 'landing-page: %s is not writable\n' "$page" >&2
        return 1
    fi

    before="$(landing_page_digest "$page")" || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$page")" || {
        printf 'landing-page: could not read the permissions of %s\n' "$page" >&2
        return 1
    }
    # Same directory as the page: the final rename must be atomic, which it is
    # only within one filesystem, and $TMPDIR is routinely another one.
    tmp="$(/usr/bin/mktemp "$(/usr/bin/dirname "$page")/.pensieve-landing-page.XXXXXX")" || {
        printf 'landing-page: could not create a temporary file next to %s — the stamped page is written by renaming one into place\n' \
            "$page" >&2
        return 1
    }
    # The label is part of what makes a line stampable: the stamp writes a
    # SHA-256, so a slot advertising anything else is left alone and the run
    # fails on the "exactly one slot" count rather than filling this build's
    # SHA-256 in under somebody else's algorithm name.
    /usr/bin/awk -v slot="$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" \
        -v label="$LANDING_PAGE_ALGORITHM_LABEL" -v sha="$sha" '
        BEGIN { stamped = 0 }
        {
            if (index($0, slot) > 0) {
                line = $0
                if (match(line, /<br[^>]*>[^<]*<\/div>/) &&
                    index(substr(line, 1, RSTART - 1), label) > 0 &&
                    sub(/<br[^>]*>[^<]*<\/div>/, "<br />" sha "</div>", line)) {
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
    after="$(landing_page_digest "$page")" || {
        /bin/rm -f "$tmp"
        return 1
    }
    if [[ "$before" != "$after" ]]; then
        /bin/rm -f "$tmp"
        printf 'landing-page: %s changed while this release was stamping it — refusing to write a snapshot that would drop that edit\n' \
            "$page" >&2
        return 1
    fi
    if ! /bin/chmod "$mode" "$tmp"; then
        /bin/rm -f "$tmp"
        printf 'landing-page: could not carry the permissions of %s onto the stamped page\n' "$page" >&2
        return 1
    fi
    if ! /bin/mv -f "$tmp" "$page"; then
        /bin/rm -f "$tmp"
        printf 'landing-page: could not write %s\n' "$page" >&2
        return 1
    fi
}

# landing_page_assert_published <page> <sha256> <expected_version> <expected_url>
#
#   0 — the page advertises exactly this checksum, for exactly this release's
#       version, next to exactly this release's artifact link, and carries no
#       placeholder
#   1 — page unreadable, wrong/absent/duplicated checksum, wrong or missing
#       declared version, a foreign artifact link, or a leftover DO-NOT-SHIP
#       marker anywhere in the file
#   2 — called wrong
#
# All four arguments are required so that no caller can assert half of the
# published contract. The version matters as much as the checksum: a parallel
# edit to <dt>Version</dt> during a build or notarization round trip would
# otherwise leave the run reporting success for a page pairing this release's
# checksum with a different release's version.
#
# The four fields are read from ONE snapshot of the page's bytes rather than
# from four separate opens. A gate that opens the file once per field can pass a
# page no revision of which was ever publishable: checksum read from the old
# page, version from the one an editor saved a millisecond later. The snapshot
# is then proved to still be the page on disk, so "the fields agree with each
# other" also means "they agree with what is published".
landing_page_assert_published() {
    local page="${1:-}"
    local sha="${2:-}"
    local expected_version="${3:-}"
    local expected_url="${4:-}"
    local snapshot page_digest snapshot_digest status=0

    if [[ -z "$page" || -z "$sha" || -z "$expected_version" || -z "$expected_url" ]]; then
        printf 'landing-page: usage: landing_page_assert_published <page> <sha256> <expected_version> <expected_url>\n' >&2
        return 2
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'landing-page: expected checksum is not a lowercase SHA-256: %s\n' "$sha" >&2
        return 2
    fi
    landing_page_readable "$page" || return $?

    snapshot="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/pensieve-landing-page-gate.XXXXXX")" || {
        printf 'landing-page: could not create a temporary file to snapshot %s for validation\n' "$page" >&2
        return 1
    }
    if ! /bin/cp "$page" "$snapshot"; then
        /bin/rm -f "$snapshot"
        printf 'landing-page: could not snapshot %s for validation\n' "$page" >&2
        return 1
    fi

    landing_page_assert_published_snapshot \
        "$snapshot" "$page" "$sha" "$expected_version" "$expected_url" || status=$?
    if (( status == 0 )); then
        # The snapshot is only evidence about the published page while it still
        # IS the published page. A page rewritten during validation fails the
        # gate loudly instead of being reported on from bytes nobody can read
        # any more.
        page_digest="$(landing_page_digest "$page")" || status=1
        snapshot_digest="$(landing_page_digest "$snapshot")" || status=1
        if (( status == 0 )) && [[ "$page_digest" != "$snapshot_digest" ]]; then
            printf 'landing-page: %s changed while this release was validating it — the page that was checked is not the page on disk\n' \
                "$page" >&2
            status=1
        fi
    fi
    /bin/rm -f "$snapshot"
    return "$status"
}

# landing_page_assert_published_snapshot <snapshot> <page> <sha256> <version> <url>
#
# The body of the gate above, reading the snapshot but naming <page> in every
# diagnostic: an operator debugging a failed release needs the path of the page
# they can open, not of a temporary copy this function already deleted.
landing_page_assert_published_snapshot() {
    local snapshot="${1:-}"
    local page="${2:-}"
    local sha="${3:-}"
    local expected_version="${4:-}"
    local expected_url="${5:-}"
    local values slot_count marker_status

    # grep exits 0 (match), 1 (no match) and 2 (read error) — collapsing 2 into
    # "no match" is exactly how a gate silently opens on an unreadable page.
    marker_status=0
    /usr/bin/grep -q -- "$LANDING_PAGE_UNFILLED_MARKER" "$snapshot" || marker_status=$?
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

    values="$(landing_page_checksum_values "$snapshot")" || return 1
    slot_count="$(landing_page_count_records "$values")"
    if (( slot_count != 1 )); then
        printf 'landing-page: %s must carry exactly one %s checksum slot, found %s\n' \
            "$page" "$LANDING_PAGE_CHECKSUM_SLOT_PATTERN" "$slot_count" >&2
        return 1
    fi
    landing_page_assert_checksum_slot_shape "$page" "$values" || return 1
    if [[ "$values" != "$sha" ]]; then
        printf 'landing-page: %s advertises checksum %s but this build'"'"'s DMG is %s\n' \
            "$page" "$values" "$sha" >&2
        return 1
    fi

    landing_page_assert_download_panel "$snapshot" "$expected_version" "$expected_url" "$page" || return 1
}
