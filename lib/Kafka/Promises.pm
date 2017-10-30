package Kafka::Promises;

use 5.018;
use strict;
use warnings;

use Exporter qw(
    import
);

our @EXPORT_OK = qw(
    promise_delay
    promise_resolved
    promise_wait
);

use AE ();
use Carp ();
use Promises ();

sub promise_delay
{
    my ( $seconds, @return ) = @_;
    my $d = Promises::deferred();
    AE::now_update; # Timers don't work well without accurate timekeeping.
    my $w; $w= AE::timer(
        $seconds, 0, sub {
            $d->resolve( @return );
            $w = undef;
        }
    );

    return $d->promise();
}

sub promise_wait
{
    my ( $promise ) = @_;
    my $cv = AE::cv();
    my $response;
    my $error;
    my $error_received = 0;
    $promise->then( sub {
            $response = $_[0];
            $cv->send();
        }, sub {
            $error = $_[0];
            $error_received = 1;
            $cv->send();
        } );

    eval {
        $cv->recv();
        1;
    } or do {
        # We really want to know who called us.
        Carp::confess( $@ );
    };

    die $error if $error_received;

    return $response;
}

sub promise_resolved
{
    my ( @return ) = @_;
    my $d = Promises::deferred();
    $d->resolve( @return );
    return $d->promise();
}


1;
