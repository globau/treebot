package TreeBot::Config;
use Moo;

use File::Slurp;
use FindBin qw($RealBin);
use YAML::Tiny;

has irc     => ( is => 'ro' );
has repos   => ( is => 'ro' );
has debug   => ( is => 'rw' );

has pid_file     => ( is => 'lazy' );
has log_file     => ( is => 'lazy' );
has data_path    => ( is => 'lazy' );

around BUILDARGS => sub {
    my ($orig, $class) = @_;
    my $config = YAML::Tiny->read("$RealBin/configuration.yaml")->[0];
    $config->{debug} = 0;
    $config->{irc}->{port} ||= 6668;
    $config->{irc}->{name} ||= $config->{irc}->{nick};
    foreach my $repo (@{ $config->{repos} }) {
        $repo->{channels} = [
            map { $_ = '#' . $_ unless /^#/; $_  }
            split /\s+/, $repo->{channels}
        ];
    }
    return $class->$orig($config);
};

sub BUILD {
    my ($self) = @_;
    die "config requires irc_host, irc_nick\n"
        unless $self->irc->{host} && $self->irc->{nick};
    mkdir($self->data_path) unless -d $self->data_path;
}

sub _coerce_channels {
    return [ split(/\s+/, $_[0]) ];
}

sub _build_pid_file  { "$RealBin/treebot.pid" }
sub _build_log_file  { "$RealBin/treebot.log" }
sub _build_data_path { "$RealBin/data"        }

my $_instance;
sub instance {
    my $class = shift;
    return defined $_instance ? $_instance : ($_instance = $class->new(@_));
}

1;
