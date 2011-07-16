#!/usr/bin/perl
package Log::Fu;
use strict;
use warnings;
BEGIN {
	no strict "refs";
	my @_strlevels;
	sub LEVELS() { qw(debug info warn err crit) }
	my $i = 0;
	foreach my $c (LEVELS) {
		*{ "LOG_" . uc($c) } = sub() { $i };
		$_strlevels[$i] = $c;
		$i++;
	}
	sub _strlevel { $_strlevels[$_[0]] }
	
	my @_syslog_levels = map {
		if ($_ eq 'warn') {
			"WARNING";
		} else {
			uc($_)
		} } @_strlevels;
	sub _syslog_level { $_syslog_levels[$_[0]]}
	#warn is not quite the same as WARNING
}

use base qw(Exporter);
use Sys::Syslog;

our @EXPORT = (map("log_" . ($_), LEVELS));
push @EXPORT, map "log_$_"."f", LEVELS;
our @EXPORT_OK = qw(set_log_level);

our $VERSION 		= '0.10';
our $SHUSH 			= 0;
our $USE_COLOR;
our $LINE_PREFIX 	= "";

my $ENABLE_SYSLOG;
my $SYSLOG_FACILITY;
my $SYSLOG_STDERR_ECHO = 0; 

#Color stuff:
BEGIN {
	if ($ENV{LOG_FU_NO_COLOR}) {
		$USE_COLOR = 0;
	} else {
		eval {
			require Term::Terminfo;
			Term::Terminfo->import();
			my $ti = Term::Terminfo->new();
			my $n_colors = $ti->getnum("colors");
			if ($n_colors < 8) {
				#Color logging disabled:
				die "Must have >= 16 colors!";
			}
		};
		if ($@) {
			$USE_COLOR = 0;
		} else {
			$USE_COLOR = 1;
		}
	}
}
my %COLORS = (
	YELLOW	=> 3,
	WHITE	=> 7,
	MAGENTA	=> 5,
	CYAN	=> 6,
	BLUE	=> 4,
	GREEN	=> 2,
	RED		=> 1,
	BLACK	=> 0,
);

use constant {
	COLOR_FG	=> 3,
	COLOR_BG	=> 4,
	COLOR_BRIGHT_FG	=> 1,
	COLOR_INTENSE_FG=> 9,
	COLOR_DIM_FG	=> 2
};
use constant {
	COLOR_RESET => "\33[0m"
};

use Data::Dumper;
use File::Basename qw(basename);
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
		if($level) {
			if (grep { $_ eq $level } LEVELS) {
				$level = eval("LOG_" . uc($level));
				my $txt = _strlevel($level);
				#log_debug("Using level '$txt' for $pkgname");
			} else {
				die "unknown log level $level";
			}
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
	my $h = \%params;
	$h->{level} = LOG_INFO if !defined $h->{level};
	$h->{target} ||= $log_target;
	$h->{can_use_color} = -t $h->{target};
	$sources{$source} = $h;
	#print Dumper(\%sources);
}

#Called to get stuff for per-package personalization
sub _get_pkg_params {
	#clandestinely does level checking
	my ($pkgname, $level) = @_;
	if(!exists($sources{$pkgname})) {
		return {
			target => $log_target,
			can_use_color => $def_target_can_use_color,
		};
	}
	if($level < $sources{$pkgname}->{level}) {
		return;
	}
	return $sources{$pkgname};
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
	my $outfile = $pparams->{target};
	my $basename = basename($filename);
	
	#Color stuff...
	if($USE_COLOR && $pparams->{can_use_color}) {
		my $fmt_begin = "\033[";
		my $fmt_end = COLOR_RESET;
		if ($level_number == LOG_ERR || $level_number == LOG_CRIT) {
			$fmt_begin .= sprintf("%s;%s%sm", COLOR_BRIGHT_FG, COLOR_FG, $COLORS{RED});
		} elsif ($level_number == LOG_WARN) {
			$fmt_begin .= sprintf("%s%sm", COLOR_FG, $COLORS{YELLOW});
		} elsif ($level_number == LOG_DEBUG) {
			$fmt_begin .= sprintf("%s;%s%sm", COLOR_DIM_FG, COLOR_FG, $COLORS{WHITE});
		} else {
			$fmt_begin = "";
			$fmt_end = "";
		}
		$message = $fmt_begin  . $message . $fmt_end;
	}
	
	my $msg = "[$level_name] $basename:$line ($subroutine): $message\n";
	if ($LINE_PREFIX) {
		$msg =~ s/^(.)/$LINE_PREFIX $1/gm;
	}
	print $outfile $msg;
	if ($ENABLE_SYSLOG) {
		syslog(_syslog_level($level_number), $msg);
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
	
	use strict "refs";
}

#From 0.03
sub set_log_level {
	my ($pkgname,$level) = @_;
	$level = eval("LOG_".uc($level));
	return if !defined $level;
	return if !exists $sources{$pkgname};
	$sources{$pkgname}->{level} = $level;
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

Log::Fu - Simple logging module and interface with absolutely no required boilerplate - Now in COLOR!

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

	use Miner::Logger { target => $some_filehandle, level => "info" };
	log_debug("this is a debug level message");
	log_info("this is an info-level message");
	log_debugf("this is a %s", "format string");

=head2 EXPORTED SYMBOLS

=over

=item log_$LEVEL($message1,$message2...,)
=item log_${LEVEL}f("put your %s here", "format string")
logs a message to the target specified at import with $LEVEL priority.

the *f variants wrap around sprintf


=item $SHUSH

Set this to a true value to silence all logging output

=item $LINE_PREFIX

if set, each new line (not message) will be prefixed by this string.

=item $USE_COLOR

Set to one if it's detected that your terminal/output device supports colors.
You can always set this to 0 to turn it off, or set C<LOG_FU_NO_COLOR> in your
environment

=back

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

=item _logger($numeric_level_constant, $level_display, $stack_offset, @messages)

$numeric_level_constant is a constant defined in this module, and is currently one
of LOG_[WARN|DEBUG|ERR|INFO|CRIT]. $level_display is how to pretty-print the level.

A not-so-obvious parameter is $stack_offset, which is the amount of stack frames
_logger should backtrack to get caller() info. All wrappers use a value of 1.

=item log_$LEVEL_with_offset($offset, @messages)

like log_*, but allows to specify an offset. Useful in $SIG{__WARN__} or DIE functions

=back

=head1 BUGS

None known

=head1 TODO

An optional (!!!) format string would be nice. Also, the ability to have functions
like log_warnf instead of inserting log_warn sprintf.. statements all over (DONE in 0.05)

=head1 COPYRIGHT

Copyright 2011 M. Nunberg for Dynamite Data
This module is dual-licensed as GPL/Perl Artistic. See README for details.