package App::SimplenoteSync;

# ABSTRACT: access and sync with simplenoteapp.com

# TODO: How to handle simultaneous edits?
# TODO: Windows compatibility?? This has not been tested AT ALL yet
# TODO: Further testing on Linux - mainly file creation time
# TODO: use file extension to determine if a note is markdown or not?

our $VERSION = '0.001';

use v5.10;
use Moose;
use MooseX::Types::Path::Class;
use namespace::autoclean;

use Log::Any qw//;
use DateTime;
use Try::Tiny;

use App::SimplenoteSync::Note;

has [ 'email', 'password' ] => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has notes => (
    is      => 'rw',
    isa     => 'HashRef[WebService::Simplenote::Note]',
    default => sub { {} },
);

has [ 'allow_server_updates', 'allow_local_updates' ] => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 1,
);

has logger => (
    is       => 'ro',
    isa      => 'Object',
    lazy     => 1,
    required => 1,
    default  => sub { return Log::Any->get_logger },
);

has sync_db => (
    is       => 'rw',
    isa      => 'Path::Class::File',
    coerce   => 1,
);

has sync_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
    metaclass => 'DoNotSerialize',
    trigger  => \&_check_sync_dir,
);

sub _check_sync_dir {
    my $self = shift;
    if ( -d $self->sync_dir ) {
        return;
    }
    $self->sync_dir->mkpath
        or die "Sync directory [" . $self->sync_dir . "] does not exist\n";
}

sub _read_sync_db {
    my $self = shift;
    my $notes;

    try {
        $notes = LoadFile( $self->sync_db );
    };

    if ( !defined $notes ) {
        $self->logger->debug('No existing sync db');
        return;
    }

    return $notes;
}

sub _write_sync_db {
    my $self = shift;

    if ( !$self->allow_local_updates ) {
        return;
    }

    $self->logger->debug('Writing sync db');
    # XXX only write if changed? Add a dirty attr?
    DumpFile( $self->sync_db, $self->notes );
}

# Save local copy of note from Simplenote server
sub get_note {
    my ( $self, $note ) = @_;

    $self->logger->infof( 'Retrieving note [%s]', $note->key );

    # XXX: anything to merge?
    $note = WebService::Simplenote::Note->new();

    $note->title( $self->_get_title_from_content( $note ) );
    $note->file( $self->title_to_filename( $note->title ) );

    if ( !$self->allow_local_updates ) {
        return;
    }
    my $fh = $note->file->open('w');
    $fh->print( $note->content );
    $fh->close;

    # Set created and modified time
    # XXX: Not sure why this has to be done twice, but it seems to on Mac OS X
    utime $note->createdate->epoch, $note->modifydate->epoch, $note->file;

    #utime $create, $modify, $filename;
    $self->notes->{$note->key} = $note;

    return 1;
}

sub delete_note {
    my ( $self, $note ) = @_;
    if ( !$self->allow_local_updates ) {
        return;
    }

    delete $self->notes->{$note->key};
    return 1;
}

sub merge_conflicts {

    # Both the local copy and server copy were changed since last sync
    # We'll merge the changes into a new master file, and flag any conflicts
    # TODO spawn some diff tool?
    my ( $self, $key ) = @_;

}

# if available, load syncdb, compare it to exsting text files, then get remote index,
# merge lists with any non indexed files, then ask for sync
sub get_local_notes {
    my ($self) = @_;
    
    $self->_read_sync_db;
    
    $self->logger->debugf( 'Scanning files in [%s]', $self->sync_dir->stringify );
    while ( my $f = $self->sync_dir->next ) {
        next unless -f $f;
        $self->logger->debug("Checking $f");
        my $is_known = 0;
        foreach my $note ( values %{ $self->notes } ) {
            $self->logger->debugf('Comparing [%s] to [%s]', $note->file->stringify, $f->stringify); 
            if ( $note->file eq $f ) {
                $is_known = 1;
                last;
            }
        }
        if (!$is_known) {
            $self->logger->info("New local file [$f]");
            my $content = $f->slurp; # TODO: iomode + encoding
            my $note = WebService::Simplenote::Note->new(
                createdate => $f->stat->ctime,
                modifydate => $f->stat->mtime,
                content    => $content,
                systemtags => ['markdown'],
                file       => $f,
            );

            $self->put_note($note);
        }
    }
    
    $self->_write_sync_database;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 LIMITATIONS

* If the simplenotesync.db file is lost, SimplenoteSync.pl is currently unable
  to realize that a text file and a note represent the same object --- instead
  you should move your local text files, do a fresh sync to download all notes
  locally, and manually replace any missing notes.

* Simplenote supports multiple notes with the same title, but two files cannot
  share the same filename. If you have two notes with the same title, only one
  will be downloaded. I suggest changing the title of the other note.

=head1 TROUBLESHOOTING

Optionally, you can enable or disable writing changes to either the local
directory or to the Simplenote web server. For example, if you want to attempt
to copy files to your computer without risking your remote data, you can
disable "$allow_server_updates". Or, you can disable "$allow_local_updates" to
protect your local data.

=head1 KNOWN ISSUES

* No merging when both local and remote file are changed between syncs - this
  might be enabled in the future

=head1 SEE ALSO

Designed for use with Simplenote:

<http://www.simplenoteapp.com/>

Based on SimplenoteSync:

<http://fletcherpenney.net/other_projects/simplenotesync/>
