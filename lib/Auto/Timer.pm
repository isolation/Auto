# Copyright (c) 2012 Ethrik Development Group
# see doc/LICENSE for license information.
package Auto::Timer;
 
use warnings;
use strict;
use base 'IO::Async::Timer::Periodic';
use feature qw(say);

sub new {
    my ($class, %opts) = @_;

    # Make sure all requirements are present.
    foreach my $what (qw|name delay function|) {
        next if exists $opts{$what};
        $opts{name} ||= 'unknown';
        $class->dbug("Timer $opts{name} does not have a '$what' option.");
        return;
    }

    # Create the actual timer.
    my $timer = $class->SUPER::new(
        interval => $opts{delay},
        on_tick  => sub {
            my $self = shift;
            my ($ok) = API::Std::callback_run("timer $self->{name}", $self->{function});
            # The callback may unload its module or replace this timer.
            return unless $Auto::TIMERS{$self->{name}}
                && $Auto::TIMERS{$self->{name}} == $self;
            if (!$ok) {
                $self->stop;
                $Auto::loop->remove($self);
                delete $Auto::TIMERS{$self->{name}};
                $class->dbug("Timer $self->{name} deleted after its callback failed.");
                return;
            }
            if ($self->{type} == 1) {
                $self->stop;
                $Auto::loop->remove($self);
                delete $Auto::TIMERS{$self->{name}};
                $class->dbug("Timer ".$self->{name}." deleted because it's a non-repeating timer.");
            }
        }
    ) or $class->dbug("Timer $opts{name} creation failed.") and return;

    $class->dbug("Timer $opts{name} created.");

    $timer->{$_} = delete $opts{$_} foreach qw(name function type);
    return $timer;
}

sub go {
    my $timer = shift;
    $timer->start;
    $Auto::loop->add($timer);
    $timer->dbug("Timer $$timer{name} started.");
    return $timer;
}

sub dbug { shift; say shift if $Auto::DEBUG; }

1;

# vim: set ai et sw=4 ts=4:
