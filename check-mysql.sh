#!/bin/bash
PROG="check-mysql.sh"
DESC="Check the health of a mysql-compatible server/database"
USAGE1="$PROG [-p|--port port] [-u|--user user] [-l...]
               [-U|--checkuser user] [host [dbname [tblname...]]]"
USAGE2="$PROG [-h|--help]"
USER=root
HOST=localhost
PORT=3306
DATABASE=mysql
EXPLICIT_DATABASE=
LEVEL=0
CHECKUSER=
TIMEOUT=5

ERRFILE=/tmp/check-mysql-$$.e
TMPFILE=/tmp/check-mysql-$$.t

PASSWORD=
VOL_SECRETS="${VOL_SECRETS:-/run/secrets}"

function help() {
    cat <<EOF
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This script checks the health/state of a mysql server. Without the
    -l|--level or -U|--checkuser options, the script only checks if the server
    is accepting connections.

    If the -l|--level flag is given, additional checking is done, the extent of
    which is defined by the number of times the flag appears. See the option
    description below for more details.

    All non-trivial checks (i.e., checks when -U|--checkuser or -l|--level
    arguments are given) require a password obtained from a file in the
    /run/secrets directory.

    The following options are supported:

    -p|--port port
            The port to use for connecting to the server (default=$PORT).

    -u|--user username
            The mysql user to connect with. This is only used if the check
            level is one or more (see -l|--level). Default is "root".

    -U|--checkuser username
            Verify that the indicated MySQL user is defined.
            
    -l|--level
            Increase the extent of checking for server/database health. The
            level increases by one each time this option is given. At level 1
            ("-l"), the "-u|--user" user/password is validated; at level 2
            ("-ll"), the existence of the indicated database and tables is
            verified; at level 3 ("-lll"), "mysqlcheck --quick" is run;
            at level 4 ("-llll"), "mysqlcheck --medium-check" is run; at
            level 5 and above, "mysqlcheck --extended" is run. Note that
            higher level values take longer to run.

    -h|--help
            Just print this help text and exit.

    Following the flag options, aguments include the host, database, and
    tables to check. All are optional. The default host is "$HOST". The
    default database is "$DATABASE".

FILES
    /run/secrets/mysql-<username>-password
            The file containing the password for MySQL user <username>.

ENVIRONMENT
    VOL_SECRETS
            If given and not empty, the name of the directory containing
            password files. Default is "/run/secrets".

RETURN VALUES

    0  Server is up and, if level is non-zero, the indicated database/tables
       are present/consistent

    1  The server could not be contacted, but the problem could be transient.

    2  The server denied access to the given username/password.

    3  The indicated host, database, table, or user (-U|--checkuser) does not
       exist

    4  Unrecognized response from the server - intervention required

    5  Apparent bug - intervention required

   16  An invalid argument was given on the command line.

   17  The password file for the user (-u|--user or root) could not be found

  128+ Script was killed by a signal (subtract 128 for signal number)

EOF
    exit 0
}
RC_SUCCESS=0
ERR_AGAIN=1
ERR_ACCESS=2
ERR_NOENT=3
ERR_UNKNOWN=4
ERR_BUG=5
ERR_ARG=16
ERR_PWFILE=17

TABLE=()

function main() {

    processCommandLine "$@"

    PASSWORD_FILE="$VOL_SECRETS/mysql-$USER-password"
    PASSWORD=
    read PASSWORD <$PASSWORD_FILE
    if [[ -x "$PASSWORD" ]] ; then
        if [[ $LEVEL -gt 0 || -n "$CHECKUSER" ]] ; then
            echo "$PROG: unable to read mysql password for $USER" >&2
            doExit $ERR_PWFILE;
        else
            # password does not matter with ping
            PASSWORD=unknown
        fi
    fi

    checkIfUp

    if [[ $LEVEL -gt 0 || -n "$CHECKUSER" ]] ; then
        checkUserPassword
    fi

    if [[ -n "$CHECKUSER" ]] ; then
         checkIfUserExists $CHECKUSER
    fi

    if [[ $LEVEL -gt 1 ]] ; then
        checkIfDatabasePresent
	rc=$?
	if [[ $rc == 0 && ${#TABLE[@]} != 0 ]] ; then
            checkIfTablesPresent
	    rc=$?
        fi
    fi
    case $LEVEL in
        0) return 0 ;;
        1) return 0 ;;
        2) return $rc ;;
	3) arg=--quick ;;
	4) arg=--medium-check ;;
	*) arg=--extended ;;
    esac
    if [[ -z "$EXPLICIT_DATABASE" ]] ; then
        runMysqlcheck -s $arg --all-databases
        return $?
    else
        runMysqlcheck -s $arg "$DATABASE" "${TABLE[@]}"
        return $?
    fi
}

function die() {
    rc="$1"
    shift
    echo "$PROG: $@" >&2
    exit $rc
}

function doExit() {
    rc="$1"
    rm -f $ERRFILE $TMPFILE
    exit $rc
}

