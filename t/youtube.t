use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json);
use Encode qw(encode);
use URI;
use File::Temp qw(tempfile);

BEGIN {
    package API::Std;
    use Exporter 'import';
    our @EXPORT_OK = qw(cmd_add cmd_del hook_add hook_del conf_get callback_run);
    our (%CONFIG, %COMMANDS, %HOOKS);
    sub cmd_add { $COMMANDS{$_[0]} = [@_]; 1 }
    sub cmd_del { delete $COMMANDS{$_[0]}; 1 }
    sub hook_add { $HOOKS{$_[1]} = $_[2]; 1 }
    sub hook_del { delete $HOOKS{$_[1]}; 1 }
    sub conf_get { $CONFIG{$_[0]} }
    sub callback_run { my ($label, $cb) = @_; $cb->(); 1 }
    sub mod_init { 1 }
    $INC{'API/Std.pm'} = __FILE__;

    package API::IRC;
    use Exporter 'import';
    our @EXPORT_OK = qw(privmsg notice);
    our (@MESSAGES, @NOTICES);
    sub privmsg { push @MESSAGES, [@_]; 1 }
    sub notice { push @NOTICES, [@_]; 1 }
    $INC{'API/IRC.pm'} = __FILE__;

    package Local::Future;
    sub new { bless {}, shift }
    sub on_ready { $_[0]{cb} = $_[1]; $_[0] }
    sub finish { $_[0]{cb}->($_[0]); $_[0] }
    sub done { $_[0]{response} = $_[1]; $_[0]->finish }
    sub fail { $_[0]{failed} = 1; $_[0]->finish }
    sub cancel { $_[0]{cancelled} = 1; $_[0]->finish }
    sub is_cancelled { $_[0]{cancelled} }
    sub is_failed { $_[0]{failed} }
    sub get { $_[0]{response} }

    package Local::Loop;
    sub add { $_[1]{loop} = $_[0]; $_[0]{members}{$_[1]} = $_[1]; 1 }
    sub remove { delete $_[1]{loop}; delete $_[0]{members}{$_[1]}; 1 }

    package Net::Async::HTTP;
    our $VERSION = '0.50';
    our (@REQUESTS, $THROW);
    sub new { my ($class, %args) = @_; bless {config => \%args}, $class }
    sub loop { $_[0]{loop} }
    sub do_request {
        die 'secret-key-in-transport-error' if $THROW;
        my ($self, %args) = @_;
        my $future = Local::Future->new;
        push @REQUESTS, { %args, client => $self, future => $future };
        return $future;
    }
    $INC{'Net/Async/HTTP.pm'} = __FILE__;
    $INC{'IO/Async/SSL.pm'} = __FILE__;

    package Local::Response;
    sub new { my ($class, $code, $body) = @_; bless {code => $code, body => $body}, $class }
    sub code { $_[0]{code} }
    sub content { $_[0]{body} }
    sub is_success { $_[0]{code} == 200 }

    package Auto;
    our $loop = bless {members => {}}, 'Local::Loop';
}

require './modules/YouTube.pm';
ok(M::YouTube::_init(), 'module initializes');
is($API::Std::COMMANDS{PLZ}[1], 0, 'PLZ is channel-only');
my $a = 'ZHVL3z6PXe4';
my $b = 'dQw4w9WgXcQ';
for my $url (
    "https://youtube.com/watch?v=$a", "http://www.youtube.com/watch?list=abc&v=$a&t=42",
    "https://m.youtube.com/watch?v=$a#t=10", "https://music.youtube.com/watch?v=$a",
    "https://youtu.be/$a?si=share&t=12", "https://www.youtu.be/$a",
    map { "https://youtube.com/$_/$a" } qw(shorts live embed),
) {
    is(M::YouTube::video_id($url), $a, "extracts $url");
}
for my $url (
    "https://youtube.com.evil.test/watch?v=$a", "https://evilyoutube.com/watch?v=$a",
    "https://youtube.com\@evil.test/watch?v=$a", "https://evil.test/https://youtu.be/$a",
    "https://youtube.com/playlist?list=$a", "https://youtube.com/watch?v=short",
    "https://youtu.be/${a}long", "https://youtu.be/$a/extra", "ftp://youtu.be/$a",
    "https://youtube.com/watch?v=$a&v=$b", "https://youtube.com/channel/$a",
) {
    ok(!defined M::YouTube::video_id($url), "rejects $url");
}
for my $pair ([PT0S => '0:00'], [PT9S => '0:09'], [PT1M => '01:00'],
    [PT3M59S => '03:59'], [PT1H2M3S => '01:02:03'], [P1DT2H => '26:00:00']) {
    is(M::YouTube::duration($pair->[0]), $pair->[1], "duration $pair->[0]");
}
ok(!defined M::YouTube::duration('PT'), 'empty duration rejected');
my $clean = M::YouTube::format_video(encode_json({items => [{id => $a,
    snippet => {title => "Title\r\nPRIVMSG #other :bad", channelTitle => "Account\x02"},
    contentDetails => {duration => 'PT9S'}}]}), $a);
