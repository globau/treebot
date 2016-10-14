package TreeBot::TreeHerder;
use Moo;

use DateTime;
use HTTP::Request;
use JSON::XS qw(decode_json);
use POE qw(Component::Curl::Multi);
use Try::Tiny;

use constant DEBUG => 0;

has irc       => ( is => 'rw' );
has resultset => ( is => 'rw' );

my $_instance;
sub instance {
    my $class = shift;
    return defined $_instance ? $_instance : ($_instance = $class->new(@_));
}

sub init {
    my ($self, $irc) = @_;
    POE::Component::Curl::Multi->spawn(
        Agent           => 'TreeBot/0.1',
        Alias           => 'ua',
        FollowRedirects => 5,
        Timeout         => 30,
        curl_debug      => DEBUG,
    );
    $self->irc($irc);
}

sub poll {
    my ($self, $kernel) = @_;

    $self->resultset(undef);

    # grab resultset
    DEBUG and print "requesting https://treeherder.mozilla.org/api/project/bmo-master/resultset/\n";
    $kernel->post(
        'ua', 'request', 'response',
        HTTP::Request->new( GET => 'https://treeherder.mozilla.org/api/project/bmo-master/resultset/' ),
        'resultset'
    );

    # clean up old revisions
    $self->_cleanup();
}

sub response {
    my ($self, $kernel, $gen_args, $call_args) = @_[OBJECT, KERNEL, ARG0, ARG1];
    DEBUG and print "processing response\n";

    # decode json
    my $response;
    try {
        $response = decode_json($call_args->[0]->content);
    } catch {
        warn "Failed to decode json: $_\n";
        warn $call_args->[0]->as_string, "\n";
        return;
    };

    # pass to handler
    DEBUG and print "handling ", $gen_args->[1], "\n";
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
                DEBUG and print "already handled result $id\n";
                $self->_touch($id);
            }
            else {
                DEBUG and print "requesting https://treeherder.mozilla.org/api/project/bmo-master/resultset/$id/status/\n";
                $kernel->post(
                    'ua', 'request', 'response',
                    HTTP::Request->new( GET => "https://treeherder.mozilla.org/api/project/bmo-master/resultset/$id/status/" ),
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

        $self->_touch($id, scalar localtime());
        DEBUG and printf "$id status: %s\n", ($response->{testfailed} ? 'failed' : 'passed');
        return unless $response->{testfailed};

        foreach my $revision (@{ $result->{revisions} }) {
            next unless $revision->{comments} =~ /^bug\s+(\d+)/i;
            my $bug_id = $1;
            print "announcing test-failure bug $bug_id\n";
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
    my ($self, $id, $data) = @_;
    my $file = TreeBot::Config->instance->data_path . '/' . $id;
    my $time = time();
    if (-e $file && !defined($data)) {
        utime($time, $time, $file)
            or die "failed to touch $file: $!\n";
    }
    else {
        open(my $fh, '>', $file)
            or die "failed to create $file: $!\n";
        print $fh $data if defined($data);
        close($fh);
    }
}

sub _cleanup {
    my ($self) = @_;
    my $now = DateTime->now;
    foreach my $file (glob(TreeBot::Config->instance->data_path . '/*')) {
        next unless $file =~ m#/\d+$#;
        my $modified = DateTime->from_epoch( epoch => (stat($file))[9] );
        my $age = $now->delta_days($modified)->in_units('days');
        next if $age <= 7;
        DEBUG and print "deleting old revision: $file\n";
        unlink($file);
    }
}

1;