function checkIfUp() {
    mysqladmin --user="$USER" --password="$PASSWORD" --connect_timeout=5 --host="$HOST" --port="$PORT" ping  >/dev/null 2>$ERRFILE
    if [[ $? == 0 ]] ; then
        return
    fi
    processMySqlErrors
    rc=$?
    if [[ $rc == 0 ]] ; then
        rc=$ERR_UNKNOWN
    fi
    doExit $rc
}

function processMySqlErrors() {
    if [[ ! -r "$ERRFILE" ]] ; then
	die $ERR_BUG "$ERRFILE: file is not readable"
    fi
    grep -v 'Using a password on the command line interface can be insecure' $ERRFILE >$TMPFILE
    mv $TMPFILE $ERRFILE
    if [[ ! -s "$ERRFILE" ]] ; then
	return 0;
    fi
    rc=$ERR_UNKNOWN
    if grep -q 'Unknown MySQL server host' $ERRFILE ; then
        rc=$ERR_NOENT
    elif grep -q 'Can.t connect to' $ERRFILE ; then
        rc=$ERR_AGAIN
    elif grep -q "Access denied for user" $ERRFILE ; then
        rc=$ERR_ACCESS
    else
	cat $ERRFILE >&2
    fi
    return $rc
}

function checkUserPassword() {
    result=$(mysqladmin --user="$USER" --password="$PASSWORD" --connect_timeout=5 --host="$HOST" --port="$PORT" ping 2>$ERRFILE)
    if [[ "$result" == "mysqld is alive" ]] ; then
        return 0
    fi
    processMySqlErrors
    rc=$?
    if [[ $rc == 0 ]] ; then
        rc=$ERR_UNKNOWN
    fi
    doExit $rc
}

function checkIfUserExists() {
    user="$1"
    result=$(runMysqlCommands "SELECT user FROM mysql.user WHERE user = '$user';")
    if [[ " $result " =~ [[:space:]]$user[[:space:]] ]] ; then
	return 0
    fi
    doExit $ERR_NOENT
}

function checkIfDatabasePresent() {
    set : $(runMysqlCommands 'show databases;')
    shift ; shift
    for database in "$@" ; do
        if [[ $database == $DATABASE ]] ; then
	    return 0
        fi
    done
    doExit $ERR_NOENT
}

function checkIfTablesPresent() {
    set : $(runMysqlCommands "use '$DATABASE'; show tables;")
    shift ; shift
    seenTables=()
    for table in "$@" ; do
        for wantedTable in "${TABLE[@]}" ; do
            if [[ $table == $wantedTable ]] ; then
                seenTables[${#seenTables[@]}]="$table"
                continue
            fi
        done
    done
    if [[ ${#seenTables[@]} != ${#TABLE[@]} ]] ; then
        doExit $ERR_NOENT
    fi
}

function runMysqlCommands() {
    echo "$1" | mysql --host="$HOST" --port="$PORT" --user="$USER" --password="$PASSWORD" 2>$ERRFILE
    processMySqlErrors
    rc=$?
    if [[ $rc != 0 ]] ; then
	doExit $rc
    fi
}

function runMysqlcheck() {
    mysqlcheck --host="$HOST" --port="$PORT" --user="$USER" --password="$PASSWORD" "$@"  2>$ERRFILE | grep -v 'OK$'
    processMySqlErrors
    rc=$?
    if [[ $rc != 0 ]] ; then
	doExit $rc
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
            -p?*)   PORT="${arg#-p}" ;;
            -p|--port)
                    PORT="$1"
                    shift ;;
            -u?*)   USER="${arg#-u}" ;;
            -u|--user)
                    USER="$1"
                    shift ;;
            -U?*)   CHECKIUSER="${arg#-U}" ;;
            -U|--checkuser)
                    CHECKUSER="$1"
                    shift ;;
            -l|--level)
                    (( LEVEL = $LEVEL + 1 )) ;;
            -l?*)   (( LEVEL = $LEVEL + 1 ))
                    split=y ;;
        esac
        if [[ $split = y ]] ; then
            set : "-${arg#-?}" "$@"
            shift
            split=n
        fi
    done
    if [[ $split = y ]] ; then
        set : "-${arg#-?}" "$@"
        shift
        split=n
    fi
    
    if [[ $HELP = 1 ]] ; then
        help
    fi
    
    if [[ $# != 0 ]] ; then
        HOST="$1"
	shift
	if [[ $# != 0 ]] ; then
	    DATABASE="$1"
	    EXPLICIT_DATABASE="$1"
	    shift
	    TABLE=("$@")
	fi
    fi
    
    if [[ ! ":$PORT" =~ ^:[[:digit:]]+$ ]] ; then
        echo "$PROG: -p|--port requires unsigned integer argument" >&2
        doExit $ERR_ARG
    fi
}

sigs="1 2 3 4 5 6 7 8 10 11 12 13 14 15 16 24 25 26"
for sig in $sigs ; do
    trap "rm -f $ERRFILE $TMPFILE ; (( rc = 128 + $sig )) ; exit \$rc" $sig
done

main "$@"
doExit $?
