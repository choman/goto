# shellcheck shell=bash
# shellcheck disable=SC2039
# SOURCE: https://github.com/iridakos/goto
# MIT License
#
# Copyright (c) 2018 Lazarus Lazaridis
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Changes to the given alias directory
# or executes a command based on the arguments.
goto()
{
  local target
  _goto_resolve_db

  if [ -z "$1" ]; then
    # display usage and exit when no args
    _goto_usage
    return
  fi

  subcommand="$1"
  shift
  case "$subcommand" in
    -c|--cleanup)
      _goto_cleanup "$@"
      ;;
    --convert) # Convert home representations in stored paths
      _goto_convert_aliases "$@"
      ;;
    --sync-home) # Rewrite stale /home/<olduser> paths to current $HOME
      _goto_rehome_aliases
      ;;
    -r|--register) # Register an alias
      _goto_register_alias "$@"
      ;;
    -u|--unregister) # Unregister an alias
      _goto_unregister_alias "$@"
      ;;
    -p|--push) # Push the current directory onto the pushd stack, then goto
      _goto_directory_push "$@"
      ;;
    -o|--pop) # Pop the top directory off of the pushd stack, then change that directory
      _goto_directory_pop
      ;;
    -l|--list|-ls|--ls)
      _goto_list_aliases "$@"
      ;;
    -x|--expand) # Expand an alias
      _goto_expand_alias "$@"
      ;;
    -h|--help)
      _goto_usage
      ;;
    -v|--version)
      _goto_version
      ;;
    *)
      _goto_directory "$subcommand"
      ;;
  esac
  return $?
}

_goto_resolve_db()
{
  local CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/goto"
  local DB_NEW="$CONFIG_DIR/goto"
  local DB_OLD="$CONFIG_DIR"

  if [ -z "$GOTO_DB" ]; then
    # Prefer the new nested path; fall back to the old flat path if it exists
    # as a file (legacy installs). On a fresh system, create the new layout.
    if [ -f "$DB_NEW" ]; then
      GOTO_DB="$DB_NEW"
    elif [ -f "$DB_OLD" ]; then
      GOTO_DB="$DB_OLD"
    else
      # Fresh system — use new layout
      GOTO_DB="$DB_NEW"
    fi
  fi

  # Resolve through symlinks so --convert and --sync-home write to the real file
  # -f is used over --canonicalize for portability (macOS compatibility)
  if [ -e "$GOTO_DB" ]; then
    GOTO_DB=$(readlink -f "$GOTO_DB")
  fi

  GOTO_DB_CONFIG_DIRNAME=$(dirname "$GOTO_DB")
  if [[ ! -d "$GOTO_DB_CONFIG_DIRNAME" ]]; then
    mkdir -p "$GOTO_DB_CONFIG_DIRNAME"
  fi
  touch -a "$GOTO_DB"
}

_goto_usage()
{
  cat <<\USAGE
usage: goto [<option>] <alias> [<directory>]

default usage:
  goto <alias> - changes to the directory registered for the given alias

OPTIONS:
  -r, --register: registers an alias
    goto -r|--register <alias> <directory>
  -u, --unregister: unregisters an alias
    goto -u|--unregister <alias>
  -p, --push: pushes the current directory onto the stack, then performs goto
    goto -p|--push <alias>
  -o, --pop: pops the top directory from the stack, then changes to that directory
    goto -o|--pop
  -l, --list, -ls, --ls: lists aliases
    goto -l|--list|--ls [--raw]
      --raw: show dirs as stored (~, \$HOME, or /home/user)
  -x, --expand: expands an alias
    goto -x|--expand <alias>
  -c, --cleanup: cleans up non existent directory aliases
    goto -c|--cleanup
  --convert: rewrite home portion of all stored paths to a common form
    goto --convert tilde        # use ~ for all home-based paths
    goto --convert home         # use \$HOME for all home-based paths
    goto --convert path         # use /home/<username> for all home-based paths
  --sync-home: rewrite any stale /home/<olduser> prefixes to current \$HOME
    goto --sync-home
  -h, --help: prints this help
    goto -h|--help
  -v, --version: displays the version of the goto script
    goto -v|--version
USAGE
}

# Displays version
_goto_version()
{
  echo "goto version 2.1.0"
}

