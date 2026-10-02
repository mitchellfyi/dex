# shellcheck shell=bash
# What did the operator hand to `dx`? A ticket, a tracker URL that is a
# ticket, a project URL, some other URL, a document, or a prompt. The
# classification decides the mode (a source always runs the full workflow),
# the workspace name, and which intake the agent follows in Phase 0.
# bash 3.2 and zsh: no captures from =~, no ${var,,}, no reserved names.

# __dx_input_trim <text> — without leading and trailing whitespace.
__dx_input_trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s\n' "$text"
}

# __dx_input_first_token <text> — the first whitespace-delimited word.
__dx_input_first_token() {
  local text
  text=$(__dx_input_trim "$1")
  printf '%s\n' "${text%%[[:space:]]*}"
}

__dx_input_lower() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# __dx_input_host_path <url> — lower-case host/path without scheme, query,
# fragment, a leading www. or a trailing slash.
__dx_input_host_path() {
  local url
  url=$(__dx_input_lower "$1")
  url="${url#*://}"
  url="${url%%\?*}"
  url="${url%%#*}"
  url="${url#www.}"
  url="${url%/}"
  printf '%s\n' "$url"
}

# __dx_input_origin_slug [repo_root] — owner/repo of the origin remote in
# lower case, for git@host:owner/repo(.git) and scheme://[user@]host/owner/repo(.git).
__dx_input_origin_slug() {
  local repo_root="${1:-.}" origin
  origin=$(git -C "$repo_root" remote get-url origin 2>/dev/null) || return 1
  origin=$(__dx_input_lower "$origin")
  origin="${origin%/}"
  origin="${origin%.git}"
  case "$origin" in
    *://*) origin="${origin#*://}"; origin="${origin#*@}"; origin="${origin#*/}" ;;
    *@*:*) origin="${origin#*:}" ;;
    *) return 1 ;;
  esac
  [[ "$origin" == */* ]] || return 1
  printf '%s\n' "$origin"
}

# __dx_input_document_path <text> — the longest leading part of the text that
# names an existing regular file: the whole text, or the text with trailing
# words dropped one at a time, so "docs/payments spec.md only the refunds"
# finds the file with the space in its name. Fails when there is none.
__dx_input_document_path() {
  local text
  text=$(__dx_input_trim "$1")
  while [[ -n "$text" ]]; do
    if [[ -f "$text" ]]; then
      printf '%s\n' "$text"
      return 0
    fi
    [[ "$text" == *[[:space:]]* ]] || return 1
    text="${text%[[:space:]]*}"
    text=$(__dx_input_trim "$text")
  done
  return 1
}

# __dx_input_segments <host/path> — sets _dx_in_host and _dx_in_seg1.._dx_in_seg4.
__dx_input_segments() {
  local host_path="$1" ipath
  _dx_in_host="${host_path%%/*}"
  ipath="${host_path#*/}"
  [[ "$ipath" == "$host_path" ]] && ipath=""
  _dx_in_seg1="${ipath%%/*}"; ipath="${ipath#*/}"; [[ "$ipath" == "$_dx_in_seg1" ]] && ipath=""
  _dx_in_seg2="${ipath%%/*}"; ipath="${ipath#*/}"; [[ "$ipath" == "$_dx_in_seg2" ]] && ipath=""
  _dx_in_seg3="${ipath%%/*}"; ipath="${ipath#*/}"; [[ "$ipath" == "$_dx_in_seg3" ]] && ipath=""
  _dx_in_seg4="${ipath%%/*}"
}

