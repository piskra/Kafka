package Kafka::IO;

=head1 NAME

Kafka::IO - Interface to network communication with the Apache Kafka server.

=head1 VERSION

This documentation refers to C<Kafka::IO> version 1.07 .

=cut



use 5.010;
use strict;
use warnings;



our $DEBUG = 0;

our $VERSION = '1.07';


use AE;
use AnyEvent::Handle;
use Carp;
use Config;
use Const::Fast;
use Data::Validate::Domain qw(
    is_hostname
);
use Data::Validate::IP qw(
    is_ipv4
    is_ipv6
);
use Errno qw(
    EAGAIN
    ECONNRESET
    EINTR
    EWOULDBLOCK
    ETIMEDOUT
);
use Fcntl;
use IO::Select;
use Params::Util qw(
    _STRING
);
use Promises qw(deferred);
use POSIX qw(
    ceil
);
use Scalar::Util qw(
    dualvar
);
use Socket qw(
    AF_INET
    AF_INET6
    IPPROTO_TCP
    MSG_DONTWAIT
    MSG_PEEK
    NI_NUMERICHOST
    NIx_NOSERV
    PF_INET
    PF_INET6
    SOCK_STREAM
    SOL_SOCKET
    SO_ERROR
    SO_RCVTIMEO
    SO_SNDTIMEO
    getaddrinfo
    getnameinfo
    inet_aton
    inet_pton
    inet_ntop
    pack_sockaddr_in
    pack_sockaddr_in6
);
use Sys::SigAction qw(
    set_sig_handler
);
use Time::HiRes ();
use Try::Tiny;

use Kafka qw(
    $ERROR_CANNOT_BIND
    $ERROR_CANNOT_RECV
    $ERROR_CANNOT_SEND
    $ERROR_MISMATCH_ARGUMENT
    $ERROR_INCOMPATIBLE_HOST_IP_VERSION
    $ERROR_NO_CONNECTION
    $IP_V4
    $IP_V6
    $KAFKA_SERVER_PORT
    $REQUEST_TIMEOUT
);
use Kafka::Exceptions;
use Kafka::Internals qw(
    $MAX_SOCKET_REQUEST_BYTES
    debug_level
    format_message
);



=head1 SYNOPSIS

    use 5.010;
    use strict;
    use warnings;

    use Scalar::Util qw(
        blessed
    );
    use Try::Tiny;

    use Kafka::IO;

    my $io;
    try {
        $io = Kafka::IO->new( host => 'localhost' );
    } catch {
        my $error = $_;
        if ( blessed( $error ) && $error->isa( 'Kafka::Exception' ) ) {
            warn 'Error: (', $error->code, ') ',  $error->message, "\n";
            exit;
        } else {
            die $error;
        }
    };

    # Closes and cleans up
    $io->close;
    undef $io;

=head1 DESCRIPTION

This module is private and should not be used directly.

In order to achieve better performance, methods of this module do not
perform arguments validation.

The main features of the C<Kafka::IO> class are:

=over 3

=item *

Provides an object oriented API for communication with Kafka.

=item *

This class allows you to create Kafka 0.9+ clients.

=back

=cut

# Hard limit of IO operation retry attempts, to prevent high CPU usage in IO retry loop
const my $MAX_RETRIES => 30;

our $_hdr;

#-- constructor ----------------------------------------------------------------

=head2 CONSTRUCTOR

=head3 C<new>

Establishes TCP connection to given host and port, creates and returns C<Kafka::IO> IO object.

C<new()> takes arguments in key-value pairs. The following arguments are currently recognized:

=over 3

=item C<host =E<gt> $host>

C<$host> is Kafka host to connect to. It can be a host name or an IP-address in
IPv4 or IPv6 form (for example '127.0.0.1', '0:0:0:0:0:0:0:1' or '::1').

=item C<port =E<gt> $port>

Optional, default = C<$KAFKA_SERVER_PORT>.

