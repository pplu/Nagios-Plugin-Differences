package Nagios::Plugin::Differences;

use strict;
no warnings;

use base 'Nagios::Plugin';

use Carp;
use File::Basename qw//;
use Storable qw//;
use Digest::MD5;

=head1 NAME

Nagios::Plugin::Differences - Module to streamline Nagios plugins
that need to store temporary data and calculate the differences
between the readings.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

This module is useful for when there is need to store a set of values
that need to be reread at the next invocation of the plugin. It provides
a set of functions to calculate the differences between the readings.

    use Nagios::Plugin::Differences;

    my $npd = Nagios::Plugin::Differences->new();
    $npd->load_last;
    # suppose last reading was
    # { 'bytes' => 200, 'packets' => 3 }
    # at time 1234567890
    $npd->new_reading({
        'bytes' => 500
        'packets' => 6
    });
    # new reading is at time 123456900
    $npd->persist;
    my $rate = $npd->rate('difference');
    # rate returns the bytes/s and the packets/s that had to be
    # attained to get from the last reading to the new reading
    # in the time passed between readings
    # { 'bytes' => 30,
    #   'packets' => 0.3 }

=head1 FUNCTIONS

=head2 new(%options)

Constructor for the Nagios::Plugin::Differences object. You
can pass 'file' => '/tmp/xxx' to override the default file
('/tmp/_nagios_plugin_$0.tmp').

=cut

sub new {
    my ($class, %options) = @_;

    my $file = delete $options{file};
    my $id = delete $options{id};

    my $self = $class->SUPER::new(%options);

    $self->{ _npd_file } = $file;
    $self->{ _npd_id }   = $id or '';

    if (not $self->{ _npd_id }) {
        use Data::Dumper;
        print Dumper(@ARGV);
        $self->{ _npd_id } = Digest::MD5::md5_hex(@ARGV);
    }

    if (not defined $self->{ _npd_file }){
      $self->{ _npd_file } = sprintf("/tmp/_nagios_plugin_%s%s.tmp",
                                     File::Basename::basename($0),
                                     "_$self->{ _npd_id }");
    }
    bless $self, $class;
}

=head2 new_reading($data, [$ts])

Report a new reading. The reading has to be a hashref. You can optionally
pass the timestamp for the reading. If you don't pass $ts, the timestamp
of the invocation of the method will be used.

=cut

sub new_reading {
    my ($self, $data, $ts) = @_;
    croak "cannot store non-hashref data" if (ref($data) ne 'HASH');
    $ts = time() if (not defined $ts);

    $self->{'last'} = $self->{'current'} if (defined $self->{'current'});
    $self->{'current'} = { 'ts' => $ts, 'data' => $data };
}

=head2 persist([$file])

Write the stored data to the temporary file

=cut

sub persist {
    my ($self, $file) = @_;
    $file ||= $self->{'file'};
    Storable::lock_store($self->{'current'}, $file);
}

=head2 load_last([$file])

Load the last reading from the temporary file.

=cut

sub load_last {
    my ($self, $file) = @_;
    $file ||= $self->{'file'};
    $self->{'last'} = $self->{'current'} if (defined $self->{'current'});
    $self->{'current'} = Storable::retrieve($file);
}


#head2 difference_from_zero
#
#Calculate the difference between current and zero.
#
#cut
#
#sub difference_from_zero {
#    my ($self) = @_;
#    return ($self->{'current'}->{'data'});
#}

=head1 CALCULATING DIFFERENCES

=head2 difference

Calculates the difference between current reading and last reading.

=cut

sub difference {
    my ($self) = @_;

    die 'no new_reading' if (not defined $self->{'current'});
    die 'no last' if (not defined $self->{'last'});

    my $current_data = $self->{'current'}->{'data'};
    my $last_data    = $self->{'last'}->{'data'};
    my $delta = {};

    foreach my $item (keys %$last_data){
        # if we don't have item, $data_last->{ xxx } will be undef. The correct reading would be zero
        $delta->{ $item } = $current_data->{ $item } - ($last_data->{ $item } || 0);
    }
    return ($delta);
}

