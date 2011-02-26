#!/usr/bin/perl
package Log::Fu;
BEGIN {
	my @_strlevels;
	sub LEVELS() { qw(debug info warn err crit) }
	my $i = 0;
	foreach my $c (LEVELS) {
		$i++;
		*{ "LOG_" . uc($c) } = sub() { $i };
		$_strlevels[$i] = $c;
	}
	sub _strlevel { $_strlevels[$_[0]] }
}
use strict;
use warnings;
use base qw(Exporter);

our @EXPORT = map "log_" . ($_), LEVELS;
our $VERSION = 0.01;
our $SHUSH = 0;
our $LINE_PREFIX = "";

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

sub _set_source_level {
	my ($source,%params) = @_;
	my $h = \%params;
	$h->{level} ||= LOG_INFO;
	$h->{target} ||= $log_target;
	$sources{$source} = $h;
	#print Dumper(\%sources);
}

sub _get_destination {
	#clandestinely does level checking
	my ($pkgname, $level) = @_;
	if(!exists($sources{$pkgname})) {
		return $log_target;
	}
	if($level < $sources{$pkgname}->{level}) {
		return;
	}
	return $sources{$pkgname}->{target};
}

sub _logger {
	return if $SHUSH; #no logging wanted!
	my ($level_number, $level_name, $stack_offset, @messages) = @_;
	my $message = join(" ", @messages);
	my (undef,undef,undef,$subroutine) = caller(1+$stack_offset);
	$subroutine ||= "-";
	my ($pkgname,$filename,$line) = caller(0+$stack_offset);
	my $outfile = _get_destination($pkgname,$level_number);
	return if !defined $outfile;
	my $basename = basename($filename);
	my $msg = "[$level_name] $basename:$line ($subroutine): $message\n";
	if ($LINE_PREFIX) {
		$msg =~ s/^(.)/$LINE_PREFIX $1/gm;
	}
	print $outfile $msg;
}

foreach my $level (LEVELS) {
	my $fn_name = "log_$level";
	no strict "refs";
	my $const = &{uc("LOG_" . $level)};
	*{ $fn_name } = sub {
		_logger($const, uc($level), 1, @_)
	};
	*{ $fn_name . "_with_offset" } = sub {
		_logger($const, uc($level), 1 + shift, @_);
	};
	use strict "refs";
}

1;

__END__

=head1 NAME

Log::Fu - Simple logging module and interface with absolutely no required boilerplate

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

=head2 EXPORTED SYMBOLS

=over

=item log_$LEVEL($message1,$message2...,)

logs a message to the target specified at import with $LEVEL priority

=item $SHUSH

Set this to a true value to silence all logging output

=item $LINE_PREFIX

if set, each new line (not message) will be prefixed by this string.

=back

=head2 PRIVATE SYMBOLS

These functions are subject to change and should not be used often. However
they may be helpful in controlling logging when absolutely necessary

=over

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
like log_warnf instead of inserting log_warn sprintf.. statements all over

=head1 COPYRIGHT

Copyright 2011 M. Nunberg for Dynamite Data
This module is dual-licensed as GPL/Perl Artistic. See README for details.