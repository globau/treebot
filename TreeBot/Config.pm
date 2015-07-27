package TreeBot::Config;
use Moo;

use File::Slurp;
use FindBin qw($RealBin);
use Mojo::JSON;

has irc_host     => ( is => 'ro' );
has irc_port     => ( is => 'ro' );
has irc_channels => ( is => 'ro', coerce => \&_coerce_channels );
has irc_nick     => ( is => 'ro' );
has irc_password => ( is => 'ro' );
has irc_name     => ( is => 'ro' );

has pid_file     => ( is => 'lazy' );
has log_file     => ( is => 'lazy' );
has data_path    => ( is => 'lazy' );

around BUILDARGS => sub {
    my ($orig, $class) = @_;
    my $json = Mojo::JSON->new();
    my $config = $json->decode(scalar read_file("$RealBin/configuration.json"))
        || die $json->error;

    $config->{irc_port} ||= 6668;
    $config->{irc_name} ||= $config->{irc_nick};

    return $class->$orig($config);
};

sub BUILD {
    my ($self) = @_;
    die "config requires irc_host, irc_channels, irc_nick\n"
        unless $self->irc_host && $self->irc_channels && $self->irc_nick;
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
