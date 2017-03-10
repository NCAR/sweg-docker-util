#!/usr/bin/perl -w
use Getopt::Long;
use Time::Local;
use File::Copy "cp";

$PROG = "docker-entrypoint.pl";
$DESC = "Patch config files before running command in container";
$USAGE1 = "$PROG --file file [--file file...] --env var [--env var...] CMD args...";
$USAGE2 = "$PROG --help";

$HELP_TEXT = <<"EOF";
NAME
    $PROG - $DESC

SYNOPSIS
    $USAGE1
    $USAGE2

DESCRIPTION
    This script modifies a set of configuration files using a given set of environment
    variables, then runs the given command using "exec".

    Files are modified by replacing all occurances of "\${varname}" with the value of
    variable "varname". For example, given an environment variable USER, which
    is set to "jsmith", and a line in configuration file "myfile", which looks like:

      echo Hello \${USER}

    the command

      $PROG --file myfile --env USER 

    would modify myfile to look like:

      echo Hello jsmith

    This script is meant to be used as a Dockerfile ENTRYPOINT, with the command and
    its arguments specified as the container CMD.

    The following options are supported:

    -f|--file filename
            The name of a configuration file. This can be used multiple times to specify
            multiple files.

    -e|--env environment_variable
            The name of an environment variable. This can be used multiple times to
            specify multiple variables. All variables named as --env options MUST be
            in the environment.

    -v|--verbose
            Write status messages to STDOUT. This can appear multiple times to increase
            verbosity.

    -h|--help
            Write this documentation to STDOUT.

EOF

$VERBOSE = 0;

$HELP = 0;
@FILES = ();
@ENVVARS = ();
$FILE_INFO = ();
$DEPLOY_ENV = ();
@errors = ();

Getopt::Long::Configure ("bundling");
GetOptions("f|file=s"   => \@FILES,
	   "e|env=s"    => \@ENVVARS,
           "v|verbose+" => \$VERBOSE,
           "h|help"     => \$HELP);

if ($HELP) {
    printf STDOUT ("%s\n",$HELP_TEXT);
    exit(0);
}

if (@ARGV == 0) {
    printf STDERR ("%s: expecting a command to run\n\n%s\n",$PROG,$HELP_TEXT);
    exit(1);
}

if ((@FILES == 0) && (@ENVVARS != 0)) {
    push(@errors,"at least one file must be specified");
} else {
    $FILE_INFO = validateFiles(@FILES);
}
if ((@ENVVARS == 0) && (@FILES != 0)) {
    push(@errors,"at least one environment variable must be specified");
} else {
    $DEPLOY_ENV = loadEnv(@ENVVARS);
}
if (@errors > 0) {
    usageError(sprintf("fatal error%s",(@errors==1)?"":"s"),@errors);
}

patchFiles($DEPLOY_ENV,$FILE_INFO,@FILES);

exec(@ARGV) or
    die "$PROG: exec error: $!\n";

exit(0);

sub usageError {
    my $mainError = shift;
    printf STDERR ("%s: %s",$PROG,$mainError);
    if (@_) {
        printf STDERR (":\n  %s\n",join("\n  ",@_));
    } else {
        printf STDERR ("\n");
    }
    printf STDERR ("Usage:\n");
    printf STDERR ("    %s\n",$USAGE1);
    printf STDERR ("    %s\n",$USAGE2);
    exit(1);
}

sub dbgPrintf {
    my $level = int($_[0]); shift;
    my $format = shift;
    if (($level <= $VERBOSE) && ($level > 0)) {
	if (@_) {
	    printf STDERR ("%${level}s$format"," ",@_);
	} else {
	    printf STDERR ("%${level}s$format"," ");
	}
    }
}

sub validateFiles {
    my %fileInfo = ();
    foreach my $file (@_) {
	my $work = "$file." . getTimestamp();
        my $failsafe = "$file.debk";
	if (! -e $file) {
	    push(@errors,"File \"$file\" does not exist");
	} elsif (! -r $file) {
	    push(@errors,"\"$file\" is not readable");
	} elsif (! -w $file) {
	    push(@errors,"\"$file\" is not writable");
	} elsif (-e $failsafe && ! -r $failsafe) {
	    push(@errors,"\"$failsafe\" is not readable");
        } else {
            #
            # "cp" (unlike "copy") is supposed to use the same metadata in the new file.
            # We copy to make sure we can write to the target directory - this file will
            # be overwritten and renamed if everything works right
	    cp($file,$work) or
		push(@errors,"Unable to copy to backup file \"$work\"");
	    my $info = {};
	    $info->{"file"} = $file;
	    $info->{"work"} = $work;
	    $info->{"failsafe"} = $failsafe;
	    $fileInfo{$file} = $info;
        }
    }
    return \%fileInfo;
}

