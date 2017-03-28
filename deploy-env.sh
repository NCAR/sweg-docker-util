#!/bin/bash
PROG="deploy-env.sh"
DESC="Patch config files then run command"
USAGE1="$PROG [-s|--strict] [-v|--verbose...] [-u|--user user] [CMD args...]"
USAGE2="$PROG -p|--parms [-r|--root altroot]"
USAGE3="$PROG -h|--help"
FILE_LIST_DEFAULT="/etc/deploy-env-files.cnf"
FILE_LIST="${DEPLOY_ENV_FILE_LIST:-$FILE_LIST_DEFAULT}"
DIR_LIST_DEFAULT="/etc/deploy-env-dirs.cnf"
DIR_LIST="${DEPLOY_ENV_DIR_LIST:-$DIR_LIST_DEFAULT}"

HELP_TEXT="
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This bash script reads a list of configuration file names, modifies the
    named files by expanding environment variable references, then runs the
    given command using \"exec\". The list of configuration file names is read
    from $FILE_LIST_DEFAULT, unless the environment variable FILE_LIST is set,
    in which case the file named by \$FILE_LIST is read.

    Files are modified by replacing all occurances of \"\${varname}\" with the
    value of the environment \"varname\" variable.

    If the script sees an extra dollar symbol in what otherwise looks like
    a variable reference (e.g., \"\$\${varname}\"), the extra dollar sign will
    be removed, but the variable refrence will not be expanded. That is,
    \"\$\${varname}\" will be replaced with \"\${varname}\".

    This script is meant to be used in a Dockerfile ENTRYPOINT, with the
    command and its arguments specified as the container CMD. For example:

      ENTRYPOINT [ \"/sweg-docker-utils/$PROG\", \"-v\" ]
      CMD [ \"/bin/myservice\" ]

    In addition to modifying configuration files, the script can optionally
    ensure that a given set of directories exists. See FILES below.

    The following options are supported:

    -s|--strict
            If a parameter reference (i.e., \"\${varname}\") refers to a non-
            existent environment variable the script will abort. Without this
            option, the script will leave the reference untouched.

    -v|--verbose
            Write status messages to STDOUT. This can appear multiple times to
            increase verbosity.

    -u|--user cmd_user
            Execute the command as the indicated user.

    -p|--parms
            Display a list of all the parameters (i.e. environment variable
            references) in the target configuration files.

    -r|--root altroot
            When used with -p|--parms, the given \"altroot\" path is prepended
            to the main configuration file and to every path in that file.
            This is typically the path of a Docker context directory that
            mirrors the structure of the container's root.

    -d|--dir directory
            Ensure the given directory and all its parents exist.

    -h|--help
            Write this documentation to STDOUT and quit.

EXAMPLES
    For example, given an environment variable USER, which is set to
    \"jsmith\", and a configuration file that looks like:

      echo Hello \${USER}

    the command

      $PROG mycommand

    would modify the configuration file to look like:

      echo Hello jsmith

    and then execute \"mycommand\"

EXIT STATUS
    The script returns 0 if no command was supplied and no errors were
    encountered. It returns 1 if an error was encountered before the command
    was exec'ed. Otherwise, it returns whatever the command returns.

FILES
    $FILE_LIST_DEFAULT
        The default file containing the list of configuration files to patch.

    $DIR_LIST_DEFAULT
        The default file containing the list of directory to create if
        necessary.

ENVIRONMENT
    DEPLOY_ENV_FILE_LIST
        If set, the file containing the list of configuration files to patch.

    DEPLOY_ENV_DIR_LIST
        If set, the file containing the list of directories to create if
        necessary.

"

FAILSAFE_SUFFIX="debk"
STRICT=0
VERBOSE=0
CMD_USER=""
SHOW_PARMS=0
ALTROOT=
HELP=0
FILES=()
DIRS=()
TMPFILE=
UNAME=`uname`

trap "if [[ -n \"$TMPFILE\" ]] ; then rm -rf \"$TMPFILE\" ; fi ; exit 1" 0

while [[ ":$1" == :-* ]] ; do
    arg="$1"
    shift
    split=n
    case $arg in
        -s?*)   STRICT=1
                split=y ;;
        -s|--strict)
                STRICT=1 ;;
        -v?*)   (( VERBOSE = $VERBOSE + 1 ))
                split=y ;;
        -v|--verbose)
                (( VERBOSE = $VERBOSE + 1 )) ;;
        -p?*)   SHOW_PARMS=1
                split=y ;;
        -p|--parms)
                SHOW_PARMS=1 ;;
        -r?*)   ALTROOT="${arg#-r}" ;;
        -r|--root)
                ALTROOT="$1" ;;
        -h?*)   HELP=1
                split=y ;;
        -h|--help)
                HELP=1 ;;
        -u?*)   CMD_USER="${arg#-u}" ;;
        -u|--user)
                CMD_USER="$1"
                shift ;;
    esac
    if [[ $split = y ]] ; then
        set : "-${arg#-?}" "$@"
        shift
        split=n
    fi
