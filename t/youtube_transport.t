use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);

BEGIN {
    eval {
        require Net::Async::HTTP;
        Net::Async::HTTP->VERSION(0.45);
        require IO::Async::SSL;
        require IO::Async::Loop;
        require IO::Async::Listener;
        require IO::Async::Stream;
        1;
    } or plan skip_all => 'Optional real HTTP test needs Net::Async::HTTP >= 0.45 and IO::Async::SSL';

    package API::Std;
    use Exporter 'import';
    our @EXPORT_OK = qw(cmd_add cmd_del hook_add hook_del conf_get callback_run);
    our %CONFIG = ('youtube:api_key' => ['offline-test-key'], 'youtube:source_ip' => ['127.0.0.1']);
    sub cmd_add { 1 } sub cmd_del { 1 } sub hook_add { 1 } sub hook_del { 1 }
    sub conf_get { $CONFIG{$_[0]} }
    sub callback_run { $_[1]->(); 1 }
    sub mod_init { 1 }
    $INC{'API/Std.pm'} = __FILE__;

    package API::IRC;
    use Exporter 'import';
    our @EXPORT_OK = qw(privmsg notice);
    our (@MESSAGES, @NOTICES);
    sub privmsg { push @MESSAGES, [@_]; 1 }
    sub notice { push @NOTICES, [@_]; 1 }
    $INC{'API/IRC.pm'} = __FILE__;
}

use URI;
use IO::Socket::INET;
require './modules/YouTube.pm';
$Auto::loop = IO::Async::Loop->new;
my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1)
    or plan skip_all => "Cannot listen on loopback: $!";
my $port = $sock->sockport;
my (@peers, @streams);
my $stall = 0;
my $listener = IO::Async::Listener->new(handle => $sock, on_stream => sub {
    my ($self, $stream) = @_;
    push @peers, $stream->read_handle->peerhost;
    push @streams, $stream;
    $stream->configure(on_read => sub {
        my ($conn, $buffer, $eof) = @_;
        if ($$buffer =~ /\r\n\r\n/) {
            $$buffer = '';
            return 0 if $stall;
            my $body = '{"items":[{"id":"ZHVL3z6PXe4","snippet":{"title":"Local test","channelTitle":"Account"},"contentDetails":{"duration":"PT3M59S"}}]}';
            $conn->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($body)."\r\nConnection: close\r\n\r\n$body");
            $conn->close_when_empty;
        }
        return 0;
    });
    $Auto::loop->add($stream);
});
$Auto::loop->add($listener);

# Change only the destination to a local fixture server. The module creates
# the real HTTP client, applies source binding, and processes real futures.
my $do_request = Net::Async::HTTP->can('do_request');
my $future;
{
    no warnings 'redefine';
    *Net::Async::HTTP::do_request = sub {
        my ($http, %args) = @_;
        $args{uri} = URI->new("http://127.0.0.1:$port/video");
        return $future = $do_request->($http, %args);
    };
}
sub pump_until {
    my ($condition) = @_;
    my $deadline = time + 5;
    $Auto::loop->loop_once(0.05) while !$condition->() && time < $deadline;
    return $condition->();
}
M::YouTube::_init();
my $src = {svr => 'test', chan => '#test', nick => 'requester'};
M::YouTube::track($src, '#test', 'https://youtu.be/ZHVL3z6PXe4');
M::YouTube::cmd_plz($src);
ok(pump_until(sub { @API::IRC::MESSAGES || @API::IRC::NOTICES }), 'real async request completes');
is_deeply(\@peers, ['127.0.0.1'], 'server observes configured source IPv4');
is_deeply($API::IRC::MESSAGES[0], ['test', '#test', "\x0301,00You\x0300,04Tube\x03 - Local test [03:59 - Account]"], 'real HTTP response reaches channel');

$API::Std::CONFIG{'youtube:source_ip'} = ['192.0.2.10'];
M::YouTube::cmd_plz($src);
ok(pump_until(sub { @API::IRC::NOTICES }), 'unassigned source bind fails promptly');
is(scalar @peers, 1, 'bind failure never falls back to default source');
is($API::IRC::NOTICES[-1][1], 'requester', 'bind error sent privately');

$API::Std::CONFIG{'youtube:source_ip'} = ['127.0.0.1'];
$stall = 1;
M::YouTube::cmd_plz($src);
ok(pump_until(sub { @peers == 2 }), 'pending request connects');
my $notices = @API::IRC::NOTICES;
M::YouTube::_void();
ok($future->is_cancelled, 'unload cancels real request future');
is(scalar @API::IRC::NOTICES, $notices, 'cancelled request stays quiet');
my @http = grep { $_->isa('Net::Async::HTTP') } $Auto::loop->notifiers;
is(scalar @http, 0, 'no module HTTP clients remain in loop');
$_->close_now for @streams;
$Auto::loop->remove($listener);
done_testing;
