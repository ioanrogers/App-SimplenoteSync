package Webservice::SimpleNote::Note;

# ABSTRACT: represents an individual note

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use MooseX::Types::DateTime qw/DateTime/;

# set by server
has key => (
    is  => 'ro',
    isa => 'Str',
    #required => 1,
);

# set by server
has ['sharekey', 'publishkey'] => (
    is  => 'ro',
    isa => 'Str',
);

has title => (
    is  => 'rw',
    isa => 'Str',
    #required => 1,
);

has deleted => (
    is  => 'ro',
    isa => 'Bool',
    default => 0,
);

has ['createdate', 'modifydate'] => (
    is => 'rw',
    isa => DateTime,
    coerce => 1,
);

# set by server
has ['syncnum', 'version', 'minversion'] => (
    is => 'rw',
    isa => 'Int',
);

has tags => (
    is => 'rw',
    isa => 'ArrayRef[Str]',
    default => sub { [] },
);

has systemtags => (
    is => 'rw',
    isa => 'ArrayRef[Str]',
    default => sub { [] },
    # pinned, unread, markdown, list
);

has file => (
    is       => 'rw',
    isa      => 'Path::Class::File',
    coerce   => 1,
);

has content => (
    is  => 'rw',
    isa => 'Str',
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;
