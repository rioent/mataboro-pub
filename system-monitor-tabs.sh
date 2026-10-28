#!/usr/bin/env bash

set -u

declare -a monitor_commands=(btop btm glances iotop nvtop)
declare -a missing_commands=()

for command_name in "${monitor_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing_commands+=("$command_name")
    fi
done

if ((${#missing_commands[@]} > 0)); then
    printf 'Cannot start all monitor tabs. Missing command(s): %s\n' "${missing_commands[*]}" >&2
    printf 'Install the missing programs, then run this script again.\n' >&2
    read -r -p 'Press Enter to close...'
    exit 1
fi

if command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal \
        --tab --title='btop'    --command="bash -lc 'exec btop'" \
        --tab --title='btm'     --command="bash -lc 'exec btm'" \
        --tab --title='glances' --command="bash -lc 'exec glances'" \
        --tab --title='iotop'   --command="bash -lc 'exec sudo iotop'" \
        --tab --title='nvtop'   --command="bash -lc 'exec nvtop'"
elif command -v mate-terminal >/dev/null 2>&1; then
    mate-terminal \
        --tab --title='btop'    --command="bash -lc 'exec btop'" \
        --tab --title='btm'     --command="bash -lc 'exec btm'" \
        --tab --title='glances' --command="bash -lc 'exec glances'" \
        --tab --title='iotop'   --command="bash -lc 'exec sudo iotop'" \
        --tab --title='nvtop'   --command="bash -lc 'exec nvtop'"
elif command -v xfce4-terminal >/dev/null 2>&1; then
    xfce4-terminal \
        --tab --title='btop'    --command="bash -lc 'exec btop'" \
        --tab --title='btm'     --command="bash -lc 'exec btm'" \
        --tab --title='glances' --command="bash -lc 'exec glances'" \
        --tab --title='iotop'   --command="bash -lc 'exec sudo iotop'" \
        --tab --title='nvtop'   --command="bash -lc 'exec nvtop'"
else
    printf '%s\n' 'No supported terminal was found.' >&2
    printf '%s\n' 'Install GNOME Terminal, MATE Terminal, or XFCE Terminal.' >&2
    read -r -p 'Press Enter to close...'
    exit 1
fi
