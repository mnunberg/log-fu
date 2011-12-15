package Log::Fu;
use strict;
use warnings;
use base qw(Exporter);
use Log::Fu::Common qw(:levels %Config LEVELS fu_term_is_ansi);
use Log::Fu::Common;
use Log::Fu::Color;
use Log::Fu::Chomp;
use Carp qw(carp);
use Sys::Syslog;
use File::Basename qw(basename);
use Constant::Generate [ map {"FLD_$_"} (qw(FH LVL FMT COLOR ISATTY CODE))];

our @EXPORT = (map("log_" . ($_), LEVELS));
push @EXPORT, map "log_$_"."f", LEVELS;
our @EXPORT_OK = qw(set_log_level);

our $VERSION 		= '0.25';

our $SHUSH 			= 0;
our $LINE_PREFIX 	= "";
our $LINE_SUFFIX	= "";

our $TERM_ANSI      = fu_term_is_ansi();
our $TERM_CLEAR_LINE= $TERM_ANSI;

our $USE_WATCHDOG 	= $ENV{LOG_FU_WATCHDOG};
our $NO_STRIP		= $ENV{LOG_FU_NO_STRIP};

our $FORCE_COLOR	= $ENV{LOG_FU_FORCE_COLOR};

our $DISPLAY_SEVERITY = $ENV{LOG_FU_DISPLAY_SEVERITY};
$DISPLAY_SEVERITY ||= 0;

my $ENABLE_SYSLOG;
my $SYSLOG_FACILITY;
my $SYSLOG_STDERR_ECHO = 0;

my $CLEAR_LINE_ESC	= "\033[0J";
#From 0.20
sub Configure {
	my %options = @_;
	
	if($USE_WATCHDOG) {
		carp "Changing global logging options..";
	}
	
	foreach my $k (keys %Config) {
		if(exists $options{$k}) {
			$Config{$k} = delete $options{$k};
		}
	}
	if(%options) {
		die "Unknown options: " . join(",", keys %options);
	}
}

#From 0.20
*AddHandler = *Log::Fu::Chomp::AddHandler;
*DelHandler = *Log::Fu::Chomp::DelHandler;


sub import {
	my $h;
	#check if we're passed an option hashref
	foreach my $i (0..$#_) {
		if(ref($_[$i]) eq "HASH") {
			$h = delete $_[$i];
		}
	}
	#get the filename of the code that's using us.
	my($pkgname,undef,undef) = caller();
	if($pkgname) {
		my($level,$target) = @{$h}{qw(level target)};
		$level = "info" unless defined $level;
		if (grep { $_ eq $level } LEVELS) {
			$level = eval("LOG_" . uc($level));
		} else {
			die "unknown log level $level";
		}
		_set_source_level($pkgname, level => $level, target => $target);
	}
	goto &Exporter::import;
}

my (%sources,$log_target);
$$log_target = *STDERR;
my $def_target_can_use_color = -t STDERR;

sub _set_source_level {
	my ($source,%params) = @_;
	my @datum;
	my $h = \%params;
	$params{level} = LOG_INFO unless defined $params{level};
	$params{target} = $log_target unless defined $params{target};
	@datum[FLD_LVL, FLD_FH] = @params{qw(level target)};
    if(ref $params{target} eq 'CODE') {
        $datum[FLD_CODE] = $params{target};
    } else {
	    $datum[FLD_COLOR] = -t $datum[FLD_FH];
	    $datum[FLD_ISATTY] = -t $datum[FLD_FH];
    }
	$sources{$source} = \@datum;
}

my $defpkg_key = '__LOG_FU_DEFAULTS__';

_set_source_level($defpkg_key);

#Called to get stuff for per-package personalization
sub _get_pkg_params {
	#clandestinely does level checking
	my ($pkgname, $level) = @_;
    my $ret = $sources{$pkgname};
    $ret ||= $sources{$defpkg_key};
    if($level < $ret->[FLD_LVL]) {
        $ret = undef;
    }
    return $ret;
}


sub _logger {
	return if $SHUSH; #no logging wanted!
	my ($level_number, $level_name, $stack_offset, @messages) = @_;
	my $message = join(" ", @messages);
	my (undef,undef,undef,$subroutine) = caller(1+$stack_offset);
	$subroutine ||= "-";
	my ($pkgname,$filename,$line) = caller(0+$stack_offset);
	my $pparams = _get_pkg_params($pkgname, $level_number);
	return if !defined $pparams;
	my $outfile = $pparams->[FLD_FH];
	my $basename = basename($filename);
	
	my $level_str = "[$level_name] ";
	#Color stuff...
	
	if( ($Log::Fu::Color::USE_COLOR && $pparams->[FLD_COLOR]) || $FORCE_COLOR) {
		$message = fu_colorize($level_number, $message);
		if($DISPLAY_SEVERITY <= 0) {
			$level_str = "";
		}
	} elsif($DISPLAY_SEVERITY == -1) {
		$level_str = "";
	}

	$subroutine = fu_chomp($subroutine);
	
	my $msg = "$level_str$basename:$line ($subroutine): $message\n";
	
	if ($LINE_PREFIX) {
		$msg =~ s/^(.)/$LINE_PREFIX$1/mg;
	}
	if($LINE_SUFFIX) {
		$msg =~ s/(.)$/$1$LINE_SUFFIX/mg;
	}
	if($pparams->[FLD_ISATTY] && $TERM_CLEAR_LINE) {
		$msg =~ s/^(.)/$CLEAR_LINE_ESC$1/mg
		#Clear the rest of the line, too:
	}
    if(ref $outfile eq 'CODE') {
        $outfile->($msg);
    } else {
	    print $outfile $msg;
    }
	
	if ($ENABLE_SYSLOG) {
		syslog(syslog_level($level_number), $msg);
	}
}

