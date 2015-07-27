package TreeBot::Daemon;
use strictures;

use Carp qw(confess);
use Daemon::Generic;
use TreeBot::Config;
use TreeBot::IRC;

sub start {
    $SIG{__DIE__} = sub { confess(@_) };
    newdaemon();
}

sub gd_preconfig {
    my ($self) = @_;
    return (
        pidfile => TreeBot::Config->instance->pid_file,
    );
}

sub gd_getopt {
    my ($self) = @_;
    if (grep { $_ eq '-d' } @ARGV) {
        @ARGV = qw(-f start);
    }
    $self->SUPER::gd_getopt();
}

sub gd_redirect_output {
    my ($self) = @_;
    my $filename = TreeBot::Config->instance->log_file;
    open(STDERR, ">>$filename")
        or die "could not open stderr: $!";
    close(STDOUT);
    open(STDOUT, ">&STDERR")
        or die "redirect STDOUT -> STDERR: $!";
}

sub gd_run {
    my ($self) = @_;
    TreeBot::IRC->start();
}

1;
