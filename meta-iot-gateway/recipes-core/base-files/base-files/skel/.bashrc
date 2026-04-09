# ~/.bashrc for IoT Gateway devel user (minimal)

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# History and completion
HISTCONTROL=ignoredups:erasedups
HISTSIZE=5000
shopt -s histappend
shopt -s cmdhist

# Colors
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
fi

# Common aliases
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias ip='ip -c'
alias jc='journalctl -b'
alias jx='journalctl -xe'
alias nm='nmcli'
alias k='kubectl 2>/dev/null || true'

# Persistent tmux socket for remote agent/operator collaboration.
if [ -d /data ] && mkdir -p /data/tmux 2>/dev/null; then
    alias tmux='tmux -S /data/tmux/gateway.sock'
fi

alias t='tmux'
alias ta='tmux attach -t main || tmux new -s main'
alias tn='tmux new -s main'

# Prompt: user@host:cwd$
PS1='\u@\h:\w\$ '

# Ensure sbin paths are present in interactive shells too
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
