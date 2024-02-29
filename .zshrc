# Path to your oh-my-zsh installation.
export ZSH=/home/_user_/.oh-my-zsh

POWERLEVEL9K_MODE='nerdfont-fontconfig'
POWERLEVEL9K_CUSTOM_CONTEXT="print '_server_alias_'"

DISABLE_AUTO_TITLE="true"
POWERLEVEL9K_VCS_STAGED_ICON='\u00b1'
POWERLEVEL9K_VCS_UNTRACKED_ICON='\u25CF'
POWERLEVEL9K_VCS_UNSTAGED_ICON='\u00b1'
POWERLEVEL9K_VCS_INCOMING_CHANGES_ICON='\u2193'
POWERLEVEL9K_VCS_OUTGOING_CHANGES_ICON='\u2191'

POWERLEVEL9K_VCS_MODIFIED_BACKGROUND='yellow'
POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND='yellow'

POWERLEVEL9K_OS_ICON_BACKGROUND="black"
POWERLEVEL9K_OS_ICON_FOREGROUND="white"
POWERLEVEL9K_CUSTOM_CONTEXT_BACKGROUND="black"
POWERLEVEL9K_CUSTOM_CONTEXT_FOREGROUND="white"
POWERLEVEL9K_DIR_HOME_FOREGROUND="white"
POWERLEVEL9K_DIR_HOME_SUBFOLDER_FOREGROUND="white"
POWERLEVEL9K_DIR_DEFAULT_FOREGROUND="white"

POWERLEVEL9K_BACKGROUND_JOBS_BACKGROUND="blue"
POWERLEVEL9K_BACKGROUND_JOBS_FOREGROUND="white"
POWERLEVEL9K_TIME_FOREGROUND='white'
POWERLEVEL9K_TIME_BACKGROUND='black'

POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon custom_context_joined dir vcs)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status background_jobs php_version root_indicator load ram nvm)

POWERLEVEL9K_SHORTEN_STRATEGY="truncate_middle"
POWERLEVEL9K_SHORTEN_DIR_LENGTH=4

POWERLEVEL9K_TIME_FORMAT="%D{%H:%M:%S}"

POWERLEVEL9K_STATUS_VERBOSE=false
export DEFAULT_USER="$USER"

ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git z zsh-syntax-highlighting)

# User configuration
export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# export MANPATH="/usr/local/man:$MANPATH"

source $ZSH/oh-my-zsh.sh

# Get specified files and total size in human readable form
alias du="du -sch"

# List all folders in tree structure
alias ltree="ls -R | grep ":$" | sed -e 's/:$//' -e 's/[^-][^\/]*\//--/g' -e 's/^/ /' -e 's/-/|/'"
