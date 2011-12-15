package Log::Fu::Common;
use strict;
use warnings;
use base qw(Exporter);
#Simple common levels

our (@EXPORT,%EXPORT_TAGS,@EXPORT_OK);
use Constant::Generate [qw(
    LOG_DEBUG
    LOG_INFO
    LOG_WARN
    LOG_ERR
    LOG_CRIT
)], -export_ok => 1,
    -tag => 'levels',
    -mapname => 'strlevel',
    -export_tags => 1;

sub LEVELS() { qw(debug info warn err crit) }
my @_syslog_levels = qw(DEBUG INFO WARNING ERR CRIT);
sub syslog_level { $_syslog_levels[$_[0]] }
push @EXPORT, qw(syslog_level LEVELS);

our %Config;

push @EXPORT_OK, '%Config';

my $term_re = qr/^(?:
xterm
xterm-color
rxvt
urxvt
rxvt-unicode
screen
tmux
konsole
gnome-terminal
vt100
linux
ansi
cygwin
)$/x;

sub fu_term_is_ansi {
    defined $ENV{TERM} and $ENV{TERM} =~ $term_re;
}
push @EXPORT, 'fu_term_is_ansi';