sub loadEnv {
    my %parms = ();
    foreach my $envvar (@_) {
	my $val = $ENV{$envvar};
	if (! defined($val)) {
	    push(@errors,"No value defined for parameter \"$envvar\"");
	} else {
	    dbgPrintf(3,"Variable \"%s\" = \"%s\"\n",$envvar,$val);
	    $parms{$envvar} = $val;
	}
    }
    return \%parms;
}

sub patchFiles {
    my $parm2value = shift;
    my $filesInfo = shift;
    foreach my $file (@_) {
	my $fileInfo = $filesInfo->{$file};
        patchFile($parm2value,$fileInfo);
    }
}

sub patchFile {
    my $parm2value = shift;
    my $fileInfo = shift;
    my $file = $fileInfo->{"file"};
    my $work = $fileInfo->{"work"};
    my $failsafe = $fileInfo->{"failsafe"};

    $patchedData = loadNamedFileAndPatch($parm2value,$file);
    if (! defined($patchedData)) {
	if (-e $failsafe) {
	    $patchedData = loadNamedFileAndPatch($parm2value,$failsafe);
	}
    }
    if (defined($patchedData)) {
	if (! -e $failsafe) {
            cp($file,$failsafe) or
		die "$PROG: Unable to write failsafe backup file\n $failsafe: $!";
        }
	writePatchedData($patchedData,$work);
	rename($work,$file) or
            die "$PROG: rename \"$work\" \"$file\": $!";
	dbgPrintf(2,"Renamed %s to %s\n",$work,$file);
	dbgPrintf(1,"Successfully patched %s\n",$file);
    } else {
	dbgprintf(1,"No change to %s\n",$file);
    }
}

sub loadNamedFileAndPatch {
    my $parm2value = shift;
    my $file = shift;
    dbgPrintf(1,"Reading \"%s\"\n",$file);
    open(SOURCE,"<",$file) or
	die "$PROG: open failed\n$file: $!\n";

    $patchedData = loadFromFileHandleAndPatch($parm2value,\*SOURCE);

    close(SOURCE) or
	die "$PROG: close failed\n$file: $!\n";
    dbgPrintf(2,"Done reading \"%s\"\n",$file);
    return $patchedData;
}

sub loadFromFileHandleAndPatch {
    my $parm2value = shift;
    my $fh = shift;

    my $modified = 0;
    @out = ();
    my $lineno = 0;
    while (<$fh>) {
        $lineno++;
        my $remaining = $_;
        chomp($remaining);
	dbgPrintf(5,"%d: %s\n",$lineno,$remaining);

	my $processed = "";
	while ($remaining =~ /^(.*)\$\{([A-Za-z_][A-Za-z_0-9]*)}(.*)$/) {
            $processed = $3 . $processed;
	    $value = $parm2value->{$2};
            if (!defined($value)) {
	        $value = "\${" . $2 . "}";
		dbgPrintf(3,"Line %d: Skipping variable reference \"%s\"\n",
			  $lineno,$value);
            } else {
		$modified = 1;
		dbgPrintf(4,"Line %d: Substituting \"%s\"\n" .
			  "    for variable reference \"\${%s}\"\n",
			  $lineno,$value,$2);
	    }
	    $processed = $value . $processed;
	    $remaining = $1;
        }
	$processed = $remaining . $processed;
	push(@out,$processed);
    }
    if (!$modified) {
	return undef;
    }
    push(@out,'');
    return join("\n",@out);
}

sub writePatchedData {
    my $patchedData = shift;
    my $filename = shift;
    open(TARGET,">",$filename) or
	die "$PROG: open failed\n$filename: $!\n";
    print TARGET $patchedData;
    close(TARGET) or
	die "$PROG: close failed\n$filename: $!\n";
    dbgPrintf(2,"Wrote %s\n",$filename);
}

@TZ_OFFSET = ();

sub getTimestamp {
    if (@TZ_OFFSET == 0) {
	$time = timelocal(0, 0, 0, 1, 0, 1970 );
	$TZ_OFFSET[0] = secsToHHMM(-$time);
	$time = timelocal(0, 0, 0, 1, 6, 1970 ) - timegm(0, 0, 0, 1, 6, 1970 );
	$TZ_OFFSET[1] = secsToHHMM(-$time);
    }
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02d%s",
		   $year+1900,$mon+1,$mday,$hour,$min,$sec,$TZ_OFFSET[$isdst?1:0]);
}

sub secsToHHMM {
    my $secs = shift;
    my $sign = ($secs < 0) ? "-" : "+";
    $min = int(abs($secs / 60));
    $hr = $min / 60;
    $min -= $hr*60;
    return sprintf("%s%02d:%02d",$sign,$hr,$min);
}

0;