is($clean, "\x0301,00You\x0300,04Tube\x03 - Title  PRIVMSG #other :bad [0:09 - Account ]", 'API strings cannot inject IRC commands or controls');
require './lib/Parser/Config.pm';
my ($config_fh, $config_path) = tempfile(UNLINK => 1);
print {$config_fh} "youtube {\n    api_key \"test-key\";\n    source_ip \"192.0.2.10\";\n}\n";
close $config_fh;
my %config = Parser::Config->new($config_path)->parse;
is_deeply($config{youtube}, {api_key => ['test-key'], source_ip => ['192.0.2.10']}, 'documented config parses with real parser');
my $src = {svr => 'net1', chan => '#chat', nick => 'requester'};
M::YouTube::cmd_plz($src);
is_deeply($API::IRC::NOTICES[-1], ['net1', 'requester', 'No recently seen YouTube title.'], 'empty history sends private NOTICE');
is(scalar @Net::Async::HTTP::REQUESTS, 0, 'empty history makes no request');
M::YouTube::track($src, '#CHAT', "(https://youtu.be/$a),", "https://youtu.be/$b?t=10.");
M::YouTube::track($src, '#chat', 'https://youtube.com/watch?v=bad');
is(scalar @Net::Async::HTTP::REQUESTS, 0, 'tracking is passive');
M::YouTube::cmd_plz($src);
like($API::IRC::NOTICES[-1][2], qr/key is not configured/, 'missing config is a NOTICE');
$API::Std::CONFIG{'youtube:api_key'} = ['secret'];
for my $ip ('not-an-ip', '999.1.2.3', '0.0.0.0', '01.2.3.4', '') {
    $API::Std::CONFIG{'youtube:source_ip'} = [$ip];
    M::YouTube::cmd_plz($src);
    like($API::IRC::NOTICES[-1][2], qr/source_ip/, "invalid bind rejected: $ip");
}
$API::Std::CONFIG{'youtube:source_ip'} = ['192.0.2.10'];
M::YouTube::cmd_plz($src);
my $req = $Net::Async::HTTP::REQUESTS[-1];
my %query = $req->{uri}->query_form;
is($query{id}, $b, 'last valid link wins across channel case variants');
is($query{part}, 'snippet,contentDetails', 'title, channel and duration in one request');
is($req->{uri}->host, 'www.googleapis.com', 'fixed API host');
is($req->{client}{config}{local_host}, '192.0.2.10', 'bind passed to private client');
is($req->{client}{config}{max_redirects}, 0, 'no redirects with API key');
is($req->{client}{config}{SSL_verify_mode}, 1, 'TLS verification required');
M::YouTube::cmd_plz($src);
is(scalar @Net::Async::HTTP::REQUESTS, 1, 'duplicate in-flight command does not send a second request');
for my $other ({%$src, chan => '#other'}, {%$src, svr => 'net2'}) {
    M::YouTube::cmd_plz($other);
    is($API::IRC::NOTICES[-1][2], 'No recently seen YouTube title.', 'history isolated by network and channel');
}
sub body {
    my ($id, $title) = @_;
    encode_json({items => [{id => $id, snippet => {title => $title, channelTitle => 'Account'}, contentDetails => {duration => 'PT3M59S'}}]});
}
M::YouTube::track($src, '#chat', "https://youtu.be/$a");
delete $src->{chan}; # Real core mutates the source after command dispatch.
$req->{future}->done(Local::Response->new(200, body($b, 'Café 猫')));
is_deeply($API::IRC::MESSAGES[-1], ['net1', '#chat', encode('UTF-8', "\x0301,00You\x0300,04Tube\x03 - Café 猫 [03:59 - Account]")], 'exact colors, UTF-8, duration, account and original destination');
is(scalar keys %{$Auto::loop->{members}}, 0, 'completed client removed');
$src->{chan} = '#chat';
for my $case ([200, '{', qr/invalid video data/], [200, '{"items":[]}', qr/unavailable/],
    [403, 'secret-key', qr/HTTP 403/], [200, body($b, 'wrong ID'), qr/invalid video data/]) {
    M::YouTube::cmd_plz($src);
    $Net::Async::HTTP::REQUESTS[-1]{future}->done(Local::Response->new($case->[0], $case->[1]));
    like($API::IRC::NOTICES[-1][2], $case->[2], 'API failure uses private generic notice');
}
M::YouTube::cmd_plz($src);
$Net::Async::HTTP::REQUESTS[-1]{future}->fail;
like($API::IRC::NOTICES[-1][2], qr/lookup failed/, 'transport failure handled');
{
    local $Net::Async::HTTP::THROW = 1;
    M::YouTube::cmd_plz($src);
    is($API::IRC::NOTICES[-1][2], 'Unable to start the YouTube lookup.', 'synchronous exceptions do not expose secrets');
    is(scalar keys %{$Auto::loop->{members}}, 0, 'failed startup cleans client');
}
$API::Std::CONFIG{'youtube:source_ip'} = ['192.0.2.11'];
M::YouTube::cmd_plz($src);
$req = $Net::Async::HTTP::REQUESTS[-1];
is($req->{client}{config}{local_host}, '192.0.2.11', 'new config applies on next command');
my $notices = @API::IRC::NOTICES;
ok(M::YouTube::_void(), 'unload succeeds with pending request');
ok($req->{future}->is_cancelled, 'unload cancels request');
is(scalar keys %{$Auto::loop->{members}}, 0, 'unload removes private client');
is(scalar @API::IRC::NOTICES, $notices, 'unload produces no late error NOTICE');
ok(!exists $API::Std::COMMANDS{PLZ} && !exists $API::Std::HOOKS{'youtube.track'}, 'unregisters hook and command');
M::YouTube::_init();
M::YouTube::cmd_plz($src);
is($API::IRC::NOTICES[-1][2], 'No recently seen YouTube title.', 'unload clears history');
M::YouTube::_void();
done_testing;
