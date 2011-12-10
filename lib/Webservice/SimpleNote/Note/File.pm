package Webservice::SimpleNote::Note::File;

# ABSTRACT: stores notes in plain files, with the metadata in YAML

# TODO: need to compare information between local and remote files when same title in both (e.g. simplenotesync.db lost, or collision)

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use YAML::Any qw/Dump LoadFile DumpFile/;

extends 'Webservice::SimpleNote::Note';

has file => (
    is       => 'rw',
    isa      => 'Path::Class::File',
    coerce   => 1,
);

has sync_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
);

MooseX::Storage::Engine->add_custom_type_handler(
    'Path::Class::File' => (
        expand => sub { Path::Class::File->new( $_[0]) },
        collapse => sub { $_[0]->stringify }
    )
);

MooseX::Storage::Engine->add_custom_type_handler(
    'Path::Class::Dir' => (
        expand => sub { Path::Class::Dir->new( $_[0]) },
        collapse => sub { $_[0]->stringify }
    )
);

sub _build_sync_dir {
    my $self = shift;
    if ( !-d $self->sync_dir ) {

        # Target directory doesn't exist
        die "Sync directory [" . $self->sync_dir . "] does not exist\n";
    }
}

# Convert note's title into file
sub title_to_filename {
    my ( $self, $title ) = @_;

    # Strip prohibited characters
    $title =~ s/\W/_/g;
    # TODO trim 
    my $file = $self->sync_dir->file("$title.txt");
    $self->logger->debug("Title [$title] => File [$file]");
    return $file;
}

# Convert filename into title and unescape special characters
sub filename_to_title {
    my ( $self, $file ) = @_;
    my $title = $file->basename;
    $title =~ s/\.txt$//;
    $self->logger->debug("File [$file] => Title [$title]");
    return $title;
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

sub _read_sync_database {
    my $self = shift;
    my $notes;

    try {
        $notes = LoadFile( $self->sync_db );
    };

    if ( !defined $notes ) {
        $self->logger->debug('No existing sync db');
        return;
    }

    $self->notes($notes);
    return 1;
}

sub _write_sync_database {
    my $self = shift;

    if ( !$self->allow_local_updates ) {
        return;
    }

    $self->logger->debug('Writing sync db');
    # XXX only write if changed? Add a dirty attr?
    DumpFile( $self->sync_db, $self->notes );
}

no Moose;
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
  