#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Log::Fu' ) || print "Bail out!
";
}

diag( "Testing Log::Fu $Log::Fu::VERSION, Perl $], $^X" );