foreach my $level (LEVELS) {
	#Plain wrappers
	my $fn_name = "log_$level";
	no strict "refs";
	my $const = &{uc("LOG_" . $level)};
	*{ $fn_name } = sub {
		_logger($const, uc($level), 1, @_)
	};
	
	#Offset wrappers
	*{ $fn_name . "_with_offset" } = sub {
		_logger($const, uc($level), 1 + shift, @_);
	};

	#format string wrappers
	*{ $fn_name . "f" } = sub {
		my $fmt_str = shift;
		_logger($const, uc($level), 1, sprintf($fmt_str, @_));
	};	
}

#From 0.03
sub set_log_level {
	my ($pkgname,$level) = @_;
	$level = eval("LOG_".uc($level));
	return if !defined $level;
	return if !exists $sources{$pkgname};
	$sources{$pkgname}->[FLD_LVL] = $level;
	return 1;
}

#From 0.04
sub start_syslog {
	#Take standard openlog options,
	my $ok = openlog(@_);
	$ENABLE_SYSLOG = 1 if $ok;
	return $ok;
}

sub stop_syslog {
	my $ok = closelog();
	$ENABLE_SYSLOG = 0 if $ok;
	return $ok;
}

1;

__END__

=head1 NAME

Log::Fu - Simplified and developer-friendly screen logging

=head1 DESCRIPTION

This is a simple interface for console logging.
It provides a few functions, C<log_info>, C<log_debug>, C<log_warn>,
C<log_crit>, and C<log_err>. They all take strings as arguments, and can take
as many arguments as you so desire (so any concatenation is done for you).

A message is printed to standard error (or to $target if specified),
prefixed with the filename, line number, and originating subroutine of the
message. A format string might become available in the future

It is also possible to configure per-package logging parameters and level limitations.
To do this, simply provide an option hashref when using the module, as shown in
the synopsis. Available levels are: debug info warn err crit

Since this module uses a very plain and simple interface, it is easy to adjust
your program to override these functions to wrap a more complex logging interface
in the future.

There is very little boilerplate code for you to write, and it will normally just
do its thing.

=head1 SYNOPSIS

    use Log::Fu;
    
	log_debug("this is a debug level message");    
	log_info("this is an info-level message");
	log_debugf("this is a %s", "format string");

=head2 IMPORTING

Usually, doing the following should just work

    use Log::Fu;

This will allow a default level of C<INFO>, and log messages to stderr.

If you need more configuration, you may pass a hashref of options during
C<use>. The keys recognized are as follows

=over

=item level

This is the minimum level of severity to display. The available levels from
least to most severe are C<debug, info, warn, err, crit>

=item target

This specifies where to log the message or which action to take. This can be
either a filehandle, in which case the messages will be printed to it, or it
can be a code reference, in which case it will be called with the formatted
message as its argument

=back

=head2 EXPORTED SYMBOLS

The main exported functions begin with a C<log_> prefix, and are completed by
a level specification. This is one of C<debug>, C<info>, C<warn>, C<err> or
C<crit>. In the examples, C<info> is shown, but may be replaced with any of the
specifiers.

=over

=item log_info($string1, $string2, ..)

=item log_infof($format, $string...)

Logs a message to the target specified by the package at import time (C<STDERR>
by default). The first form will just concatenate its arguments together, while
the second form using a printf-style format string.

If the level specified is below the level of importance specified during import-time
the message will not be printed.

=back

=head2 Configuration Package Variables

=over

=item $Log::Fu::SHUSH

Set this to a true value to silence all logging output

=item $Log::Fu::LINE_PREFIX

if set, each new line (not message) will be prefixed by this string.

=item $Log::Fu::LINE_SUFFIX

If set, this will be placed at the end of each line.

=item $Log::Fu::TERM_CLEAR_LINE

