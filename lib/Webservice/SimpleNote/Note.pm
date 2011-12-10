package Webservice::SimpleNote::Note;

# ABSTRACT: represents an individual note

use v5.10;
use Moose;
use MooseX::Types::DateTime qw/DateTime/;
use MooseX::Storage;

with Storage('format' => 'JSON');

# set by server
has key => (
    is  => 'rw',
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

# XXX: always coerce to utf-8?
has content => (
    is  => 'rw',
    isa => 'Str',
);

MooseX::Storage::Engine->add_custom_type_handler(
    'DateTime' => (
        expand => sub { DateTime->from_epoch( epoch => $_[0]) },
        collapse => sub { $_[0]->epoch }
    )
);

# If title is too long, it won't be a valid filename
sub trim_title {
    my ( $self, $title ) = @_;
    $title =~ s/^(.{1,240}).*?$/$1/;
    $title =~ s/(.*)\s.*?$/$1/;        # Try to trim at a word boundary

    return $title;
}

sub _get_title_from_content {
    my ( $self, $note ) = @_;
    
    my $content = $note->content;
    
    # TODO look for first line which contains some \w
    # Parse into title and content (if present)
    $content =~ s/^(.*?)(\n{1,2}|\Z)//s;    # First line is title
    my $title   = $1;
    my $divider = $2;

    # If first line is particularly long, it will get trimmed, so
    # leave it in body, and make a short version for the title
    if ( length($title) > 240 ) {

        # Restore first line to content and create new title
        $content = $title . $divider . $content;
        $title   = $self->trim_title($title);
    }

    return $title;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
