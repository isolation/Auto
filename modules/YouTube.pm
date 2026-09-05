# YouTube metadata on demand. Output based on isolation's AdvTitle (2014).
# Released under the same license as Auto; see doc/LICENSE.
package M::YouTube;
use strict;
use warnings;
use API::Std qw(cmd_add cmd_del hook_add hook_del conf_get callback_run);
use API::IRC qw(privmsg notice);
use Net::Async::HTTP 0.45;
use IO::Async::SSL;
use JSON::PP qw(decode_json);
use URI;
use URI::QueryParam;
use Encode qw(encode);
use Socket qw(AF_INET);

my (%latest, %pending);
my $active;
our %HELP_PLZ = (
    en => 'Show the latest YouTube video mentioned in this channel. Syntax: PLZ',
);

sub _init {
    cmd_add('PLZ', 0, 0, \%HELP_PLZ, \&cmd_plz) or return;
    hook_add('on_cprivmsg', 'youtube.track', \&track) or return;
    $active = 1;
    return 1;
}

sub _void {
    $active = 0;
    for my $request (values %pending) {
        $request->{future}->cancel if $request->{future};
        $Auto::loop->remove($request->{http}) if $request->{http}->loop;
    }
    %pending = ();
    %latest = ();
    hook_del('on_cprivmsg', 'youtube.track');
    cmd_del('PLZ');
    return 1;
}

# Match Auto's case-insensitive channel lookup; network IDs remain distinct.
sub channel_key { return lc $_[0] }

sub video_id {
    my ($url) = @_;
    my $uri = URI->new($url);
    return unless $uri->can('host') && $uri->scheme =~ /\Ahttps?\z/i;
    return if defined $uri->userinfo;
    my $host = lc($uri->host // '');
    my $id;
    if ($host eq 'youtu.be' || $host eq 'www.youtu.be') {
        ($id) = $uri->path =~ m{\A/([A-Za-z0-9_-]{11})/?\z};
    }
    elsif ($host =~ /\A(?:www\.|m\.|music\.)?youtube\.com\z/) {
        if ($uri->path eq '/watch') {
            my @ids = $uri->query_param('v');
            $id = $ids[0] if @ids == 1;
        }
        else {
            ($id) = $uri->path =~ m{\A/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})/?\z};
        }
    }
    return defined($id) && $id =~ /\A[A-Za-z0-9_-]{11}\z/ ? $id : undef;
}

sub track {
    my ($src, $chan, @words) = @_;
    my $message = join ' ', @words;
    while ($message =~ m{(?<![A-Za-z0-9_/])https?://[^\s<>"\x00-\x1f]+}gi) {
        my $url = $&;
        $url =~ s/[.,!;:)\]}]+\z//;
        my $id = eval { video_id($url) };
        $latest{$src->{svr}}{channel_key($chan)} = $id if defined $id;
    }
    return 1;
}

sub config_value {
    my ($name) = @_;
    my ($values) = conf_get('youtube:'.$name);
    return ref($values) eq 'ARRAY' ? $values->[0] : undef;
}

