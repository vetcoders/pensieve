#!/usr/bin/env bash

# Deterministic release-build provenance helpers.
#
# This file is intentionally sourceable. It does not change shell options and
# every public function reports failures through stderr + a non-zero return.
# Callers may therefore use it from both the release pipeline and isolated-app
# validation without inheriting process-wide policy.

PENSIEVE_BUILD_PROVENANCE_SCHEMA_VERSION="2"
PENSIEVE_BUILD_RECIPE_SCHEMA="pensieve-release-v2"
PENSIEVE_BUILD_PROVENANCE_RESOURCE="PensieveBuildProvenance.plist"

build_provenance_error() {
    printf 'build provenance: %s\n' "$*" >&2
}

# build_provenance_cleanup_dmg_staging PATH
#
# Release snapshots deliberately make compiler-visible inputs read-only. The
# resource modes survive into the signed app and then into the disposable DMG
# staging copy, so a plain recursive removal cannot descend through those
# copied directories. Unlock only non-symlink entries in that one derived
# staging tree, never the signed source app, before removing it. The exact
# path-shape and symlink guards keep this cleanup from becoming a generic
# recursive-delete primitive.
build_provenance_cleanup_dmg_staging() {
    local staging_path="${1:-}"

    case "$staging_path" in
        /*/dist/dmg-staging) ;;
        *)
            build_provenance_error \
                "refusing cleanup outside an exact dist/dmg-staging path: $staging_path"
            return 1
            ;;
    esac
    if [[ -L "$staging_path" ]]; then
        build_provenance_error \
            "refusing cleanup through a symlinked DMG staging root: $staging_path"
        return 1
    fi
    [[ -e "$staging_path" ]] || return 0

    # A terminal-attached `rm -R` prompts for a read-only file even when its
    # parent directory is writable. Do not follow symlinks: staging is a
    # copied release artifact and this function may mutate only that exact
    # derived tree.
    /usr/bin/find -P "$staging_path" ! -type l -exec /bin/chmod u+w {} + \
        || return 1
    /bin/rm -R -- "$staging_path"
}

build_provenance_is_sha256() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

build_provenance_sha256_file() {
    local path="$1"
    local output

    [[ -f "$path" ]] || {
        build_provenance_error "file not found: $path"
        return 1
    }
    output="$(/usr/bin/shasum -a 256 -- "$path")" || return 1
    output="${output%%[[:space:]]*}"
    build_provenance_is_sha256 "$output" || {
        build_provenance_error "invalid SHA-256 output for $path"
        return 1
    }
    printf '%s\n' "$output"
}

build_provenance_sha256_text() {
    local output

    output="$(printf '%s' "$1" | /usr/bin/shasum -a 256)" || return 1
    output="${output%%[[:space:]]*}"
    build_provenance_is_sha256 "$output" || return 1
    printf '%s\n' "$output"
}

build_provenance_normalize_repository_location() {
    local location="$1"

    case "$location" in
        git@*:* )
            location="https://${location#git@}"
            location="${location/:/\/}"
            ;;
    esac
    location="${location%/}"
    location="${location%.git}"
    printf '%s\n' "$location"
}

build_provenance_checkout_origin() {
    local checkout="$1"
    local origin

    origin="$(/usr/bin/git -C "$checkout" remote get-url origin 2>/dev/null)" || return 1
    if [[ -d "$origin" || -f "$origin/HEAD" ]]; then
        origin="$(/usr/bin/git -C "$origin" remote get-url origin 2>/dev/null)" || return 1
    fi
    build_provenance_normalize_repository_location "$origin"
}

# Append one path-sensitive file identity to RECORDS. A symlink is never
# trusted as a shortcut: its literal target and the bytes of the resolved
# file referent are both bound, and the referent must remain inside
# ALLOWED_ROOT. Directory symlinks are rejected here: SwiftPM checkouts need
# them, so their complete Git tree + validated relationships use the dedicated
# checkout digest below; product source and sealed bundle resources do not.
build_provenance_append_path_record() {
    local path="$1"
    local label="$2"
    local allowed_root="$3"
    local records_file="$4"
    local link_target link_hash referent referent_kind referent_hash payload_hash

    allowed_root="$(/bin/realpath "$allowed_root" 2>/dev/null)" || return 1
    if [[ -L "$path" ]]; then
        link_target="$(/usr/bin/readlink "$path")" || {
            build_provenance_error "could not read symlink input: $path"
            return 1
        }
        case "$link_target" in
            /*)
                build_provenance_error "absolute runtime-input symlink is unsafe: $path -> $link_target"
                return 1
                ;;
        esac
        referent="$(/bin/realpath "$path" 2>/dev/null)" || {
            build_provenance_error "broken or cyclic runtime-input symlink: $path -> $link_target"
            return 1
        }
        case "$referent" in
            "$allowed_root"|"$allowed_root"/*) ;;
            *)
                build_provenance_error "runtime-input symlink escapes its allowed root: $path -> $referent"
                return 1
                ;;
        esac
        link_hash="$(build_provenance_sha256_text "$link_target")" || return 1
        if [[ -f "$referent" ]]; then
            referent_kind="file"
            referent_hash="$(build_provenance_sha256_file "$referent")" || return 1
        elif [[ -d "$referent" ]]; then
            build_provenance_error \
                "directory symlink is unsupported outside a pinned SwiftPM checkout: $path"
            return 1
        else
            build_provenance_error "unsupported symlink referent: $path -> $referent"
            return 1
        fi
        printf 'symlink\0%s\0%s\0%s\0%s\0' \
            "$label" "$link_hash" "$referent_kind" "$referent_hash" >>"$records_file"
        return
    fi

    [[ -f "$path" ]] || {
        build_provenance_error "runtime input is neither a file nor a symlink: $path"
        return 1
    }
    payload_hash="$(build_provenance_sha256_file "$path")" || return 1
    printf 'file\0%s\0%s\0' "$label" "$payload_hash" >>"$records_file"
}

# A checkout is accepted only when its working tree exactly matches HEAD. The
# digest then binds the complete recursive Git tree (paths, modes and object
# identities), every referenced object's raw bytes through `cat-file --batch`,
# the actual compiler-visible working-tree bytes through batched Git blob IDs, and
# every symlink's literal target-to-referent relationship. The working-tree
# pass is load-bearing: Git status/diff may trust assume-unchanged or
# skip-worktree bits, whereas the compiler always reads the files on disk.
build_provenance_git_checkout_digest() {
    local checkout="$1"
    local work_dir tree_file oids_file records_file links_file ignored_file
    local working_paths_file expected_oids_file actual_oids_file
    local checkout_status record state relative target referent referent_kind
    local target_hash referent_relative digest metadata mode object_id submodule submodule_digest
    local actual_path actual_permissions actual_mode actual_object_id

    checkout="$(cd "$checkout" 2>/dev/null && pwd -P)" || return 1
    checkout_status="$(/usr/bin/git -C "$checkout" status \
        --porcelain=v1 --untracked-files=all 2>/dev/null)" || return 1
    [[ -z "$checkout_status" ]] || {
        build_provenance_error "SwiftPM checkout is dirty: $checkout"
        printf '%s\n' "$checkout_status" >&2
        return 1
    }

    work_dir="$(/usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/pensieve-checkout-provenance.XXXXXX")" || return 1
    tree_file="$work_dir/tree"
    oids_file="$work_dir/oids"
    records_file="$work_dir/records"
    links_file="$work_dir/links"
    ignored_file="$work_dir/ignored"
    working_paths_file="$work_dir/working-paths"
    expected_oids_file="$work_dir/expected-oids"
    actual_oids_file="$work_dir/actual-oids"

    # Ignored source can still be discovered by SwiftPM. Permit only metadata
    # and SwiftPM's own administrative directories; any other ignored path is
    # an unpinned build input and fails closed.
    if ! /usr/bin/git -C "$checkout" status --porcelain=v1 -z \
        --untracked-files=all --ignored=matching >"$ignored_file"; then
        /bin/rm -R "$work_dir"
        return 1
    fi
    while IFS= read -r -d '' record; do
        state="${record:0:2}"
        [[ "$state" == "!!" ]] || continue
        relative="${record:3}"
        case "$relative" in
            .DS_Store|*/.DS_Store|.build|.build/*|.swiftpm|.swiftpm/*) ;;
            *)
                /bin/rm -R "$work_dir"
                build_provenance_error \
                    "SwiftPM checkout contains ignored runtime input: $checkout/$relative"
                return 1
                ;;
        esac
    done <"$ignored_file"

    if ! /usr/bin/git -C "$checkout" ls-tree -r -z --full-tree HEAD >"$tree_file" \
        || ! /usr/bin/git -C "$checkout" ls-tree -r \
            --format='%(objecttype) %(objectname)' HEAD \
            | /usr/bin/awk '$1 == "blob" { print $2 }' \
            | LC_ALL=C /usr/bin/sort -u >"$oids_file"; then
        /bin/rm -R "$work_dir"
        return 1
    fi
    printf 'pensieve-git-checkout-v1\0' >"$records_file"
    /bin/cat "$tree_file" >>"$records_file" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /usr/bin/git -C "$checkout" cat-file --batch <"$oids_file" \
        >>"$records_file" || {
        /bin/rm -R "$work_dir"
        return 1
    }

    # Do not trust the index's clean bit. Seal every regular tracked file as it
    # exists on disk and validate its compiler-visible executable mode against
    # the committed tree. Batched `git hash-object --no-filters` keeps this pass
    # fast even for large dependencies and compares the raw on-disk bytes with
    # the exact blob object named by `ls-tree`.
    : >"$working_paths_file"
    while IFS= read -r -d '' record; do
        metadata="${record%%$'\t'*}"
        relative="${record#*$'\t'}"
        mode="${metadata%% *}"
        object_id="${metadata##* }"
        actual_path="$checkout/$relative"
        case "$mode" in
            100644|100755)
                [[ -f "$actual_path" && ! -L "$actual_path" ]] || {
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "SwiftPM checkout tracked-file shape mismatch: $actual_path"
                    return 1
                }
                actual_permissions="$(/usr/bin/stat -f '%Lp' "$actual_path" 2>/dev/null)" || {
                    /bin/rm -R "$work_dir"
                    return 1
                }
                if (( (8#$actual_permissions & 8#111) != 0 )); then
                    actual_mode="100755"
                else
                    actual_mode="100644"
                fi
                [[ "$actual_mode" == "$mode" ]] || {
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "SwiftPM checkout tracked-file mode mismatch: $actual_path"
                    return 1
                }
                printf '%s\0' "$relative" >>"$working_paths_file" || {
                    /bin/rm -R "$work_dir"
                    return 1
                }
                printf '%s\n' "$object_id" >>"$expected_oids_file" || {
                    /bin/rm -R "$work_dir"
                    return 1
                }
                ;;
            120000)
                [[ -L "$actual_path" ]] || {
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "SwiftPM checkout tracked symlink is missing: $actual_path"
                    return 1
                }
                target="$(/usr/bin/readlink "$actual_path")" || {
                    /bin/rm -R "$work_dir"
                    return 1
                }
                actual_object_id="$(printf '%s' "$target" \
                    | /usr/bin/git -C "$checkout" hash-object \
                        --stdin --no-filters 2>/dev/null)" || {
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "could not identify compiler-visible SwiftPM checkout symlink: $actual_path"
                    return 1
                }
                [[ "$actual_object_id" == "$object_id" ]] || {
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "SwiftPM checkout symlink target differs from committed blob: $actual_path"
                    return 1
                }
                ;;
            160000)
                [[ -d "$actual_path" ]] || {
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "SwiftPM checkout submodule is not initialized: $actual_path"
                    return 1
                }
                ;;
            *)
                /bin/rm -R "$work_dir"
                build_provenance_error \
                    "unsupported tracked mode $mode in SwiftPM checkout: $actual_path"
                return 1
                ;;
        esac
    done <"$tree_file"
    if [[ -s "$working_paths_file" ]]; then
        # Hash regular files in batches rather than starting one Git process per
        # path. NUL-delimited xargs preserves even unusual tracked path names;
        # hash-object emits one object ID per argument in the same order.
        if ! (cd "$checkout" \
            && /usr/bin/xargs -0 /usr/bin/git hash-object --no-filters -- \
                <"$working_paths_file" >"$actual_oids_file"); then
            /bin/rm -R "$work_dir"
            build_provenance_error \
                "could not identify compiler-visible SwiftPM checkout bytes: $checkout"
            return 1
        fi
        if ! /usr/bin/cmp -s "$expected_oids_file" "$actual_oids_file"; then
            # The slow path runs only on rejection and gives the operator the
            # first exact file instead of a checkout-wide generic error.
            while IFS= read -r -d '' record; do
                metadata="${record%%$'\t'*}"
                relative="${record#*$'\t'}"
                mode="${metadata%% *}"
                case "$mode" in 100644|100755) ;; *) continue ;; esac
                object_id="${metadata##* }"
                actual_object_id="$(/usr/bin/git -C "$checkout" hash-object \
                    --no-filters -- "$relative" 2>/dev/null)" || actual_object_id=""
                [[ "$actual_object_id" == "$object_id" ]] && continue
                /bin/rm -R "$work_dir"
                build_provenance_error \
                    "SwiftPM checkout file bytes differ from committed blob: $checkout/$relative"
                return 1
            done <"$tree_file"
            /bin/rm -R "$work_dir"
            build_provenance_error \
                "SwiftPM checkout file bytes differ from committed tree: $checkout"
            return 1
        fi
        printf 'working-tree-object-ids-v1\0' >>"$records_file"
        /bin/cat "$actual_oids_file" >>"$records_file" || {
            /bin/rm -R "$work_dir"
            return 1
        }
    fi

    # SwiftPM may initialize dependency submodules (GRDB does). A gitlink only
    # binds the expected commit, not the bytes present in the nested worktree,
    # so recursively seal and validate each initialized submodule as well.
    while IFS= read -r -d '' record; do
        metadata="${record%%$'\t'*}"
        relative="${record#*$'\t'}"
        mode="${metadata%% *}"
        [[ "$mode" == "160000" ]] || continue
        object_id="${metadata##* }"
        submodule="$checkout/$relative"
        [[ -d "$submodule" ]] || {
            /bin/rm -R "$work_dir"
            build_provenance_error "SwiftPM checkout submodule is not initialized: $submodule"
            return 1
        }
        [[ "$(/usr/bin/git -C "$submodule" rev-parse HEAD 2>/dev/null)" == "$object_id" ]] || {
            /bin/rm -R "$work_dir"
            build_provenance_error \
                "SwiftPM checkout submodule revision mismatch: $submodule"
            return 1
        }
        submodule_digest="$(build_provenance_git_checkout_digest "$submodule")" || {
            /bin/rm -R "$work_dir"
            return 1
        }
        printf 'submodule-checkout\0%s\0%s\0%s\0' \
            "$relative" "$object_id" "$submodule_digest" >>"$records_file" || {
            /bin/rm -R "$work_dir"
            return 1
        }
    done <"$tree_file"

    if ! /usr/bin/find "$checkout" \
        \( -name .git -o -name .build -o -name .swiftpm \) -type d -prune -o \
        -type l -print0 | LC_ALL=C /usr/bin/sort -zu >"$links_file"; then
        /bin/rm -R "$work_dir"
        return 1
    fi
    while IFS= read -r -d '' record; do
        relative="${record#"$checkout"/}"
        target="$(/usr/bin/readlink "$record")" || {
            /bin/rm -R "$work_dir"
            return 1
        }
        case "$target" in
            /*)
                /bin/rm -R "$work_dir"
                build_provenance_error \
                    "absolute SwiftPM checkout symlink is unsafe: $record -> $target"
                return 1
                ;;
        esac
        referent="$(/bin/realpath "$record" 2>/dev/null)" || {
            /bin/rm -R "$work_dir"
            build_provenance_error \
                "broken or cyclic SwiftPM checkout symlink: $record -> $target"
            return 1
        }
        case "$referent" in
            "$checkout"|"$checkout"/*) ;;
            *)
                /bin/rm -R "$work_dir"
                build_provenance_error \
                    "SwiftPM checkout symlink escapes checkout: $record -> $referent"
                return 1
                ;;
        esac
        if [[ -f "$referent" ]]; then
            referent_kind="file"
        elif [[ -d "$referent" ]]; then
            referent_kind="directory"
        else
            /bin/rm -R "$work_dir"
            build_provenance_error "unsupported SwiftPM symlink referent: $record"
            return 1
        fi
        target_hash="$(build_provenance_sha256_text "$target")" || {
            /bin/rm -R "$work_dir"
            return 1
        }
        if [[ "$referent" == "$checkout" ]]; then
            referent_relative="."
        else
            referent_relative="${referent#"$checkout"/}"
        fi
        printf 'symlink-relationship\0%s\0%s\0%s\0%s\0' \
            "$relative" "$target_hash" "$referent_kind" "$referent_relative" \
            >>"$records_file" || {
            /bin/rm -R "$work_dir"
            return 1
        }
    done <"$links_file"

    digest="$(build_provenance_sha256_file "$records_file")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

build_provenance_runtime_input_status() {
    local repo_root="$1"
    local ffi_profile="$2"

    /usr/bin/git -C "$repo_root" status --porcelain=v1 --untracked-files=all -- \
        VERSION \
        scripts/build-release.sh \
        scripts/lib/bundle-identity.sh \
        scripts/lib/build-provenance.sh \
        scripts/lib/rpath-hygiene.sh \
        Pensieve/Package.swift \
        Pensieve/Package.resolved \
        Pensieve/Sources \
        Pensieve/Resources \
        Pensieve/scripts \
        "Pensieve/Vendor/qube-ffi/$ffi_profile/libqube_ffi.dylib" 2>/dev/null
}

build_provenance_assert_runtime_inputs_clean() {
    local repo_root="$1"
    local ffi_profile="$2"
    local status ignored_file record state relative invalid_ignored

    /usr/bin/git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        build_provenance_error "release inputs are not inside a Git worktree: $repo_root"
        return 1
    }
    status="$(build_provenance_runtime_input_status "$repo_root" "$ffi_profile")" || return 1
    [[ -z "$status" ]] || {
        build_provenance_error "release runtime inputs differ from HEAD:"
        printf '%s\n' "$status" >&2
        return 1
    }

    ignored_file="$(/usr/bin/mktemp \
        "${TMPDIR:-/tmp}/pensieve-runtime-ignored.XXXXXX")" || return 1
    if ! /usr/bin/git -C "$repo_root" status --porcelain=v1 -z \
        --untracked-files=all --ignored=matching -- \
        VERSION \
        scripts/build-release.sh \
        scripts/lib/bundle-identity.sh \
        scripts/lib/build-provenance.sh \
        scripts/lib/rpath-hygiene.sh \
        Pensieve/Package.swift \
        Pensieve/Package.resolved \
        Pensieve/Sources \
        Pensieve/Resources \
        Pensieve/scripts \
        "Pensieve/Vendor/qube-ffi/$ffi_profile/libqube_ffi.dylib" \
        >"$ignored_file" 2>/dev/null; then
        /bin/rm -f "$ignored_file"
        return 1
    fi
    invalid_ignored=""
    while IFS= read -r -d '' record; do
        state="${record:0:2}"
        [[ "$state" == "!!" ]] || continue
        relative="${record:3}"
        # Finder metadata is neither discovered nor compiled by SwiftPM. Keep
        # it out of the provenance surface; every other ignored path under a
        # runtime-producing directory is an unpinned input and fails closed.
        case "$relative" in
            .DS_Store|*/.DS_Store) ;;
            *)
                invalid_ignored="$relative"
                break
                ;;
        esac
    done <"$ignored_file"
    /bin/rm -f "$ignored_file"
    [[ -z "$invalid_ignored" ]] || {
        build_provenance_error \
            "release runtime inputs contain ignored source: $invalid_ignored"
        return 1
    }
}