C<$port> is integer attribute denoting the port number of to access Apache Kafka.

C<$KAFKA_SERVER_PORT> is the default Apache Kafka server port that can be imported
from the L<Kafka|Kafka> module.

=item C<timeout =E<gt> $timeout>

C<$REQUEST_TIMEOUT> is the default timeout that can be imported from the L<Kafka|Kafka> module.

Special behavior when C<timeout> is set to C<undef>:

=back

=over 3

=item *

Alarms are not used internally (namely when performing C<gethostbyname>).

=item *

Default C<$REQUEST_TIMEOUT> is used for the rest of IO operations.

=back

=over 3

=item C<ip_version =E<gt> $ip_version>

Force version of IP protocol for resolving host name (or interpretation of passed address).

Optional, undefined by default, which works in the following way: version of IP address
is detected automatically, host name is resolved into IPv4 address.

See description of L<$IP_V4|Kafka::IO/$IP_V4>, L<$IP_V6|Kafka::IO/$IP_V6>
in C<Kafka> L<EXPORT|Kafka/EXPORT>.

=back

=cut
sub new {
    my ( $class, %p ) = @_;

    my $self = bless {
        host        => '',
        timeout     => $REQUEST_TIMEOUT,
        port        => $KAFKA_SERVER_PORT,
        ip_version  => undef,
        af          => '',  # Address family constant
        pf          => '',  # Protocol family constant
        ip          => '',  # Human-readable textual representation of the ip address
        in_use      => 0,
        server      => '',  # Remember the name, so we will be able to find the server from the io
    }, $class;

    exists $p{$_} and $self->{$_} = $p{$_} foreach keys %$self;

    # we trust it: make it untainted
    ( $self->{host} ) = $self->{host} =~ /\A(.+)\z/;
    ( $self->{port} ) = $self->{port} =~ /\A(.+)\z/;

    print STDERR "New connection to $self->{host}:$self->{port}\n";

    $self->{socket}     = undef;
    $self->{_ae_handle} = undef;

    return $self;
}

sub DESTROY
{
    my ( $self ) = @_;
    print STDERR "DESTROYing connection to $self->{host}:$self->{port}\n";
}

#-- public attributes ----------------------------------------------------------

=head2 METHODS

The following methods are provided by C<Kafka::IO> class:

=cut

=head3 C<< send( $message <, $timeout> ) >>

Sends a C<$message> to Kafka.

The argument must be a bytes string.

Use optional C<$timeout> argument to override default timeout for this request only.

Returns the number of characters sent.

=cut
sub send {
    my ( $self, $message, $timeout ) = @_;

    my $len = $self->async_send( $message, $timeout );

    $timeout = $self->{timeout} // $REQUEST_TIMEOUT unless defined $timeout;
    $self->_error( $ERROR_MISMATCH_ARGUMENT, '->send' )
        unless $timeout > 0
    ;

    my $handle = $self->{_ae_handle};

    my $timeout_timer;
    my $has_timeout;
    my $cv = AE::cv();
    $handle->on_drain( sub {
            my ( $hdl ) = @_;
            $timeout_timer = undef;
            $cv->send();
        } );

    AE::now_update();
    $timeout_timer = AE::timer $timeout, 0, sub {
        if ( $timeout_timer ) {
            $timeout_timer = undef;
            $has_timeout = 1;
            $self->close();
            $cv->send();
        }
        return;
    };

    $cv->recv();

    $timeout_timer = undef;
    $handle->on_drain( undef );

    return 0 if $has_timeout;

    return $len;
}

sub async_send {
    my ( $self, $message, $timeout ) = @_;

    $self->_error( $ERROR_MISMATCH_ARGUMENT, '->send' )
        unless defined( _STRING( $message ) )
    ;
    my $length = length( $message );
    $self->_error( $ERROR_MISMATCH_ARGUMENT, '->send' )
        unless $length <= $MAX_SOCKET_REQUEST_BYTES
    ;
    my $handle = $self->{_ae_handle};
    $self->_error( $ERROR_NO_CONNECTION, 'Attempt to work with a closed socket' ) unless $handle;

    $self->_debug_msg( $message, 'Request to', 'green' )
        if $self->debug_level >= 2
    ;

    $handle->push_write( $message );

    return length $message;
}

