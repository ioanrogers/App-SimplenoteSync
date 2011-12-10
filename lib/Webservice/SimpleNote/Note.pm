package Webservice::SimpleNote::Note;

# ABSTRACT: represents an individual note

use v5.10;
use Moose;
use MooseX::Types::DateTime qw/DateTime/;
use MooseX::Storage;

with Storage( 'format' => 'JSON' );

# set by server
has key => (
    is  => 'rw',
    isa => 'Str',

    #required => 1,
);

# set by server
has [ 'sharekey', 'publishkey' ] => (
    is  => 'ro',
    isa => 'Str',
);

has title => (
    is  => 'rw',
    isa => 'Str',

    #required => 1,
);

has deleted => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has [ 'createdate', 'modifydate' ] => (
    is     => 'rw',
    isa    => DateTime,
    coerce => 1,
);

# set by server
has [ 'syncnum', 'version', 'minversion' ] => (
    is  => 'rw',
    isa => 'Int',
);

has tags => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

has systemtags => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },

    # pinned, unread, markdown, list
);

# XXX: always coerce to utf-8?
has content => (
    is  => 'rw',
    isa => 'Str',
);

MooseX::Storage::Engine->add_custom_type_handler(
    'DateTime' => (
        expand   => sub { DateTime->from_epoch( epoch => $_[0] ) },
        collapse => sub { $_[0]->epoch }
    )
);

# TODO: auto change title on content change?
sub _get_title_from_content {
    my $self = shift;

    my $content = $self->content;

    # First line is title
    $content =~ /(.+)/;
    my $title = $1;

    # Strip prohibited characters
    # XXX preferable encoding scheme?
    $title =~ s/\W/ /g;
    $title =~ s/^\s+//;
    $title =~ s/\s+$//;
    return $title;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