build_provenance_assert_head() {
    local repo_root="$1"
    local expected_commit="$2"
    local actual_commit

    [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    actual_commit="$(/usr/bin/git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || return 1
    [[ "$actual_commit" == "$expected_commit" ]] || {
        build_provenance_error \
            "repository HEAD moved during provenance verification: expected $expected_commit, found $actual_commit"
        return 1
    }
}

# build_provenance_runtime_input_digest REPO_ROOT FFI_PROFILE
#
# Hashes the complete runtime-producing source surface plus the narrow release
# recipe in a deterministic, path-sensitive format. Timestamps, ownership and
# permissions are excluded; file/symlink identity and bytes are included. The
# vendored runtime input is deliberately ONE profile-specific dylib, not the
# whole Vendor tree; smoke harnesses are deliberately not recipe inputs.
build_provenance_runtime_input_digest() {
    local repo_root="$1"
    local ffi_profile="$2"
    local package_root sources_root resources_root package_scripts_root ffi_path
    local work_dir paths_file records_file path relative digest
    local package_resolved checkouts_root pin_count pin_index pin_identity pin_location pin_revision
    local checkout candidate candidate_revision candidate_origin expected_origin matches checkout_digest

    case "$ffi_profile" in
        debug|release) ;;
        *)
            build_provenance_error "FFI profile must be debug or release, got: $ffi_profile"
            return 1
            ;;
    esac

    repo_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || {
        build_provenance_error "repository root is not readable: $repo_root"
        return 1
    }
    package_root="$repo_root/Pensieve"
    sources_root="$package_root/Sources"
    resources_root="$package_root/Resources"
    package_scripts_root="$package_root/scripts"
    ffi_path="$package_root/Vendor/qube-ffi/$ffi_profile/libqube_ffi.dylib"
    package_resolved="$package_root/Package.resolved"
    checkouts_root="$package_root/.build/checkouts"

    for path in \
        "$repo_root/VERSION" \
        "$package_root/Package.swift" \
        "$package_root/Package.resolved" \
        "$repo_root/scripts/build-release.sh" \
        "$repo_root/scripts/lib/bundle-identity.sh" \
        "$repo_root/scripts/lib/build-provenance.sh" \
        "$repo_root/scripts/lib/rpath-hygiene.sh" \
        "$ffi_path"
    do
        [[ -f "$path" ]] || {
            build_provenance_error "required runtime input is missing: $path"
            return 1
        }
    done
    for path in "$sources_root" "$resources_root" "$package_scripts_root"; do
        [[ -d "$path" ]] || {
            build_provenance_error "required runtime input directory is missing: $path"
            return 1
        }
    done

    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pensieve-build-provenance.XXXXXX")" \
        || return 1
    paths_file="$work_dir/paths"
    records_file="$work_dir/records"

    if ! {
        printf '%s\0' \
            "$repo_root/VERSION" \
            "$package_root/Package.swift" \
            "$package_root/Package.resolved" \
            "$repo_root/scripts/build-release.sh" \
            "$repo_root/scripts/lib/bundle-identity.sh" \
            "$repo_root/scripts/lib/build-provenance.sh" \
            "$repo_root/scripts/lib/rpath-hygiene.sh" \
            "$ffi_path"
        /usr/bin/find "$sources_root" "$resources_root" "$package_scripts_root" \
            ! -name .DS_Store \( -type f -o -type l \) -print0
    } | LC_ALL=C /usr/bin/sort -zu >"$paths_file"; then
        /bin/rm -R "$work_dir"
        build_provenance_error "could not enumerate runtime inputs"
        return 1
    fi

    printf 'pensieve-runtime-input-v2\0' >"$records_file"
    while IFS= read -r -d '' path; do
        relative="${path#"$repo_root"/}"
        if ! build_provenance_append_path_record \
            "$path" "$relative" "$repo_root" "$records_file"; then
            /bin/rm -R "$work_dir"
            return 1
        fi
    done <"$paths_file"

    pin_count="$(/usr/bin/plutil -extract pins raw -n "$package_resolved" 2>/dev/null)" || {
        /bin/rm -R "$work_dir"
        build_provenance_error "could not read dependency pins from $package_resolved"
        return 1
    }
    [[ "$pin_count" =~ ^[0-9]+$ ]] || {
        /bin/rm -R "$work_dir"
        build_provenance_error "Package.resolved has an invalid pins array"
        return 1
    }
    if (( pin_count > 0 )) && [[ ! -d "$checkouts_root" ]]; then
        /bin/rm -R "$work_dir"
        build_provenance_error "SwiftPM checkouts are missing; run 'swift package resolve' first"
        return 1
    fi

    pin_index=0
    while (( pin_index < pin_count )); do
        pin_identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw -n \
            "$package_resolved" 2>/dev/null)" || {
            /bin/rm -R "$work_dir"
            build_provenance_error "Package.resolved pin $pin_index has no identity"
            return 1
        }
        pin_location="$(/usr/bin/plutil -extract "pins.$pin_index.location" raw -n \
            "$package_resolved" 2>/dev/null)" || {
            /bin/rm -R "$work_dir"
            build_provenance_error "Package.resolved pin $pin_identity has no location"
            return 1
        }
        pin_revision="$(/usr/bin/plutil -extract "pins.$pin_index.state.revision" raw -n \
            "$package_resolved" 2>/dev/null)" || {
            /bin/rm -R "$work_dir"
            build_provenance_error "Package.resolved pin $pin_identity has no revision"
            return 1
        }
        [[ "$pin_identity" =~ ^[A-Za-z0-9._-]+$ && "$pin_revision" =~ ^[0-9a-f]{40}$ ]] || {
            /bin/rm -R "$work_dir"
            build_provenance_error "Package.resolved contains an unsafe pin identity or revision"
            return 1
        }
        expected_origin="$(build_provenance_normalize_repository_location "$pin_location")" || {
            /bin/rm -R "$work_dir"
            return 1
        }
        matches=0
        checkout=""
        for candidate in "$checkouts_root"/*; do
            [[ -e "$candidate/.git" ]] || continue
            candidate_revision="$(/usr/bin/git -C "$candidate" rev-parse HEAD 2>/dev/null)" \
                || continue
            [[ "$candidate_revision" == "$pin_revision" ]] || continue
            candidate_origin="$(build_provenance_checkout_origin "$candidate" 2>/dev/null)" \
                || continue
            [[ "$candidate_origin" == "$expected_origin" ]] || continue
            checkout="$candidate"
            matches=$((matches + 1))
        done
        if (( matches != 1 )); then
            /bin/rm -R "$work_dir"
            build_provenance_error \
                "Package.resolved pin $pin_identity@$pin_revision matched $matches exact checkouts"
            return 1
        fi
        checkout_digest="$(build_provenance_git_checkout_digest "$checkout")" || {
            /bin/rm -R "$work_dir"
            return 1
        }
        printf 'package-pin\0%s\0%s\0%s\0' \
            "$pin_identity" "$expected_origin" "$pin_revision" >>"$records_file" || {
            /bin/rm -R "$work_dir"
            return 1
        }
        if ! printf 'package-checkout-sha256\0%s\0%s\0' \
            "$pin_identity" "$checkout_digest" >>"$records_file"; then
            /bin/rm -R "$work_dir"
            return 1
        fi
        pin_index=$((pin_index + 1))
    done

    digest="$(build_provenance_sha256_file "$records_file")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

# build_provenance_commit_runtime_input_digest REPO_ROOT COMMIT FFI_PROFILE
#   [SWIFT_EXECUTABLE]
#
# Materialize runtime-producing bytes from the named Git object, resolve its
# Package.resolved graph into a fresh checkout root, and fingerprint that
# isolated tree. The caller's index, status bits, working-tree bytes and
# existing .build cache are not consulted. SWIFT_EXECUTABLE is injectable only
# so the helper can be exercised by a hermetic script test; production callers
# should omit it and use the toolchain selected by xcrun.
build_provenance_commit_runtime_input_digest() (
    local repo_root="$1"
    local commit="$2"
    local ffi_profile="$3"
    local swift_executable="${4:-}"
    local resolved_commit work_dir snapshot_root snapshot_package resolve_log
    local resolved_before resolved_after digest original_status

    # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap below
    cleanup_commit_snapshot() {
        original_status="$?"
        trap - EXIT INT TERM
        if [[ -n "${work_dir:-}" && -d "$work_dir" ]]; then
            /bin/chmod -R u+w "$work_dir" >/dev/null 2>&1 || true
            /bin/rm -R -- "$work_dir" >/dev/null 2>&1 || true
        fi
        exit "$original_status"
    }
    trap cleanup_commit_snapshot EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    case "$ffi_profile" in
        debug|release) ;;
        *)
            build_provenance_error "FFI profile must be debug or release, got: $ffi_profile"
            return 1
            ;;
    esac
    repo_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || {
        build_provenance_error "repository root is not readable: $repo_root"
        return 1
    }
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
        build_provenance_error "commit must be a full 40-character Git object ID"
        return 1
    }
    resolved_commit="$(/usr/bin/git -C "$repo_root" rev-parse "$commit^{commit}" \
        2>/dev/null)" || {
        build_provenance_error "commit is not available in the repository: $commit"
        return 1
    }
    [[ "$resolved_commit" == "$commit" ]] || return 1
    if [[ -z "$swift_executable" ]]; then
        swift_executable="$(/usr/bin/xcrun --find swift 2>/dev/null)" || {
            build_provenance_error "xcrun could not locate the Swift toolchain"
            return 1
        }
    fi
    [[ "$swift_executable" == /* && -x "$swift_executable" && ! -d "$swift_executable" ]] || {
        build_provenance_error "Swift executable is not an absolute executable file: $swift_executable"
        return 1
    }

    work_dir="$(/usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/pensieve-commit-provenance.XXXXXX")" || return 1
    snapshot_root="$work_dir/source"
    snapshot_package="$snapshot_root/Pensieve"
    resolve_log="$work_dir/swift-resolve.log"
    /bin/mkdir -p "$snapshot_root" || return 1
    if ! /usr/bin/git -C "$repo_root" archive --format=tar "$commit" -- \
        VERSION \
        Pensieve/Package.swift \
        Pensieve/Package.resolved \
        Pensieve/Sources \
        Pensieve/Resources \
        Pensieve/scripts \
        "Pensieve/Vendor/qube-ffi/$ffi_profile/libqube_ffi.dylib" \
        scripts/build-release.sh \
        scripts/lib/bundle-identity.sh \
        scripts/lib/build-provenance.sh \
        scripts/lib/rpath-hygiene.sh \
        | /usr/bin/tar -xf - -C "$snapshot_root"; then
        build_provenance_error \
            "could not materialize runtime inputs from commit $commit"
        return 1
    fi
    resolved_before="$(build_provenance_sha256_file \
        "$snapshot_package/Package.resolved")" || return 1
    if ! FFI_PROFILE="$ffi_profile" "$swift_executable" package resolve \
        --package-path "$snapshot_package" >"$resolve_log" 2>&1; then
        /usr/bin/tail -25 "$resolve_log" >&2 || true
        build_provenance_error \
            "could not resolve the pinned SwiftPM graph from commit $commit"
        return 1
    fi
    resolved_after="$(build_provenance_sha256_file \
        "$snapshot_package/Package.resolved")" || return 1
    [[ "$resolved_after" == "$resolved_before" ]] || {
        build_provenance_error \
            "fresh resolution rewrote Package.resolved from commit $commit"
        return 1
    }
    digest="$(build_provenance_runtime_input_digest "$snapshot_root" "$ffi_profile")" \
        || return 1
    build_provenance_is_sha256 "$digest" || return 1
    printf '%s\n' "$digest"
)

# build_provenance_normalized_macho_digest MACH_O
#
# Code signatures contain signing-time material and therefore cannot be part
# of a reproducible payload identity. Hash an exact copy after removing its
# embedded signature and normalizing non-runtime symbol/linkedit bookkeeping.
#
# `codesign --remove-signature` truncates the signature blob, but deliberately
# leaves `__LINKEDIT.vmsize` at the value required by the former signature.
# The same executable consequently hashes differently after an ad-hoc versus
# Developer ID signature even though its runtime payload is identical. Apple's
# `strip -S` removes non-runtime debug symbols and canonicalizes that residual
# linkedit geometry while preserving code, data, exports, relocations and dylib
# load commands. The original binary is never mutated.
build_provenance_normalized_macho_digest() {
    local macho="$1"
    local work_dir copy digest

    [[ -f "$macho" ]] || {
        build_provenance_error "Mach-O payload not found: $macho"
        return 1
    }
    /usr/bin/otool -h "$macho" >/dev/null 2>&1 || {
        build_provenance_error "payload is not a readable Mach-O: $macho"
        return 1
    }

    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pensieve-macho-provenance.XXXXXX")" \
        || return 1
    copy="$work_dir/payload"
    if ! /bin/cp -p "$macho" "$copy"; then
        /bin/rm -R "$work_dir"
        return 1
    fi

    # `codesign -d` also recognizes a signature invalidated by
    # install_name_tool, which is exactly what needs normalizing here.
    if /usr/bin/codesign -d "$copy" >/dev/null 2>&1; then
        if ! /usr/bin/codesign --remove-signature "$copy" >/dev/null 2>&1; then
            /bin/rm -R "$work_dir"
            build_provenance_error "could not remove Mach-O signature from copy of $macho"
            return 1
        fi
    fi

    if ! /usr/bin/strip -S "$copy" >/dev/null 2>&1; then
        /bin/rm -R "$work_dir"
        build_provenance_error "could not normalize Mach-O linkedit metadata for $macho"
        return 1
    fi

    digest="$(build_provenance_sha256_file "$copy")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

# The code signature seals bytes, but it does not make a bundle launchable.
# In particular, removing the executable bit from the main binary leaves both
# its signature and normalized Mach-O digest intact. Verify the filesystem
# shape separately so a signed but unlaunchable bundle can never satisfy the
# provenance gate. The FFI is data loaded by dyld, so it must be a real,
# readable file but does not need an executable permission bit.
build_provenance_assert_payload_shapes() {
    local main_macho="$1"
    local ffi_macho="$2"

    [[ -f "$main_macho" && ! -L "$main_macho" && -r "$main_macho" \
        && -x "$main_macho" ]] || {
        build_provenance_error \
            "main executable is not a regular, readable executable file: $main_macho"
        return 1
    }
    [[ -f "$ffi_macho" && ! -L "$ffi_macho" && -r "$ffi_macho" ]] || {
        build_provenance_error \
            "embedded qube-ffi is not a regular, readable dylib: $ffi_macho"
        return 1
    }
}

build_provenance_macho_architecture() {
    local macho="$1"
    local architecture

    [[ -f "$macho" ]] || {
        build_provenance_error "Mach-O payload not found: $macho"
        return 1
    }
    architecture="$(/usr/bin/lipo -archs "$macho" 2>/dev/null)" || {
        build_provenance_error "could not inspect Mach-O architecture: $macho"
        return 1
    }
    architecture="$(printf '%s\n' "$architecture" | /usr/bin/xargs)"
    [[ -n "$architecture" ]] || return 1
    printf '%s\n' "$architecture"
}

build_provenance_assert_macho_architecture() {
    local macho="$1"
    local expected="$2"
    local actual

    actual="$(build_provenance_macho_architecture "$macho")" || return 1
    [[ "$actual" == "$expected" ]] || {
        build_provenance_error \
            "Mach-O architecture mismatch for $macho: expected '$expected', found '$actual'"
        return 1
    }
}

build_provenance_codesign_team_identifier() {
    local target="$1"
    local team

    team="$(/usr/bin/codesign -d --verbose=4 "$target" 2>&1 \
        | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)" || return 1
    [[ -n "$team" ]] || {
        build_provenance_error "signed payload has no TeamIdentifier field: $target"
        return 1
    }
    [[ "$team" != "not set" ]] || team="not-set"
    printf '%s\n' "$team"
}

# A TeamIdentifier string is metadata, not proof of trust: an ad-hoc or foreign
# certificate can carry lookalike subject fields. Developer ID release payloads
# must satisfy Apple's own code-signing requirement language: Apple generic
# anchor, Developer ID Application leaf marker, and the exact Team OU. This does
# not require notarization and therefore remains valid for release-local builds.
build_provenance_assert_developer_id_signature() {
    local target="$1"
    local expected_team="$2"
    local requirement actual_team

    [[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || {
        build_provenance_error \
            "Developer ID TeamIdentifier must be 10 uppercase alphanumerics: $expected_team"
        return 1
    }
    actual_team="$(build_provenance_codesign_team_identifier "$target")" || return 1
    [[ "$actual_team" == "$expected_team" ]] || {
        build_provenance_error \
            "Developer ID TeamIdentifier mismatch for $target: expected $expected_team, found $actual_team"
        return 1
    }
    requirement="=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$expected_team\""
    /usr/bin/codesign --verify --strict --test-requirement "$requirement" \
        "$target" >/dev/null 2>&1 || {
        build_provenance_error \
            "signature is not Apple-anchored Developer ID Application code for Team $expected_team: $target"
        return 1
    }
}

build_provenance_hardened_runtime_value() {
    local target="$1"
    local details

    details="$(/usr/bin/codesign -d --verbose=4 "$target" 2>&1)" || {
        build_provenance_error "could not inspect CodeDirectory flags: $target"
        return 1
    }
    case "$details" in
        *flags=*'runtime'*) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

build_provenance_no_entitlements_digest() {
    build_provenance_sha256_text 'pensieve-no-entitlements-v1'
}

build_provenance_canonical_plist_digest() {
    local plist="$1"
    local work_dir canonical digest

    /usr/bin/plutil -lint "$plist" >/dev/null 2>&1 || {
        build_provenance_error "not a readable plist: $plist"
        return 1
    }
    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pensieve-plist-provenance.XXXXXX")" \
        || return 1
    canonical="$work_dir/canonical.plist"
    if ! /bin/cp "$plist" "$canonical" \
        || ! /usr/bin/plutil -convert binary1 "$canonical" >/dev/null 2>&1; then
        /bin/rm -R "$work_dir"
        return 1
    fi
    digest="$(build_provenance_sha256_file "$canonical")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

build_provenance_codesign_entitlements_digest() {
    local target="$1"
    local work_dir extracted digest

    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pensieve-entitlements.XXXXXX")" \
        || return 1
    extracted="$work_dir/entitlements.plist"
    if ! /usr/bin/codesign -d --entitlements :- "$target" >"$extracted" 2>/dev/null \
        || [[ ! -s "$extracted" ]]; then
        /bin/rm -R "$work_dir"
        build_provenance_no_entitlements_digest
        return
    fi
    digest="$(build_provenance_canonical_plist_digest "$extracted")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

build_provenance_entitlements_file_digest() {
    local entitlements="$1"

    if [[ -z "$entitlements" ]]; then
        build_provenance_no_entitlements_digest
        return
    fi
    [[ -f "$entitlements" ]] || {
        build_provenance_error "expected entitlements file not found: $entitlements"
        return 1
    }
    build_provenance_canonical_plist_digest "$entitlements"
}

# Read a plist policy from the exact Git commit named by the provenance check,
# not from a mutable worktree path. This closes the otherwise tiny TOCTOU where
# a long-running --dmg-only verification could compare a sealed artifact with
# entitlements changed after COMMIT was captured.
build_provenance_git_plist_digest() {
    local repo_root="$1"
    local commit="$2"
    local relative_path="$3"
    local work_dir plist digest

    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
        build_provenance_error "commit must be a full 40-character Git object ID"
        return 1
    }
    case "$relative_path" in
        ""|/*|..|../*|*/../*|*/..)
            build_provenance_error "unsafe Git plist path: $relative_path"
            return 1
            ;;
    esac
    [[ "$relative_path" =~ ^[A-Za-z0-9._/-]+$ ]] || {
        build_provenance_error "unsafe Git plist path: $relative_path"
        return 1
    }

    work_dir="$(/usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/pensieve-git-plist-provenance.XXXXXX")" || return 1
    plist="$work_dir/policy.plist"
    if ! /usr/bin/git -C "$repo_root" show "$commit:$relative_path" >"$plist" 2>/dev/null; then
        /bin/rm -R "$work_dir"
        build_provenance_error \
            "could not read $relative_path from provenance commit $commit"
        return 1
    fi
    digest="$(build_provenance_canonical_plist_digest "$plist")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

