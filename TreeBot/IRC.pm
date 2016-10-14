package TreeBot::IRC;
use Moo;

use DateTime;
use IRC::Utils ':ALL';;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::NickServID;
use TreeBot::Config;
use TreeBot::TreeHerder;

my $_irc;
sub irc { $_irc }

sub start {
    my $config = TreeBot::Config->instance;
    $_irc = POE::Component::IRC->spawn(
        nick        => $config->irc->{nick},
        ircname     => $config->irc->{name},
        server      => $config->irc->{host},
        port        => $config->irc->{port},
    ) or die "failed: $!\n";

    $_irc->plugin_add(
        'NickServID',
        POE::Component::IRC::Plugin::NickServID->new(
            Password => $config->irc->{password},
        )
    ) if $config->irc->{password};

    POE::Session->create(
        package_states => [
            'TreeBot::IRC' => [ qw(
                _start
                irc_001
                irc_join
                poll_tree
            ) ],
        ],
        object_states => [
            TreeBot::TreeHerder->instance => [ qw(
                response
            ) ],
        ],
        heap => { irc => $_irc },
        options => { trace => 0, default => 0 },
    );

    $poe_kernel->run();
}

#
# poe handlers
#

sub _start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $irc = $heap->{irc};
    my $config = TreeBot::Config->instance;
    $irc->yield(register => 'all');
    $heap->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add('Connector' => $heap->{connector});
    $irc->yield (
        connect => {
            Server  => $config->irc->{host},
            Port    => $config->irc->{port},
            Nick    => $config->irc->{nick},
        }
    );
}

sub irc_001 {
    my ($kernel, $sender) = @_[KERNEL, SENDER];
    my $irc = $sender->get_heap();
    my $config = TreeBot::Config->instance;
    TreeBot::TreeHerder->instance->init($irc);
    my %channels;
    foreach my $repo (@{ $config->repos }) {
        foreach my $channel (@{ $repo->{channels} }) {
            $channels{lc($channel)} = 1;
        }
    }
    foreach my $channel (sort keys %channels) {
        $irc->yield(join => $channel);
    }
}

sub irc_join {
    my ($kernel, $sender, $channel) = @_[KERNEL, SENDER, ARG0];
    my $irc = $sender->get_heap();
    return unless parse_user($_[ARG0]) eq $irc->nick_name;
    $kernel->delay(poll_tree => 1);
}

sub poll_tree {
    my ($kernel, $sender) = @_[KERNEL, SENDER];
    TreeBot::TreeHerder->instance->poll($kernel, $sender->get_heap());
    $kernel->delay(poll_tree => 60);
}

1;