# Expands directory.
# Helpful for ~, ., .. paths
_goto_expand_directory()
{
  builtin cd "$1" 2>/dev/null && pwd
}

# Normalizes a stored directory path for display.
# Without --raw: expands ~ and $HOME to /home/<username> (the real path).
# With --raw:    shows the stored value as-is (may be ~, $HOME, or /home/...).
_goto_display_directory()
{
  local dir="$1" raw="$2"
  if [[ "$raw" == "1" ]]; then
    echo "$dir"
  else
    # Expand $HOME variable and ~ to the real path
    dir="${dir/\$HOME/$HOME}"
    dir="${dir/\~/$HOME}"
    echo "$dir"
  fi
}

# Normalizes a directory to its canonical /home/<username> form for storage.
# Converts ~, $HOME, and /home/<username> — they all resolve to the same thing.
_goto_normalize_home()
{
  local dir="$1"
  dir="${dir/\~/$HOME}"
  dir="${dir/\$HOME/$HOME}"
  echo "$dir"
}

# Converts the home portion of all stored paths to a given form.
# Usage: _goto_convert_aliases tilde|home|path
_goto_convert_aliases()
{
  if [[ "$1" != "tilde" && "$1" != "home" && "$1" != "path" ]]; then
    _goto_error "usage: goto --convert tilde|home|path"
    return 1
  fi

  local mode="$1"
  local tmp="${GOTO_DB}.tmp"
  local changed=0
  local messages=()

  while read -r name directory; do
    # Resolve whatever form is stored to the real absolute path first
    local real="${directory/\$HOME/$HOME}"
    real="${real/\~/$HOME}"

    # Only touch entries that actually live under $HOME
    if [[ "$real" == "$HOME"* ]]; then
      local suffix="${real#$HOME}"
      local new_dir
      case "$mode" in
        tilde)  new_dir="~${suffix}" ;;
        home)   new_dir="\$HOME${suffix}" ;;
        path)   new_dir="${HOME}${suffix}" ;;
      esac
      if [[ "$new_dir" != "$directory" ]]; then
        # Collect message with the raw stored value (not evaluated)
        messages+=("Converting '$name': $directory -> $new_dir")
        (( changed++ ))
        directory="$new_dir"
      fi
    fi
    echo "$name $directory"
  done < "$GOTO_DB" > "$tmp" && mv "$tmp" "$GOTO_DB"

  # Print messages after the redirection is closed
  for msg in "${messages[@]}"; do
    echo "$msg"
  done

  if [[ "$changed" -eq 0 ]]; then
    echo "No entries needed conversion."
  else
    echo "$changed alias(es) converted to '$mode' form."
  fi
}

# Rewrites any /home/<olduser> prefixes that don't match the current $HOME
# to use the current $HOME instead (preserving the subdirectory path).
# Useful when sharing a goto DB across machines with different usernames.
# Runs silently -- no output on success.
_goto_rehome_aliases()
{
  local tmp="${GOTO_DB}.tmp"

  while read -r name directory; do
    local new_dir="$directory"

    local resolved="${directory/\$HOME/$HOME}"
    resolved="${resolved/\~/$HOME}"

    if [[ "$resolved" =~ ^/home/[^/]+(/.*)? ]]; then
      local prefix
      prefix=$(echo "$resolved" | sed 's|^\(/home/[^/]*\).*|\1|')
      if [[ "$prefix" != "$HOME" ]]; then
        local suffix="${resolved#$prefix}"
        new_dir="${HOME}${suffix}"
      fi
    fi
    echo "$name $new_dir"
  done < "$GOTO_DB" > "$tmp" && mv "$tmp" "$GOTO_DB"
}