build_provenance_canonical_info_digest() {
    local info_plist="$1"
    local work_dir canonical key digest environment_keys

    /usr/bin/plutil -lint "$info_plist" >/dev/null 2>&1 || {
        build_provenance_error "bundle Info.plist is invalid: $info_plist"
        return 1
    }
    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pensieve-info-provenance.XXXXXX")" \
        || return 1
    canonical="$work_dir/Info.plist"
    /bin/cp "$info_plist" "$canonical" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    # Isolated smoke staging intentionally rewrites these identity-only fields,
    # then re-signs the bundle.
    for key in \
        CFBundleExecutable \
        CFBundleIdentifier \
        CFBundleName \
        CFBundleDisplayName
    do
        /usr/bin/plutil -remove "$key" "$canonical" >/dev/null 2>&1 || true
    done

    # The staged identity also carries exactly two isolation environment keys;
    # its external identity manifest pins their values. Never erase an unknown
    # LSEnvironment override from provenance: production must have none, and a
    # staged bundle may contain only this closed allowlist.
    if environment_keys="$(/usr/bin/plutil -extract LSEnvironment raw \
        "$canonical" 2>/dev/null)"; then
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            case "$key" in
                PENSIEVE_SUPPORT_DIR|PENSIEVE_KEYCHAIN_SERVICE) ;;
                *)
                    /bin/rm -R "$work_dir"
                    build_provenance_error \
                        "unexpected LSEnvironment key in bundle Info.plist: $key"
                    return 1
                    ;;
            esac
        done <<<"$environment_keys"
        /usr/bin/plutil -remove LSEnvironment.PENSIEVE_SUPPORT_DIR \
            "$canonical" >/dev/null 2>&1 || true
        /usr/bin/plutil -remove LSEnvironment.PENSIEVE_KEYCHAIN_SERVICE \
            "$canonical" >/dev/null 2>&1 || true
        /usr/bin/plutil -remove LSEnvironment "$canonical" >/dev/null 2>&1 || true
    fi
    if ! /usr/bin/plutil -convert binary1 "$canonical" >/dev/null 2>&1; then
        /bin/rm -R "$work_dir"
        return 1
    fi
    digest="$(build_provenance_sha256_file "$canonical")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

