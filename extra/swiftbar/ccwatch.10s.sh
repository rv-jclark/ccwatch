#!/bin/bash
#
# <bitbar.title>ccwatch</bitbar.title>
# <bitbar.version>1.0</bitbar.version>
# <bitbar.desc>Every Claude Code session on this machine, and which one is stuck.</bitbar.desc>
# <bitbar.dependencies>bash,jq,ccwatch</bitbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# ccwatch as a macOS menu bar item, for SwiftBar or xbar.
#
# Install by SYMLINKING this file into the plugin folder, rather than copying
# it — a copy is a second version of the plugin that stops getting the fixes,
# and the symlink is also how the script finds the checkout it came from:
#
#   ln -s "$PWD/extra/swiftbar/ccwatch.10s.sh" ~/Library/Application\ Support/SwiftBar/
#
# The `10s` in the filename is the refresh interval, and it is the plugin host
# that reads it, not this script. Rename the file to change it. Ten seconds
# rather than the two the terminal uses: a repaint you are watching is worth a
# filesystem walk, and one running unattended all day is not. `ccwatch` walks
# the transcript tree on every snapshot, which was measured at 1.7GB on a
# working machine — profile your own with `CCWATCH_PROFILE=1 ccwatch --json`
# before going faster than this.
#
# There is deliberately no judgement in here. Every verdict, threshold and
# word comes from `ccwatch bar`, so the menu bar and the terminal cannot
# disagree about whether something is stuck — two renderings that decide that
# separately eventually do, and then there is no telling which one is lying.

# ⚠️ The plugin host does not run plugins through a login shell, so $PATH here
# is NOT the one your terminal has — it is a short system default, and on an
# Apple Silicon machine that means no /opt/homebrew/bin. `ccwatch` calls `need
# jq`, which exits rather than guessing, so without this the menu bar would
# report a missing jq on a machine that plainly has one.
PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
export PATH

# ⚠️ Resolved through symlinks, the same loop `ccwatch` uses on itself and for
# the same reason: the documented install is a symlink, so `dirname $0` is the
# plugin folder rather than the checkout, and the relative path to bin/ccwatch
# from there points at nothing. A loop rather than `readlink -f`, because the
# BSD readlink macOS shipped for years has no -f.
self=${BASH_SOURCE[0]}
hops=0
while [ -L "$self" ]; do
  hops=$((hops + 1))
  [ "$hops" -gt 40 ] && break          # a symlink cycle must not hang the menu
  d=$(cd -- "$(dirname -- "$self")" && pwd)
  self=$(readlink -- "$self")
  case "$self" in /*) ;; *) self="$d/$self";; esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd)

# CCWATCH_BIN wins if you set it, for an install this search does not cover.
if [ -z "${CCWATCH_BIN:-}" ]; then
  for candidate in \
    "$here/../../bin/ccwatch" \
    "$(command -v ccwatch 2>/dev/null)" \
    /usr/local/bin/ccwatch \
    /opt/homebrew/bin/ccwatch \
    "$HOME/.local/bin/ccwatch"
  do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then CCWATCH_BIN=$candidate; break; fi
  done
fi

# ⚠️ Not `cc 0`, and not an empty menu. "I cannot find ccwatch" and "nothing is
# running" are different facts, and the menu bar is where they look identical:
# both are a calm item with nothing under it. Anything that is not a reading
# says so in words.
if [ -z "${CCWATCH_BIN:-}" ]; then
  echo "cc ! | sfimage=exclamationmark.triangle"
  echo "---"
  echo "ccwatch not found | color=red"
  echo "Symlink this plugin from the ccwatch checkout, or set CCWATCH_BIN in it. | size=11"
  echo "Looked beside the plugin, on PATH, and in the usual bin directories. | size=11 color=gray"
  exit 0
fi

# ⚠️ Not `exec`, and this is the same rule again rather than caution. `ccwatch`
# can exit before printing anything — `need jq` does exactly that — and the
# plugin host renders stdout, so a plugin that exec'd into a tool which died
# would leave an item with a blank title and nothing under it. That is
# indistinguishable from a machine with nothing running, which is the one
# reading this tool must never produce. So the output is taken first, and an
# empty one is reported as the failure it is.
out=$("$CCWATCH_BIN" bar 2>/dev/null)
if [ -n "$out" ]; then
  printf '%s\n' "$out"
  exit 0
fi

# Re-run for the reason, on the failure path only. `ccwatch` writes its
# diagnosis to stderr, and the pipe is stripped from it for the same reason
# `ccwatch bar` strips one from a session name: `bash=` is a parameter the menu
# format accepts, so nothing reaches a line able to open the parameter list.
why=$("$CCWATCH_BIN" bar 2>&1 >/dev/null | tr '|' ' ' | head -1)
echo "cc ! | sfimage=exclamationmark.triangle"
echo "---"
echo "ccwatch produced no output | color=red"
echo "This is NOT \"nothing is running\" — ccwatch could not run. | size=11"
[ -n "$why" ] && echo "$why | size=11 color=gray"
echo "---"
echo "Run ccwatch doctor | bash=\"$CCWATCH_BIN\" param1=doctor terminal=true"
exit 0
