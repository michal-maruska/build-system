#! /usr/bin/zsh

# Common functions for the scripts
info()
{
    cecho yellow "$1" >&2
}

check_getopt()
{
    if getopt -T; then # should test (( $? = -4 ))
        echo "incompatible getopt(1) installed. Abort" >&2
        exit 1
    fi
}

# The hook between git-checkout & build.
prepare_hook_name()
{
    # Support for 2 different versions of gbp:
    local gbp_version
    gbp_version=$(gbp buildpackage --version 2>/dev/null | cut --delimiter=' ' --fields=2)

    if [[ -n "$gbp_version" ]] && dpkg --compare-versions "$gbp_version" 'gt' 0.6; then
        PREVERSION_HOOK_NAME=--git-postexport
    else
        PREVERSION_HOOK_NAME=--git-prebuild
    fi
}

possibly_trace()
{
    if [[ -n "${DEBUG-}" && "${DEBUG-}" != "n" ]]; then
        echo "set -x"
    fi
}

# Keep only the 2-numbers NNN.MMMwhatever
drop_verbal_suffix()
{
    # conditionally remove, e.g. 1.2ubuntu -> 1.2
    if [[ $VERSION =~ '^([[:digit:]]+)\.([[:digit:]]+)([^.[:digit:]].*)$' ]]; then
        if [[ -n "${DEBUG-}" && "${DEBUG-}" != "n" ]]; then
            cecho red "drop_verbal_suffix: Discarding $match[3] from $VERSION"
        fi
        VERSION="$match[1].$match[2]"
    fi
}

# Detect a current git tag on HEAD to avoid recreating it.
# Return 1 if no such tag exists.
# Return 0 & set the following variables if successful:
# VERSION, DISTRIBUTION, GIT_OFFSET
get_current_tag()
{
    local description
    if ! description=$(git describe --tags 2>/dev/null); then
        # Are there any tags at all:
        if git tag -l | grep -q .; then
            cecho red "not past Git tag, but other tags present"
            if [[ "${FORCE-n}" != "y" ]]; then
                exit 1
            fi
        else
            VERSION=
            DISTRIBUTION=
            return 1
        fi
    else
        # 2 possibilities:
        # Either only the tag (possibly name/version),
        # or name/version-offset-g{hash} eg. release|debian/3.4-2568-g59abc
        if [[ $description =~ '^([^/]+)/(.*)-([[:digit:]]+)-g[[:alnum:]]*$' ]]; then
            DISTRIBUTION=$match[1]
            VERSION=$match[2]
            GIT_OFFSET=$match[3]
        elif [[ $description =~ '^([^/]+)/(.*)$' ]]; then
            DISTRIBUTION=$match[1]
            VERSION=$match[2]
        else
            echo "Found a non-release git tag: $description. So ignoring it." >&2
            return 1
        fi
    fi

    if [[ -n "${DEBUG-}" && "${DEBUG-}" != "n" ]]; then
        cecho yellow "version: $VERSION git-offset: ${GIT_OFFSET:-} distro: $DISTRIBUTION" >&2
    fi
}

# Decide whether debian/changelog needs a new section
# Return 0 iff changelog needs updating
changelog_needs_new_section()
{
    local type=$1
    local FILE="debian/changelog"

    if [[ "${FORCE-n}" == "y" ]]; then
        return 0
    elif git status --porcelain "$FILE" 2>/dev/null | grep -q '^ M'; then
        # It's modified already.
        cecho yellow "$FILE is dirty"
        if [[ "$type" == "release" ]]; then
            return 0
        else
            return 1
        fi
    elif [[ $(git log --pretty=%P -n 1 2>/dev/null | wc -w) -gt 1 ]]; then
        cecho yellow "$FILE is clean but now we merged and merge commits need special attention"
        return 0
    elif ! git rev-parse --verify HEAD~1 >/dev/null 2>&1 || ! git diff HEAD~1 --name-status "$FILE" 2>/dev/null | grep -q '^[AM]'; then
        cecho yellow "$FILE was not updated during the last commit"
        return 0
    elif git status --porcelain 2>/dev/null | grep -q '^ M'; then
        # Something changed, but not debian/changelog
        return 1
    elif git diff --name-only HEAD~1 2>/dev/null | grep -q "$FILE"; then
        return 1
    else
        return 0
    fi
}

# Increase VERSION and compare with the one in debian/changelog.
_get_new_version()
{
    local step=$1

    increase_version -r "$step"
    local git_version=$VERSION

    load_distr_version_from_changelog

    if dpkg --compare-versions "$VERSION" lt "$git_version"; then
        VERSION=$git_version
    fi

    info "new version is $DISTRIBUTION $VERSION"
}

git_reset_changelog()
{
    local FILE=debian/changelog
    if git status --porcelain "$FILE" 2>/dev/null | grep -q '^[M ]M'; then
        mv "$FILE" "$FILE.pre-release"
        git checkout "$FILE"
    fi
}

