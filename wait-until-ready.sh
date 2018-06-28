#!/bin/bash
PROG="wait-until-ready.sh"
DESC="Wait until a command returns 0 or a non-transient error"
USAGE1="$PROG [-v|--verbose] [-w|--wait tmout_secs] [-s|--sleep sleep_secs]
              [-n|--normal retcodes] [-t|--transient retcodes] command args..."
USAGE2="$PROG [-h|--help]"
TIMEOUT=60
SLEEP_SECS=5
VERBOSE=0

function help() {
    cat <<EOF
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This script runs a "status" command in a loop until the command
    returns an exit code that indicates either that the checked service
    is healthy (return code = 0) or it encountered a non-transient error.
    Exit codes greater than 128 are assumed to be fatal.

    -w|--wait tmout_secs
            How many seconds to wait before timing out (default=$TIMEOUT).

    -s|--sleep secs
            How many seconds to sleep between executions of the command
            (default=$SLEEP_SECS)

    -n|--normal retcodes
            Register the given comma-separated return codes as being indicative
            of a healthy condition. Default value is 0. If the indicated
            command returns one of these codes, this script returns with a
            return code of 0.

    -t|--transient retcodes
            Register the given comma-separated return codes as being indicative
            of a transient error condition. If the indicated command returns
            one of these codes, this script will wait and retry. By default,
            all codes from 1 to 128 are assumed to be transient.

    -v|--verbose
            Be verbose.

    -h|--help
            Just print this help text and exit.

    Arguments following flag options are taken as the "service status"
    command. This command should be short-lived. Its execution time is not
    counted towards the script's timeout.

RETURN VALUES
    0       The command returned 0
    1       The command did not return 0 (or a fatal error) within the
            timeout period
    2       The command returned a fatal error (i.e. one that indicated neither
            health nor a transient condition)
    3       Usage error

EOF
    exit 0
}
ERR_TIMEOUT=1
ERR_COMMAND_FAIL=2
ERR_USAGE=3

COMMAND=()
HEALTHY_CODES=" 0 "
TRANSIENT_CODES=
ACCUM_SLEEP=0

function main() {
    initTransientCodes

    processCommandLine "$@"

    while : ; do
        runCommandAndCheckReturnCode
	doSleepOrTimeout
    done
}

function die() {
    rc="$1"
    shift
    echo "$PROG: $@" >&2
    exit $rc
}

function vecho() {
    if [[ $VERBOSE != 0 ]] ; then
	echo "$@"
    fi
}

function runCommandAndCheckReturnCode() {
    vecho "Running ${COMMAND[@]}"
    "${COMMAND[@]}"
    checkReturnCode $?
}

function checkReturnCode() {
    retcode=$1

    if [[ "$HEALTHY_CODES" == *" $retcode "* ]] ; then
        vecho "Result=$retcode -> healthy: exiting"
	exit 0
    elif [[ "$TRANSIENT_CODES" == *" $retcode "* ]] ; then
        vecho "Result=$retcode -> transient error"
    else
        vecho "Result=$retcode -> non-transient error"
	exit $ERR_COMMAND_FAIL
    fi
}

function doSleepOrTimeout() {
    (( secs_remaining = $TIMEOUT - $ACCUM_SLEEP ))
    if [[ $secs_remaining -le 0 ]] ; then
        vecho "Timeout!"
	exit $ERR_TIMEOUT
    elif [[ $secs_remaining -lt $SLEEP_SECS ]] ; then
        SLEEP_SECS=$secs_remaining
    fi
    vecho "(Sleeping $SLEEP_SECS seconds)"
    sleep $SLEEP_SECS
    (( ACCUM_SLEEP = $ACCUM_SLEEP + $SLEEP_SECS ))
}

function initTransientCodes() {
    i=0
    codes=()
    while [[ $i -lt 128 ]] ; do
        (( n = $i + 1 ))
	codes[$i]=$n
	i=$n
    done
    TRANSIENT_CODES=" ${codes[@]} "
}

function processCommandLine() {
    while [[ ":$1" == :-* ]] ; do
        arg="$1"
        shift
        split=n
        case $arg in
            -h?*)   help ;;
            -h|--help)
                    help ;;
            -v?*)   VERBOSE=1
                    split=y ;;
            -v|--verbose)
                    VERBOSE=1 ;;
            -w?*)   TIMEOUT="${arg#-w}" ;;
            -w|--wait)
                    TIMEOUT="$1"
                    shift ;;
            -s?*)   SLEEP_SECS="${arg#-s}" ;;
            -s|--sleep)
                    SLEEP_SECS="$1"
                    shift ;;
            -n?*)   normal_retcodes="${arg#-n}" ;;
            -n|--normal)
                    normal_retcodes="$1"
                    shift ;;
            -t?*)   transient_retcodes="${arg#-t}" ;;
            -t|--transient)
                    transient_retcodes="$1"
                    shift ;;
        esac
        if [[ $split = y ]] ; then
            set : "-${arg#-?}" "$@"
            shift
            split=n
            continue
        fi
    done

    COMMAND=("$@")

    validatePosInt '-w|--wait' $TIMEOUT
    validatePosInt '-s|--sleep' $SLEEP_SECS
    if [[ -n "$normal_retcodes" ]] ; then
        HEALTHY_CODES=$(splitRetcodeList '-n|--normal' "$normal_retcodes") ||
            exit $?
    fi
    if [[ -n "$transient_retcodes" ]] ; then
        TRANSIENT_CODES=$(splitRetcodeList '-t|--transient' "$transient_retcodes") ||
            exit $?
    fi
    if [[ ${#COMMAND[@]} == 0 ]] ; then
        die $ERR_USAGE "expecting command"
    fi
}

function validatePosInt() {
    optString="$1"
    inval="$2"
    if [[ ! "$inval" =~ ^[1-9][0-9]*$ ]] ; then
        die $ERR_USAGE "Option $optString requires positive integer argument"
    fi
}

function splitRetcodeList() {
    optString="$1"
    inval="$2"
    if [[ ! "$inval" =~ ^[,0-9]+$ ]] ; then
        die $ERR_USAGE "Argument to $optString must be comma-separated list of integers"
    fi

    SAVE_IFS="$IFS"
    IFS="$IFS,"
    set : $inval
    shift
    IFS="$SAVE_IFS"
    for retcode in "$@" ; do
        if [[ "$retcode" =~ ^[1-9][0-9]*$ ]] ; then
            continue
        elif [[ "$retcode" == 0 ]] ; then
            continue
        else
            die $ERR_USAGE "Argument to $optString must be list of integers"
        fi
        if [[ $retcode -gt 255 ]] ; then
            die $ERR_USAGE "$optStr return codes must be less than 256"
        fi
    done
    echo " $@ "
}

main "$@"
