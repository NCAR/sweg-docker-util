#!/bin/bash
PROG=docker-build.sh
DESC="Run docker build and tag the resulting image using label values"
USAGE1="$PROG [-l] [-r|--repo] repo [-- build_opts...]"
USAGE2="$PROG -h|--help"
BUILDLOG="${BUILD_LOG:=./build.log}"
REPO_USER=ncar/

function help() {
    cat <<EOF
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This script runs "docker build ." and uses the "name", and "version"
    labels in the resulting image along with an explicit or default "repo"
    name to tag the image with "<repo>/<name>:<version>" and "<repo>/<name>".
    The latter is automatically assigned the version tag "latest" by docker.
    Both tags are written to stdout following the string "TAG: ".

    Note that the "name", and "version" labels are not automatically
    applied to an image by docker; the Dockerfile must use "LABEL" instructions
    to set these explicitly.

    The folowing options are supported:

    -u|--user <repo_username>
        Use the given repo username name rather than the default
        ($REPO_USER).

    -l|--log
        Append the build time, image ID, "repo" label, "name" label, and
        "version" label to the file "$BUILDLOG".

    -h|--help  Print this help message and quit.

    Any arguments following a "--" argument are passed verbatim to
    "docker build".

ENVIRONMENT
    BUILDLOG
            The name of the log file. Ignored if -l|--log is not given.

EOF
    exit 0
}

WRITE_LOG=n

function main() {
    if [[ ! -f Dockerfile ]] ; then
        runSubBuilds
    else
	doBuild
    fi
}

function runSubBuilds() {
    if [[ -f BUILD ]] ; then
	dirs=$(grep -v ' *#' BUILD)
    else
	dockerfiles=$(echo */Dockerfile)
        if [[ "$dockerfiles" = '*/Dockerfile' ]] ; then
            echo "$PROG: cannot find Dockerfile!" >&2
	    exit 1
        fi
        for dockerfile in $dockerfiles ; do
	    dirs="$dirs $(dirname $dockerfile)"
        done
    fi
    scriptdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    for dir in $dirs ; do
        if [[ ! -d "$dir" ]] ; then
            continue
        fi
	echo "======== $dir ========"
	(cd $dir ; $scriptdir/$PROG "$@")
	echo
    done
    exit 0
}

function doBuild() {
    if [[ ":$1" == ":-l" || ":$1" == ":--log" ]] ; then
        WRITE_LOG=y
    fi

    CURRTIME=$(date '+%Y-%m-%dT%H:%M:%S%z')
    TMPFILE="/tmp/docker-build-$$.log"
    trap "rm -f $TMPFILE ; exit 1" 1 2 3

    docker build $BUILD_OPTS . | while read line ; do
        echo "$line"
        if [[ $line =~ Successfully[[:space:]]built[[:space:]](.*)$ ]] ; then
    	echo "${BASH_REMATCH[1]}" >$TMPFILE
        fi
    done
    #
    # The while loop above runs in a subshell, so variables set there would
    # not be available here.
    #
    if [[ -s $TMPFILE ]] ; then
        read IMAGE <$TMPFILE
        rm -f $TMPFILE
        set $(docker inspect --format '{{.Config.Labels.name}} {{.Config.Labels.version}}' $IMAGE)
        name="$1"
        version="$2"
        docker tag $IMAGE "$REPO_USER$name"
        echo "TAG: $REPO_USER$name"
        docker tag $IMAGE "$REPO_USER$name:$version"
        echo "TAG: $REPO_USER$name:$version"
        if [[ $WRITE_LOG == y ]] ; then
            echo $CURRTIME $IMAGE $REPO_USER $name $version  >>$BUILDLOG
        fi
        exit 0
    else
        exit 1
    fi
}

function processCommandLine() {
    split=n
    while [[ ":$1" == :-* ]] ; do
        arg="$1"
        shift
        split=n
        case $arg in
            -h?*)   help ;;
            -h|--help)
                    help ;;
            -r?*)   REPO_USER="${arg#-r}" ;;
            -r|--repo)
                    REPO_USER="$1"
                    if [[ $REPO_USER =~ ^([a-z0-9]+)/?$ ]] ; then
                        REPO_USER="${BASH_REMATCH[1]}/"
                    fi
                    shift ;;
            -l?*)   WRITE_LOG=y
                    split=y ;;
            -l|--log)
                    WRITE_LOG=y
                    shift ;;
	    --)     shift
                    BUILD_OPTS=("$@")
		    return ;;
	    -*)     echo "$PROG: unknown option: $arg" >&2
		    exit 1 ;;
        esac
        if [[ $split = y ]] ; then
            set : "-${arg#-?}" "$@"
            shift
            split=n
        fi
    done
}


main