# Hash every sealed runtime payload in the bundle except the two Mach-Os that
# have their own normalized digests, the provenance plist itself (to avoid a
# circular hash), and Apple-owned outer signature/notarization material (which
# is intentionally signing-time dependent). `_CodeSignature` is produced by
# codesign; the exact top-level `Contents/CodeResources` file is the stapled
# notarization ticket. Neither is a Pensieve resource, and both are verified by
# their platform authorities. Info.plist is canonicalized only across the four
# isolated-smoke identity rewrites documented above.
build_provenance_bundle_auxiliary_digest() {
    local app_bundle="$1"
    local main_macho="$2"
    local ffi_macho="$3"
    local contents info_plist manifest work_dir paths_file records_file path relative digest info_digest

    app_bundle="$(cd "$app_bundle" 2>/dev/null && pwd -P)" || {
        build_provenance_error "bundle is not readable: $app_bundle"
        return 1
    }
    # A mounted bundle can be reached through aliases such as `/var` and
    # `/private/var`. `find` below emits physical paths, so canonicalize the
    # separately hashed Mach-Os as well. Otherwise their alias-spelled paths
    # miss the exclusions and are counted again as auxiliary resources.
    main_macho="$(/bin/realpath "$main_macho" 2>/dev/null)" || {
        build_provenance_error "main executable is not readable: $main_macho"
        return 1
    }
    ffi_macho="$(/bin/realpath "$ffi_macho" 2>/dev/null)" || {
        build_provenance_error "embedded qube-ffi is not readable: $ffi_macho"
        return 1
    }
    contents="$app_bundle/Contents"
    info_plist="$contents/Info.plist"
    manifest="$(build_provenance_bundle_manifest_path "$app_bundle")"
    [[ -f "$info_plist" && -f "$main_macho" && -f "$ffi_macho" ]] || {
        build_provenance_error "bundle is missing an auxiliary-digest input: $app_bundle"
        return 1
    }
    info_digest="$(build_provenance_canonical_info_digest "$info_plist")" || return 1

    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pensieve-bundle-provenance.XXXXXX")" \
        || return 1
    paths_file="$work_dir/paths"
    records_file="$work_dir/records"
    if ! /usr/bin/find "$contents" \
        -path "$contents/_CodeSignature" -type d -prune -o \
        \( -type f -o -type l \) -print0 \
        | LC_ALL=C /usr/bin/sort -zu >"$paths_file"; then
        /bin/rm -R "$work_dir"
        return 1
    fi
    printf 'pensieve-bundle-auxiliary-v1\0canonical-info\0%s\0' \
        "$info_digest" >"$records_file"
    while IFS= read -r -d '' path; do
        [[ "$path" != "$info_plist" ]] || continue
        [[ "$path" != "$main_macho" ]] || continue
        [[ "$path" != "$ffi_macho" ]] || continue
        [[ "$path" != "$manifest" ]] || continue
        [[ "$path" != "$contents/CodeResources" ]] || continue
        relative="${path#"$app_bundle"/}"
        if ! build_provenance_append_path_record \
            "$path" "$relative" "$app_bundle" "$records_file"; then
            /bin/rm -R "$work_dir"
            return 1
        fi
    done <"$paths_file"
    digest="$(build_provenance_sha256_file "$records_file")" || {
        /bin/rm -R "$work_dir"
        return 1
    }
    /bin/rm -R "$work_dir"
    printf '%s\n' "$digest"
}