# Lists registered aliases.
_goto_list_aliases()
{
  local raw=0
  if [[ "$1" == "--raw" ]]; then
    raw=1
  fi

  local IFS=$' '
  if [ -f "$GOTO_DB" ]; then
    local maxlength=0
    while read -r name directory; do
      local length=${#name}
      if [[ $length -gt $maxlength ]]; then
        local maxlength=$length
      fi
    done < "$GOTO_DB"
    while read -r name directory; do
      local display
      display=$(_goto_display_directory "$directory" "$raw")
      printf "\e[1;36m%${maxlength}s  \e[0m%s\n" "$name" "$display"
    done < "$GOTO_DB"
  else
    echo "You haven't configured any directory aliases yet."
  fi
}

# Expands a registered alias.
_goto_expand_alias()
{
  if [ "$#" -ne "1" ]; then
    _goto_error "usage: goto -x|--expand <alias>"
    return
  fi

  local resolved

  resolved=$(_goto_find_alias_directory "$1")
  if [ -z "$resolved" ]; then
    _goto_error "alias '$1' does not exist"
    return
  fi

  echo "$resolved"
}

# Lists duplicate directory aliases
_goto_find_duplicate()
{
  local duplicates=
  local dir
  dir=$(_goto_normalize_home "$1")

  # Compare against normalized (real-path) form of each stored entry
  duplicates=$(while read -r name stored; do
    local real="${stored/\$HOME/$HOME}"
    real="${real/\~/$HOME}"
    if [[ "$real" == "$dir" ]]; then
      echo "$name $stored"
    fi
  done < "$GOTO_DB" 2>/dev/null)
  echo "$duplicates"
}

# Detects the home form used by existing DB entries (tilde, home, or path).
# Inspects the first entry that lives under $HOME and returns the form it uses.
# Falls back to "path" if the DB is empty or no home-based entries exist.
_goto_db_home_form()
{
  while read -r _ directory; do
    local real="${directory/\$HOME/$HOME}"
    real="${real/\~/$HOME}"
    if [[ "$real" == "$HOME"* ]]; then
      if [[ "$directory" == "~"* ]]; then
        echo "tilde"; return
      elif [[ "$directory" == "\$HOME"* ]]; then
        echo "home"; return
      else
        echo "path"; return
      fi
    fi
  done < "$GOTO_DB" 2>/dev/null
  echo "path"
}

# Applies the DB's home form to a real (expanded) path.
_goto_apply_home_form()
{
  local real="$1" form="$2"
  if [[ "$real" == "$HOME"* ]]; then
    local suffix="${real#$HOME}"
    case "$form" in
      tilde)  echo "~${suffix}" ;;
      home)   echo "\$HOME${suffix}" ;;
      *)      echo "$real" ;;
    esac
  else
    echo "$real"
  fi
}

# Registers and alias.
_goto_register_alias()
{
  if [ "$#" -ne "2" ]; then
    _goto_error "usage: goto -r|--register <alias> <directory>"
    return 1
  fi

  if ! [[ $1 =~ ^[[:alnum:]]+[a-zA-Z0-9_-]*$ ]]; then
    _goto_error "invalid alias - can start with letters or digits followed by letters, digits, hyphens or underscores"
    return 1
  fi

  local resolved
  resolved=$(_goto_find_alias_directory "$1")

  if [ -n "$resolved" ]; then
    _goto_error "alias '$1' exists"
    return 1
  fi

  local directory
  # Expand to real path to validate the directory exists
  local expanded
  expanded=$(_goto_expand_directory "$(_goto_normalize_home "$2")")
  if [ -z "$expanded" ]; then
    _goto_error "failed to register '$1' to '$2' - can't cd to directory"
    return 1
  fi
  # Store in the same home form the rest of the DB uses
  local form
  form=$(_goto_db_home_form)
  directory=$(_goto_apply_home_form "$expanded" "$form")

  local duplicate
  duplicate=$(_goto_find_duplicate "$directory")
  if [ -n "$duplicate" ]; then
    _goto_warning "duplicate alias(es) found: \\n$duplicate"
  fi

  # Append entry to file.
  echo "$1 $directory" >> "$GOTO_DB"
  echo "Alias '$1' registered successfully."
}

# Unregisters the given alias.
_goto_unregister_alias()
{
  if [ "$#" -ne "1" ]; then
    _goto_error "usage: goto -u|--unregister <alias>"
    return 1
  fi

  local resolved
  resolved=$(_goto_find_alias_directory "$1")
  if [ -z "$resolved" ]; then
    _goto_error "alias '$1' does not exist"
    return 1
  fi

  # shellcheck disable=SC2034
  local readonly GOTO_DB_TMP="$HOME/.goto_"
  # Delete entry from file.
  sed "/^$1 /d" "$GOTO_DB" > "$GOTO_DB_TMP" && mv "$GOTO_DB_TMP" "$GOTO_DB"
  echo "Alias '$1' unregistered successfully."
}

