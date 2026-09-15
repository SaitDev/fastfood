#!/usr/bin/env bash

COLS=144
ROWS=34

osascript <<EOF
tell application "iTerm2"
    repeat with w in windows
        tell current session of w
            set columns to $COLS
            set rows to $ROWS
        end tell
    end repeat
end tell
EOF