=head3 C<< receive( $length <, $timeout> ) >>

Receives a message up to C<$length> size from Kafka.

C<$length> argument must be a positive number.

Use optional C<$timeout> argument to override default timeout for this call only.

Returns a reference to the received message.

=cut

sub receive {
    my $self = shift;
    return promise_wait( $self->async_receive( @_ ) );
}

sub async_receive {
    my ( $self, $length, $timeout ) = @_;

    $self->_error( $ERROR_MISMATCH_ARGUMENT, '->receive' )
        unless $length > 0
    ;
    $timeout = $self->{timeout} // $REQUEST_TIMEOUT unless defined $timeout;
    $self->_error( $ERROR_MISMATCH_ARGUMENT, '->receive' )
        unless $timeout > 0
    ;
    my $handle = $self->{_ae_handle};
    $self->_error( $ERROR_NO_CONNECTION, 'Attempt to work with a closed socket' ) unless $handle;

    my $d = deferred;

    my $timeout_timer = 1;
    $handle->push_read( chunk => $length, sub
    {
        my ( $hdl, $response ) = @_;
        if ( $d->is_done ) {
            print STDERR "Ignoring response\n";
        } else {
            $timeout_timer = undef;
            $d->resolve( \$response );
        }
        return;
    } );

    # I tried to use (r)timeout of AnyEvent::Handle, but that does
    # not seem to work as expected. The timer is often called immediately,
    # but sometimes not at all.
    AE::now_update();
    $timeout_timer = AE::timer $timeout, 0, sub {
        return if $d->is_done;
        $timeout_timer = undef;
        $self->close();
        # $self->_error( $ERROR_CANNOT_RECV, "timed out" );
        $d->reject( "timed out" );
        return;
    };

    return $d->promise;
}

sub available {
    my $self = shift;
    return !$self->{in_use};
}

sub set_in_use {
    my ( $self, $flag ) = @_;
    $self->{in_use} = $flag;
}

=head3 C<close>

Closes connection to Kafka server.
Returns true if those operations succeed and if no error was reported by any PerlIO layer.

=cut
sub close {
    my ( $self ) = @_;

    $self->set_in_use( 0 );
    my $ret = 1;
    if ( $self->{socket} ) {
        $ret = CORE::close( $self->{socket} );
        $self->{socket}     = undef;
        $self->{_ae_handle} = undef;
    }

    return $ret;
}

# The method verifies if we can connect to a Kafka broker.
# This is evil: opens and immediately closes a NEW connection so do not use unless there is a strong reason for it.
sub _is_alive {
    my ( $self ) = @_;

    my $socket = $self->{socket};
    return unless $socket;

    socket( my $tmp_socket, $self->{pf}, SOCK_STREAM, IPPROTO_TCP );
    my $is_alive = CORE::connect( $tmp_socket, getpeername( $socket ) );
    CORE::close( $tmp_socket );

    return $is_alive;
}

#-- private attributes ---------------------------------------------------------

#-- private methods ------------------------------------------------------------

# You need to have access to Kafka instance and be able to connect through TCP.
# uses http://devpit.org/wiki/Connect%28%29_with_timeout_%28in_Perl%29
sub connect {
    my ( $self ) = @_;

    return if $self->{socket};
    $self->set_error( undef );

    my $error;
    try {
        $self->_connect();
    } catch {
        $error = $_;
    };

    $self->_error( $ERROR_CANNOT_BIND, format_message("Kafka::IO(%s:%s)->connect: %s", $self->{host}, $self->{port}, $error ) )
        if defined $error
    ;

    return $self;
}