# Pushes the current directory onto the stack, then goto
_goto_directory_push()
{
  if [ "$#" -ne "1" ]; then
    _goto_error "usage: goto -p|--push <alias>"
    return
  fi

  { pushd . || return; } 1>/dev/null 2>&1

  _goto_directory "$@"
}

# Pops the top directory from the stack, then goto
_goto_directory_pop()
{
  { popd || return; } 1>/dev/null 2>&1
}

# Unregisters aliases whose directories no longer exist.
_goto_cleanup()
{
  if ! [ -f "$GOTO_DB" ]; then
    return
  fi

  while IFS= read -r i && [ -n "$i" ]; do
    echo "Cleaning up: $i"
    _goto_unregister_alias "$i"
  done <<< "$(while read -r al dir; do
    local real="${dir/\$HOME/$HOME}"
    real="${real/\~/$HOME}"
    [ ! -d "$real" ] && echo "$al"
  done < "$GOTO_DB")"
}

# Changes to the given alias' directory
_goto_directory()
{
  # directly goto the special name that is unable to be registered due to invalid alias, eg: ~
  if ! [[ $1 =~ ^[[:alnum:]]+[a-zA-Z0-9_-]*$ ]]; then
    { builtin cd "$1" 2> /dev/null && return 0; } || \
    { _goto_error "Failed to goto '$1'" && return 1; }
  fi

  local target

  target=$(_goto_resolve_alias "$1") || return 1

  # Expand $HOME and ~ in stored paths before cd
  target="${target/\$HOME/$HOME}"
  target="${target/\~/$HOME}"

  builtin cd "$target" 2> /dev/null || \
    { _goto_error "Failed to goto '$target'" && return 1; }
}

# Fetches the alias directory.
_goto_find_alias_directory()
{
  local resolved

  resolved=$(sed -n "s/^$1 \\(.*\\)/\\1/p" "$GOTO_DB" 2>/dev/null)
  echo "$resolved"
}

# Displays the given error.
# Used for common error output.
_goto_error()
{
  (>&2 echo -e "goto error: $1")
}

# Displays the given warning.
# Used for common warning output.
_goto_warning()
{
  (>&2 echo -e "goto warning: $1")
}

# Displays entries with aliases starting as the given one.
_goto_print_similar()
{
  local similar

  similar=$(sed -n "/^$1[^ ]* .*/p" "$GOTO_DB" 2>/dev/null)
  if [ -n "$similar" ]; then
    (>&2 echo "Did you mean:")
    (>&2 column -t <<< "$similar")
  fi
}

# Fetches alias directory, errors if it doesn't exist.
_goto_resolve_alias()
{
  local resolved

  resolved=$(_goto_find_alias_directory "$1")

  if [ -z "$resolved" ]; then
    _goto_error "unregistered alias $1"
    _goto_print_similar "$1"
    return 1
  else
    echo "${resolved}"
  fi
}

# Completes the goto function with the available commands
_complete_goto_commands()
{
  local IFS=$' \t\n'

  # shellcheck disable=SC2207
  COMPREPLY=($(compgen -W "-r --register -u --unregister -p --push -o --pop -l --list -ls --ls -x --expand -c --cleanup --convert --sync-home -v --version" -- "$1"))
}

# Completes the goto function with the available aliases
_complete_goto_aliases()
{
  local IFS=$'\n' matches
  _goto_resolve_db

  # shellcheck disable=SC2207
  matches=($(sed -n "/^$1/p" "$GOTO_DB" 2>/dev/null))

  if [ "${#matches[@]}" -eq "1" ]; then
    # remove the filenames attribute from the completion method
    compopt +o filenames 2>/dev/null

    # if you find only one alias don't append the directory
    COMPREPLY=("${matches[0]// *}")
  else
    for i in "${!matches[@]}"; do
      # remove the filenames attribute from the completion method
      compopt +o filenames 2>/dev/null

      if ! [[ $(uname -s) =~ Darwin* ]]; then
        matches[$i]=$(printf '%*s' "-$COLUMNS" "${matches[$i]}")

        COMPREPLY+=("$(compgen -W "${matches[$i]}")")
      else
        COMPREPLY+=("${matches[$i]// */}")
      fi
    done
  fi
}