# dx_input_kind <raw> [repo_root]
# ticket | github-issue | github-pr | linear-issue | linear-project |
# github-project | url | document | prompt
dx_input_kind() {
  local raw="$1" repo_root="${2:-.}" trimmed first lower host_path origin_slug
  trimmed=$(__dx_input_trim "$raw")
  if [[ -z "$trimmed" ]]; then
    printf 'prompt\n'
    return 0
  fi
  if [[ "$trimmed" =~ ^[a-zA-Z]*-?[0-9]+$ ]]; then
    printf 'ticket\n'
    return 0
  fi
  # A document is an existing regular file, possibly with spaces in its name
  # and possibly followed by instructions about it.
  if __dx_input_document_path "$trimmed" >/dev/null; then
    printf 'document\n'
    return 0
  fi
  first=$(__dx_input_first_token "$trimmed")
  lower=$(__dx_input_lower "$first")
  case "$lower" in
    http://*|https://*) ;;
    *) printf 'prompt\n'; return 0 ;;
  esac
  host_path=$(__dx_input_host_path "$first")
  __dx_input_segments "$host_path"
  case "$_dx_in_host" in
    github.com)
      if [[ "$_dx_in_seg3" == projects && "$_dx_in_seg4" =~ ^[0-9]+$ ]]; then
        # orgs/<org>/projects/<n>, users/<u>/projects/<n>, <owner>/<repo>/projects/<n>
        printf 'github-project\n'
        return 0
      fi
      if [[ ( "$_dx_in_seg3" == issues || "$_dx_in_seg3" == pull ) && "$_dx_in_seg4" =~ ^[0-9]+$ ]]; then
        origin_slug=$(__dx_input_origin_slug "$repo_root" 2>/dev/null || true)
        if [[ -n "$origin_slug" && "$origin_slug" == "$_dx_in_seg1/$_dx_in_seg2" ]]; then
          if [[ "$_dx_in_seg3" == issues ]]; then printf 'github-issue\n'; else printf 'github-pr\n'; fi
          return 0
        fi
      fi
      ;;
    linear.app)
      if [[ "$_dx_in_seg2" == issue && "$_dx_in_seg3" =~ ^[a-z0-9]+-[0-9]+$ ]]; then
        printf 'linear-issue\n'
        return 0
      fi
      if [[ "$_dx_in_seg2" == project && -n "$_dx_in_seg3" ]]; then
        printf 'linear-project\n'
        return 0
      fi
      ;;
  esac
  printf 'url\n'
}

# dx_input_ticket <raw> [repo_root] — the ticket a ticket-like input names:
# the key or number itself, the issue or PR number of a GitHub URL on this
# repository, or the upper-case key of a Linear issue URL. Fails otherwise.
dx_input_ticket() {
  local raw="$1" repo_root="${2:-.}" kind first host_path
  kind=$(dx_input_kind "$raw" "$repo_root")
  case "$kind" in
    ticket)
      __dx_input_trim "$raw"
      ;;
    github-issue|github-pr)
      first=$(__dx_input_first_token "$raw")
      host_path=$(__dx_input_host_path "$first")
      __dx_input_segments "$host_path"
      printf '%s\n' "$_dx_in_seg4"
      ;;
    linear-issue)
      first=$(__dx_input_first_token "$raw")
      host_path=$(__dx_input_host_path "$first")
      __dx_input_segments "$host_path"
      printf '%s' "$_dx_in_seg3" | LC_ALL=C tr '[:lower:]' '[:upper:]'
      printf '\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# dx_input_slug <raw> <kind> — a short workspace slug that names the source:
# the project part of a project URL, host and path of another URL, the file
# name of a document, the words of a prompt. At most 48 characters.
dx_input_slug() {
  local raw="$1" kind="$2" first host_path text slug
  case "$kind" in
    linear-project)
      first=$(__dx_input_first_token "$raw")
      host_path=$(__dx_input_host_path "$first")
      __dx_input_segments "$host_path"
      text="${_dx_in_seg2} ${_dx_in_seg3}"
      ;;
    github-project)
      first=$(__dx_input_first_token "$raw")
      host_path=$(__dx_input_host_path "$first")
      __dx_input_segments "$host_path"
      if [[ "$_dx_in_seg1" == orgs || "$_dx_in_seg1" == users ]]; then
        text="${_dx_in_seg2} ${_dx_in_seg3} ${_dx_in_seg4}"
      else
        text="${_dx_in_seg1} ${_dx_in_seg2} ${_dx_in_seg3} ${_dx_in_seg4}"
      fi
      ;;
    url|github-issue|github-pr|linear-issue)
      first=$(__dx_input_first_token "$raw")
      text=$(__dx_input_host_path "$first")
      ;;
    document)
      text=$(__dx_input_document_path "$raw") || text=$(__dx_input_first_token "$raw")
      text="${text##*/}"
      text="${text%.*}"
      ;;
    *)
      text="$raw"
      ;;
  esac
  slug=$(dx_slugify "$text")
  if [[ "${#slug}" -gt 48 ]]; then
    slug="${slug:0:48}"
    slug="${slug%-*}"
  fi
  slug="${slug%-}"
  printf '%s\n' "$slug"
}