# build_provenance_write_manifest MANIFEST COMMIT INPUT_SHA FFI_PROFILE
#   CONFIGURATION ARCH MAIN_PAYLOAD_SHA FFI_PAYLOAD_SHA BUILD_DATE
build_provenance_write_manifest() {
    local manifest="$1"
    local commit="$2"
    local input_digest="$3"
    local ffi_profile="$4"
    local configuration="$5"
    local architecture="$6"
    local main_payload_digest="$7"
    local ffi_payload_digest="$8"
    local build_date="$9"
    local partial digest app_bundle info_plist executable main_macho ffi_macho
    local auxiliary_digest signing_team main_team ffi_team entitlements_digest
    local main_hardened_runtime ffi_hardened_runtime

    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
        build_provenance_error "commit must be a full 40-character Git object ID"
        return 1
    }
    for digest in "$input_digest" "$main_payload_digest" "$ffi_payload_digest"; do
        build_provenance_is_sha256 "$digest" || {
            build_provenance_error "manifest digest is not SHA-256: $digest"
            return 1
        }
    done
    case "$ffi_profile" in debug|release) ;; *) return 1 ;; esac
    [[ -n "$configuration" && -n "$architecture" && -n "$build_date" ]] || return 1
    [[ -d "$(dirname "$manifest")" ]] || {
        build_provenance_error "manifest parent does not exist: $(dirname "$manifest")"
        return 1
    }

    app_bundle="$(cd "$(dirname "$manifest")/../.." 2>/dev/null && pwd -P)" || return 1
    info_plist="$app_bundle/Contents/Info.plist"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "$info_plist" 2>/dev/null)" || return 1
    [[ -n "$executable" && "$executable" != */* ]] || return 1
    main_macho="$app_bundle/Contents/MacOS/$executable"
    ffi_macho="$app_bundle/Contents/Frameworks/libqube_ffi.dylib"
    build_provenance_assert_payload_shapes "$main_macho" "$ffi_macho" || return 1
    auxiliary_digest="$(build_provenance_bundle_auxiliary_digest \
        "$app_bundle" "$main_macho" "$ffi_macho")" || return 1
    main_team="$(build_provenance_codesign_team_identifier "$main_macho")" || return 1
    ffi_team="$(build_provenance_codesign_team_identifier "$ffi_macho")" || return 1
    [[ "$main_team" == "$ffi_team" ]] || {
        build_provenance_error \
            "main executable and FFI carry different TeamIdentifiers: $main_team vs $ffi_team"
        return 1
    }
    signing_team="$main_team"
    entitlements_digest="$(build_provenance_codesign_entitlements_digest "$main_macho")" \
        || return 1
    main_hardened_runtime="$(build_provenance_hardened_runtime_value "$main_macho")" \
        || return 1
    ffi_hardened_runtime="$(build_provenance_hardened_runtime_value "$ffi_macho")" \
        || return 1
    for digest in "$auxiliary_digest" "$entitlements_digest"; do
        build_provenance_is_sha256 "$digest" || return 1
    done

    partial="$manifest.partial.$$"
    /bin/rm -f "$partial"
    if ! /usr/bin/plutil -create xml1 "$partial" \
        || ! /usr/bin/plutil -insert SchemaVersion -integer "$PENSIEVE_BUILD_PROVENANCE_SCHEMA_VERSION" "$partial" \
        || ! /usr/bin/plutil -insert BuildRecipeSchema -string "$PENSIEVE_BUILD_RECIPE_SCHEMA" "$partial" \
        || ! /usr/bin/plutil -insert Commit -string "$commit" "$partial" \
        || ! /usr/bin/plutil -insert RuntimeInputSHA256 -string "$input_digest" "$partial" \
        || ! /usr/bin/plutil -insert FFIProfile -string "$ffi_profile" "$partial" \
        || ! /usr/bin/plutil -insert FFILibraryName -string "libqube_ffi.dylib" "$partial" \
        || ! /usr/bin/plutil -insert FFIInputRelativePath -string "Pensieve/Vendor/qube-ffi/$ffi_profile/libqube_ffi.dylib" "$partial" \
        || ! /usr/bin/plutil -insert BuildConfiguration -string "$configuration" "$partial" \
        || ! /usr/bin/plutil -insert Architecture -string "$architecture" "$partial" \
        || ! /usr/bin/plutil -insert MainExecutableNormalizedSHA256 -string "$main_payload_digest" "$partial" \
        || ! /usr/bin/plutil -insert FFILibraryNormalizedSHA256 -string "$ffi_payload_digest" "$partial" \
        || ! /usr/bin/plutil -insert BundleAuxiliarySHA256 -string "$auxiliary_digest" "$partial" \
        || ! /usr/bin/plutil -insert SigningTeamIdentifier -string "$signing_team" "$partial" \
        || ! /usr/bin/plutil -insert EntitlementsSHA256 -string "$entitlements_digest" "$partial" \
        || ! /usr/bin/plutil -insert MainHardenedRuntime -bool "$main_hardened_runtime" "$partial" \
        || ! /usr/bin/plutil -insert FFIHardenedRuntime -bool "$ffi_hardened_runtime" "$partial" \
        || ! /usr/bin/plutil -insert BuildDate -string "$build_date" "$partial" \
        || ! /usr/bin/plutil -lint "$partial" >/dev/null; then
        /bin/rm -f "$partial"
        build_provenance_error "could not write manifest: $manifest"
        return 1
    fi
    if ! /bin/mv -f "$partial" "$manifest"; then
        /bin/rm -f "$partial"
        return 1
    fi
}

build_provenance_read_manifest_value() {
    local manifest="$1"
    local key="$2"

    [[ -f "$manifest" ]] || {
        build_provenance_error "manifest not found: $manifest"
        return 1
    }
    /usr/bin/plutil -extract "$key" raw -n "$manifest" 2>/dev/null || {
        build_provenance_error "manifest is missing key: $key"
        return 1
    }
}

build_provenance_expect_manifest_value() {
    local manifest="$1"
    local key="$2"
    local expected="$3"
    local actual

    actual="$(build_provenance_read_manifest_value "$manifest" "$key")" || return 1
    [[ "$actual" == "$expected" ]] || {
        build_provenance_error "$key mismatch: expected '$expected', found '$actual'"
        return 1
    }
}

# build_provenance_verify_manifest MANIFEST EXPECTED_COMMIT EXPECTED_INPUT_SHA
#   EXPECTED_FFI_PROFILE EXPECTED_CONFIGURATION EXPECTED_ARCH MAIN_MACHO FFI_MACHO
#   [TEAM_POLICY]
#
# TEAM_POLICY defaults to `strict`: both runtime payloads must retain the
# trusted TeamIdentifier sealed into the manifest. The only other policy,
# `staged`, exists for a copied smoke bundle whose primary executable is
# necessarily re-signed when its bundle identity changes. That mode accepts the
# manifest TeamIdentifier or an ad-hoc `not-set` TeamIdentifier for the primary
# executable, but never relaxes the nested FFI identity and additionally binds
# the outer bundle to the current primary-executable signature. Payload bytes,
# entitlements and hardened-runtime flags remain exact in both modes.
build_provenance_verify_manifest() {
    local manifest="$1"
    local expected_commit="$2"
    local expected_input_digest="$3"
    local expected_ffi_profile="$4"
    local expected_configuration="$5"
    local expected_architecture="$6"
    local main_macho="$7"
    local ffi_macho="$8"
    local team_policy="${9:-strict}"
    local expected_main_payload expected_ffi_payload actual_main_payload actual_ffi_payload
    local expected_auxiliary actual_auxiliary expected_team main_team ffi_team outer_team
    local expected_entitlements actual_main_entitlements actual_ffi_entitlements outer_entitlements
    local no_entitlements
    local expected_main_hardened expected_ffi_hardened actual_main_hardened actual_ffi_hardened
    local outer_hardened
    local app_bundle build_date

    case "$team_policy" in
        strict|staged) ;;
        *)
            build_provenance_error "unknown manifest TeamIdentifier policy: $team_policy"
            return 1
            ;;
    esac

    /usr/bin/plutil -lint "$manifest" >/dev/null 2>&1 || {
        build_provenance_error "manifest is not a valid plist: $manifest"
        return 1
    }
    build_provenance_expect_manifest_value "$manifest" SchemaVersion \
        "$PENSIEVE_BUILD_PROVENANCE_SCHEMA_VERSION" || return 1
    build_provenance_expect_manifest_value "$manifest" BuildRecipeSchema \
        "$PENSIEVE_BUILD_RECIPE_SCHEMA" || return 1
    build_provenance_expect_manifest_value "$manifest" Commit "$expected_commit" || return 1
    build_provenance_expect_manifest_value "$manifest" RuntimeInputSHA256 \
        "$expected_input_digest" || return 1
    build_provenance_expect_manifest_value "$manifest" FFIProfile "$expected_ffi_profile" || return 1
    build_provenance_expect_manifest_value "$manifest" FFILibraryName "libqube_ffi.dylib" || return 1
    build_provenance_expect_manifest_value "$manifest" FFIInputRelativePath \
        "Pensieve/Vendor/qube-ffi/$expected_ffi_profile/libqube_ffi.dylib" || return 1
    build_provenance_expect_manifest_value "$manifest" BuildConfiguration \
        "$expected_configuration" || return 1
    build_provenance_expect_manifest_value "$manifest" Architecture \
        "$expected_architecture" || return 1

    build_provenance_assert_payload_shapes "$main_macho" "$ffi_macho" || return 1
    build_provenance_assert_macho_architecture "$main_macho" "$expected_architecture" \
        || return 1
    build_provenance_assert_macho_architecture "$ffi_macho" "$expected_architecture" \
        || return 1

    build_date="$(build_provenance_read_manifest_value "$manifest" BuildDate)" || return 1
    [[ "$build_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        build_provenance_error "BuildDate is not canonical UTC: $build_date"
        return 1
    }

    expected_main_payload="$(build_provenance_read_manifest_value \
        "$manifest" MainExecutableNormalizedSHA256)" || return 1
    expected_ffi_payload="$(build_provenance_read_manifest_value \
        "$manifest" FFILibraryNormalizedSHA256)" || return 1
    expected_auxiliary="$(build_provenance_read_manifest_value \
        "$manifest" BundleAuxiliarySHA256)" || return 1
    expected_team="$(build_provenance_read_manifest_value \
        "$manifest" SigningTeamIdentifier)" || return 1
    expected_entitlements="$(build_provenance_read_manifest_value \
        "$manifest" EntitlementsSHA256)" || return 1
    expected_main_hardened="$(build_provenance_read_manifest_value \
        "$manifest" MainHardenedRuntime)" || return 1
    expected_ffi_hardened="$(build_provenance_read_manifest_value \
        "$manifest" FFIHardenedRuntime)" || return 1
    build_provenance_is_sha256 "$expected_main_payload" || return 1
    build_provenance_is_sha256 "$expected_ffi_payload" || return 1
    build_provenance_is_sha256 "$expected_auxiliary" || return 1
    build_provenance_is_sha256 "$expected_entitlements" || return 1
    [[ -n "$expected_team" ]] || return 1
    [[ "$expected_main_hardened" == "true" || "$expected_main_hardened" == "false" ]] \
        || return 1
    [[ "$expected_ffi_hardened" == "true" || "$expected_ffi_hardened" == "false" ]] \
        || return 1

    actual_main_payload="$(build_provenance_normalized_macho_digest "$main_macho")" || return 1
    actual_ffi_payload="$(build_provenance_normalized_macho_digest "$ffi_macho")" || return 1
    [[ "$actual_main_payload" == "$expected_main_payload" ]] || {
        build_provenance_error "main executable payload does not match the manifest"
        return 1
    }
    [[ "$actual_ffi_payload" == "$expected_ffi_payload" ]] || {
        build_provenance_error "embedded qube-ffi payload does not match the manifest"
        return 1
    }

    app_bundle="$(cd "$(dirname "$manifest")/../.." 2>/dev/null && pwd -P)" || return 1
    actual_auxiliary="$(build_provenance_bundle_auxiliary_digest \
        "$app_bundle" "$main_macho" "$ffi_macho")" || return 1
    [[ "$actual_auxiliary" == "$expected_auxiliary" ]] || {
        build_provenance_error "bundle Info.plist/resources do not match the manifest"
        return 1
    }

    main_team="$(build_provenance_codesign_team_identifier "$main_macho")" || return 1
    ffi_team="$(build_provenance_codesign_team_identifier "$ffi_macho")" || return 1
    [[ "$ffi_team" == "$expected_team" ]] || {
        build_provenance_error \
            "embedded FFI TeamIdentifier mismatch: expected $expected_team, found $ffi_team"
        return 1
    }
    case "$team_policy" in
        strict)
            [[ "$main_team" == "$expected_team" ]] || {
                build_provenance_error \
                    "main executable TeamIdentifier mismatch: expected $expected_team, found $main_team"
                return 1
            }
            ;;
        staged)
            [[ "$main_team" == "$expected_team" || "$main_team" == "not-set" ]] || {
                build_provenance_error \
                    "staged main executable TeamIdentifier is neither the sealed source team nor ad-hoc: expected $expected_team or not-set, found $main_team"
                return 1
            }
            outer_team="$(build_provenance_codesign_team_identifier "$app_bundle")" || return 1
            [[ "$outer_team" == "$main_team" ]] || {
                build_provenance_error \
                    "staged outer bundle and main executable carry different TeamIdentifiers: outer=$outer_team, main=$main_team"
                return 1
            }
            ;;
    esac
    actual_main_entitlements="$(build_provenance_codesign_entitlements_digest "$main_macho")" \
        || return 1
    [[ "$actual_main_entitlements" == "$expected_entitlements" ]] || {
        build_provenance_error "main executable entitlements do not match the manifest"
        return 1
    }
    if [[ "$team_policy" == "staged" ]]; then
        outer_entitlements="$(build_provenance_codesign_entitlements_digest "$app_bundle")" \
            || return 1
        [[ "$outer_entitlements" == "$expected_entitlements" ]] || {
            build_provenance_error \
                "staged outer bundle entitlements do not match the manifest"
            return 1
        }
    fi
    actual_ffi_entitlements="$(build_provenance_codesign_entitlements_digest "$ffi_macho")" \
        || return 1
    no_entitlements="$(build_provenance_no_entitlements_digest)" || return 1
    [[ "$actual_ffi_entitlements" == "$no_entitlements" ]] || {
        build_provenance_error "embedded qube-ffi unexpectedly carries entitlements"
        return 1
    }
    actual_main_hardened="$(build_provenance_hardened_runtime_value "$main_macho")" \
        || return 1
    actual_ffi_hardened="$(build_provenance_hardened_runtime_value "$ffi_macho")" \
        || return 1
    [[ "$actual_main_hardened" == "$expected_main_hardened" ]] || {
        build_provenance_error "main executable hardened-runtime flag does not match the manifest"
        return 1
    }
    [[ "$actual_ffi_hardened" == "$expected_ffi_hardened" ]] || {
        build_provenance_error "embedded qube-ffi hardened-runtime flag does not match the manifest"
        return 1
    }
    if [[ "$team_policy" == "staged" ]]; then
        outer_hardened="$(build_provenance_hardened_runtime_value "$app_bundle")" \
            || return 1
        [[ "$outer_hardened" == "$expected_main_hardened" ]] || {
            build_provenance_error \
                "staged outer bundle hardened-runtime flag does not match the manifest"
            return 1
        }
    fi
}

# build_provenance_verify_staged_manifest MANIFEST EXPECTED_COMMIT
#   EXPECTED_INPUT_SHA EXPECTED_FFI_PROFILE EXPECTED_CONFIGURATION EXPECTED_ARCH
#   MAIN_MACHO FFI_MACHO
#
# Explicit security boundary for identity-rewritten smoke copies. Production
# and release-source verification must continue to use the strict function.
build_provenance_verify_staged_manifest() {
    [[ "$#" -eq 8 ]] || {
        build_provenance_error \
            "staged manifest verification expects exactly 8 arguments, got $#"
        return 1
    }
    build_provenance_verify_manifest "$@" staged
}

build_provenance_bundle_manifest_path() {
    printf '%s/Contents/Resources/%s\n' "$1" "$PENSIEVE_BUILD_PROVENANCE_RESOURCE"
}

# build_provenance_verify_bundle_against_source APP_BUNDLE REPO_ROOT COMMIT
#   [EXPECTED_CONFIGURATION] [EXPECTED_ARCH] [EXPECTED_FFI_PROFILE]
#   [EXPECTED_TEAM] [EXPECTED_ENTITLEMENTS_SPEC] [EXPECTED_HARDENED_RUNTIME]
#   [EXPECTED_BUNDLE_ID] [EXPECTED_EXECUTABLE] [EXPECTED_BUNDLE_NAME]
#   [EXPECTED_SIGNATURE_POLICY] [PRECOMPUTED_INPUT_SHA]
#
# Full API for an isolated runtime harness: the bundle must carry a valid
# manifest, its payloads must match that manifest, and the manifest input
# digest must match the current source tree for the recorded FFI profile.
# EXPECTED_ENTITLEMENTS_SPEC is either a readable plist path (test harnesses)
# or git:<repo-relative-path> (release lanes; policy is read from COMMIT).
build_provenance_verify_bundle_against_source() {
    local app_bundle="$1"
    local repo_root="$2"
    local expected_commit="$3"
    local expected_configuration="${4:-release}"
    local expected_architecture="${5:-arm64}"
    local expected_ffi_profile="${6:-}"
    local expected_team="${7:-}"
    local expected_entitlements_spec="${8:-}"
    local expected_hardened_runtime="${9:-}"
    local expected_bundle_id="${10:-}"
    local expected_executable="${11:-}"
    local expected_bundle_name="${12:-}"
    local expected_signature_policy="${13:-team-only}"
    local precomputed_input_digest="${14:-}"
    local manifest info_plist executable bundle_identifier bundle_name bundle_display_name
    local bundle_commit ffi_profile input_digest
    local manifest_team outer_team manifest_entitlements outer_entitlements expected_entitlements
    local manifest_main_hardened manifest_ffi_hardened outer_hardened
    local repo_version repo_build bundle_version bundle_build main_macho ffi_macho

    case "$expected_signature_policy" in
        team-only|developer-id) ;;
        *)
            build_provenance_error \
                "unknown signature policy: $expected_signature_policy"
            return 1
            ;;
    esac
    if [[ -z "$precomputed_input_digest" ]]; then
        build_provenance_assert_head "$repo_root" "$expected_commit" || return 1
        build_provenance_assert_runtime_inputs_clean "$repo_root" \
            "${expected_ffi_profile:-release}" || return 1
    else
        build_provenance_is_sha256 "$precomputed_input_digest" || {
            build_provenance_error "precomputed runtime-input digest is not SHA-256"
            return 1
        }
        [[ "$(/usr/bin/git -C "$repo_root" rev-parse "$expected_commit^{commit}" \
            2>/dev/null)" == "$expected_commit" ]] || {
            build_provenance_error \
                "provenance commit is not available as an exact commit object: $expected_commit"
            return 1
        }
    fi

    manifest="$(build_provenance_bundle_manifest_path "$app_bundle")"
    info_plist="$app_bundle/Contents/Info.plist"
    /usr/bin/codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1 || {
        build_provenance_error "bundle signature is invalid; provenance is not sealed: $app_bundle"
        return 1
    }
    [[ -f "$info_plist" ]] || {
        build_provenance_error "bundle Info.plist not found: $info_plist"
        return 1
    }
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null)" || {
        build_provenance_error "bundle has no CFBundleExecutable: $app_bundle"
        return 1
    }
    [[ "$executable" != */* && -n "$executable" ]] || {
        build_provenance_error "unsafe CFBundleExecutable value: $executable"
        return 1
    }
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$info_plist" 2>/dev/null)" || return 1
    bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' \
        "$info_plist" 2>/dev/null)" || return 1
    bundle_display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' \
        "$info_plist" 2>/dev/null)" || return 1
    if [[ -n "$expected_bundle_id" && "$bundle_identifier" != "$expected_bundle_id" ]]; then
        build_provenance_error \
            "bundle identifier $bundle_identifier does not match release identity $expected_bundle_id"
        return 1
    fi
    if [[ -n "$expected_executable" && "$executable" != "$expected_executable" ]]; then
        build_provenance_error \
            "bundle executable $executable does not match release identity $expected_executable"
        return 1
    fi
    if [[ -n "$expected_bundle_name" \
        && ( "$bundle_name" != "$expected_bundle_name" \
            || "$bundle_display_name" != "$expected_bundle_name" ) ]]; then
        build_provenance_error \
            "bundle name/display identity does not match release identity $expected_bundle_name"
        return 1
    fi
    main_macho="$app_bundle/Contents/MacOS/$executable"
    ffi_macho="$app_bundle/Contents/Frameworks/libqube_ffi.dylib"
    build_provenance_assert_payload_shapes "$main_macho" "$ffi_macho" || return 1
    bundle_commit="$(/usr/libexec/PlistBuddy -c 'Print :PensieveBuildCommit' "$info_plist" 2>/dev/null)" || {
        build_provenance_error "bundle has no PensieveBuildCommit: $app_bundle"
        return 1
    }
    [[ "$bundle_commit" == "$expected_commit" ]] || {
        build_provenance_error "Info.plist commit does not match expected commit"
        return 1
    }
    repo_version="$(/usr/bin/git -C "$repo_root" show "$expected_commit:VERSION" \
        2>/dev/null | /usr/bin/tr -d '[:space:]')" || {
        build_provenance_error "could not read VERSION from provenance commit"
        return 1
    }
    [[ -n "$repo_version" ]] || {
        build_provenance_error "VERSION at provenance commit is empty"
        return 1
    }
    repo_build="$(/usr/bin/git -C "$repo_root" rev-list --count "$expected_commit" \
        2>/dev/null)" || {
        build_provenance_error "expected commit is not available for build-number proof"
        return 1
    }
    bundle_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -n \
        "$info_plist" 2>/dev/null)" || return 1
    bundle_build="$(/usr/bin/plutil -extract CFBundleVersion raw -n \
        "$info_plist" 2>/dev/null)" || return 1
    [[ "$bundle_version" == "$repo_version" ]] || {
        build_provenance_error \
            "bundle version $bundle_version does not match repository VERSION $repo_version"
        return 1
    }
    [[ "$bundle_build" == "$repo_build" ]] || {
        build_provenance_error \
            "bundle build $bundle_build does not match commit count $repo_build"
        return 1
    }

    ffi_profile="$(build_provenance_read_manifest_value "$manifest" FFIProfile)" || return 1
    if [[ -n "$expected_ffi_profile" && "$ffi_profile" != "$expected_ffi_profile" ]]; then
        build_provenance_error \
            "FFI profile mismatch: expected $expected_ffi_profile, found $ffi_profile"
        return 1
    fi
    if [[ -n "$precomputed_input_digest" ]]; then
        input_digest="$precomputed_input_digest"
    else
        input_digest="$(build_provenance_runtime_input_digest "$repo_root" "$ffi_profile")" \
            || return 1
        # Recheck the ref after the expensive dependency/byte pass. A concurrent
        # commit that changes only docs would leave the runtime digest unchanged,
        # but an artifact labeled as commit A must not be approved while HEAD is B.
        build_provenance_assert_head "$repo_root" "$expected_commit" || return 1
        build_provenance_assert_runtime_inputs_clean "$repo_root" "$ffi_profile" || return 1
    fi

    build_provenance_verify_manifest \
        "$manifest" \
        "$expected_commit" \
        "$input_digest" \
        "$ffi_profile" \
        "$expected_configuration" \
        "$expected_architecture" \
        "$main_macho" \
        "$ffi_macho" || return 1

    manifest_team="$(build_provenance_read_manifest_value \
        "$manifest" SigningTeamIdentifier)" || return 1
    outer_team="$(build_provenance_codesign_team_identifier "$app_bundle")" || return 1
    [[ "$outer_team" == "$manifest_team" ]] || {
        build_provenance_error \
            "outer bundle TeamIdentifier $outer_team does not match nested payloads $manifest_team"
        return 1
    }
    if [[ -n "$expected_team" && "$outer_team" != "$expected_team" ]]; then
        build_provenance_error \
            "bundle TeamIdentifier $outer_team is not trusted (expected $expected_team)"
        return 1
    fi
    if [[ "$expected_signature_policy" == "developer-id" ]]; then
        [[ -n "$expected_team" ]] || {
            build_provenance_error \
                "Developer ID signature policy requires an expected TeamIdentifier"
            return 1
        }
        build_provenance_assert_developer_id_signature \
            "$app_bundle" "$expected_team" || return 1
        build_provenance_assert_developer_id_signature \
            "$main_macho" "$expected_team" || return 1
        build_provenance_assert_developer_id_signature \
            "$ffi_macho" "$expected_team" || return 1
    fi

    manifest_entitlements="$(build_provenance_read_manifest_value \
        "$manifest" EntitlementsSHA256)" || return 1
    outer_entitlements="$(build_provenance_codesign_entitlements_digest "$app_bundle")" \
        || return 1
    [[ "$outer_entitlements" == "$manifest_entitlements" ]] || {
        build_provenance_error "outer bundle entitlements do not match the main executable"
        return 1
    }
    if [[ -n "$expected_entitlements_spec" ]]; then
        case "$expected_entitlements_spec" in
            git:*)
                expected_entitlements="$(build_provenance_git_plist_digest \
                    "$repo_root" "$expected_commit" \
                    "${expected_entitlements_spec#git:}")" || return 1
                ;;
            *)
                expected_entitlements="$(build_provenance_entitlements_file_digest \
                    "$expected_entitlements_spec")" || return 1
                ;;
        esac
        [[ "$outer_entitlements" == "$expected_entitlements" ]] || {
            build_provenance_error \
                "bundle entitlements do not match the expected release-lane entitlements"
            return 1
        }
    fi
    if [[ -n "$expected_hardened_runtime" ]]; then
        [[ "$expected_hardened_runtime" == "true" \
            || "$expected_hardened_runtime" == "false" ]] || {
            build_provenance_error \
                "expected hardened-runtime value must be true or false"
            return 1
        }
        manifest_main_hardened="$(build_provenance_read_manifest_value \
            "$manifest" MainHardenedRuntime)" || return 1
        manifest_ffi_hardened="$(build_provenance_read_manifest_value \
            "$manifest" FFIHardenedRuntime)" || return 1
        outer_hardened="$(build_provenance_hardened_runtime_value "$app_bundle")" \
            || return 1
        [[ "$outer_hardened" == "$expected_hardened_runtime" \
            && "$manifest_main_hardened" == "$expected_hardened_runtime" \
            && "$manifest_ffi_hardened" == "$expected_hardened_runtime" ]] || {
            build_provenance_error \
                "hardened-runtime mismatch: expected $expected_hardened_runtime, outer=$outer_hardened, main=$manifest_main_hardened, FFI=$manifest_ffi_hardened"
            return 1
        }
    fi
}

