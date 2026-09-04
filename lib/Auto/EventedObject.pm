# lib/Auto/EventedObject.pm
# Copyright (C) 2010-2012 Ethrik Development Group, et al.
# This program is free software; rights to this code are stated in doc/LICENSE.
package Auto::EventedObject;

use warnings;
use strict;

use Auto::Attributes qw(events);

# create a new evented object
sub new {
    bless { events => {} }, shift;
}

# attach an event callback
sub attach_event {
    my ($obj, $event, $code, $name, $priority) = @_;
    $priority ||= 0; # priority does not matter, so call last.
    $obj->{events}->{$event}->{$priority} ||= [];
    push @{$obj->{events}->{$event}->{$priority}}, [$name, $code];
    return 1;
}

sub fire_event {
    my ($obj, $event) = (shift, shift);

    # event does not have any callbacks
    return unless $obj->{events}->{$event};

    # iterate through callbacks by priority.
    foreach my $priority (sort { $b <=> $a } keys %{$obj->{events}->{$event}}) {
        foreach my $cb (@{$obj->{events}->{$event}->{$priority}}) {

            # create info about the call
            my %info = (
                object   => $obj,
                callback => $cb->[0],
                caller   => [caller 1],
                priority => $priority
            );

            # call it.
            API::Std::callback_run("object event $event callback $cb->[0]", $cb->[1], \%info, @_);
        }
    }

    return 1;
}

sub delete_event {
    my ($obj, $event, $name) = @_;

    # event does not have any callbacks
    return unless $obj->{events}->{$event};

    # iterate through callbacks and delete matches
    foreach my $priority (keys %{$obj->{events}->{$event}}) {
        my $a = $obj->{events}->{$event}->{$priority};
        @$a   = grep { $_->[0] ne $name } @$a;
    }        
  
    return 1;
}

# aliases
*on   = *attach_event;
*del  = *delete_event;
*fire = *fire_event;

1;

# vim: set ai et sw=4 ts=4:
