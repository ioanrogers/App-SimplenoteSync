package App::SimplenoteSync::Note;

# ABSTRACT: stores notes in plain files,

use v5.10.1;
use Moo;
use MooX::Types::MooseLike::Base qw/:all/;
use Path::Class;
use Try::Tiny;
use Method::Signatures;
use Data::Printer;
extends 'WebService::Simplenote::Note';

# XXX Converting too Moo creates trigger issues! The title trigger is being fired
# before systemtags are set
#has '+title' => (trigger => \&_title_to_filename,);

# XXX trigger is always fired before file_extension is set
has file => (
    is  => 'rw',
    isa => InstanceOf ['Path::Class::File'],

    #trigger   => \&_has_markdown_ext,
    predicate => 'has_file',
    lazy      => 1,
);

has file_extension => (
    is      => 'ro',
    lazy    => 1,
    isa     => HashRef,
    default => sub {
        {
            default  => 'txt',
            markdown => 'mkdn',
        };
    },
);

has notes_dir => (
    is      => 'ro',
    lazy    => 1,
    isa     => InstanceOf ['Path::Class::Dir'],
    default => sub {
        my $self = shift;
        say "NOTES DIR?";
        if ($self->has_file) {
            say "FROM FILE: " . $self->file;
            return $self->file->dir;
        } else {
            return Path::Class::Dir->new($ENV{HOME}, 'Notes');
        }
    },
);

has ignored => (
    is      => 'rw',
    isa     => Bool,
    default => sub {0},
);

# set the markdown systemtag if the file has a markdown extension
method _has_markdown_ext (@_) {
    p $self;
    my $ext = $self->file_extension->{markdown};

    if ($self->file =~ m/\.$ext$/ && !$self->is_markdown) {
        $self->set_markdown;
    }

    return 1;
}

# Convert note's title into file
method _title_to_filename (@_) {
    say "TITLE TO FILENAME";
    p @_;

    # don't change if already set
    #if (defined $self->file) {
    #return;
    #}

    # TODO trim
    my $file = $self->title;

    # non-word to underscore
    $file =~ s/\W/_/g;
    $file .= '.';

    if ($self->is_markdown) {
        $file .= $self->file_extension->{markdown};
        $self->logger->debug('Note is markdown');
    } else {
        $file .= $self->file_extension->{default};
        $self->logger->debug('Note is plain text');
    }
    $self->file($self->notes_dir->file($file));

    return 1;
}

method load_content () {
    my $content;

    if (!$self->file) {
        $self->_title_to_filename;
    }

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

method save_content () {
    if (!$self->file) {
        $self->_title_to_filename;
    }
    try {
        my $fh = $self->file->open('w');

        # data from simplenote should always be utf8
        $fh->binmode(':utf8');
        $fh->print($self->content);
    }
    catch {
        $self->logger->error("Failed to write content to file: $_");
        return;
    };

    return 1;
}

around 'TO_JSON' => sub {
    my ($orig, $self) = @_;

    my $hash = $orig->($self);

    delete $hash->{notes_dir};
    delete $hash->{file};
    delete $hash->{file_extension};
    delete $hash->{ignored};

    return $hash;
};

1;
