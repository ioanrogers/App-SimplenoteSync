package App::SimplenoteSync::Note;

# ABSTRACT: stores notes in plain files,

use v5.10;
use Moose;
use Method::Signatures;
use MooseX::Types::Path::Class;
use Try::Tiny;
use namespace::autoclean;

extends 'WebService::Simplenote::Note';

has '+title' => (trigger => \&_title_to_filename,);

has file => (
    is      => 'rw',
    isa     => 'Path::Class::File',
    coerce  => 1,
    trigger => \&_has_markdown_ext,
);

has file_extension => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => ['DoNotSerialize'],
    default => sub {{
            default  => 'txt',
            markdown => 'mkdn',
    }},
);

has notes_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    traits   => ['DoNotSerialize'],
    required => 1,
    default  => sub { return $_[0]->file->dir },
);

has ignored => (
    is      => 'rw',
    isa     => 'Bool',
    traits  => ['DoNotSerialize'],
    default => 0,
);

MooseX::Storage::Engine->add_custom_type_handler(
    'Path::Class::File' => (
        expand   => sub { Path::Class::File->new($_[0]) },
        collapse => sub { $_[0]->stringify }));

# set the markdown systemtag if the file has a markdown extension
method _has_markdown_ext(@_) {
    my $ext = $self->file_extension->{markdown};

    if ($self->file =~ m/\.$ext$/ && !$self->is_markdown) {
        $self->set_markdown;
    }

    return 1;
}

# Convert note's title into file
method _title_to_filename(Str $title, Str $old_title?) {

    # don't change if already set
    if (defined $self->file) {
        return;
    }

    # TODO trim
    my $file = $title;

    # non-word to underscore
    $file =~ s/\W/_/g;
    $file .= '.';

    if (grep '/markdown/', @{$self->systemtags}) {
        $file .= $self->file_extension->{markdown};
        $self->logger->debug('Note is markdown');
    } else {
        $file .= $self->file_extension->{default};
        $self->logger->debug('Note is plain text');
    }

    $self->file($self->notes_dir->file($file));

    return 1;
}

method load_content {
    my $content;

    try {
        $content = $self->file->slurp(iomode => '<:utf8');
    }
    catch {
        $self->logger->error("Failed to read file: $_");
        return;
    };

    $self->content($content);
    return 1;

}

__PACKAGE__->meta->make_immutable;

1;
