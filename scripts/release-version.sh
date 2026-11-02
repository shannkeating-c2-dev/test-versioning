#!/usr/bin/env bash
# Semantic version calculator for release allocation.
#
#   latest
#     Read strict vMAJOR.MINOR.PATCH lines on stdin and print the greatest.
#     An empty list prints v0.0.0.
#
#   bump vMAJOR.MINOR.PATCH [FEATURE_PATTERN]
#     Read merged branch names on stdin. A name containing FEATURE_PATTERN
#     as a segment (bounded by the start, the end, or / _ -) bumps minor
#     and resets patch. Anything else bumps patch. FEATURE_PATTERN is an
#     extended regular expression matched case-insensitively. Default: feature.
#
#   discover TAGS_FILE BRANCHES_FILE RELEASES_FILE
#     TAGS_FILE lists git tags. BRANCHES_FILE lists release branches,
#     including legacy names. RELEASES_FILE lists GitHub release tag names
#     and must include drafts. Prints:
#       latest_version=<greatest allocated version, or v0.0.0>
#       history_base=<origin/release/vX.Y.Z | vX.Y.Z | empty>
#     latest_version counts draft releases so a version cannot be reused.
#     history_base is only the newest tag or release branch, because a draft
#     has no reachable commit. A release branch is preferred over a tag of
#     the same version. Allow-listed legacy branch names are ignored with a
#     warning. Pre-release tags are an error.

set -euo pipefail

SEMVER_PATTERN='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
PRERELEASE_PATTERN='^(release/)?v[0-9]+\.[0-9]+\.[0-9]+-'

usage() {
  echo "Usage: $0 {latest|bump vMAJOR.MINOR.PATCH [FEATURE_PATTERN]|discover TAGS_FILE BRANCHES_FILE RELEASES_FILE}" >&2
}

validate_version() {
  local version="$1"
  if [[ "$version" =~ $PRERELEASE_PATTERN ]]; then
    echo "Pre-release tag is not allowed: $version (expected vMAJOR.MINOR.PATCH)" >&2
    return 1
  fi
  if [[ ! "$version" =~ $SEMVER_PATTERN ]]; then
    echo "Invalid semantic version: $version (expected vMAJOR.MINOR.PATCH)" >&2
    return 1
  fi
}