done

if [[ $HELP = 1 ]] ; then
    echo "$HELP_TEXT"
    exit 0
fi

if [[ $SHOW_PARMS = 1 ]] ; then
    if [[ "$VERBOSE$STRICT$CMD_USER$#" != "000" ]] ; then
        echo "$PROG: --parms is not compatible with other options" >&2
        exit 1
    fi
    if [[ "$FILE_LIST" == /* ]] ; then
	FILE_LIST="$ALTROOT$FILE_LIST"
    fi
else
    ALTROOT=
fi

function main() {

    validateFile "$FILE_LIST"

    loadFileList

    loadDirList

    if [[ $SHOW_PARMS == 1 ]] ; then
	showParms "${FILES[@]}"
        trap 0
        exit 0
    fi

    patchFiles "${FILES[@]}"

    createDirs "${DIRS[@]}"

    runCommand "$CMD_USER" "$@"
}

function validateFile() {
    if [[ ! -e "$1" ]] ; then
        echo "$PROG: \"$1\" does not exist" >&2
        exit 1
    fi
    if [[ ! -r "$1" ]] ; then
        echo "$PROG: \"$1\" is not readable" >&2
        exit 1
    fi
}

function loadFileList() {
    while read line ; do
        logPrintf 4 "line=\"%s\"\n" "$line"
        if [[ $line =~ ^[\ \	]*$ ]] ; then
            :
        elif [[ $line =~ ^[\ \	]*# ]] ; then
            :
        else
	    tmp="${line## }"
            file="${tmp%% }"
            if [[ "$file" == /* ]] ; then
		file="$ALTROOT$file"
            fi
	    if validateConfigFile "$file" ; then
                FILES[${#FILES[@]}]="$file"
            else 
                exit 1
            fi
        fi
    done <$FILE_LIST
}

function validateConfigFile() {
    file="$1"
    dir=$(dirname "$file")
    if [[ ! -f "$file" ]] ; then
        echo "$PROG: \"$file\": not a file" >&1
        return 1
    elif [[ ! -r "$file" ]] ; then
        echo "$PROG: \"$file\": not readable" >&1
        return 1
    elif [[ ! -w "$dir" ]] ; then
        echo "$PROG: \"$dir/\": not writable" >&1
        return 1
    fi
    return 0
}

function loadDirList() {
    if [[ ! -f "$DIR_LIST" || ! -r "$DIR_LIST" ]] ; then
	return
    fi
    while read line ; do
        logPrintf 4 "line=\"%s\"\n" "$line"
        if [[ $line =~ ^[\ \	]*$ ]] ; then
            :
        elif [[ $line =~ ^[\ \	]*# ]] ; then
            :
        else
	    tmp="${line## }"
            dir="${tmp%% }"
            DIRS[${#DIRS[@]}]="$dir"
        fi
    done <$DIR_LIST
}

function showParms() {
    TMPFILE="/tmp/deploy-env.tmp"
    for file in "$@" ; do
        failsafe="$file.debk"
        if [[ -e "$failsafe" ]] ; then
            infile="$failsafe"
            echo "Warning: reading from \"$failsafe\"" >&2
        else
            infile="$file"
        fi
        while read line ; do
            while [[ $line =~ ^(.*)\$\{([A-Za-z_][A-Za-z_0-9]*)}(.*)$ ]] ; do
                line="${BASH_REMATCH[1]}"
                varname="${BASH_REMATCH[2]}"
                if [[ $line != *$ ]] ; then
                    echo "$varname" >>$TMPFILE
                fi
            done
	done <$infile
    done
    sort -u <$TMPFILE
    rm -f $TMPFILE
}

function patchFiles() {
    for file in "$@" ; do
        patchFile $file
    done
}

function patchFile() {
    file="$1"
    failsafe="$file.debk"
    if [[ -e "$failsafe" ]] ; then
        infile="$failsafe"
        echo "Warning: reading from \"$failsafe\"" >&2
    else
        infile="$file"
    fi
    TMPFILE="$file.deTmp"
    rm -rf "$TMPFILE"
    logPrintf 1 "Reading \"%s\"\n" "$file"
    modified=0
    lineno=0
    missingVars=0
    while read line ; do
        (( lineno = $lineno + 1 ))
        patchLine "$file" $lineno "$line"
	echo "$patchedLine" >>$TMPFILE
        if [[ $? != 0 ]] ; then
            echo "$PROG: error writing temp file" >&2
            exit 1
        fi
    done <$infile
    if [[ $STRICT = 1 && $missingVars != 0 ]] ; then
        echo "$PROG: aborting (strict mode)" >&2
        exit 1
    fi
    if [[ $modified = 0 ]] ; then
        rm -rf "$TMPFILE"
        TMPFILE=
    else
        commitFile "$TMPFILE" "$file"
    fi
}

function patchLine() {
    file="$1"; shift
    lineno="$1"; shift
    remaining="$1"; shift
    logPrintf 5 "%d: %s\n" $lineno $remaining
    processed=""
    value=
    while [[ $remaining =~ ^(.*)\$\{([A-Za-z_][A-Za-z_0-9]*)}(.*)$ ]] ; do
        # note the regex matches the LAST variable reference on the line
        remaining="${BASH_REMATCH[1]}"
        varname="${BASH_REMATCH[2]}"
        skipped="${BASH_REMATCH[3]}"
        processed="$skipped$processed"
        if [[ $remaining == *$ ]] ; then
            value="{$varname}"
            modified=1
        else
            eval value=\"\${$varname-uNsEtVaRiAbLe}\"
            if [[ ":$value" == ":uNsEtVaRiAbLe" ]] ; then
                (( missingVars = $missingVars + 1 ))
                msg="$file[$lineno]: Unknown variable \"$varname\""
                if [[ $STRICT == 1 ]] ; then
                    echo "$msg" >&2
                else
                    logPrintf 3 "%s\n" "$msg"
                fi
            else
                logPrintf 4 "Line %d: Substituting \"%s\"\n    for variable reference \"\${%s}\"\n" "$lineno" "$value" "$varname"
                modified=1
            fi
        fi
        processed="$value$processed"
    done
    patchedLine="$remaining$processed"
}

function commitFile() {
    tmpfile="$1" ; shift
    file="$1" ; shift
    failsafe="$file.$FAILSAFE_SUFFIX"
    if [[ ! -e "$failsafe" ]] ; then
        backup="$failsafe"
    else
        rotateSaveFiles "$file"
        backup="$file.save.0"
    fi
    replaceFile "$file" "$TMPFILE" "$backup"
}

function rotateSaveFiles() {
    file="$1" ; shift
    ls -1 $file.save.* 2>/dev/null | while read path ; do
        if [[ "$path" =~ .*save\.([0-9][0-9]*) ]] ; then
            echo "${BASH_REMATCH[1]}" "$path"
        fi
    done | sort -rn | while read index path ; do
        (( newindex = $index + 1 ))
        mv "$path" "$file.save.$newindex"
    done
    
}

function replaceFile() {
    existing="$1" ; shift
    new="$1" ; shift
    backup="$1" ; shift
    if [[ "$UNAME" = Linux ]] ; then
        # Might be testing on e.g. Mac, where --reference is unsupported
        chown --reference="$existing" "$new"
        chmod --reference="$existing" "$new"
    fi
    ln "$existing" "$backup"
    if [[ $? != 0 ]] ; then
        exit 1
    fi
    mv "$new" "$existing"
    if [[ $? != 0 ]] ; then
        exit 1
    fi
    logPrintf 2 "\"%s\" replaced successfully\n" $existing
}

function createDirs() {
    for dir in "$@" ; do
        if [[ ! -d $dir ]] ; then
            logPrintf 1 "Creating directory \"%s\"\n" "$dir"
            mkdir -p "$dir" || exit 1
        fi
    done
}

function runCommand() {
    user="$1"
    shift
    if [[ $# != 0 ]] ; then
        type runuser >/dev/null 2>&1
        no_runuser=$?
        if [[ -n "$user" && $no_runuser == 0 && `whoami` == root ]] ; then
            logPrintf 2 "exec runuser -m -u \"%s\" \"%s\"\n" "$CMD_USER" "$*"
            exec runuser -m -u "$CMD_USER" "$@"
        else
            logPrintf 2 "exec %s\n" "$*"
            exec "$@"
        fi
        echo "$PROG: exec failed!" >&1
        exit 1
    fi
}

function logPrintf() {
    level="$1"; shift
    format="$1"; shift
    if [[ $level -le $VERBOSE ]] ; then
        printf " -%${level}s$format" " " "$@"
    fi
}

main $@
rc=$?

trap 0

exit $rc
