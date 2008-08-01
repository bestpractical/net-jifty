#!/usr/bin/env perl
package Net::Jifty::Record;
use Moose;
use Net::Jifty;

has id => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has _interface => (
    is       => 'ro',
    isa      => 'Net::Jifty',
    required => 1,
);

has _model_class => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

=head2 update col1 => val1, col2 => val2, etc

Updates this record with the given arguments.

=cut

sub update {
    my $self = shift;
    $self->_interface->update(
        $self->_model_class,
        id => $self->id,
        @_,
    );
}

=head2 delete

Delete this record.

=cut

sub delete {
    my $self = shift;
    $self->_interface->delete(
        $self->_model_class,
        id => $self->id,
    );
}

=head2 load interface, ID
=head2 load interface, column => value

Class method that loads a particular record by ID (or any column, value). Returns the record or undef.

=cut

sub load {
    my $class     = shift;
    my $interface = shift;
    my ($column, $value);

    if (@_ > 2) {
        confess "load called with more than two arguments - it's currently limited to one (column, value) pair."
    }
    elsif (@_ == 2) {
        ($column, $value) = @_;
    }
    elsif (@_ == 1) {
        ($column, $value) = ('id', $_[0]);
    }
    else {
        confess "Please use load(interface, ID) or load(interface, column, value).";
    }

    my $hash = eval {
        $interface->read($class->_default_model_class, $column, $value)
    };
    warn $@ if $@;
    return undef if !$hash;

    # remove undef values (which trigger type constraint violations)
    for (keys %$hash) {
        delete $hash->{$_} if !defined($hash->{$_});
    }

    my $record = $class->new(
        _interface => $interface,
        %$hash,
    );

    return $record;
}

sub _default_model_class { shift->meta->get_attribute('_model_class')->default }

__PACKAGE__->meta->make_immutable;
no Moose;

1;