sub duration {
    my ($value) = @_;
    return unless defined($value) && !ref($value)
        && $value =~ /\AP(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/;
    my ($d, $h, $m, $s) = ($1, $2, $3, $4);
    return unless defined($h) || defined($m) || defined($s);
    my $seconds = ($d || 0)*86400 + ($h || 0)*3600 + ($m || 0)*60 + ($s || 0);
    return sprintf('%02d:%02d:%02d', int($seconds/3600), int($seconds/60)%60, $seconds%60) if $seconds >= 3600;
    return sprintf('%02d:%02d', int($seconds/60), $seconds%60) if $seconds >= 60;
    return sprintf('0:%02d', $seconds);
}

sub format_video {
    my ($body, $id) = @_;
    my $data = decode_json($body);
    die 'Invalid response' unless ref($data) eq 'HASH' && ref($data->{items}) eq 'ARRAY';
    return unless @{$data->{items}};
    my $video = $data->{items}[0];
    die 'Invalid video' unless ref($video) eq 'HASH' && ($video->{id} // '') eq $id
        && ref($video->{snippet}) eq 'HASH' && ref($video->{contentDetails}) eq 'HASH';
    my ($title, $channel) = @{$video->{snippet}}{qw(title channelTitle)};
    my $time = duration($video->{contentDetails}{duration});
    die 'Missing metadata' unless defined($time) && defined($title) && !ref($title)
        && defined($channel) && !ref($channel);
    # API strings must not introduce IRC commands or formatting controls.
    s/[\x00-\x1f\x7f]/ /g for ($title, $channel);
    return "\x0301,00You\x0300,04Tube\x03 - $title [$time - $channel]";
}

sub cmd_plz {
    my ($src) = @_;
    return unless $active && defined $src->{chan};
    # Core removes chan from its source hash after command dispatch.
    my ($svr, $chan, $nick) = @{$src}{qw(svr chan nick)};
    my $key = channel_key($chan);
    my $id = $latest{$svr}{$key};
    return notice($svr, $nick, 'No recently seen YouTube title.') unless defined $id;
    my $request_key = "$svr\0$key";
    return notice($svr, $nick, 'A YouTube lookup is already in progress.') if $pending{$request_key};
    my $api_key = config_value('api_key');
    my $ip = config_value('source_ip');
    return notice($svr, $nick, 'YouTube API key is not configured.') unless defined($api_key) && length($api_key);
    # A specified invalid bind must never silently use the default interface.
    if (defined($ip) && ($ip !~ /\A(?:\d{1,3}\.){3}\d{1,3}\z/
        || $ip eq '0.0.0.0' || grep { $_ > 255 || /\A0\d/ } split /\./, $ip)) {
        return notice($svr, $nick, 'YouTube source_ip must be an IPv4 address.');
    }
    my $request = {};
    my $ok = eval {
        my $http = Net::Async::HTTP->new(
            user_agent => 'Auto YouTube', timeout => 15, max_redirects => 0,
            close_after_request => 1, fail_on_error => 0,
            SSL_verify_mode => 1, SSL_verifycn_scheme => 'http',
            (defined($ip) ? (family => AF_INET, local_host => $ip, local_port => 0) : ()),
        );
        $request->{http} = $http;
        $Auto::loop->add($http);
        my $uri = URI->new('https://www.googleapis.com/youtube/v3/videos');
        $uri->query_form(part => 'snippet,contentDetails', id => $id,
            fields => 'items(id,snippet(title,channelTitle),contentDetails(duration))', key => $api_key);
        my $future = $http->do_request(uri => $uri);
        $request->{future} = $future;
        $pending{$request_key} = $request;
        $future->on_ready(sub {
            my ($done) = @_;
            delete $pending{$request_key};
            $Auto::loop->remove($http) if $http->loop;
            return unless $active && !$done->is_cancelled;
            callback_run('YouTube response', sub {
                # Never echo Google/transport errors, which can contain the key.
                return notice($svr, $nick, 'YouTube lookup failed. Please try again later.') if $done->is_failed;
                my ($response) = $done->get;
                return notice($svr, $nick, 'YouTube lookup failed (HTTP '.$response->code.').') unless $response->is_success;
                my $message;
                my $parsed = eval { $message = format_video($response->content, $id); 1 };
                return notice($svr, $nick, 'YouTube returned invalid video data.') unless $parsed;
                return notice($svr, $nick, 'That YouTube video is unavailable.') unless defined $message;
                # Auto's socket layer writes bytes, not Unicode characters.
                privmsg($svr, $chan, encode('UTF-8', $message));
            });
        });
        1;
    };
    unless ($ok) {
        delete $pending{$request_key};
        $request->{future}->cancel if $request->{future};
        $Auto::loop->remove($request->{http}) if $request->{http} && $request->{http}->loop;
        notice($svr, $nick, 'Unable to start the YouTube lookup.');
    }
    return 1;
}

API::Std::mod_init('YouTube', 'Auto Project; isolation', '1.00', '3.0.0a11');
# build: cpan=Net::Async::HTTP,IO::Async::SSL,JSON::PP,URI perl=5.010000

1;

__END__

=head1 NAME

YouTube - Display the most recently mentioned YouTube video on PLZ

=head1 CONFIGURATION

    youtube {
        api_key "your-youtube-data-api-v3-key";
        source_ip "192.0.2.10";
    }

The optional source_ip binds requests to a local IPv4 address. Tracking is
memory-only, per channel and network. PLZ uses the configured command prefix
and returns C<YouTube - Title [03:59 - Channel Name]> with the original AdvTitle
colors. Empty history and lookup failures produce a NOTICE to the requester.

=head1 DEPENDENCIES

Net::Async::HTTP 0.45 or later, IO::Async::SSL, JSON::PP, and URI.

=head1 LICENSE

Released under the same license as Auto. YouTube label and duration formatting
are based on AdvTitle, Copyright 2014 isolation.

=cut