# Bash programmable completion for the goto function
_complete_goto_bash()
{
  local cur="${COMP_WORDS[$COMP_CWORD]}" prev

  if [ "$COMP_CWORD" -eq "1" ]; then
    # if we are on the first argument
    if [[ $cur == -* ]]; then
      # and starts like a command, prompt commands
      _complete_goto_commands "$cur"
    else
      # and doesn't start as a command, prompt aliases
      _complete_goto_aliases "$cur"
    fi
  elif [ "$COMP_CWORD" -eq "2" ]; then
    # if we are on the second argument
    prev="${COMP_WORDS[1]}"

    if [[ $prev = "-u" ]] || [[ $prev = "--unregister" ]]; then
      # prompt with aliases if user tries to unregister one
      _complete_goto_aliases "$cur"
    elif [[ $prev = "--convert" ]]; then
      # prompt with convert modes
      local IFS=$' \t\n'
      COMPREPLY=($(compgen -W "tilde home path" -- "$cur"))
    elif [[ $prev = "-x" ]] || [[ $prev = "--expand" ]]; then
      # prompt with aliases if user tries to expand one
      _complete_goto_aliases "$cur"
    elif [[ $prev = "-p" ]] || [[ $prev = "--push" ]]; then
      # prompt with aliases only if user tries to push
      _complete_goto_aliases "$cur"
    fi
  elif [ "$COMP_CWORD" -eq "3" ]; then
    # if we are on the third argument
    prev="${COMP_WORDS[1]}"

    if [[ $prev = "-r" ]] || [[ $prev = "--register" ]]; then
      # prompt with directories only if user tries to register an alias
      local IFS=$' \t\n'

      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -d -- "$cur"))
    fi
  fi
}

# Zsh programmable completion for the goto function
_complete_goto_zsh()
{
  local all_aliases=()
  _goto_resolve_db
  while IFS= read -r line; do
    all_aliases+=("$line")
  done <<< "$(sed -e 's/ /:/g' $GOTO_DB 2>/dev/null)"

  local state
  local -a options=(
    '(1)'{-r,--register}'[registers an alias]:register:->register'
    '(- 1 2)'{-u,--unregister}'[unregisters an alias]:unregister:->unregister'
    '(: -)'{-l,--list,-ls,--ls}'[lists aliases]'
    '(*)'{-c,--cleanup}'[cleans up non existent directory aliases]'
    '(1)--convert[rewrite home form in all stored paths]:mode:(tilde home path)'
    '(*)--sync-home[rewrite stale /home/<olduser> paths to current home]'
    '(1 2)'{-x,--expand}'[expands an alias]:expand:->aliases'
    '(1 2)'{-p,--push}'[pushes the current directory onto the stack, then performs goto]:push:->aliases'
    '(*)'{-o,--pop}'[pops the top directory from stack, then changes to that directory]'
    '(: -)'{-h,--help}'[prints this help]'
    '(* -)'{-v,--version}'[displays the version of the goto script]'
  )

  _arguments -C \
    "${options[@]}" \
    '1:alias:->aliases' \
    '2:dir:_files' \
  && ret=0

  case ${state} in
    (aliases)
      _describe -t aliases 'goto aliases:' all_aliases && ret=0
    ;;
    (unregister)
      _describe -t aliases 'unregister alias:' all_aliases && ret=0
    ;;
  esac
  return $ret
}

goto_aliases=($(alias | sed -n "s/.*\s\(.*\)='goto'/\1/p"))
goto_aliases+=("goto")

for i in "${goto_aliases[@]}"
	do
		# Register the goto completions.
	if [ -n "${BASH_VERSION}" ]; then
	  if ! [[ $(uname -s) =~ Darwin* ]]; then
	    complete -o filenames -F _complete_goto_bash $i
	  else
	    complete -F _complete_goto_bash $i
	  fi
	elif [ -n "${ZSH_VERSION}" ]; then
	  compdef _complete_goto_zsh $i
	else
	  echo "Unsupported shell."
	  exit 1
	fi
done