# Compare strict versions. Prints the greatest argument. Requires at least one.
max_version() {
  local candidate="$1" latest="$1"
  local latest_major latest_minor latest_patch
  local major minor patch

  [[ "$latest" =~ $SEMVER_PATTERN ]]
  latest_major=$((10#${BASH_REMATCH[1]}))
  latest_minor=$((10#${BASH_REMATCH[2]}))
  latest_patch=$((10#${BASH_REMATCH[3]}))
  shift

  for candidate in "$@"; do
    [[ "$candidate" =~ $SEMVER_PATTERN ]]
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    patch=$((10#${BASH_REMATCH[3]}))
    if (( major > latest_major ||
          (major == latest_major && minor > latest_minor) ||
          (major == latest_major && minor == latest_minor && patch > latest_patch) )); then
      latest="$candidate"
      latest_major=$major
      latest_minor=$minor
      latest_patch=$patch
    fi
  done
  printf '%s\n' "$latest"
}

latest_version() {
  local candidate
  local -a versions=()

  while IFS= read -r candidate || [[ -n "${candidate:-}" ]]; do
    [[ -z "$candidate" ]] && continue
    validate_version "$candidate"
    versions+=("$candidate")
  done

  if ((${#versions[@]} == 0)); then
    printf '%s\n' "v0.0.0"
    return
  fi
  max_version "${versions[@]}"
}

bump_version() {
  local current="$1" feature_pattern="${2:-feature}"
  local branch branch_lower bump="patch" feature_regex regex_status=0
  local major minor patch

  feature_pattern="${feature_pattern,,}"
  if [[ -z "$feature_pattern" ]]; then
    feature_pattern="feature"
  fi
  [[ "a" =~ $feature_pattern ]] || regex_status=$?
  if [[ "$regex_status" -eq 2 ]]; then
    echo "Invalid bump feature pattern: $feature_pattern" >&2
    return 1
  fi

  validate_version "$current"
  [[ "$current" =~ $SEMVER_PATTERN ]]
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))

  # The pattern is one segment. "feature" matches "LEAS-1-feature-x" and not "myfeature".
  feature_regex="(^|[/_-])(${feature_pattern})([/_-]|\$)"

  while IFS= read -r branch || [[ -n "${branch:-}" ]]; do
    [[ -z "$branch" ]] && continue
    branch_lower="${branch,,}"
    if [[ "$branch_lower" =~ $feature_regex ]]; then
      bump="minor"
    fi
  done

  if [[ "$bump" == "minor" ]]; then
    minor=$((minor + 1))
    patch=0
  else
    patch=$((patch + 1))
  fi
  printf 'v%d.%d.%d\n' "$major" "$minor" "$patch"
}

# Reduce refs/remotes/origin/release/v1.2.3, origin/release/v1.2.3 and
# refs/tags/v1.2.3 to release/v1.2.3 or v1.2.3.
normalize_ref() {
  local name="$1"
  name="${name#refs/remotes/origin/}"
  name="${name#refs/heads/}"
  name="${name#refs/tags/}"
  name="${name#origin/}"
  printf '%s\n' "$name"
}

# Date-stamped release branches from before vMAJOR.MINOR.PATCH.
# These shapes are intentional. A name that matches none of them is an error,
# so an unfamiliar branch cannot disappear without being reported.
is_legacy_release_name() {
  local name="$1"
  [[ "$name" =~ ^release/prod-[0-9]{8}(-([0-9]+|v[0-9]+))?$ ]] && return 0
  [[ "$name" =~ ^release/release-[0-9]{8,9}-([0-9]+|v[0-9]+)$ ]] && return 0
  [[ "$name" =~ ^release/release-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] && return 0
  [[ "$name" =~ ^release/[0-9]{8}-[0-9]+$ ]] && return 0
  [[ "$name" == "release/initial-prod-release" ]] && return 0
  return 1
}

ignore_legacy_release_name() {
  echo "Warning: ignoring allow-listed legacy release name: $1" >&2
}

reject_prerelease() {
  echo "Pre-release tag is not allowed: $1 (expected vMAJOR.MINOR.PATCH)" >&2
  exit 1
}

reject_unrecognised() {
  echo "Unrecognised release name: $1 (not a strict vMAJOR.MINOR.PATCH version and not in the legacy allow-list)" >&2
  exit 1
}

is_strict_version_name() {
  local name="$1"
  [[ "$name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || "$name" =~ ^release/v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_of_name() {
  local name="$1"
  name="${name#release/}"
  printf '%s\n' "$name"
}

# Classify one release-branch line into BRANCH_VERSIONS, a warning, or an error.
record_branch_name() {
  local raw="$1" name legacy_name
  name="$(normalize_ref "$raw")"

  if is_strict_version_name "$name"; then
    BRANCH_VERSIONS+=("$(version_of_name "$name")")
    return
  fi
  if [[ "$name" =~ $PRERELEASE_PATTERN ]]; then
    reject_prerelease "$raw"
  fi

  legacy_name="$name"
  if [[ "$legacy_name" != release/* ]]; then
    legacy_name="release/$legacy_name"
  fi
  if is_legacy_release_name "$legacy_name"; then
    ignore_legacy_release_name "$raw"
    return
  fi
  reject_unrecognised "$raw"
}

# Tags and GitHub release tag names. Legacy branch names are not valid here.
record_tag_name() {
  local raw="$1" name
  name="$(normalize_ref "$raw")"

  if [[ "$name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    TAG_VERSIONS+=("$name")
    return
  fi
  if [[ "$name" =~ $PRERELEASE_PATTERN ]]; then
    reject_prerelease "$raw"
  fi
  echo "Invalid semantic version: $raw (expected vMAJOR.MINOR.PATCH)" >&2
  exit 1
}

record_release_name() {
  local raw="$1" name
  name="$(normalize_ref "$raw")"

  if [[ "$name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RELEASE_VERSIONS+=("$name")
    return
  fi
  if [[ "$name" =~ $PRERELEASE_PATTERN ]]; then
    reject_prerelease "$raw"
  fi
  echo "Invalid semantic version: $raw (expected vMAJOR.MINOR.PATCH)" >&2
  exit 1
}

read_name_file() {
  local file="$1" recorder="$2" line
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    "$recorder" "$line"
  done < "$file"
}

discover_versions() {
  local tags_file="$1" branches_file="$2" releases_file="$3"
  local file history="" history_base="" latest="v0.0.0" version
  local -a TAG_VERSIONS=() BRANCH_VERSIONS=() RELEASE_VERSIONS=()
  local -a allocated=() reachable=()

  for file in "$tags_file" "$branches_file" "$releases_file"; do
    if [[ ! -f "$file" ]]; then
      echo "Release list is not a file: $file" >&2
      exit 2
    fi
  done

  read_name_file "$tags_file" record_tag_name
  read_name_file "$branches_file" record_branch_name
  read_name_file "$releases_file" record_release_name

  allocated=("${TAG_VERSIONS[@]}" "${BRANCH_VERSIONS[@]}" "${RELEASE_VERSIONS[@]}")
  if ((${#allocated[@]} > 0)); then
    latest="$(max_version "${allocated[@]}")"
  fi

  reachable=("${TAG_VERSIONS[@]}" "${BRANCH_VERSIONS[@]}")
  if ((${#reachable[@]} > 0)); then
    history="$(max_version "${reachable[@]}")"
    history_base="$history"
    if ((${#BRANCH_VERSIONS[@]} > 0)); then
      for version in "${BRANCH_VERSIONS[@]}"; do
        if [[ "$version" == "$history" ]]; then
          history_base="origin/release/${history}"
          break
        fi
      done
    fi
  fi

  printf 'latest_version=%s\n' "$latest"
  printf 'history_base=%s\n' "$history_base"
}

case "${1:-}" in
  latest) latest_version ;;
  bump)
    [[ $# -eq 2 || $# -eq 3 ]] || { echo "Usage: $0 bump vMAJOR.MINOR.PATCH [FEATURE_PATTERN]" >&2; exit 2; }
    bump_version "$2" "${3:-feature}"
    ;;
  discover)
    [[ $# -eq 4 ]] || { echo "Usage: $0 discover TAGS_FILE BRANCHES_FILE RELEASES_FILE" >&2; exit 2; }
    discover_versions "$2" "$3" "$4"
    ;;
  *) usage; exit 2 ;;
esac
