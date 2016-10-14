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
        curl_debug      => 0,
    );
    $self->irc($irc);
    $self->resultset({});
}

sub poll {
    my ($self, $kernel) = @_;
    my $config = TreeBot::Config->instance;

    # grab resultsets
    foreach my $repo (@{ $config->repos }) {
        my $project = $repo->{project};
        $self->resultset->{$project} = undef;
        my $url = "https://treeherder.mozilla.org/api/project/$project/resultset/";
        DEBUG and print "requesting $url\n";
        $kernel->post(
            'ua', 'request', 'response',
            HTTP::Request->new( GET => $url ),
            "resultset:$project",
        );
    }

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
    my $event = $gen_args->[1];
    DEBUG and print "handling $event\n";
    if ($event =~ /^resultset:(.+)/) {
        $self->resultset_handler($kernel, $response, $1);
    }
    elsif ($event =~ /^status:([^:]+):(\d+)/) {
        $self->status_handler($kernel, $response, $1, $2);
    }
}

sub resultset_handler {
    my ($self, $kernel, $response, $project) = @_;

    try {
        $self->resultset->{$project} = $response->{results};
        foreach my $result (@{ $response->{results} }) {
            my $id = $result->{id};
            if ($self->_exists($project, $id)) {
                DEBUG and print "already handled result $project:$id\n";
                $self->_touch($project, $id);
            }
            else {
                my $url = "https://treeherder.mozilla.org/api/project/$project/resultset/$id/status/";
                DEBUG and print "requesting $url\n";
                $kernel->post(
                    'ua', 'request', 'response',
                    HTTP::Request->new( GET => $url ),
                    "status:$project:$id"
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
    my ($self, $kernel, $response, $project, $id) = @_;
    return if $response->{running};
    my $config = TreeBot::Config->instance;

    try {
        my ($result) = grep { $_->{id} == $id } @{ $self->resultset->{$project} };
        if (!$result) {
            warn "failed to find $project:$id in resultset\n";
            return;
        }

        $self->_touch($project, $id, scalar localtime());
        DEBUG and printf "$project:$id status: %s\n", ($response->{testfailed} ? 'failed' : 'passed');
        return unless $response->{testfailed};

        foreach my $revision (@{ $result->{revisions} }) {
            next unless $revision->{comments} =~ /^bug\s+(\d+)/i;
            my $bug_id = $1;
            my $msg = "Test Failure: Bug $bug_id - " .
                "https://treeherder.mozilla.org/#/jobs?repo=$project&revision=" . $revision->{revision};
            foreach my $repo (@{ $config->repos }) {
                next unless $repo->{project} eq $project;
                foreach my $channel (@{ $repo->{channels} }) {
                    print "announcing $project test-failure bug $bug_id in $channel\n";
                    $self->irc->yield( privmsg => $channel => $msg );
                }
            }
        }
    } catch {
        my $error = $_;
        $error =~ s/(^\s+|\s+$)//g;
        warn "$error\n";
    };
}

sub _exists {
    my ($self, $project, $id) = @_;
    my $file = TreeBot::Config->instance->data_path . "/$project.$id";
    return -e $file;
}

sub _touch {
    my ($self, $project, $id, $data) = @_;
    my $file = TreeBot::Config->instance->data_path . "/$project.$id";
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
        next unless $file =~ m#/[^\.]+\.\d+$#;
        my $modified = DateTime->from_epoch( epoch => (stat($file))[9] );
        my $age = $now->delta_days($modified)->in_units('days');
        next if $age <= 7;
        DEBUG and print "deleting old revision: $file\n";
        unlink($file);
    }
}

1;