sub _connect {
    my ( $self ) = @_;

    $self->{socket}     = undef;
    $self->{_ae_handle} = undef;

    my $name    = $self->{host};
    my $port    = $self->{port};
    my $timeout = $self->{timeout};

    my $ip = '';
    if ( $self->_get_family( $name ) ) {
        $ip = $self->{ip} = $name;
    } else {
        if ( defined $timeout ) {
            my $remaining;
            my $start = time();

            $self->_debug_msg( format_message( "name = '%s', number of wallclock seconds = %s", $name, ceil( $timeout ) ) )
                if $self->debug_level;

            # DNS lookup.
            local $@;
            my $h = set_sig_handler( 'ALRM', sub { die 'alarm clock restarted' },
                {
                    mask    => [ 'ALRM' ],
                    safe    => 0,   # perl 5.8+ uses safe signal delivery so we need unsafe signal for timeout to work
                }
            );
            eval {
                $remaining = alarm( ceil( $timeout ) );
                $ip = $self->_gethostbyname( $name );
                alarm 0;
            };
            alarm 0;                                # race condition protection
            my $error = $@;
            undef $h;

            $self->_debug_msg( format_message( "_connect: ip = '%s', error = '%s', \$? = %s, \$! = '%s'", $ip, $error, $?, $! ) )
                if $self->debug_level;

            die $error if $error;
            die( format_message( "gethostbyname %s: \$? = '%s', \$! = '%s'\n", $name, $?, $! ) ) unless $ip;

            my $elapsed = time() - $start;
            # $SIG{ALRM} restored automatically, but we need to restart previous alarm manually

            $self->_debug_msg( format_message( '_connect: %s (remaining) - %s (elapsed) = %s', $remaining, $elapsed, $remaining - $elapsed ) )
                if $self->debug_level;
            if ( $remaining ) {
                if ( $remaining - $elapsed > 0 ) {
                    $self->_debug_msg( '_connect: remaining - elapsed > 0 (to alarm restart)' )
                        if $self->debug_level;
                    alarm( ceil( $remaining - $elapsed ) );
                } else {
                    $self->_debug_msg( '_connect: remaining - elapsed < 0 (to alarm function call)' )
                        if $self->debug_level;
                    # $SIG{ALRM}->();
                    kill ALRM => $$;
                }
                $self->_debug_msg( "_connect: after alarm 'recalled'" )
                    if $self->debug_level;
            }
        } else {
            $ip = $self->_gethostbyname( $name );
            die( format_message( "could not resolve host name to IP address: %s\n", $name ) ) unless $ip;
        }
    }

    # Create socket.
    socket( my $connection, $self->{pf}, SOCK_STREAM, scalar getprotobyname( 'tcp' ) ) or die( "socket: $!\n" );

    # Set autoflushing.
    my $file_handle = select( $connection ); $| = 1; select $file_handle;

    # Set FD_CLOEXEC.
    my $flags = fcntl( $connection, F_GETFL, 0 ) or die "fcntl: $!\n";
    fcntl( $connection, F_SETFL, $flags | FD_CLOEXEC ) or die "fnctl: $!\n";

    $flags = fcntl( $connection, F_GETFL, 0 ) or die "fcntl F_GETFL: $!\n"; # 0 for error, 0e0 for 0.
    fcntl( $connection, F_SETFL, $flags | O_NONBLOCK ) or die "fcntl F_SETFL O_NONBLOCK: $!\n"; # 0 for error, 0e0 for 0.

    # Connect returns immediately because of O_NONBLOCK.
    my $sockaddr = $self->{af} eq AF_INET
        ? pack_sockaddr_in(  $port, inet_aton( $ip ) )
        : pack_sockaddr_in6( $port, inet_pton( $self->{af}, $ip ) )
    ;
    CORE::connect( $connection, $sockaddr ) || $!{EINPROGRESS} || die( format_message( "connect ip = %s, port = %s: %s\n", $ip, $port, $! ) );

    # Reset O_NONBLOCK.
    $flags = fcntl( $connection, F_GETFL, 0 ) or die "fcntl F_GETFL: $!\n";  # 0 for error, 0e0 for 0.
    fcntl( $connection, F_SETFL, $flags & ~ O_NONBLOCK ) or die "fcntl F_SETFL not O_NONBLOCK: $!\n";  # 0 for error, 0e0 for 0.

    # Use select() to poll for completion or error. When connect succeeds we can write.
    my $vec = '';
    vec( $vec, fileno( $connection ), 1 ) = 1;
    select( undef, $vec, undef, $timeout // $REQUEST_TIMEOUT );
    unless ( vec( $vec, fileno( $connection ), 1 ) ) {
        # If no response yet, impose our own timeout.
        $! = ETIMEDOUT;
        die( format_message( "connect ip = %s, port = %s: %s\n", $ip, $port, $! ) );
    }

    # This is how we see whether it connected or there was an error. Document Unix, are you kidding?!
    $! = unpack( 'L', getsockopt( $connection, SOL_SOCKET, SO_ERROR ) );
    die( format_message( "connect ip = %s, port = %s: %s\n", $ip, $port, $! ) ) if $!;

    # Set timeout on all reads and writes.
    #
    # Note the difference between Perl's sysread() and read() calls: sysread()
    # queries the kernel exactly once, with max delay specified here. read()
    # queries the kernel repeatedly until there's a read error (such as this
    # timeout), EOF, or a full buffer. So when using read() with a timeout of one
    # second, if the remote server sends 1 byte repeatedly at 1 second intervals,
    # read() will read the whole buffer very slowly and sysread() will return only
    # the first byte. The print() and syswrite() calls are similarly different.
    # <> is of course similar to read() but delimited by newlines instead of buffer
    # sizes.
    my $timeval = _get_timeval( $timeout // $REQUEST_TIMEOUT );
    setsockopt( $connection, SOL_SOCKET, SO_SNDTIMEO, $timeval ) // die "setsockopt SOL_SOCKET, SO_SNDTIMEO: $!\n";
    setsockopt( $connection, SOL_SOCKET, SO_RCVTIMEO, $timeval ) // die "setsockopt SOL_SOCKET, SO_RCVTIMEO: $!\n";

    $self->{socket} = $connection;
    $self->{_ae_handle} = AnyEvent::Handle->new(
        fh => $connection,
    );

    return $connection;
}

# Packing timeval
# uses http://trinitum.org/wp/packing-timeval/
sub _get_timeval {
    my $timeout = shift;

    my $intval = int( $timeout );                               # sec
    my $fraction = int( ( $timeout - $intval ) * 1_000_000 );   # ms

    if ( $Config{osname} eq 'netbsd' && _major_osvers() >= 6 && $Config{longsize} == 4 ) {
        if ( defined $Config{use64bitint} ) {
            $timeout = pack( 'QL', int( $timeout ), $fraction );
        } else {
            $timeout = pack(
                'LLL',
                (
                    $Config{byteorder} eq '1234'
                        ? ( $timeout, 0, $fraction )
                        : ( 0, $timeout, $fraction )
                )
            );
        }
    } else {
        $timeout = pack( 'L!L!', $timeout, $fraction );
    }

    return $timeout;
}

sub _major_osvers {
    my $osvers = $Config{osvers};
    my ( $major_osvers ) = $osvers =~ /^(\d+)/;
    $major_osvers += 0;

    return $major_osvers;
}

sub _gethostbyname {
    my ( $self, $name ) = @_;

    my $is_v4_fqdn = 1;
    $self->{ip} = '';

    my $ip_version = $self->{ip_version};
    if ( defined( $ip_version ) && $ip_version == $IP_V6 ) {
        my ( $err, @addrs ) = getaddrinfo(
            $name,
            '',     # not interested in the service name
            {
                family      => AF_INET6,
                socktype    => SOCK_STREAM,
                protocol    => IPPROTO_TCP,
            },
        );
        return( $self->{ip} ) if $err;

        $is_v4_fqdn = 0;
        for my $addr ( @addrs ) {
            my ( $err, $ipaddr ) = getnameinfo( $addr->{addr}, NI_NUMERICHOST, NIx_NOSERV );
            next if $err;

            $self->{af} = AF_INET6;
            $self->{pf} = PF_INET6;
            $self->{ip} = $ipaddr;
            last;
        }
    }

    if ( $is_v4_fqdn && ( !defined( $ip_version ) || $ip_version == $IP_V4 ) ) {
        if ( my $ipaddr = gethostbyname( $name ) ) {
            $self->{ip} = inet_ntop( $self->{af}, $ipaddr );
        }
    }

    return $self->{ip};
}

sub _get_family {
    my ( $self, $name ) = @_;

    my $is_ip;
    my $ip_version = $self->{ip_version} // 0;
    if ( ( ( $is_ip = is_ipv6( $name ) ) && !$ip_version ) || $ip_version == $IP_V6 ) {
        $self->_error( $ERROR_INCOMPATIBLE_HOST_IP_VERSION, format_message( 'ip_version = %s, host = %s', $ip_version, $name ) )
            if
                   $ip_version
                && (
                        ( !$is_ip && is_ipv4( $name ) )
                    || ( $is_ip && $ip_version == $IP_V4 )
                )
        ;

        $self->{af} = AF_INET6;
        $self->{pf} = PF_INET6;
    } elsif ( ( ( $is_ip = is_ipv4( $name ) ) && !$ip_version ) || $ip_version == $IP_V4 ) {
        $self->_error( $ERROR_INCOMPATIBLE_HOST_IP_VERSION, format_message( 'ip_version = %s, host = %s', $ip_version, $name ) )
            if
                   $ip_version
                && (
                        ( !$is_ip && is_ipv6( $name ) )
                    || ( $is_ip && $ip_version == $IP_V6 )
                )
        ;

        $self->{af} = AF_INET;
        $self->{pf} = PF_INET;
    } elsif ( !$ip_version ) {
        $self->{af} = AF_INET;
        $self->{pf} = PF_INET;
    }

    return $is_ip;
}

# Show additional debugging information
sub _debug_msg {
    my ( $self, $message, $header, $colour ) = @_;

    if ( $header ) {
        unless ( $_hdr ) {
            require Data::HexDump::Range;
            $_hdr = Data::HexDump::Range->new(
                FORMAT                          => 'ANSI',  # 'ANSI'|'ASCII'|'HTML'
                COLOR                           => 'bw',    # 'bw' | 'cycle'
                OFFSET_FORMAT                   => 'hex',   # 'hex' | 'dec'
                DATA_WIDTH                      => 16,      # 16 | 20 | ...
                DISPLAY_RANGE_NAME              => 0,
#                MAXIMUM_RANGE_NAME_SIZE         => 16,
                DISPLAY_COLUMN_NAMES            => 1,
                DISPLAY_RULER                   => 1,
                DISPLAY_OFFSET                  => 1,
#                DISPLAY_CUMULATIVE_OFFSET       => 1,
                DISPLAY_ZERO_SIZE_RANGE_WARNING => 0,
                DISPLAY_ZERO_SIZE_RANGE         => 1,
                DISPLAY_RANGE_NAME              => 0,
#                DISPLAY_RANGE_SIZE              => 1,
                DISPLAY_ASCII_DUMP              => 1,
                DISPLAY_HEX_DUMP                => 1,
#                DISPLAY_DEC_DUMP                => 1,
#                COLOR_NAMES                     => {},
                ORIENTATION                     => 'horizontal',
            );
        }

        say STDERR
            "# $header ", $self->{host}, ':', $self->{port}, "\n",
            '# Hex Stream: ', unpack( 'H*', $message ), "\n",
            $_hdr->dump(
                [
                    [ 'data', length( $message ), $colour ],
                ],
                $message
            )
        ;
    } else {
        say STDERR format_message( '[%s] %s', scalar( localtime ), $message );
    }

    return;
}

# Handler for errors
sub _error {
    my $self = shift;
    my %args = throw_args( @_ );
    $self->_debug_msg( format_message( 'throwing IO error %s: %s', $args{code}, $args{message} ) )
        if $self->debug_level;
    Kafka::Exception::IO->throw( %args );
}

sub set_error
{
    my ( $self, $error ) = @_;
    $self->{last_error} = $error;
}

sub last_error
{
    my $self = shift;
    return $self->{last_error};
}

1;

__END__

=head1 DIAGNOSTICS

When error is detected, an exception, represented by object of C<Kafka::Exception::IO> class,
is thrown (see L<Kafka::Exceptions|Kafka::Exceptions>).

L<code|Kafka::Exceptions/code> and a more descriptive L<message|Kafka::Exceptions/message> provide
information about thrown exception. Consult documentation of the L<Kafka::Exceptions|Kafka::Exceptions>
for the list of all available methods.

Authors suggest using of L<Try::Tiny|Try::Tiny>'s C<try> and C<catch> to handle exceptions while
working with L<Kafka|Kafka> package.

Here is the list of possible error messages that C<Kafka::IO> may produce:

=over 3

=item C<Invalid argument>

Invalid arguments were passed to a method.

=item C<Cannot send>

Message cannot be sent on a C<Kafka::IO> object socket.

=item C<Cannot receive>

Message cannot be received.

=item C<Cannot bind>

TCP connection cannot be established on given host and port.

=back

=head2 Debug mode

Debug output can be enabled by passing desired level via environment variable
using one of the following ways:

C<PERL_KAFKA_DEBUG=1>     - debug is enabled for the whole L<Kafka|Kafka> package.

C<PERL_KAFKA_DEBUG=IO:1>  - enable debug for C<Kafka::IO> only.

C<Kafka::IO> supports two debug levels (level 2 includes debug output of 1):

=over 3

=item 1

Additional information about processing events/alarms.

=item 2

Dump of binary messages exchange with Kafka server.

=back

=head1 SEE ALSO

The basic operation of the Kafka package modules:

L<Kafka|Kafka> - constants and messages used by the Kafka package modules.

L<Kafka::Connection|Kafka::Connection> - interface to connect to a Kafka cluster.

L<Kafka::Producer|Kafka::Producer> - interface for producing client.

L<Kafka::Consumer|Kafka::Consumer> - interface for consuming client.

L<Kafka::Message|Kafka::Message> - interface to access Kafka message
properties.

L<Kafka::Int64|Kafka::Int64> - functions to work with 64 bit elements of the
protocol on 32 bit systems.

L<Kafka::Protocol|Kafka::Protocol> - functions to process messages in the
Apache Kafka's Protocol.

L<Kafka::IO|Kafka::IO> - low-level interface for communication with Kafka server.

L<Kafka::Exceptions|Kafka::Exceptions> - module designated to handle Kafka exceptions.

L<Kafka::Internals|Kafka::Internals> - internal constants and functions used
by several package modules.

A wealth of detail about the Apache Kafka and the Kafka Protocol:

Main page at L<http://kafka.apache.org/>

Kafka Protocol at L<https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol>

=head1 SOURCE CODE

Kafka package is hosted on GitHub:
L<https://github.com/TrackingSoft/Kafka>

=head1 AUTHOR

Sergey Gladkov

Please use GitHub project link above to report problems or contact authors.

=head1 CONTRIBUTORS

Alexander Solovey

Jeremy Jordan

Sergiy Zuban

Vlad Marchenko

Damien Krotkine

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012-2017 by TrackingSoft LLC.

This package is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. See I<perlartistic> at
L<http://dev.perl.org/licenses/artistic.html>.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.

=cut
