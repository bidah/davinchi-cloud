# Sourced from ~/.bashrc on the box: put interactive shells in the shared tmux
# session "main". Reopening the web terminal (or `daytona ssh`) reattaches to it.
# Opt out for one shell with NO_TMUX=1. Detach: Ctrl-b d.
case $- in *i*) ;; *) return ;; esac
if [ -z "$TMUX" ] && [ -z "$NO_TMUX" ] && [ "$TERM" != dumb ] && command -v tmux >/dev/null; then
  tmux new-session -A -s main && exit
fi
