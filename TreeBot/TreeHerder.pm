package TreeBot::TreeHerder;
use Moo;

use HTTP::Request;
use JSON::XS qw(decode_json);
use POE qw(Component::Client::HTTP);
use Try::Tiny;

has irc       => ( is => 'rw' );
has resultset => ( is => 'rw' );

my $_instance;
sub instance {
    my $class = shift;
    return defined $_instance ? $_instance : ($_instance = $class->new(@_));
}

sub init {
    my ($self, $irc) = @_;
    POE::Component::Client::HTTP->spawn(
        Agent           => 'TreeBot/0.1',
        Alias           => 'ua',
        FollowRedirects => 5,
        Timeout         => 30,
    );
    $self->irc($irc);
}

sub poll {
    my ($self, $kernel) = @_;

    $self->resultset(undef);

    # grab resultset
    print "requesting https://treeherder.mozilla.org/api/project/bmo-master/resultset\n";
    $kernel->post(
        'ua', 'request', 'response',
        HTTP::Request->new( GET => 'https://treeherder.mozilla.org/api/project/bmo-master/resultset' ),
        'resultset'
    );

    # clean up old revisions
    $self->_cleanup();
}

sub response {
    my ($self, $kernel, $gen_args, $call_args) = @_[OBJECT, KERNEL, ARG0, ARG1];

    # decode json
    my $response;
    try {
        $response = decode_json($call_args->[0]->decoded_content);
    } catch {
        warn "Failed to decode json: $_\n";
        warn $call_args->[0]->as_string(), "\n";
        return;
    };

    # pass to handler
    if ($gen_args->[1] eq 'resultset') {
        $self->resultset_handler($kernel, $response);
    }
    elsif ($gen_args->[1] =~ /^status\.(\d+)/) {
        $self->status_handler($kernel, $1, $response);
    }
}

sub resultset_handler {
    my ($self, $kernel, $response) = @_;

    try {
        $self->resultset($response->{results});
        foreach my $result (@{ $response->{results} }) {
            my $id = $result->{id};
            if ($self->_exists($id)) {
                $self->_touch($id);
            }
            else {
                print "requesting https://treeherder.mozilla.org/api/project/bmo-master/resultset/$id/status\n";
                $kernel->post(
                    'ua', 'request', 'response',
                    HTTP::Request->new( GET => "https://treeherder.mozilla.org/api/project/bmo-master/resultset/$id/status" ),
                    "status.$id"
                );
            }
        }
    } catch {
        my $error = $_;
        $error =~ s/(^\s+|\s+$)//g;
        warn "$error\n";
    };
}

sub status_handler {
    my ($self, $kernel, $id, $response) = @_;
    return if $response->{running};

    try {
        my ($result) = grep { $_->{id} == $id } @{ $self->resultset() };
        return unless $result;

        $self->_touch($id);
        return unless $response->{testfailed};

        foreach my $revision (@{ $result->{revisions} }) {
            next unless $revision->{comments} =~ /^bug\s+(\d+)/i;
            my $bug_id = $1;
            print "announcing text-failure bug $bug_id\n";
            my $msg = "Test Failure: Bug $bug_id - " .
                "https://treeherder.mozilla.org/#/jobs?repo=bmo-master&revision=" . $revision->{revision};
            foreach my $channel (@{ TreeBot::Config->instance->irc_channels }) {
                $self->irc->yield( privmsg => $channel => $msg );
            }
        }
    } catch {
        my $error = $_;
        $error =~ s/(^\s+|\s+$)//g;
        warn "$error\n";
    };
}

sub _exists {
    my ($self, $id) = @_;
    my $file = TreeBot::Config->instance->data_path . '/' . $id;
    return -e $file;
}

sub _touch {
    my ($self, $id) = @_;
    my $file = TreeBot::Config->instance->data_path . '/' . $id;
    my $time = time();
    if (-e $file) {
        utime($time, $time, $file)
            or die "failed to touch $file: $!\n";
    }
    else {
        open(my $fh, '>', $file)
            or die "failed to create $file: $!\n";
        close($fh);
    }
}

sub _cleanup {
    my ($self) = @_;
    # TODO delete files older than 7 days
}

1;
