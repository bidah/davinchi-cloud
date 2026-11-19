#!/bin/sh
# `editor` on the box: the Agent SDK editor with the API key from `up --anthropic-key`.
# The key lives only in ~/.editor.env so Claude Code (subscription) never picks it up.
[ -f "$HOME/.editor.env" ] && . "$HOME/.editor.env"
exec /opt/editor/bin/python /opt/scripts/editor.py "$@"
