package Webservice::SimpleNote::Storage;

# ABSTRACT: Handles storage of the notes and metadata

use v5.10;
use Moose;
use namespace::autoclean;

has logger => (
    is       => 'ro',
    isa      => 'Object',
    lazy     => 1,
    required => 1,
    default  => sub { return Log::Any->get_logger },
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;