# Generate changelog entry and commit it.
# input: USER_VERSION, USER_DISTRIBUTION, DCH_OPTIONS
# modifies/output: VERSION, DISTRIBUTION
generate_commit_changelog()
{
    local opts=()
    if [[ "$1" == "-q" ]]; then
        opts+=(--spawn-editor=never)
        shift
    fi

    local step=$1
    if [[ -n "${USER_VERSION:-}" ]]; then
        echo "overriding the version, as requested" >&2
        VERSION=${USER_VERSION}
    else
        _get_new_version "$step"
    fi

    [[ -n "$USER_DISTRIBUTION" ]] && DISTRIBUTION=$USER_DISTRIBUTION

    eval $(possibly_trace)
    git_reset_changelog

    local gbp_version
    gbp_version=$(gbp buildpackage --version 2>/dev/null | cut -d ' ' -f 2)
    if [[ -n "$gbp_version" ]] && dpkg --compare-versions "$gbp_version" gt 0.6; then
        if [[ -n "$DISTRIBUTION" ]]; then
            DCH_OPTIONS+=(--distribution "$DISTRIBUTION")
        fi
    fi

    gbp dch "${DCH_OPTIONS[@]}" --release --auto --new-version="$VERSION" "${opts[@]}" --spawn-editor=never

    rm -f debian/changelog.pre-release
    if git status --porcelain debian/changelog 2>/dev/null | grep -q '^[M ]M'; then
        git add debian/changelog
        git commit -m "release"
        GITSHA=$(git rev-list --max-count=1 HEAD)
    fi
}

# Using external tools, parse debian/changelog
# and set: DISTRIBUTION, VERSION
load_distr_version_from_changelog()
{
    local FILE="debian/changelog"
    DISTRIBUTION=$(deb-pkg-distribution "$FILE")
    VERSION=$(deb-pkg-version "$FILE")
}

# Check if the author/maintainer matches
my_own_project()
{
    [[ $(deb-pkg-maintainer debian/control 2>/dev/null) == *maruska* ]]
}

# Increase the VERSION variable
increase_version()
{
    local release="n"
    if [[ "$1" == "-r" ]]; then
        release=y
        shift
    fi

    local step=$1

    # After a snapshot version: x.y.z~snapshot, drop the ~suffix on release
    if [[ "$release" == "y" ]] && my_own_project; then
        if [[ $VERSION =~ '^(.*)~.*$' ]]; then
            VERSION="$match[1]"
            return
        fi
    fi

    local prefix
    local major
    local middle
    local minor
    local tail
    # non-digit(digit).*non-digit(digit*)non-digit*
    #           major     middle  minor  tail
    if [[ "$VERSION"  =~ '([^0-9]*)([0-9]+)(.*[^0-9])([0-9]+)([^0-9]*)' ]];
    then
        prefix=$match[1]
        major=$match[2]
        middle=$match[3]
        minor=$match[4]
        tail=$match[5]
    else
        # major. minor the last number!
        prefix=""
        major=${VERSION%%.*} # longest matching is dropped. So this is beginning up to first "."
        minor=${VERSION##*.} # longest dropped ->  from the last "." to the end.

        tail=.${VERSION#*.} # shortest at the beginning is dropped.
        middle=${tail%.*}
    fi
    cecho red "increasing version($prefix, $major, $middle, $minor, $tail) by step: $step"

    if my_own_project;
    then
        if [ $step = "major" ]
        then
            if ! major=$(expr $major + 1);
            then
                echo "cannot increase $VERSION"
                exit 1
            fi
            minor=0
        else
            if ! minor=$(expr $minor + 1)
            then
                echo "cannot increase $VERSION by minor"
                exit 1
            fi
        fi
        VERSION="$prefix$major${middle}$minor$tail"
    else
        VERSION="$prefix$major$middle${minor}-maruska"
    fi
}

# Toggle between ssh-agent implementation in GPG and native SSH-agent
ssh_works=y

# Restart gpg-agent daemon
restart_gpg()
{
    cecho red "restarting gpg-agent" >&2
    local ssh_option=""
    if [[ "$ssh_works" != "y" ]]; then
        ssh_option="--enable-ssh-support"
    fi
    gpg-agent --daemon ${ssh_option} --default-cache-ttl 1800 \
        --write-env-file "${HOME}/.gpg-agent-info" >! ~/.gpg-agent-info
}

# Reload shell code generated by gpg-agent
load_config()
{
    local BKP_SSH_AUTH_SOCK BKP_SSH_AGENT_PID
    if [[ "$ssh_works" == "y" ]]; then
        BKP_SSH_AUTH_SOCK=$SSH_AUTH_SOCK
        BKP_SSH_AGENT_PID=${SSH_AGENT_PID-}
    fi

    if [[ -f ~/.gpg-agent-info ]]; then
        source ~/.gpg-agent-info
        export GPG_AGENT_INFO
    fi

    if [[ "$ssh_works" == "y" ]]; then
        SSH_AUTH_SOCK=$BKP_SSH_AUTH_SOCK
        SSH_AGENT_PID=$BKP_SSH_AGENT_PID
    else
        export SSH_AUTH_SOCK
        export SSH_AGENT_PID
    fi
}

# Verify gpg agent is responsive; start a new one if not
check_start_gnupg()
{
    local gpg_response
    gpg_response=$(gpg-connect-agent '/echo ahoj' '/bye' 2>/dev/null || true)

    if ! gpg-connect-agent -q '/bye' 2>/dev/null || [[ "$gpg_response" != "ahoj" ]]; then
        cecho yellow "Have to restart gpg" >&2
        restart_gpg
        load_config
    fi

    gpg_response=$(gpg-connect-agent '/echo ahoj' '/bye' 2>/dev/null || true)
    if gpg-connect-agent -q '/bye' 2>/dev/null && [[ "$gpg_response" == "ahoj" ]]; then
        cecho green "gpg is ok on ${GPG_AGENT_INFO-}" >&2
    fi

    export GPG_TTY=$(tty 2>/dev/null || true)
}

