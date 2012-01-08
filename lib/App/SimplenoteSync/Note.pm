package App::SimplenoteSync::Note;

# ABSTRACT: stores notes in plain files,

# TODO: need to compare information between local and remote files when same title in both (e.g. simplenotesync.db lost, or collision)

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use namespace::autoclean;

extends 'WebService::Simplenote::Note';

has '+title' => (

    #    is  => 'rw',
    #    isa => 'Str',
    trigger => \&title_to_filename,
);

has file => (
    is      => 'rw',
    isa     => 'Path::Class::File',
    coerce  => 1,
    trigger => \&is_markdown,
);

has file_extension => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => ['DoNotSerialize'],
    default => sub {
        {
            default  => 'txt',
            markdown => 'mkdn',
        };
    }
);

# XXX should we serialise this?
has notes_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    traits   => ['DoNotSerialize'],
    required => 1,
    default  => sub { return $_[0]->file->dir },
);

MooseX::Storage::Engine->add_custom_type_handler(
    'Path::Class::File' => (
        expand   => sub { Path::Class::File->new( $_[0] ) },
        collapse => sub { $_[0]->stringify }
    )
);

# set the markdown systemtag if the file has a markdown extension
sub is_markdown {
    my $self = shift;

    # TODO an array of possibilities? e.g. mkdn, markdown, md
    # maybe from system mime info?
    my $ext = $self->file_extension->{markdown};
    warn "Looking for '$ext'\n";
    warn $self->file;
    if ( $self->file =~ m/\.$ext$/ ) {
        $self->systemtags( ['markdown'] );
        warn "IS MARKDOWN\n";
    }

    return 1;
}

# Convert note's title into file
sub title_to_filename {
    my ( $self, $title, $old_title ) = @_;

    # don't change if already set
    if ( defined $self->file ) {
        return;
    }

    # TODO trim
    my $file = $title;

    # non-word to underscore
    $file =~ s/\W/_/g;
    $file .= '.';

    if ( grep '/markdown/', @{ $self->systemtags } ) {
        $file .= $self->file_extension->{markdown};
        warn "TtoF is markdown\n";
    } else {
        $file .= $self->file_extension->{default};
        warn "TtoF is txt\n";
    }

    $self->file( $self->notes_dir->file( $file ) );

    return 1;
}

sub time_thingy {
    my ( $self, $file ) = @_;

    # my @d = gmtime( ( $file->stat) )[9] );
    # $file{$filepath}{modify} = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1,
    # $d[3], $d[2], $d[1], $d[0];

    # #         if ( $^O =~ /darwin/i ) {

    # #             # The following works on Mac OS X - need a "birth time", not ctime
    # # created time
    # @d = gmtime( readpipe("stat -f \"%B\" \"$filepath\"") );
    # } else {

    # #             # TODO: Need a better way to do this on non Mac systems
    # # get file's modification time
    # @d = gmtime( ( stat("$filepath") )[9] );
    # }

    # #         $file{$filepath}{create} = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $d[5] + 1900, $d[4] + 1,
    # $d[3], $d[2], $d[1], $d[0];
}

__PACKAGE__->meta->make_immutable;

1;

=head1 FEATURES

* Bidirectional synchronization between the Simplenote web site and a local
  directory of text files on your computer

* The ability to manipulate your notes (via the local text files) using other
  applications (e.g. [Notational Velocity](http://notational.net/) if you use
  "Plain Text Files" for storage, shell scripts, AppleScript, 
  [TaskPaper](http://www.hogbaysoftware.com/products/taskpaper), etc.) -
  you're limited only by your imagination
  
  * Certain characters are prohibited in filenames (:,\,/) - if present in the
  title, they are stripped out. (#TODO should be dependent on filesystem, surely?)
  
