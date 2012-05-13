package App::SimplenoteSync::Note;

# ABSTRACT: stores notes in plain files,

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use Try::Tiny;
use namespace::autoclean;

extends 'WebService::Simplenote::Note';

use Method::Signatures;

has '+title' => (trigger => \&_title_to_filename,);

has file => (
    is        => 'rw',
    isa       => 'Path::Class::File',
    coerce    => 1,
    traits    => ['NotSerialised'],
    trigger   => \&_has_markdown_ext,
    predicate => 'has_file',
);

has file_extension => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => ['NotSerialised'],
    default => sub {{
            default  => 'txt',
            markdown => 'mkdn',
    }},
);

has notes_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    traits   => ['NotSerialised'],
    required => 1,
    default  => sub {
        my $self = shift;
        if ($self->has_file) {
            return $self->file->dir;
        } else {
            return Path::Class::Dir->new($ENV{HOME}, 'Notes');
        }
    },
);

has ignored => (
    is      => 'rw',
    isa     => 'Bool',
    traits  => ['NotSerialised'],
    default => 0,
);

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