# build_provenance_verify_bundle_against_commit_digest APP_BUNDLE REPO_ROOT
#   COMMIT COMMIT_INPUT_SHA [EXPECTED_CONFIGURATION] [EXPECTED_ARCH]
#   [EXPECTED_FFI_PROFILE] [EXPECTED_TEAM] [EXPECTED_ENTITLEMENTS_SPEC]
#   [EXPECTED_HARDENED_RUNTIME] [EXPECTED_BUNDLE_ID] [EXPECTED_EXECUTABLE]
#   [EXPECTED_BUNDLE_NAME] [EXPECTED_SIGNATURE_POLICY]
#
# Verify an artifact against a digest independently materialized from COMMIT.
# Unlike the live-source API, this does not inspect or trust the caller's index,
# status bits, working tree, or existing SwiftPM checkouts.
build_provenance_verify_bundle_against_commit_digest() {
    [[ "$#" -ge 4 && "$#" -le 14 ]] || {
        build_provenance_error \
            "commit-digest bundle verification expects 4 to 14 arguments, got $#"
        return 1
    }
    build_provenance_verify_bundle_against_source \
        "$1" \
        "$2" \
        "$3" \
        "${5:-release}" \
        "${6:-arm64}" \
        "${7:-}" \
        "${8:-}" \
        "${9:-}" \
        "${10:-}" \
        "${11:-}" \
        "${12:-}" \
        "${13:-}" \
        "${14:-team-only}" \
        "$4"
}
