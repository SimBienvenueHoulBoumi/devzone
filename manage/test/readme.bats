#!/usr/bin/env bats
# readme.bats: every command cited in README.md and manage/docs/reference.md
# (devzone, make, npx devzone) must use a known CLI command name.
# The authorized names are built by the test itself from:
#   - bash manage/devzone --help
#   - the "  devzone" lines of the help text of .devcontainer/help.sh (#557)
#   - the Makefile targets

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    AUTHORIZED=""
    : > "$BATS_TEST_TMPDIR/words.txt"
    add_word() {
        [ -n "$1" ] && echo "$1" >> "$BATS_TEST_TMPDIR/words.txt"
    }

    # 1. manage/devzone --help : first word after " devzone "
    bash "$RACINE/manage/devzone" --help | while IFS= read -r line; do
        case "$line" in
            *" devzone "*)
                word="${line#* devzone }"
                word="${word%% *}"
                case "$word" in
                    ''|--*) ;;
                    *)
                        if [ "${word:0:1}" != "<" ]; then add_word "$word"; fi
                        ;;
                esac
                ;;
        esac
    done

    # 2. .devcontainer/help.sh : lines beginning with "  devzone" (the help text)
    while IFS= read -r line; do
        case "$line" in
            '  devzone'*)
                word="${line#*devzone }"
                word="${word%% *}"
                case "$word" in
                    ''|--*) ;;
                    *)
                        if [ "${word:0:1}" != "<" ]; then add_word "$word"; fi
                        ;;
                esac
                ;;
        esac
    done < "$RACINE/.devcontainer/help.sh"

    # 3. top-level pod command cited by the reference, absent from the help text
    add_word status

    # 4. Makefile targets
    while IFS= read -r line; do
        case "$line" in
            [a-z-]*:*) add_word "${line%%:*}" ;;
        esac
    done < "$RACINE/Makefile"

    AUTHORIZED="$(tr '\n' ' ' < "$BATS_TEST_TMPDIR/words.txt")"
}

# Return 0 if $1 is an authorized word.
authorized() {
    case " $AUTHORIZED " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Verify a cited command: extract the first word after the prefix
# (npx devzone, make, devzone) and ensure it is authorized.
verify_command() {
    local cmd word rest
    cmd="$1"
    # Leading spaces and tabs.
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    [ -n "$cmd" ] || return 0
    if [[ $cmd == npx\ devzone* ]]; then
        rest="${cmd#npx devzone}"
        if [[ $rest == @* ]]; then
            rest="${rest#* }"
        fi
        rest="${rest#"${rest%%[! ]*}"}"
        word="${rest%% *}"
    elif [[ $cmd == make\ * ]]; then
        word="${cmd#make }"
        word="${word%% *}"
    elif [[ $cmd == devzone\ * ]]; then
        word="${cmd#devzone }"
        word="${word%% *}"
    else
        return 0
    fi
    # « devzone : text » is a message of devzone (an output), not a command; the
    # help used to authorize the word « : » by accident (« devzone : »).
    case "$word" in ''|--*|:|devzone|devzone.instance|mon-devzone) return 0 ;;
    esac
    case "$word" in devzone-*) return 0 ;; esac
    [ "${word:0:1}" = "<" ] && return 0
    if ! authorized "$word"; then
        echo "unknown command: $word (first word of '$cmd')"
        return 1
    fi
    return 0
}

@test "readme and reference cite known CLI commands" {
    unknown=""
    verify_file() {
        local file
        file="$BATS_TEST_TMPDIR/$(basename "$1").filtered"
        cp "$1" "$file"
        : > "$BATS_TEST_TMPDIR/candidates.txt"
        # Inline code between backticks.
        pattern="\`[^\`]+\`"
        grep -oE "$pattern" "$file" | while IFS= read -r span; do
            span="${span#\`}"
            span="${span%\`}"
            echo "$span" >> "$BATS_TEST_TMPDIR/candidates.txt"
        done
        # Lines of ```sh / ```bash blocks.
        awk '/^```(sh|bash)/{b=1;next}/^```/{b=0}b' "$file" >> "$BATS_TEST_TMPDIR/candidates.txt"
        while IFS= read -r line; do
            if ! verify_command "$line"; then
                unknown="$unknown $line"
            fi
        done < "$BATS_TEST_TMPDIR/candidates.txt"
    }
    verify_file "$RACINE/README.md"
    verify_file "$RACINE/manage/docs/reference.md"
    if [ -n "$unknown" ]; then
        echo "Unknown commands in documentation:$unknown"
        return 1
    fi
}