=head2 forward_difference($wrap_at)

=cut

sub forward_difference {
    my ($self, $wrap_at) = @_;

    die 'no new_reading' if (not defined $self->{'current'});
    die 'no last' if (not defined $self->{'last'});

    my $current_data = $self->{'current'}->{'data'};
    my $last_data    = $self->{'last'}->{'data'};
    my $delta = {};

    foreach my $item (keys %$last_data){
        if ($current_data->{ $item } >= $last_data->{ $item }){
            $delta->{ $item } = $current_data->{ $item } - ($last_data->{ $item } || 0);
        } else {
            # If the current reading is smaller than the last time we saw it, then we have to
            # take into account the wrap value.
            # time |=======|------------|===========|
            #      0      current       last        wrap
            $delta->{ $item } = ($wrap_at - $last_data->{ $item }) + $current_data->{ $item };
        }
    }
    return ($delta);
}

=head2 forward_difference_unknown_wrap

If the value of a key from the current reading is less than the last reading, the
difference will be taken from zero. This is handy when you are storing counters
that increment, but can be reset to zero.

=cut

sub forward_difference_unknown_wrap {
    my ($self) = @_;

    die 'no new_reading' if (not defined $self->{'current'});
    die 'no last' if (not defined $self->{'last'});

    my $current_data = $self->{'current'}->{'data'};
    my $last_data    = $self->{'last'}->{'data'};
    my $delta = {};

    foreach my $item (keys %$last_data){
        if ($current_data->{ $item } >= $last_data->{ $item }){
            $delta->{ $item } = $current_data->{ $item } - ($last_data->{ $item } || 0);
        } else {
            # If the current reading is smaller than the last time we saw it, then we have to
            # discard the last reading. The counter has been reset, and we cannot know what
            # happened between the last reading and the current one.
            # time |=======|------------|???????....
            #             current       last
            $delta->{ $item } = $current_data->{ $item };
        }
    }
    return ($delta);
}

=head2 rate($method, [params_to_method])

Calculate the rate of change (derive) between the current reading and the last reading.
To calculate rate of change, you need to calculate the change. The change gets calculated
with any of the "difference" methods

  $npd->rate('difference');

  $npd->rate('forward_difference', 1000);

  $npd->rate('forward_difference_unknown_wrap');

=cut

sub rate {
    my ($self, $method, @params_to_method) = @_;

    my $delta = $self->$method(@params_to_method);
    my $time = $self->{'current'}->{'ts'} - $self->{'last'}->{'ts'};

    my $rates = {};
    foreach my $item (keys %$delta){
        $rates->{$item} = $delta->{$item} / $time;
    }

    return $rates;
}

=head2 proportion(

Calculate the proportions of the values of one key respect to the total sum of all the values.

  proportion({ 'red' => 5, 'green' => 15 });
  # returns: { 'red' => 0.25, 'green' => 0.75 }

=cut

sub proportion {
    my ($self, $hashref) = @_;

    my $total = 0;
    map { $total += $_ } values %$hashref;

    my $proportion = {};
    foreach my $item (keys %$hashref){
        $proportion->{$item} = $hashref->{$item} / $total;
    }
    return($proportion);
}

1;


=head1 AUTHOR

JLMARTIN, C<< <jlmartinez at capside.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-nagios-plugin-differences at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Nagios-Plugin-Differences>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Nagios::Plugin::Differences

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Nagios-Plugin-Differences>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Nagios-Plugin-Differences>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Nagios-Plugin-Differences>

=item * Search CPAN

L<http://search.cpan.org/dist/Nagios-Plugin-Differences>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2009 Jose Luis Martinez Torres, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Nagios::Plugin::Differences
