#!/bin/bash
PROG="check-mysql.sh"
DESC="Check the health of a mysql-compatible server/database"
USAGE1="$PROG [-p|--port port] [-l] [host [dbname [tblname...]]]"
USAGE2="$PROG [-h|--help]"
USER=root
HOST=localhost
PORT=3306
DATABASE=mysql
EXPLICIT_DATABASE=
LEVEL=0
TMPFILE=/tmp/check-mysql-$$
TMPFILE2=/tmp/check-mysql2-$$
TIMEOUT=5
trap "rm -f $TMPFILE $TMPFILE2 ; exit 1" 0 1 2 3 15

PASSWORD=
VOL_SECRETS="${VOL_SECRETS:-/run/secrets}"

HELP_TEXT="
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This script checks the health of a mysql server. The extent of checking
    is defined by the -l/--level option which can be included multiple times
    to increase the amount of checking: at level 0 (no -l/--level arguments)
    the name of the server host is validated and the server is \"pinged\". See
    -l|--level below for more details.

    All non-trivial checks (i.e., checks when one or more -l|--level arguments
    are given) require a password obtained from a file in the /run/secrets
    directory.

    The following options are supported:

    -p|--port port
            The port to use for connecting to the server (default=$PORT).

    -l|--level
            Increase the extent of checking for server/database health. The
            default level is 0, but the level increases by one each time this
            option is given. For example, \"$PROG -lll\" would set the
            level to 3. At level 0, the server host is \"ping\"; at level 1,
            the existence of the indicated database and tables is verified.
            At level 2, \"mysqlcheck --quick\" is run. At level 3,
            \"mysqlcheck --medium-check\" is run. At level 4 and above,
            \"mysqlcheck --extended\" is run. Note that higher level values
            take longer to run.

    -h|--help
            Just print this help text and exit.

    Following the flag options, aguments include the host, database, and
    tables to check. All are optional. The default host is \"$HOST\". The
    default database is \"$DATABASE\".

ENVIRONMENT
    VOL_SECRETS
            If given and not empty, the name of the directory containing
            password files. Default is \"/run/secrets\". The password file must
            have the name \"mysql-<user>-password\". 
"

TABLE=()

HELP=0

function main() {

    processCommandLine "$@"

    PASSWORD_FILE="$VOL_SECRETS/mysql-$USER-password"
    read PASSWORD <$PASSWORD_FILE
    if [[ $? != 0 ]] ; then
        echo "$PROG: unable to read mysql password for $USER" >&2
        exit 1;
    fi

    checkIfUp

    if [[ $LEVEL -gt 0 ]] ; then
        checkIfDatabasePresent
	rc=$?
	if [[ $rc == 0 && ${#TABLE[@]} != 0 ]] ; then
            checkIfTablesPresent
	    rc=$?
        fi
    fi
    case $LEVEL in
        0) return 0 ;;
        1) return $rc ;;
	2) arg=--quick ;;
	3) arg=--medium-check ;;
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

function checkIfUp() {
    mysqladmin --user="$USER" --password="$PASSWORD" --connect_timeout=5 --host="$HOST" --port="$PORT" ping  >/dev/null 2>&1
    if [[ $? != 0 ]] ; then
        echo "$PROG: unable to ping $HOST" >&2
	exit 1
    fi
}

function checkIfDatabasePresent() {
    set : $(runMysqlCommands 'show databases;')
    shift ; shift
    for database in "$@" ; do
        if [[ $database == $DATABASE ]] ; then
	    return 0
        fi
    done
    echo "$PROG: unable to verify database \"$DATABASE\" is on $HOST" >&2
    return 1
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
        echo "$PROG: one or more tables not found in $HOST:$DATABASE" >&2
        exit 1
    fi
}

function runMysqlCommands() {
    echo "$1" | mysql "--user=$USER" "--password=$PASSWORD" 2>$TMPFILE
    grep -v 'Using a password on the command line interface can be insecure' $TMPFILE >&2
    rm -f $TMPFILE
}

function runMysqlcheck() {
    mysqlcheck --user="$USER" --password="$PASSWORD" "$@" >$TMPFILE 2>&1
    grep -v 'Using a password on the command line interface can be insecure' $TMPFILE >$TMPFILE2
    if [[ -s $TMPFILE2 ]] ; then
	cat $TMPFILE2 >&2
	rc=1
    fi
    rm -f $TMPFILE $TMPFILE2
    return $rc
}

function processCommandLine() {
    split=n
    while [[ ":$1" == :-* ]] ; do
        arg="$1"
        shift
        split=n
        case $arg in
            -h?*)   HELP=1
                    split=y ;;
            -h|--help)
                    HELP=1 ;;
            -p?*)   PORT="${arg#-p}" ;;
            -p|--port)
                    PORT="$1"
                    shift ;;
            -p?*)   PORT="${arg#-p}" ;;

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
        echo "$HELP_TEXT"
        exit 0
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
        exit 1
    fi
}

main "$@"
rc=$?

rm -f $TMPFILE $TMPFILE2
trap 0
exit $rc

cat >>/dev/null <<EOF
What do we want the webapp to do if the database is unavailable? Wait? Fail?

  -> fail fast when starting up

Healthcheck for webapp should check database (?)
  
Maybe write generic wait-until-healthy.sh that uses a given healthcheck
command?

What about initializing an empty database, like with xdmod?

Should the db container fail if there is no database, and leave initializing
to the dbinit container? Should it spin and wait? And what do we do in the
dbinit container once the database is initialized? Use restart policy "no".

Pass the mysql root password to the db container so it can initialize an
empty database.

Have dbinit wait until the database is running and default tables are created.
Then have it check if xdmod tables are present




EOF

