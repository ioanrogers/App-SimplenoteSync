package App::SimplenoteSync::Note;

# ABSTRACT: stores notes in plain files,

# TODO: need to compare information between local and remote files when same title in both (e.g. simplenotesync.db lost, or collision)

use v5.10;
use Moose;
use MooseX::Types::Path::Class;

extends 'WebService::Simplenote::Note';

has file => (
    is       => 'rw',
    isa      => 'Path::Class::File',
    coerce   => 1,
);

has file_extensions => (
    is => 'ro',
    isa => 'HashRef',
    metaclass => 'DoNotSerialize',
    default => sub {
        {
            default  => 'txt',
            markdown => 'mkdn',
        }
    }
);

MooseX::Storage::Engine->add_custom_type_handler(
    'Path::Class::File' => (
        expand => sub { Path::Class::File->new( $_[0]) },
        collapse => sub { $_[0]->stringify }
    )
);

# Convert note's title into file
sub title_to_filename {
    my ( $self, $title ) = @_;

    
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
  