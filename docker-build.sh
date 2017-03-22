#!/bin/bash
PROG=build.sh
DESC="Run docker build and tag the resulting image using label values"
USAGE1="$PROG [-l]"
USAGE2="$PROG -h|--help"
BUILDLOG="./build.log"

if [[ ":$1" == ":-h" || ":$1" == ":--help" ]] ; then
    cat <<EOF
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This script runs "docker build ." and uses the "repo", "name", and
    "version" labels in the resulting image to tag the image with
    "<repo>/<name>:<version>" and "<repo>/<name>". The latter is automatically
    assigned the version tag "latest" by docker. Both tags are written to
    stdout following the string "TAG: ".

    Note that the "repo", "name", and "version" labels are not automatically
    applied to an image by docker; the Dockerfile must use "LABEL" instructions
    to set these explicitly.

    The folowing options are supported:

    -l|--log    Append the build time, image ID, "repo" label, "name" label, and
               "version" label to the file "$BUILDLOG".

    -h|--help  Print this help message and quit.

EOF
    exit 0
fi

WRITE_LOG=n
if [[ ":$1" == ":-l" || ":$1" == ":--log" ]] ; then
    WRITE_LOG=y
fi

CURRTIME=$(date '+%Y-%m-%dT%H:%M:%S%z')
TMPFILE="/tmp/docker-build-$$.log"
trap "rm -f $TMPFILE ; exit 1" 1 2 3

docker build . | while read line ; do
    echo "$line"
    if [[ $line =~ Successfully[[:space:]]built[[:space:]](.*)$ ]] ; then
	echo "${BASH_REMATCH[1]}" >$TMPFILE
    fi
done
#
# The while loop above runs in a subshell, so variables set there would not be
# available here.
#
if [[ -s $TMPFILE ]] ; then
    read IMAGE <$TMPFILE
    rm -f $TMPFILE
    set $(docker inspect --format '{{.Config.Labels.repo}} {{.Config.Labels.name}} {{.Config.Labels.version}}' $IMAGE)
    repo="$1"
    name="$2"
    version="$3"
    docker tag $IMAGE "$repo/$name"
    echo "TAG: $repo/$name"
    docker tag $IMAGE "$repo/$name:$version"
    echo "TAG: $repo/$name:$version"
    if [[ $WRITE_LOG == y ]] ; then
        echo $CURRTIME $IMAGE $repo $name $version  >>$BUILDLOG
    fi
    exit 0
else
    exit 1
fi