If set to true, C<Log::Fu> will print C<\033[0J> after each line. Handy
for use in conjunction with linefeed-like status bars


=item $Log::Fu::USE_COLOR

Set to one if it's detected that your terminal/output device supports colors.
You can always set this to 0 to turn it off, or set C<LOG_FU_NO_COLOR> in your
environment. As of version 0.20, the C<ANSI_COLORS_DISABLED> environment variable
is supported as well.

=back

=head2 Caller Information Display

By default, C<Log::Fu> will print out unabbridged caller information which will
look something like:

	[WARN] demo.pl:30 (ShortNamespace::echo): What about here
	
Often, caller information is unbearably long, and for this, an API has been provided
which allows you to strip and shorten caller/namespace components.

For C<Log::Fu>, caller information is divided into three categories,
the B<namespace>, the B<intermediate> components, and the function B<basename>.

The function C<My::Very::Long::Namespace::do_something> has a
top-level-namespace of C<My>, a function basename of C<do_something>,
and its intermediate components are C<Very::Long::Namespace>.

Currently, this is all accessed by a single function:

=head3 Log::Fu::Configure

This non-exported function will configure stripping/shortening options, or turn
them off, depending on the options:

Synopsis:

	Log::Fu::Configure(
		Strip => 1,
		StripMoreIndicator => '~',
		StripComponents	   => 2,
		StripTopLevelNamespace => 0
	);
	
Will configure C<Log::Fu> to display at most two intermediate components,
and to never shorten the top level namespace. For namespaces shortened, it
will use the '~' character to indicate this.

The full list of options follow:

=over

=item Strip

This is a boolean value. Set this to 0 to disable all stripping functions.

=item StripMoreIndicator

This is a string. When a component is stripped, it is suffixed with the value
of this parameter. Something short like '~' (DOS-style) should suffice, and is
the default.

=item StripMaxComponents

How many intermediate components to allow. If caller information has more
than this number of intermediate components (excluding the top-level namespace
and the function basename), they will be stripped, starting from the beginning.

The default value is 2

=item StripKeepChars

When an intermediate component is stripped, it will retain this many characters.
The default is 2

=item StripTopLevelNamespace

This value is the maximum length of the top-level namespace before it is shortened.
Set this to 0 (the default) to disable shortening of the top-level namespace

=item StripCallerWidth

The maximum allowable width for caller information before it is processed
or stripped. Caller information under this limit is not shortened/stripped

=item StripSubBasename

The length of the function basename. If set, functions longer than this value
will be shortened, with characters being chomped from the I<beginning> of the name.

Set this to 0 (the default) to disable shortening of the function basename.

=back

=head3 Log::Fu::AddHandler($prefix, $coderef)

If more fine-grained control is needed for the printing of debug information, this
function can be used to add a handler for C<$prefix>. The handler is passed one
argument (the fully-qualified function name called), and should return a string
with the new caller information.

Calls originating from packages which contain the string C<$prefix> will be processed
through this handler.

=head3 Log::Fu::DelHandler($prefix)

Unregister a handler for C<$prefix>, added with L</Log::Fu::AddHandler>

=head3 $Log::Fu::NO_STRIP, $ENV{LOG_FU_NO_STRIP}

Set these to true to disable all stripping/shortening

=head3 $Log::Fu::USE_WATCHDOG, $ENV{LOG_FU_WATCHDOG}

If set to true, C<Log::Fu> will warn whenever its stripping/shortening
configuration has been changed. This is useful to detect if some offending
code is changing your logging preferences

=head2 SEVERITY DISPLAY

As of version 0.23, displaying of severity information (e.g. C<[INFO]>)
is disabled if colors are enabled. This is because the colors themselves uniquely
identify the severity level.

=head3 $Log::Fu::DISPLAY_SEVERITY, $ENV{LOG_FU_DISPLAY_SEVERITY}

This option controls the printing of severity messages. If set to 0 (the default),
then the default behavior mentioned above is assumed. If greater than zero,
the severity level is always printed. If less than zero, then the severity
level is never printed

=head2 PRIVATE SYMBOLS

These functions are subject to change and should not be used often. However
they may be helpful in controlling logging when absolutely necessary

=over

=item Log::Fu::set_log_level($pkgname, $levelstr)

Sets $pkgname's logging level to $levelstr. $levelstr is one of err, debug, info,
warn, crit etc.

=item Log::Fu::start_syslog(@params)

Enables logging to syslog. @params are the options passed to L<Sys::Syslog/openlog>

=item Log::Fu::stop_syslog()

Stops logging to syslog

=item Log::Fu::_logger($numeric_level_constant, $level_display, $stack_offset, @messages)

$numeric_level_constant is a constant defined in this module, and is currently one
of LOG_[WARN|DEBUG|ERR|INFO|CRIT]. $level_display is how to pretty-print the level.

A not-so-obvious parameter is $stack_offset, which is the amount of stack frames
_logger should backtrack to get caller() info. All wrappers use a value of 1.

=item Log::Fu::log_warn_with_offset($offset, @messages)

like log_*, but allows to specify an offset. Useful in $SIG{__WARN__} or DIE functions

=back

=head1 BUGS

None known

=head1 TODO

Allow an option for user defined C<~/.logfu> preferences, so that presets can be
selected.

=head1 COPYRIGHT

Copyright 2011 M. Nunberg

This module is dual-licensed as GPL/Perl Artistic. See README for details.
