#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use IO::String;
my $fh = IO::String->new();

require "Log/Fu.pm";
Log::Fu->import({level => "warn", target => $fh});
*set_log_level = \&Log::Fu::set_log_level;

log_debug("INFO MESSAGE");
$fh->seek(0);
is($fh->getline(), undef, "INFO doesn't display");
log_warn("WARN MESSAGE");
$fh->seek(0);
like($fh->getline(), qr/WARN MESSAGE/, "WARN displays");

$fh->truncate(0);
$fh->seek(0);
ok(set_log_level(__PACKAGE__, "DEBUG"), "changing log level to DEBUG");

log_debug("DEBUG MESSAGE POST LEVEL SET");
$fh->seek(0);
like($fh->getline(), qr/DEBUG MESSAGE POST LEVEL SET/, "DEBUG displays");

$fh->truncate(0);
ok(set_log_level(__PACKAGE__, "ERR"), "changing log level to ERR");
log_warn("This warning message shouldn't appear");
$fh->seek(0);
is($fh->getline, undef, "WARN doesn't display");

done_testing();